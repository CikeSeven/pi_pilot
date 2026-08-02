package com.pipilot.pi_pilot

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private const val INST = "inst-a"
private const val BRIDGE = "bridge-abc"
private const val EPOCH = "epoch-1"

private fun store(installationId: String = INST): NativeCursorStore =
    NativeCursorStore(InMemoryCursorStorage(), installationId)

class NativeCursorStoreTest {
    @Test
    fun cursorRoundTrips() {
        val cursors = store()
        assertTrue(cursors.advance(NotificationCursor(BRIDGE, EPOCH, 42)))
        val read = cursors.read(BRIDGE)
        assertEquals(EPOCH, read?.eventEpoch)
        assertEquals(42L, read?.through)
    }

    @Test
    fun missingCursorReadsAsNull() {
        assertNull(store().read(BRIDGE))
    }

    @Test
    fun cursorNeverRegressesWithinSameEpoch() {
        val cursors = store()
        cursors.advance(NotificationCursor(BRIDGE, EPOCH, 100))
        // 迟到的旧 ack 不能把位点拉回去,否则已显示的事件会被重新拉取并再次通知。
        assertFalse(cursors.advance(NotificationCursor(BRIDGE, EPOCH, 50)))
        assertEquals(100L, cursors.read(BRIDGE)?.through)
    }

    @Test
    fun epochChangeAcceptsLowerSequence() {
        val cursors = store()
        cursors.advance(NotificationCursor(BRIDGE, EPOCH, 100))
        // 事件库被重置:sequence 从头开始,必须接受更小的值。
        assertTrue(cursors.advance(NotificationCursor(BRIDGE, "epoch-2", 3)))
        assertEquals("epoch-2", cursors.read(BRIDGE)?.eventEpoch)
        assertEquals(3L, cursors.read(BRIDGE)?.through)
    }

    @Test
    fun separateInstallationsKeepIndependentCursors() {
        val storage = InMemoryCursorStorage()
        val a = NativeCursorStore(storage, "inst-a")
        val b = NativeCursorStore(storage, "inst-b")
        a.advance(NotificationCursor(BRIDGE, EPOCH, 10))
        b.advance(NotificationCursor(BRIDGE, EPOCH, 3))
        // 同一台 Bridge 的两台手机不能互相推进游标。
        assertEquals(10L, a.read(BRIDGE)?.through)
        assertEquals(3L, b.read(BRIDGE)?.through)
    }

    @Test
    fun separateBridgesKeepIndependentCursors() {
        val cursors = store()
        cursors.advance(NotificationCursor("bridge-1", EPOCH, 10))
        cursors.advance(NotificationCursor("bridge-2", EPOCH, 77))
        assertEquals(10L, cursors.read("bridge-1")?.through)
        assertEquals(77L, cursors.read("bridge-2")?.through)
    }

    @Test
    fun rebaseReportsTheHistoryGap() {
        val cursors = store()
        cursors.advance(NotificationCursor(BRIDGE, EPOCH, 10))
        // Bridge 说最早只剩 51 了:11..50 这段永久丢失,必须如实报出缺口。
        val gap = cursors.rebase(BRIDGE, EPOCH, 51)
        assertEquals(40L, gap)
        assertEquals(50L, cursors.read(BRIDGE)?.through)
    }

    @Test
    fun rebaseAcrossEpochReportsNoGap() {
        val cursors = store()
        cursors.advance(NotificationCursor(BRIDGE, EPOCH, 10))
        // 换 epoch 意味着旧 sequence 无意义,不能拿它算缺口。
        assertEquals(0L, cursors.rebase(BRIDGE, "epoch-2", 1))
        assertEquals(0L, cursors.read(BRIDGE)?.through)
    }

    @Test
    fun orphanedBridgeCursorIsRemoved() {
        val cursors = store()
        cursors.advance(NotificationCursor(BRIDGE, EPOCH, 10))
        cursors.orphan(BRIDGE)
        assertNull(cursors.read(BRIDGE))
    }

    @Test
    fun malformedCursorReadsAsNull() {
        val storage = InMemoryCursorStorage()
        storage.put("$INST\u001f$BRIDGE", "garbage")
        // 坏记录当作没有:从 Bridge 重新对账比信一个坏位点安全。
        assertNull(NativeCursorStore(storage, INST).read(BRIDGE))
    }

    @Test
    fun knownBridgesListsOnlyOwnInstallation() {
        val storage = InMemoryCursorStorage()
        val a = NativeCursorStore(storage, "inst-a")
        val b = NativeCursorStore(storage, "inst-b")
        a.advance(NotificationCursor("bridge-1", EPOCH, 1))
        b.advance(NotificationCursor("bridge-2", EPOCH, 1))
        assertEquals(listOf("bridge-1"), a.knownBridges())
        assertEquals(listOf("bridge-2"), b.knownBridges())
    }
}

