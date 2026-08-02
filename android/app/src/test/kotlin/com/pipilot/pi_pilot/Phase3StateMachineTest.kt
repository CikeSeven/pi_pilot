package com.pipilot.pi_pilot

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// Phase 3 纯 JVM 状态机回归。
///
/// 覆盖 advisor 点名的六类:失败后持续重试/onFailure+onClosed 只排一次/
/// stop 取消/网络恢复立即重连且退避清零/旧世代回调全部失效/持久目标
/// 序列化往返(空 Intent 重建的持久层基础)。这些类刻意无 Android 依赖,
/// 不需要 Looper。
class ReconnectControllerTest {

    private fun newController() = ReconnectController()

    @Test
    fun `continued retry after failure with capped backoff`() {
        val c = newController()
        val gen = c.start()
        val expected = longArrayOf(1_000, 2_000, 4_000, 8_000, 15_000, 15_000)
        for (round in expected.indices) {
            val s = c.onConnectionLost(gen)
            assertNotNull("round $round should schedule", s)
            assertEquals(round + 1, s!!.attempt)
            assertEquals("round $round delay", expected[round], s.delayMs)
            // 点火后回到 RUNNING,下一次丢失排下一轮。
            assertNotNull(c.fire(gen, s.attempt))
        }
        assertEquals(6, c.attempt)
    }

    @Test
    fun `paired onFailure and onClosed produce exactly one reconnect`() {
        val c = newController()
        val gen = c.start()
        val first = c.onConnectionLost(gen)
        val second = c.onConnectionLost(gen)
        assertNotNull(first)
        assertNotNull(second)
        // 第二次返回同一个 pending,attempt 不得翻倍。
        assertEquals(first!!.attempt, second!!.attempt)
        assertEquals(first.delayMs, second.delayMs)
        assertEquals(1, c.attempt)
    }

    @Test
    fun `stop cancels pending reconnect and rejects everything after`() {
        val c = newController()
        val gen = c.start()
        val s = c.onConnectionLost(gen)!!
        c.stop(gen)
        assertNull("fire after stop must fail", c.fire(gen, s.attempt))
        assertNull("lost after stop must not schedule", c.onConnectionLost(gen))
        assertNull("network after stop must not schedule", c.onNetworkAvailable(gen))
        assertEquals(ReconnectController.State.STOPPED, c.state)
    }

    /// coordinator.stop() 的幂等守卫读的就是这三个条件。
    /// 真机日志里 Dart 一次生命周期切换会连发 3-6 次 stopWatcher,
    /// 守卫靠它们判定「已经停完了,无需再跑一遗」。
    @Test
    fun `repeated stop keeps stopped state and no pending`() {
        val c = newController()
        val gen = c.start()
        c.onConnectionLost(gen)
        assertNotNull("precondition: a schedule is pending", c.pendingSchedule())
        c.stop(gen)
        // 首次 stop 后守卫条件已全部成立。
        assertEquals(ReconnectController.State.STOPPED, c.state)
        assertNull("stop must clear pending", c.pendingSchedule())
        // 重复 stop 不得把状态挖回 PENDING/RUNNING,也不得重新排期。
        repeat(5) { c.stop(gen) }
        assertEquals(ReconnectController.State.STOPPED, c.state)
        assertNull("repeated stop must not re-arm", c.pendingSchedule())
    }

    @Test
    fun `network recovery fires immediately and resets backoff`() {
        val c = newController()
        val gen = c.start()
        // 三次失败把退避推到 4s。
        repeat(3) {
            val s = c.onConnectionLost(gen)!!
            assertNotNull(c.fire(gen, s.attempt))
        }
        val recovery = c.onNetworkAvailable(gen)
        assertNotNull(recovery)
        assertEquals(0L, recovery!!.delayMs)
        assertEquals(0, recovery.attempt)
        assertNotNull(c.fire(gen, recovery.attempt))
        // 退避已清零:下一次失败重新从 1s 起步。
        val next = c.onConnectionLost(gen)!!
        assertEquals(1, next.attempt)
        assertEquals(1_000L, next.delayMs)
    }

    @Test
    fun `stale generation callbacks are all rejected`() {
        val c = newController()
        val oldGen = c.start()
        val s = c.onConnectionLost(oldGen)!!
        val newGen = c.start()
        assertTrue(newGen > oldGen)
        assertNull(c.onConnectionLost(oldGen))
        assertNull(c.fire(oldGen, s.attempt))
        assertNull(c.onNetworkAvailable(oldGen))
        c.onConnected(oldGen) // 不得生效
        // 新世代的 pending 已被 start 清空,但状态机本身仍可工作。
        val fresh = c.onConnectionLost(newGen)
        assertNotNull(fresh)
        assertEquals(1, fresh!!.attempt)
    }

