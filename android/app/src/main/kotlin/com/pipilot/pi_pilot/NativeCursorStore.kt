package com.pipilot.pi_pilot

import android.content.Context
import android.content.SharedPreferences
import android.util.Log

/// 通知消费位点。
///
/// 与旧的 source cursor 严格区分:那个绑 hubId(进程级,Bridge 重启即失效),
/// 这个绑 bridgeInstallationId + eventEpoch(跨重启稳定)。
/// 键必须包含 installationId,否则同一台 Bridge 的多台手机会互相推进游标。
data class NotificationCursor(
    val bridgeInstallationId: String,
    val eventEpoch: String,
    /// 已安全处理的最高连续 sequence。排他语义:through=130 表示 1..130 都处理完了。
    val through: Long,
)

/// cursor 的持久化抽象。抽出来同样是为了纯 JVM 可测。
interface CursorStorage {
    fun get(key: String): String?
    fun put(key: String, value: String)
    fun remove(key: String)
    fun keys(): Set<String>
}

class PrefsCursorStorage(context: Context, prefsName: String) : CursorStorage {
    private val prefs: SharedPreferences =
        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)

    override fun get(key: String): String? = prefs.getString(key, null)

    override fun put(key: String, value: String) {
        // commit 而非 apply:cursor 落盘失败会导致重复通知或漏通知,
        // 必须同步确认写入。这条路径调用频率低(每次 ack 一次),开销可接受。
        prefs.edit().putString(key, value).commit()
    }

    override fun remove(key: String) {
        prefs.edit().remove(key).commit()
    }

    override fun keys(): Set<String> = prefs.all.keys
}

class InMemoryCursorStorage : CursorStorage {
    private val map = mutableMapOf<String, String>()
    override fun get(key: String): String? = map[key]
    override fun put(key: String, value: String) {
        map[key] = value
    }
    override fun remove(key: String) {
        map.remove(key)
    }
    override fun keys(): Set<String> = map.keys.toSet()
}

/// 持久通知 cursor。
///
/// 这是替换 `notification_controller.dart:158` 的 `_streamingWhenBackgrounded`
/// 和 `WatcherTaskState` 进程内存态的关键:那两个都是内存字段,进程被杀后归零,
/// 于是「后台期间发生过 streaming -> idle」这件事无从证明。
/// 持久 cursor 让重连后能从 Bridge 精确补齐,不依赖任何内存基线。
class NativeCursorStore(
    private val storage: CursorStorage,
    private val installationId: String,
) {
    companion object {
        private const val TAG = "PiPilotCursor"
        const val PREFS = "pipilot_notification_cursor_v1"
        private const val SCHEMA = "1"
        private const val FIELD_SEP = "\u001f"

        fun create(context: Context, installationId: String): NativeCursorStore =
            NativeCursorStore(PrefsCursorStorage(context, PREFS), installationId)
    }

    private fun key(bridgeInstallationId: String): String =
        "$installationId$FIELD_SEP$bridgeInstallationId"

    fun read(bridgeInstallationId: String): NotificationCursor? {
        val raw = storage.get(key(bridgeInstallationId)) ?: return null
        val parts = raw.split(FIELD_SEP)
        if (parts.size != 3 || parts[0] != SCHEMA) {
            Log.w(TAG, "dropping malformed cursor for ${shortId(bridgeInstallationId)}")
            return null
        }
        val through = parts[2].toLongOrNull() ?: return null
        return NotificationCursor(bridgeInstallationId, parts[1], through)
    }

    /// 写入 cursor。只允许前进,除非 epoch 变了。
    ///
    /// 不允许回退的理由:回退会让已经显示过的事件被重新拉取并再次通知。
    /// epoch 变化是唯一例外 —— 那意味着 Bridge 的事件库被重置,
    /// 旧 sequence 已无意义,必须接受新 epoch 的位点。
    fun advance(cursor: NotificationCursor): Boolean {
        val existing = read(cursor.bridgeInstallationId)
        if (existing != null &&
            existing.eventEpoch == cursor.eventEpoch &&
            existing.through >= cursor.through
        ) {
            return false
        }
        val encoded = "$SCHEMA$FIELD_SEP${cursor.eventEpoch}$FIELD_SEP${cursor.through}"
        storage.put(key(cursor.bridgeInstallationId), encoded)
        return true
    }

    /// cursor 过期后 rebase 到 Bridge 给出的最早可用位点。
    ///
    /// 这里刻意写成显式方法而不是复用 advance:rebase 意味着中间有一段
    /// 历史事件永久丢失了,调用方必须记录这个缺口并在诊断页显示,
    /// 不能当成一次正常的推进。
    fun rebase(bridgeInstallationId: String, eventEpoch: String, oldestAvailable: Long): Long {
        val previous = read(bridgeInstallationId)
        val newThrough = maxOf(0L, oldestAvailable - 1)
        val encoded = "$SCHEMA$FIELD_SEP$eventEpoch$FIELD_SEP$newThrough"
        storage.put(key(bridgeInstallationId), encoded)
        val gap = if (previous == null || previous.eventEpoch != eventEpoch) {
            0L
        } else {
            maxOf(0L, newThrough - previous.through)
        }
        if (gap > 0) {
            Log.w(TAG, "cursor rebased past $gap event(s) for ${shortId(bridgeInstallationId)}")
        }
        return gap
    }

    /// Bridge 身份变了(重装/配置被清空):旧 cursor 成为孤儿。
    /// 不静默接管也不静默丢弃 —— 让调用方提示用户确认重新配对。
    fun orphan(bridgeInstallationId: String) {
        storage.remove(key(bridgeInstallationId))
    }

    fun knownBridges(): List<String> =
        storage.keys()
            .filter { it.startsWith("$installationId$FIELD_SEP") }
            .map { it.substringAfter("$installationId$FIELD_SEP") }
}

