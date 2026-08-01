package com.pipilot.pi_pilot

import android.content.Context
import android.content.SharedPreferences
import android.util.Log

/// 去重表的存储抽象。
///
/// 抽出来的唯一目的是可测:SharedPreferences 在纯 JVM 单元测试里不可用,
/// 而去重逻辑(状态只向前、stale pending 可重试、超量清理)正是最需要
/// 被测试覆盖的部分。生产实现是 SharedPreferences,测试注入内存实现。
interface DedupeStorage {
    fun get(key: String): String?
    fun put(key: String, value: String)
    fun remove(keys: Collection<String>)
    fun entries(): Map<String, String>
    fun clear()
}

/// SharedPreferences 实现。
///
/// 为什么不用 Room/SQLite:表很小(默认 2048 条上限),且必须在 FCM
/// onMessageReceived 回调里同步读写 —— 那个回调只有有界时间,
/// 不能等异步数据库初始化。
class PrefsDedupeStorage(context: Context, prefsName: String) : DedupeStorage {
    private val prefs: SharedPreferences =
        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)

    override fun get(key: String): String? = prefs.getString(key, null)

    override fun put(key: String, value: String) {
        prefs.edit().putString(key, value).apply()
    }

    override fun remove(keys: Collection<String>) {
        if (keys.isEmpty()) return
        val editor = prefs.edit()
        for (key in keys) editor.remove(key)
        editor.apply()
    }

    @Suppress("UNCHECKED_CAST")
    override fun entries(): Map<String, String> =
        prefs.all.filterValues { it is String } as Map<String, String>

    override fun clear() {
        prefs.edit().clear().apply()
    }
}

/// 内存实现,仅供测试与无持久化降级路径使用。
class InMemoryDedupeStorage : DedupeStorage {
    private val map = linkedMapOf<String, String>()
    override fun get(key: String): String? = map[key]
    override fun put(key: String, value: String) {
        map.remove(key)
        map[key] = value
    }
    override fun remove(keys: Collection<String>) {
        for (key in keys) map.remove(key)
    }
    override fun entries(): Map<String, String> = LinkedHashMap(map)
    override fun clear() = map.clear()
}

/// 通知在本机的处理状态。
///
/// 为什么不是「exactly-once」:claim()、NotificationManager.notify() 和
/// 状态落盘是三个独立操作,无法置于同一原子事务。崩溃窗口里只有两种可能 ——
/// 先落盘后 notify 则崩溃即丢通知,先 notify 后落盘则崩溃即重复。
/// 所以这里承认重复,靠 stableNotificationId + onlyAlertOnce 把重复
/// 变成「静默更新同一条通知」,用户侧仍只被打扰一次。
/// 见 stable-plan.md §2.1/§2.2。
enum class DeliveryState {
    /// 已 claim,尚未调用 notify()。崩溃停在这里的允许重试。
    PENDING,

    /// 已调用 notify()。注意:这不代表用户看见了 ——
    /// 渠道被关、权限被撤、系统限流都可能让它不可见。
    DISPLAY_REQUESTED,

    /// notify() 后确认该 id 出现在 activeNotifications 里。
    /// 只有这个状态才计入 SLO 分子。
    DISPLAY_CONFIRMED,

    /// 已显示过的事件再次到达,静默跳过。
    SUPPRESSED_DUPLICATE,

    /// 通知权限或渠道被关闭,无法显示。
    BLOCKED,
    ;

    /// 状态只向前推进。迟到的乱序回执不能把状态降级,
    /// 否则会误判成「还没显示」而重复打扰用户。
    fun rank(): Int = when (this) {
        PENDING -> 1
        DISPLAY_REQUESTED -> 2
        SUPPRESSED_DUPLICATE -> 3
        DISPLAY_CONFIRMED -> 4
        BLOCKED -> 4
    }
}

data class DeliveryRecord(
    val eventId: String,
    val state: DeliveryState,
    val notificationId: Int,
    val at: Long,
)