    @Test
    fun `fire requires matching attempt and pending state`() {
        val c = newController()
        val gen = c.start()
        assertNull("no pending -> fire rejected", c.fire(gen, 1))
        val s = c.onConnectionLost(gen)!!
        assertNull("wrong attempt", c.fire(gen, s.attempt + 1))
        assertNull("wrong generation", c.fire(gen + 1, s.attempt))
        assertNotNull(c.fire(gen, s.attempt))
        // 点火后 pending 已消费,重复点火必须失败。
        assertNull(c.fire(gen, s.attempt))
    }

    @Test
    fun `onConnected resets backoff`() {
        val c = newController()
        val gen = c.start()
        repeat(3) {
            val s = c.onConnectionLost(gen)!!
            assertNotNull(c.fire(gen, s.attempt))
        }
        c.onConnected(gen)
        val s = c.onConnectionLost(gen)!!
        assertEquals(1, s.attempt)
        assertEquals(1_000L, s.delayMs)
    }
}

class LanConnectionStateTest {

    @Test
    fun `transitions follow current generation`() {
        val h = LanConnectionStateHolder()
        val gen = h.beginGeneration()
        assertEquals(LanConnectionState.DISCONNECTED, h.state)
        assertTrue(h.transitionTo(gen, LanConnectionState.CONNECTING, "connect"))
        assertTrue(h.transitionTo(gen, LanConnectionState.READY, "ready"))
        assertTrue(h.isReady())
        assertEquals("ready", h.lastReason)
    }

    @Test
    fun `stale generation cannot overwrite newer state`() {
        val h = LanConnectionStateHolder()
        val oldGen = h.beginGeneration()
        val newGen = h.beginGeneration()
        assertTrue(h.transitionTo(newGen, LanConnectionState.READY, "new ready"))
        assertFalse(
            "old generation disconnect must be rejected",
            h.transitionTo(oldGen, LanConnectionState.DISCONNECTED, "stale"),
        )
        assertEquals(LanConnectionState.READY, h.state)
        assertEquals("new ready", h.lastReason)
    }

    @Test
    fun `isReady only in READY state`() {
        val h = LanConnectionStateHolder()
        val gen = h.beginGeneration()
        assertFalse(h.isReady())
        h.transitionTo(gen, LanConnectionState.CATCHING_UP)
        assertFalse("catch-up is not ready", h.isReady())
        h.transitionTo(gen, LanConnectionState.READY)
        assertTrue(h.isReady())
        h.transitionTo(gen, LanConnectionState.DEGRADED, "lost")
        assertFalse(h.isReady())
    }
}

class NativeLanTargetTest {

    private fun sample(bridgeId: String? = "bridge-abc") = NativeLanTarget(
        deviceId = "dev-1",
        host = "192.168.1.10",
        port = 9377,
        wrappedToken = "plain:tok-123",
        clientId = "app-x:native-watcher:dev-1",
        bridgeInstallationId = bridgeId,
        savedAtMillis = 1_700_000_000_000L,
    )

    @Test
    fun `serialize round trip preserves all fields`() {
        val original = sample()
        val restored = NativeLanTarget.deserialize(original.serialize())
        assertEquals(original, restored)
    }

    @Test
    fun `null bridgeInstallationId survives round trip`() {
        val original = sample(bridgeId = null)
        val restored = NativeLanTarget.deserialize(original.serialize())
        assertNotNull(restored)
        assertNull(restored!!.bridgeInstallationId)
        assertEquals(original, restored)
    }

    @Test
    fun `malformed records read as absent`() {
        assertNull(NativeLanTarget.deserialize(""))
        assertNull(NativeLanTarget.deserialize("garbage"))
        // schema 不符
        assertNull(NativeLanTarget.deserialize(sample().serialize().replaceFirst("1", "2")))
        // 字段数不符
        assertNull(NativeLanTarget.deserialize("1\u001fdev-1\u001fhost"))
        // port 非数字
        assertNull(
            NativeLanTarget.deserialize(
                sample().serialize().replace("9377", "notaport"),
            ),
        )
    }

    @Test
    fun `empty critical fields are treated as corrupt`() {
        val broken = sample().copy(host = "")
        assertNull(NativeLanTarget.deserialize(broken.serialize()))
        val brokenToken = sample().copy(wrappedToken = "")
        assertNull(NativeLanTarget.deserialize(brokenToken.serialize()))
    }

    @Test
    fun `plain cipher round trips and rejects wrong prefix`() {
        val cipher = PlainTokenCipher()
        val wrapped = cipher.wrap("tok-abc")
        assertEquals("tok-abc", cipher.unwrap(wrapped))
        assertNull(cipher.unwrap("gcm:something"))
    }
}