/// 连续前缀累加器。
///
/// ack 只能推进到「已收到事件 + Bridge 明确声明的 skipped range」构成的
/// 最高连续前缀。先收到 130 但缺 129 时绝不能 ack 130 ——
/// 那会让 129 永久丢失。见 stable-plan.md §7.4。
class ContiguousPrefix(private var through: Long) {
    private val received = sortedSetOf<Long>()

    fun current(): Long = through

    /// 采信 Bridge 声明的页起点。
    ///
    /// Bridge 在每页里给出 fromExclusive:本页从这个位点之后开始。若本地
    /// through 落后于它,说明这段区间要么已在上一次 catch-up 里确认过,要么
    /// 被服务端按 scope/TTL 判定为不必投递 —— 两种情况都不会再有事件到达。
    /// 不对齐的话:实时推送的 seq=N 与本地 through=0 永远不连续,drain() 推不动,
    /// ack 因 through<=0 被跳过,cursor 永久卡在 0(实测复现)。
    fun rebaseTo(fromExclusive: Long) {
        if (fromExclusive <= through) return
        through = fromExclusive
        // 丢掉已被新起点覆盖的悬挂 sequence,否则 hasGap() 会假报缺口。
        received.removeIf { it <= through }
        drain()
    }

    /// 收到一个 sequence。
    fun accept(sequence: Long) {
        if (sequence <= through) return
        received.add(sequence)
        drain()
    }

    /// Bridge 声明某个区间被 scope 排除或已被 TTL 回收。
    /// 这些 sequence 永远不会到达,必须计入连续性,否则 cursor 永久卡住。
    fun acceptSkipped(from: Long, throughInclusive: Long) {
        var seq = maxOf(from, through + 1)
        while (seq <= throughInclusive) {
            received.add(seq)
            seq++
        }
        drain()
    }

    private fun drain() {
        while (received.remove(through + 1)) {
            through++
        }
    }

    /// 是否存在缺口(收到了更高的 sequence 但中间有洞)。
    /// 有缺口时应停止 ack 并请求 resync。
    fun hasGap(): Boolean = received.isNotEmpty()

    fun pendingCount(): Int = received.size
}