/// 通知去重表。
///
/// 唯一键是 `installationId + bridgeInstallationId + eventId`:
/// 同一台手机上,同一个 Bridge 的同一个事件只处理一次。
/// 换 Bridge 或重装应用都应产生独立的记录空间。
///
/// 存储用 SharedPreferences 而非 Room/SQLite:表很小(默认上限 2048 条),
/// 且必须在 FCM 回调里同步读写 —— 那个回调只有有界时间,不能等异步数据库。
class NotificationDeduplicator(
    private val storage: DedupeStorage,
    private val maxEntries: Int = MAX_ENTRIES,
    private val retentionMs: Long = RETENTION_MS,
    private val now: () -> Long = { System.currentTimeMillis() },
) {
    companion object {
        private const val TAG = "PiPilotNotifyDedupe"
        const val PREFS = "pipilot_notification_dedupe_v1"
        private const val MAX_ENTRIES = 2_048
        private const val RETENTION_MS = 7L * 24 * 60 * 60 * 1000

        /// 记录格式版本。降级安装读到更高版本时按「无记录」处理。
        private const val RECORD_SCHEMA = "1"
        /// 单元分隔符。枚举名与数字都不可能包含它。
        private const val FIELD_SEP = "\u001f"

        /// 生产入口:用 SharedPreferences 存储。
        fun create(context: Context): NotificationDeduplicator =
            NotificationDeduplicator(PrefsDedupeStorage(context, PREFS))
    }

    private fun key(scope: String, eventId: String): String = "$scope\u0000$eventId"

    /// 尝试占用这个事件。返回 null 表示已被处理过(调用方应跳过渲染),
    /// 返回记录表示可以继续显示。
    ///
    /// claim 后崩溃、display 前崩溃时,记录停在 PENDING —— 重启后允许重试,
    /// 不能永久吞掉通知。重试可能造成重复,由 onlyAlertOnce 吸收。
    @Synchronized
    fun claim(scope: String, eventId: String, notificationId: Int): DeliveryRecord? {
        val existing = read(scope, eventId)
        if (existing != null) {
            when (existing.state) {
                DeliveryState.PENDING -> {
                    // 上次崩在 claim 与 notify 之间,允许重试。
                    Log.i(TAG, "retrying stale pending event ${shortId(eventId)}")
                }
                DeliveryState.DISPLAY_REQUESTED,
                DeliveryState.DISPLAY_CONFIRMED,
                DeliveryState.SUPPRESSED_DUPLICATE,
                DeliveryState.BLOCKED,
                -> return null
            }
        }
        val record = DeliveryRecord(eventId, DeliveryState.PENDING, notificationId, now())
        write(scope, record)
        return record
    }

    @Synchronized
    fun markState(scope: String, eventId: String, state: DeliveryState): DeliveryRecord? {
        val existing = read(scope, eventId) ?: return null
        // 状态只向前:已 DISPLAY_CONFIRMED 的不能被迟到的 DISPLAY_REQUESTED 覆盖。
        if (existing.state.rank() > state.rank()) return existing
        val next = existing.copy(state = state, at = now())
        write(scope, next)
        return next
    }

    @Synchronized
    fun read(scope: String, eventId: String): DeliveryRecord? {
        val raw = storage.get(key(scope, eventId)) ?: return null
        return decode(eventId, raw)
    }

    private fun write(scope: String, record: DeliveryRecord) {
        storage.put(key(scope, record.eventId), encode(record))
        pruneIfNeeded()
    }

    /// 清理过期与超量记录。清理时保留仍可能在通知栏里的映射 ——
    /// 删掉正在显示的通知的 ID 映射会让后续更新变成新弹一条。
    private fun pruneIfNeeded() {
        val all = storage.entries()
        if (all.size <= maxEntries) return
        val cutoff = now() - retentionMs
        val doomed = mutableListOf<String>()
        val candidates = mutableListOf<Pair<String, Long>>()
        for ((mapKey, value) in all) {
            val at = timestampOf(value)
            if (at == null) {
                doomed.add(mapKey)
                continue
            }
            if (at < cutoff) doomed.add(mapKey) else candidates.add(mapKey to at)
        }
        // 仍然超量:丢最老的。清理不删仍可能在通知栏里的映射 ——
        // 删掉正在显示的通知的 ID 映射会让后续更新变成新弹一条。
        val overflow = candidates.size - maxEntries
        if (overflow > 0) {
            candidates.sortBy { it.second }
            for (i in 0 until overflow) doomed.add(candidates[i].first)
        }
        storage.remove(doomed)
        if (doomed.isNotEmpty()) Log.i(TAG, "pruned ${doomed.size} dedupe records")
    }

    @Synchronized
    fun clear() {
        storage.clear()
    }

    fun size(): Int = storage.entries().size

    /// 记录编码。刻意不用 JSONObject:
    ///  1. onMessageReceived 只有有界时间,少一层解析更稳。
    ///  2. org.json 在 JVM 单元测试里是 stub(调用即抛 not mocked),
    ///     用它会让去重逻辑 —— 恰恰是最该被测的部分 —— 无法测试。
    /// 三个字段全是受控值域(枚举名/整数/时间戳),不含用户输入,
    /// 所以定长分隔符编码是安全的。
    private fun encode(record: DeliveryRecord): String =
        "$RECORD_SCHEMA$FIELD_SEP${record.state.name}$FIELD_SEP" +
            "${record.notificationId}$FIELD_SEP${record.at}"

    private fun decode(eventId: String, raw: String): DeliveryRecord? {
        val parts = raw.split(FIELD_SEP)
        if (parts.size != 4 || parts[0] != RECORD_SCHEMA) {
            Log.w(TAG, "dropping malformed dedupe record for ${shortId(eventId)}")
            return null
        }
        val state = try {
            DeliveryState.valueOf(parts[1])
        } catch (_: IllegalArgumentException) {
            // 未知状态名(降级安装读到新版记录):当作没有,宁可重复一次。
            Log.w(TAG, "unknown delivery state in record for ${shortId(eventId)}")
            return null
        }
        val nid = parts[2].toIntOrNull() ?: return null
        val at = parts[3].toLongOrNull() ?: return null
        return DeliveryRecord(eventId = eventId, state = state, notificationId = nid, at = at)
    }

    private fun timestampOf(raw: String): Long? {
        val parts = raw.split(FIELD_SEP)
        if (parts.size != 4) return null
        return parts[3].toLongOrNull()
    }
}

