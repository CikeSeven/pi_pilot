package com.pipilot.pi_pilot

import android.content.Context
import org.json.JSONObject

/// 传输无关的通知协议引擎(stable-plan.md §7,remote_hint_v1 核心)。
///
/// 抽取自 BridgeWatcher 与 LanConnectionCoordinator 两份近乎相同的协议代码:
/// 帧从哪条传输进来(LAN ws / P2P DataChannel / 未来推送回连)都一样,
/// 协议处理、cursor、去重、展示只有一份 —— advisor 明确要求不在 Dart 复制
/// cursor/去重逻辑,也不让两份 Kotlin 各自演化。
///
/// 职责划分:
/// - 引擎:hello 能力判定与身份守卫、订阅、分页、skippedRanges 连续性、
///   批量静默投递、receipt、连续前缀 ack、cursor_expired/resync/scope_changed。
/// - 传输(各 owner):socket 生命周期、重连、legacy 回退、KeepAliveService
///   状态、把出站帧真正发出去。
///
/// 线程:与两个 owner 的现状一致,所有方法在调用方(socket 读)线程执行;
/// ready 回调统一 post 到主线程。
class NotificationProtocolEngine(
    context: Context,
    private val installationId: String,
    private val diagPrefix: String,
    private val identityStore: IdentityStore? = null,
) {
    /// 身份守卫(coordinator 的 NSD 自愈需要,其他传输传 null 跳过)。
    /// 认证身份与持久值不符时绝不改写 endpoint;首次连接才学习落盘。
    interface IdentityStore {
        fun persistedBridgeId(): String?
        fun adopt(bridgeId: String)
    }

    enum class HelloOutcome {
        /// 协议可用且已订阅 —— 传输不要再发 hub_select_source 之类旧帧。
        SUBSCRIBED,

        /// 旧 Bridge 没有 notification_events_v1 —— 传输自行决定 legacy 回退。
        LEGACY,

        /// 认证身份与持久值冲突 —— 传输应关连接,绝不能改写 endpoint。
        IDENTITY_CONFLICT,
    }

    private val appContext = context.applicationContext
    private val gate = NotificationGate(
        NotificationDeduplicator.create(appContext),
        NativeNotificationRenderer(appContext),
    )
    // installationId 已是每安装稳定值(nativeWatcherClientId 由 appClientId+deviceId
    // 派生);LAN 与 P2P 路径必须用同一个,否则 Bridge 当成两台 installation、
    // 各自一套 cursor,同一事件会通知两次。
    private val cursors = NativeCursorStore.create(appContext, installationId)

    private val outbound = ArrayDeque<String>()
    private val postedNotificationIds = mutableSetOf<Int>()

    /// 每次 start 由传输刷新(通知开关页可改)。
    @Volatile var vibrate: Boolean = false

    @Volatile var readyListener: ((Boolean) -> Unit)? = null

    /// cursor_expired 导致的 rebase 通知(coordinator 要记 cursor_recovery 指标)。
    @Volatile var cursorRebaseListener: ((gap: Long, oldest: Long) -> Unit)? = null

    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

    var notificationProtocol = false
        private set
    var bridgeInstallationId: String? = null
        private set
    var eventEpoch: String? = null
        private set
    var isReady = false
        private set

    private var prefix: ContiguousPrefix? = null

    /// 当前已持久化的 cursor 位置;无 cursor 时 -1(诊断页用)。
    fun cursorThroughForDebug(): Long =
        bridgeInstallationId?.let { cursors.read(it)?.through } ?: -1L

    /// 处理 bridge_hello。suffix 用于订阅请求 id(各传输带自己的 run/generation
    /// 前缀,便于把响应帧对回本次连接)。
    @Synchronized
    fun onHello(frame: JSONObject, suffix: String): HelloOutcome {
        val caps = frame.optJSONArray("capabilities")
        val supportsEvents = (0 until (caps?.length() ?: 0))
            .any { caps?.optString(it) == "notification_events_v1" }
        val helloBridgeId = frame.optString("bridgeInstallationId").takeIf { it.isNotEmpty() }
        val helloEpoch = frame.optString("eventEpoch").takeIf { it.isNotEmpty() }

        notificationProtocol = supportsEvents && helloBridgeId != null && helloEpoch != null
        if (!notificationProtocol || helloBridgeId == null || helloEpoch == null) {
            WatcherDiagnostics.log("$diagPrefix: bridge lacks notification_events_v1")
            return HelloOutcome.LEGACY
        }

        val store = identityStore
        if (store != null) {
            val persistedId = store.persistedBridgeId()
            if (persistedId != null && persistedId != helloBridgeId) {
                ConnectionMetrics.record(appContext, "identity_conflict")
                WatcherDiagnostics.log(
                    "$diagPrefix identity_conflict(persisted=${persistedId.take(14)} hello=${helloBridgeId.take(14)})",
                )
                setReady(false)
                return HelloOutcome.IDENTITY_CONFLICT
            }
            if (persistedId == null) {
                store.adopt(helloBridgeId)
                WatcherDiagnostics.log("$diagPrefix identity adopted(${helloBridgeId.take(14)})")
            }
        }

        bridgeInstallationId = helloBridgeId
        eventEpoch = helloEpoch
        subscribeNotifications(suffix, helloBridgeId, helloEpoch)
        return HelloOutcome.SUBSCRIBED
    }

    /// 喂入一帧。返回 true 表示被通知协议消费;false 由传输自行处理
    /// (如 watcher 的 legacy streaming 边沿、hub_* 会话帧)。
    ///
    /// notification_subscribe / notification_next_page 的首页数据在
    /// response.data 里,不是独立的 notification_events 帧 —— 漏掉的后果是
    /// cursor 永久卡死(真机踩过),所以 response 解包必须在这里。
    @Synchronized
    fun onFrame(frame: JSONObject): Boolean {
        val type = frame.optString("type")
        if (type == "response") {
            val data = frame.optJSONObject("data") ?: return false
            if (!data.optString("type").startsWith("notification_")) return false
            onNotificationFrame(data)
            return true
        }
        if (!type.startsWith("notification_")) return false
        onNotificationFrame(frame)
        return true
    }

    /// 取走排队中的出站帧(subscribe/next_page/ack/receipt),传输负责发送。
    @Synchronized
    fun pollOutbound(): List<String> {
        if (outbound.isEmpty()) return emptyList()
        val frames = outbound.toList()
        outbound.clear()
        return frames
    }

    /// 传输断开:立刻撤 ready,让 Dart 恢复兜底,不留空窗。
    @Synchronized
    fun onTransportClosed() {
        setReady(false)
    }

    /// owner 停止:清协议状态,撤 ready。传输自行处理 socket 与重连。
    @Synchronized
    fun reset() {
        bridgeInstallationId = null
        eventEpoch = null
        notificationProtocol = false
        prefix = null
        outbound.clear()
        setReady(false)
    }

    /// owner 停止时撤掉自己弹过的通知。
    fun cancelPostedNotifications() {
        if (postedNotificationIds.isEmpty()) return
        val manager = appContext.getSystemService(android.app.NotificationManager::class.java)
        for (id in postedNotificationIds) manager?.cancel(id)
        postedNotificationIds.clear()
    }

    /// 旧路径(无 notification_events_v1 的 Bridge)的合成完成通知:
    /// 没有权威 eventId,由传输合成稳定键,仍走同一去重表与渲染入口。
    fun deliverSynthesized(scope: String, event: RenderableEvent): DeliveryState {
        val state = gate.deliver(scope, event)
        if (state == DeliveryState.DISPLAY_REQUESTED || state == DeliveryState.DISPLAY_CONFIRMED) {
            postedNotificationIds.add(StableNotificationId.forEvent(event.collapseKey ?: event.eventId))
        }
        return state
    }

    private fun onNotificationFrame(frame: JSONObject) {
        when (frame.optString("type")) {
            "notification_events" -> handleNotificationEvents(frame)

            // 只有这一帧才代表原生层真正接管了通知。
            "notification_ready" -> {
                setReady(true)
                ackCursor()
            }

            "notification_cursor_expired" -> {
                val bridgeId = bridgeInstallationId ?: return
                val epoch = frame.optString("eventEpoch").takeIf { it.isNotEmpty() } ?: return
                val oldest = frame.optLong("oldestAvailable", 1L)
                // rebase 意味着中间一段历史永久丢失,如实记录缺口而不是假装补齐。
                val gap = cursors.rebase(bridgeId, epoch, oldest)
                eventEpoch = epoch
                prefix = ContiguousPrefix(maxOf(0L, oldest - 1))
                cursorRebaseListener?.invoke(gap, oldest)
                WatcherDiagnostics.log(
                    "$diagPrefix cursor expired reason=${frame.optString("reason")} gap=$gap; rebased to ${oldest - 1}",
                )
                // rebase 后重新订阅,拿到新的固定 tip。
                subscribeNotifications("rebase-${System.currentTimeMillis()}", bridgeId, epoch)
            }

            "notification_resync_required", "notification_scope_changed" -> {
                // 服务端要求重来:先撤 ready 让 Dart 恢复兜底,再重新订阅。
                setReady(false)
                val bridgeId = bridgeInstallationId ?: return
                val epoch = eventEpoch ?: return
                WatcherDiagnostics.log("$diagPrefix resync: ${frame.optString("type")}")
                subscribeNotifications("resync-${System.currentTimeMillis()}", bridgeId, epoch)
            }
        }
    }

    /// 发起通知订阅。cursor 为 null 时 Bridge 从最早可用位点开始,
    /// 不会补发全部历史 —— 首次安装不该被几百条旧通知淹没。
    private fun subscribeNotifications(suffix: String, bridgeId: String, epoch: String) {
        val saved = cursors.read(bridgeId)
        // epoch 不匹配说明 Bridge 事件库被重置过,旧 sequence 无意义。
        val cursorJson = if (saved != null && saved.eventEpoch == epoch) {
            JSONObject().put("eventEpoch", saved.eventEpoch).put("sequence", saved.through)
        } else {
            null
        }
        prefix = ContiguousPrefix(if (cursorJson != null) saved!!.through else 0L)
        val payload = JSONObject()
            .put("type", "notification_subscribe")
            .put("id", "$diagPrefix-notify-$suffix")
            .put("installationId", installationId)
            .put("scopeVersion", 1)
            .put("pageLimit", 100)
        if (cursorJson != null) payload.put("cursor", cursorJson)
        outbound.addLast(payload.toString())
        WatcherDiagnostics.log("$diagPrefix subscribe(from=${saved?.through ?: 0})")
    }

    /// 处理一页事件(catch-up 或实时推送)。
    ///
    /// 关键:skippedRanges 必须计入连续性。被 scope 排除或已被 TTL 回收的
    /// sequence 永远不会到达,不计入的话 cursor 会永久卡住。
    private fun handleNotificationEvents(frame: JSONObject) {
        val accumulator = prefix ?: return
        val bridgeId = bridgeInstallationId ?: return

        WatcherDiagnostics.log(
            "$diagPrefix events(from=${frame.optLong("fromExclusive", -1)} through=${frame.optLong("through", -1)} " +
                "count=${frame.optJSONArray("events")?.length() ?: 0} hasMore=${frame.optBoolean("hasMore")})",
        )

        // 先按 Bridge 声明的页起点对齐。实时推送(live=true)的帧不带
        // fromExclusive,此时保持本地位点不动。
        if (frame.has("fromExclusive")) {
            accumulator.rebaseTo(frame.optLong("fromExclusive"))
        }

        val skipped = frame.optJSONArray("skippedRanges")
        for (i in 0 until (skipped?.length() ?: 0)) {
            val range = skipped?.optJSONObject(i) ?: continue
            accumulator.acceptSkipped(range.optLong("from"), range.optLong("through"))
        }

        val events = frame.optJSONArray("events")
        val total = events?.length() ?: 0
        // 批量追补只打扰一次:除末页最后一条外全部静默入栈。
        // 真机实测冻结 6 分钟后 8 条在 133ms 内逐条响铃,那是骚扰不是提醒。
        // 后翻页时 hasMore 为真,此时连最后一条也要静默——真正的打扰留给末页。
        val hasMore = frame.optBoolean("hasMore")
        for (i in 0 until total) {
            val event = events?.optJSONObject(i) ?: continue
            val eventId = event.optString("eventId").takeIf { it.isNotEmpty() } ?: continue
            val sequence = event.optLong("sequence", -1L)
            if (sequence < 0) continue
            deliverEvent(
                scope = "$installationId\u0000$bridgeId",
                event = event,
                silent = hasMore || i < total - 1,
            )
            accumulator.accept(sequence)
        }

        // 还有分页就继续拉,不能停在半路 —— 停下等于漏掉后面的完成事件。
        if (hasMore) {
            outbound.addLast(
                JSONObject()
                    .put("type", "notification_next_page")
                    .put("id", "$diagPrefix-notify-page-${System.currentTimeMillis()}")
                    .put("scopeVersion", 1)
                    .toString(),
            )
            return
        }
        ackCursor()
    }

    private fun deliverEvent(scope: String, event: JSONObject, silent: Boolean = false) {
        val eventId = event.optString("eventId").takeIf { it.isNotEmpty() } ?: return
        val presentation = event.optJSONObject("presentation")
        val type = event.optString("type")
        val renderable = RenderableEvent(
            eventId = eventId,
            type = type,
            title = presentation?.optString("title")?.takeIf { it.isNotEmpty() } ?: "PiPilot",
            body = presentation?.optString("body")?.takeIf { it.isNotEmpty() },
            collapseKey = event.optString("collapseKey").takeIf { it.isNotEmpty() },
            vibrate = vibrate,
            silent = silent,
        )
        val started = System.currentTimeMillis()
        if (type == "input_resolved") {
            // 等待输入已被处理:撤掉原来那条提醒,不新弹一条。
            gate.resolve(scope, renderable)
            WatcherDiagnostics.log(
                "$diagPrefix deliver(id=${eventId.take(8)} state=RESOLVED ms=${System.currentTimeMillis() - started})",
            )
            return
        }
        val state = gate.deliver(scope, renderable)
        if (state == DeliveryState.BLOCKED) {
            ConnectionMetrics.record(appContext, "blocked_permission")
        }
        if (state == DeliveryState.DISPLAY_REQUESTED || state == DeliveryState.DISPLAY_CONFIRMED) {
            postedNotificationIds.add(
                StableNotificationId.forEvent(renderable.collapseKey ?: eventId),
            )
        }
        WatcherDiagnostics.log(
            "$diagPrefix deliver(id=${eventId.take(8)} state=$state silent=$silent ms=${System.currentTimeMillis() - started})",
        )
        // receipt 只服务仲裁与指标,不推进 cursor,失败也不影响正确性。
        outbound.addLast(
            JSONObject()
                .put("type", "notification_receipt")
                .put("installationId", installationId)
                .put("eventId", eventId)
                .put("state", receiptStateName(state))
                .put("at", java.time.Instant.now().toString())
                .toString(),
        )
    }

    /// ack 到最高连续前缀。ContiguousPrefix.current() 本身就是连续值,
    /// 上方有缺口(hasGap)不影响下方 ack 的正确性,但要如实记诊断。
    private fun ackCursor() {
        val accumulator = prefix ?: return
        val bridgeId = bridgeInstallationId ?: return
        val epoch = eventEpoch ?: return
        val through = accumulator.current()
        if (through <= 0) {
            WatcherDiagnostics.log("$diagPrefix ack skipped(through=$through)")
            return
        }
        val advanced = cursors.advance(NotificationCursor(bridgeId, epoch, through))
        WatcherDiagnostics.log(
            "$diagPrefix ack send(through=$through advanced=$advanced gap=${accumulator.hasGap()})",
        )
        outbound.addLast(
            JSONObject()
                .put("type", "notification_ack")
                .put("installationId", installationId)
                .put("eventEpoch", epoch)
                .put("through", through)
                .toString(),
        )
    }

    private fun setReady(value: Boolean) {
        if (isReady == value) return
        isReady = value
        val listener = readyListener ?: return
        handler.post { listener.invoke(value) }
    }

    companion object {
        fun receiptStateName(state: DeliveryState): String = when (state) {
            DeliveryState.PENDING -> "received"
            DeliveryState.DISPLAY_REQUESTED -> "display_requested"
            DeliveryState.DISPLAY_CONFIRMED -> "display_confirmed"
            DeliveryState.SUPPRESSED_DUPLICATE -> "suppressed_duplicate"
            DeliveryState.BLOCKED -> "blocked_permission"
        }
    }
}