class ContiguousPrefixTest {
    @Test
    fun inOrderSequencesAdvanceImmediately() {
        val prefix = ContiguousPrefix(0)
        prefix.accept(1)
        prefix.accept(2)
        prefix.accept(3)
        assertEquals(3L, prefix.current())
        assertFalse(prefix.hasGap())
    }

    @Test
    fun aGapBlocksAdvancement() {
        val prefix = ContiguousPrefix(128)
        // 先收到 130,缺 129:绝不能 ack 130,那会让 129 永久丢失。
        prefix.accept(130)
        assertEquals(128L, prefix.current())
        assertTrue(prefix.hasGap())
    }

    @Test
    fun fillingTheGapDrainsTheBuffer() {
        val prefix = ContiguousPrefix(128)
        prefix.accept(130)
        prefix.accept(131)
        assertEquals(128L, prefix.current())
        prefix.accept(129)
        // 洞被补上后一次性推进到最高连续位点。
        assertEquals(131L, prefix.current())
        assertFalse(prefix.hasGap())
    }

    @Test
    fun skippedRangesCountTowardContinuity() {
        val prefix = ContiguousPrefix(0)
        prefix.accept(1)
        // 2..5 被 scope 排除或已被 TTL 回收:它们永远不会到达,
        // 必须计入连续性,否则 cursor 永久卡在 1。
        prefix.acceptSkipped(2, 5)
        prefix.accept(6)
        assertEquals(6L, prefix.current())
        assertFalse(prefix.hasGap())
    }

    @Test
    fun skippedRangeAloneAdvancesCursor() {
        val prefix = ContiguousPrefix(10)
        prefix.acceptSkipped(11, 20)
        assertEquals(20L, prefix.current())
    }

    @Test
    fun duplicateSequencesAreIdempotent() {
        val prefix = ContiguousPrefix(0)
        prefix.accept(1)
        prefix.accept(1)
        prefix.accept(1)
        assertEquals(1L, prefix.current())
        assertFalse(prefix.hasGap())
    }

    @Test
    fun sequencesBelowCursorAreIgnored() {
        val prefix = ContiguousPrefix(100)
        prefix.accept(50)
        assertEquals(100L, prefix.current())
        assertFalse(prefix.hasGap())
    }

    @Test
    fun outOfOrderBurstResolvesToHighestContiguous() {
        val prefix = ContiguousPrefix(0)
        // 乱序到达是常态(LAN 与 FCM 同时投递)。
        for (seq in listOf(4L, 2L, 5L, 1L, 3L)) prefix.accept(seq)
        assertEquals(5L, prefix.current())
        assertFalse(prefix.hasGap())
    }

    @Test
    fun overlappingSkippedRangeIsSafe() {
        val prefix = ContiguousPrefix(5)
        // Bridge 重发了一段已经推进过的 skipped range:必须幂等。
        prefix.acceptSkipped(1, 8)
        assertEquals(8L, prefix.current())
    }

    @Test
    fun rebaseToAdoptsBridgePageStart() {
        // 真机复现的 cursor 卡死:首次订阅本地起点是 0,Bridge 首页却声明
        // fromExclusive=7。不采信这个起点,实时推送的 seq=8 就永远与 0 不连续,
        // drain() 推不动,ack 因 through<=0 被跳过,cursor 永久停在 0。
        val prefix = ContiguousPrefix(0)
        prefix.rebaseTo(7)
        assertEquals(7L, prefix.current())
        prefix.accept(8)
        assertEquals(8L, prefix.current())
        assertFalse(prefix.hasGap())
    }

    @Test
    fun rebaseToNeverMovesBackwards() {
        // 迟到的旧页不能把已确认的位点拉回去,否则会重复投递已显示的通知。
        val prefix = ContiguousPrefix(10)
        prefix.rebaseTo(4)
        assertEquals(10L, prefix.current())
    }

    @Test
    fun rebaseToClearsCoveredPendingSequences() {
        // 悬挂的高位 sequence 被新起点覆盖后必须清掉,否则 hasGap() 假报缺口,
        // watcher 会一直拒绝 ack 并反复请求 resync。
        val prefix = ContiguousPrefix(0)
        prefix.accept(3)
        assertTrue(prefix.hasGap())
        prefix.rebaseTo(5)
        assertEquals(5L, prefix.current())
        assertFalse(prefix.hasGap())
    }
}