/// 由 eventId 推导稳定通知 ID。
///
/// 这是「同一事件最多打扰一次」的核心:所有投递路径(原生 LAN、FCM、Dart)
/// 对同一 eventId 必然算出同一个 ID,于是重复投递落到同一个通知槽位,
/// 系统行为是替换而非新增。配合 setOnlyAlertOnce(true),第二次不再震动/响铃。
///
/// 必须避开 FGS 常驻通知的固定 ID 1(KeepAliveService.notificationId)。
object StableNotificationId {
    /// 保留区间:1 是 FGS 常驻通知,2-99 留给将来的固定用途通知。
    private const val RESERVED_CEILING = 100

    fun forEvent(eventId: String): Int {
        // FNV-1a:实现简单、无需依赖、分布足够均匀。
        var hash = -0x7ee3623bL // 2166136261 as signed
        for (byte in eventId.toByteArray()) {
            hash = hash xor (byte.toLong() and 0xff)
            hash *= 16777619L
            hash = hash and 0xffffffffL
        }
        val positive = (hash and 0x7fffffffL).toInt()
        // 映射到 [RESERVED_CEILING, Int.MAX_VALUE)
        val span = Int.MAX_VALUE - RESERVED_CEILING
        return RESERVED_CEILING + (positive % span)
    }
}

internal fun shortId(value: String): String =
    if (value.length <= 8) value else value.substring(0, 8)
