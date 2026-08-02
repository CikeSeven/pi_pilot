package com.pipilot.pi_pilot

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private const val SCOPE = "inst-a\u0000bridge-a"

private fun dedupe(
    maxEntries: Int = 2_048,
    retentionMs: Long = 7L * 24 * 60 * 60 * 1000,
    clock: () -> Long = { 1_000L },
): NotificationDeduplicator =
    NotificationDeduplicator(
        storage = InMemoryDedupeStorage(),
        maxEntries = maxEntries,
        retentionMs = retentionMs,
        now = clock,
    )

class StableNotificationIdTest {
    @Test
    fun sameEventIdAlwaysMapsToSameSlot() {
        // 这是「重复投递只打扰一次」的基础:LAN、FCM、Dart 三条路径
        // 对同一 eventId 必须算出同一个通知 id,系统才会替换而非新增。
        val id = StableNotificationId.forEvent("event-abc")
        assertEquals(id, StableNotificationId.forEvent("event-abc"))
    }

    @Test
    fun differentEventsGetDifferentSlots() {
        // 不同任务的完成通知不能 collapse 成一条,否则会吞通知。
        val a = StableNotificationId.forEvent("event-a")
        val b = StableNotificationId.forEvent("event-b")
        assertNotEquals(a, b)
    }

    @Test
    fun neverCollidesWithForegroundServiceNotification() {
        // FGS 常驻通知固定用 id=1(KeepAliveService.notificationId)。
        // 撞上它会把常驻通知替换掉,前台服务就失去了可见凭据。
        for (i in 0 until 5_000) {
            val id = StableNotificationId.forEvent("event-$i")
            assertTrue("id=$id 落进了保留区间", id >= 100)
        }
    }

    @Test
    fun idsAreAlwaysPositive() {
        // 负数 id 在部分 OEM 上行为未定义。
        for (i in 0 until 5_000) {
            assertTrue(StableNotificationId.forEvent("x".repeat(i % 40) + i) > 0)
        }
    }
}

class NotificationDeduplicatorTest {
    @Test
    fun firstClaimSucceedsAndSecondIsSuppressed() {
        val table = dedupe()
        assertNotNull(table.claim(SCOPE, "e1", 100))
        table.markState(SCOPE, "e1", DeliveryState.DISPLAY_CONFIRMED)
        // 迟到的 FCM 携带同一 eventId 到达:必须被抑制,不再打扰用户。
        assertNull(table.claim(SCOPE, "e1", 100))
    }

    @Test
    fun stalePendingIsRetriedAfterCrash() {
        val table = dedupe()
        // 崩溃发生在 claim 之后、notify 之前:状态停在 PENDING。
        assertNotNull(table.claim(SCOPE, "e1", 100))
        assertEquals(DeliveryState.PENDING, table.read(SCOPE, "e1")?.state)
        // 重启后必须允许重试,不能永久吞掉这条通知。
        assertNotNull(table.claim(SCOPE, "e1", 100))
    }

    @Test
    fun stateOnlyMovesForward() {
        val table = dedupe()
        table.claim(SCOPE, "e1", 100)
        table.markState(SCOPE, "e1", DeliveryState.DISPLAY_CONFIRMED)
        // 迟到的乱序回执不能把状态降级,否则仲裁会误判成「还没显示」而重发。
        table.markState(SCOPE, "e1", DeliveryState.DISPLAY_REQUESTED)
        assertEquals(DeliveryState.DISPLAY_CONFIRMED, table.read(SCOPE, "e1")?.state)
    }

    @Test
    fun blockedIsTerminalAndNotRetried() {
        val table = dedupe()
        table.claim(SCOPE, "e1", 100)
        table.markState(SCOPE, "e1", DeliveryState.BLOCKED)
        // 权限/渠道被关是终态:重试也不会显示,不该反复尝试。
        assertNull(table.claim(SCOPE, "e1", 100))
    }

    @Test
    fun separateInstallationsDoNotShareDedupeState() {
        val table = dedupe()
        table.claim("inst-a\u0000bridge-a", "e1", 100)
        table.markState("inst-a\u0000bridge-a", "e1", DeliveryState.DISPLAY_CONFIRMED)
        // 另一台设备(或另一个 Bridge)必须能独立显示同一事件。
        assertNotNull(table.claim("inst-b\u0000bridge-a", "e1", 100))
        assertNotNull(table.claim("inst-a\u0000bridge-b", "e1", 100))
    }

    @Test
    fun expiredRecordsArePruned() {
        var clock = 10_000L
        val table = dedupe(maxEntries = 2, retentionMs = 1_000L, clock = { clock })
        table.claim(SCOPE, "old-1", 100)
        table.claim(SCOPE, "old-2", 101)
        clock += 60_000L
        // 超过保留期后新的写入会触发清理。
        table.claim(SCOPE, "fresh", 102)
        assertNull(table.read(SCOPE, "old-1"))
        assertNotNull(table.read(SCOPE, "fresh"))
    }

    @Test
    fun overflowDropsOldestFirst() {
        var clock = 0L
        val table = dedupe(maxEntries = 3, retentionMs = Long.MAX_VALUE, clock = { clock })
        for (i in 0 until 6) {
            clock += 100
            table.claim(SCOPE, "e$i", 100 + i)
        }
        // 最老的被挤掉,最新的必须还在。
        assertNull(table.read(SCOPE, "e0"))
        assertNotNull(table.read(SCOPE, "e5"))
        assertTrue(table.size() <= 4)
    }

    @Test
    fun malformedRecordIsTreatedAsAbsent() {
        val storage = InMemoryDedupeStorage()
        storage.put("$SCOPE\u0000e1", "{ not json")
        val table = NotificationDeduplicator(storage)
        // 记录坏了就当没有:重复一次通知比永久吞掉更可接受。
        assertNull(table.read(SCOPE, "e1"))
        assertNotNull(table.claim(SCOPE, "e1", 100))
    }

    @Test
    fun notificationIdIsPreservedAcrossStateChanges() {
        val table = dedupe()
        table.claim(SCOPE, "e1", 4242)
        table.markState(SCOPE, "e1", DeliveryState.DISPLAY_REQUESTED)
        // 通知 id 必须稳定,否则 input_resolved 取消不到原来那条。
        assertEquals(4242, table.read(SCOPE, "e1")?.notificationId)
    }
}

class DeliveryStateRankTest {
    @Test
    fun confirmedOutranksRequested() {
        assertTrue(
            DeliveryState.DISPLAY_CONFIRMED.rank() > DeliveryState.DISPLAY_REQUESTED.rank(),
        )
    }

    @Test
    fun requestedOutranksPending() {
        assertTrue(DeliveryState.DISPLAY_REQUESTED.rank() > DeliveryState.PENDING.rank())
    }

    @Test
    fun blockedIsTerminalRank() {
        // 被阻塞与已确认同为终态:都不该再触发 fallback 推送。
        assertEquals(DeliveryState.DISPLAY_CONFIRMED.rank(), DeliveryState.BLOCKED.rank())
    }

    @Test
    fun duplicateSuppressionRanksBelowConfirmation() {
        assertTrue(
            DeliveryState.SUPPRESSED_DUPLICATE.rank() < DeliveryState.DISPLAY_CONFIRMED.rank(),
        )
    }
}
