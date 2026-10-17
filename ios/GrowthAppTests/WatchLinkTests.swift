import XCTest
@testable import GrowthApp

/// 手表 → 手机的消息契约(W1 spec 决定 2)。
///
/// 系统的 `transferFile` 不保证顺序、可能重发,手机还可能在挪完文件、
/// 推进游标之前被杀。这几种都会**真实发生**,而每一种出错的样子都是
/// 「一块音频记错了场次 / 转写了两次 / 静默少了一块」—— 没有任何东西会报错。
/// 所以逐个构造乱序、重复、缺号、崩溃重放去打。
final class WatchLinkTests: XCTestCase {

    private let t0 = ISO8601DateFormatter().date(from: "2026-10-12T09:00:00Z")!
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func block(_ seq: Int) -> LedgerEntry {
        LedgerEntry(block: BlockRecord(seq: seq, startedAt: at(Double(seq) * 5),
                                       endedAt: at(Double(seq + 1) * 5),
                                       hardCut: false,
                                       fileName: String(format: "block-%04d.m4a", seq)))
    }

    // MARK: - 按序应用

    func testInOrderAppliesAll() {
        let p = WatchLink.plan(nextExpected: 0, pending: [0, 1, 2])
        XCTAssertEqual(p, .init(apply: [0, 1, 2], duplicates: [], missing: nil))
    }

    func testOutOfOrderAppliesInOrder() {
        let p = WatchLink.plan(nextExpected: 0, pending: [2, 0, 1])
        XCTAssertEqual(p.apply, [0, 1, 2], "到达顺序 2,0,1 ⇒ 应用顺序必须是 0,1,2")
        XCTAssertNil(p.missing)
    }

    func testDuplicateIsDropped() {
        let p = WatchLink.plan(nextExpected: 3, pending: [1, 3, 3, 2])
        XCTAssertEqual(p.apply, [3], "同一号到两次只应用一次")
        XCTAssertEqual(p.duplicates, [1, 2])
    }

    func testGapHolds() {
        let p = WatchLink.plan(nextExpected: 0, pending: [0, 2, 3])
        XCTAssertEqual(p.apply, [0], "缺 1 ⇒ 2、3 必须等着,不许跳过")
        XCTAssertEqual(p.missing, 1)
    }

    func testGapAtHeadAppliesNothing() {
        let p = WatchLink.plan(nextExpected: 5, pending: [6, 7])
        XCTAssertEqual(p.apply, [])
        XCTAssertEqual(p.missing, 5)
    }

    func testNothingPending() {
        XCTAssertEqual(WatchLink.plan(nextExpected: 4, pending: []),
                       .init(apply: [], duplicates: [], missing: nil))
    }

    // MARK: - 崩溃重放

    /// 挪完文件、记完账,游标还没前进就被杀 ⇒ 重启后同一条又来一次。
    /// 账本最后一行已经是它 ⇒ 不再追加;否则同一块进两次账本 = 转写两次。
    func testCrashReplaySkipsLastLine() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchlink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = dir.appendingPathComponent("ledger.jsonl")

        // 走一遍真实路径:手表账本 → 消息 → 手机账本 → 读回来
        let original = block(0)
        let msg = WatchMessage(v: WatchLink.version, installID: "A", msgSeq: 0,
                               day: "2026-10-12", entry: original,
                               sentAt: at(5), watchBattery: 0.8)
        let received = try WatchLink.message(fromMetadata: WatchLink.metadata(msg))
        try BlockLedger.append(received.entry, to: ledger)

        try BlockLedger.append(block(1), to: ledger)
        let mirror = try BlockLedger.read(from: ledger).entries
        XCTAssertTrue(WatchLink.alreadyApplied(received.entry, in: mirror),
                      "经过两次编码之后必须仍然认得出是同一条,否则崩溃重放会重复记账")
        XCTAssertTrue(WatchLink.alreadyApplied(original, in: mirror),
                      "不在最后一行也要认得出 —— 换安装号整天重发时重复的是整本")
        XCTAssertFalse(WatchLink.alreadyApplied(block(2), in: mirror))
        XCTAssertFalse(WatchLink.alreadyApplied(original, in: []))
    }

    /// 亚秒时间戳:秒精度往返之后,两条本来不同的条目不能变得相等。
    func testSubsecondEntriesStayDistinctAfterRoundTrip() throws {
        let a = LedgerEntry(at: t0.addingTimeInterval(0.2), mark: .paused)
        let b = LedgerEntry(at: t0.addingTimeInterval(0.7), mark: .resumed)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchlink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = dir.appendingPathComponent("ledger.jsonl")
        try BlockLedger.append(a, to: ledger)
        try BlockLedger.append(b, to: ledger)
        let back = try BlockLedger.read(from: ledger).entries
        XCTAssertNotEqual(back[0], back[1], "种类不同的两条,同一秒也必须是两条")
    }

    // MARK: - 外发账(手表侧状态机)

    private func book() -> WatchLink.Book { WatchLink.Book(installID: "A") }

    func testEnqueueAssignsConsecutiveSeqsAndPinsFiles() {
        var b = book()
        let m0 = b.enqueue(block(0), day: "d1", path: "recordings/d1/block-0000.m4a",
                           now: at(5), battery: 0.9)
        let m1 = b.enqueue(LedgerEntry(at: at(6), mark: .paused), day: "d1",
                           path: "outbox/msg-1.json", now: at(6), battery: nil)
        XCTAssertEqual([m0.msgSeq, m1.msgSeq], [0, 1])
        XCTAssertEqual(b.sent(day: "d1"), 2)
        XCTAssertEqual(b.inflightBlocks, 1, "标记不算块")
        XCTAssertEqual(b.pinnedPaths, ["recordings/d1/block-0000.m4a", "outbox/msg-1.json"])
    }

    /// 号分配并落盘之后、交给系统之前被杀 ⇒ 系统队列里没有它 ⇒ 必须用**同一份消息**重发。
    func testKilledBeforeTransferIsResentWithSameSeq() {
        var b = book()
        let m0 = b.enqueue(block(0), day: "d1", path: "p0", now: at(5), battery: nil)
        let m1 = b.enqueue(block(1), day: "d1", path: "p1", now: at(10), battery: nil)
        // 系统队列里只有 0 号(1 号没来得及交)
        let again = b.needsResend(outstanding: [m0.msgSeq])
        XCTAssertEqual(again.map(\.message), [m1], "重发的必须是原消息,不能换号")
    }

    func testDeliveredUnpinsAndStopsResend() {
        var b = book()
        let m0 = b.enqueue(block(0), day: "d1", path: "p0", now: at(5), battery: nil)
        b.delivered(m0.msgSeq)
        XCTAssertEqual(b.pinnedPaths, [], "送到之后保留期才可以删它")
        XCTAssertEqual(b.needsResend(outstanding: []), [])
    }

    /// 失败的不当场重发:持续性错误(手机 App 没装)会让它每秒空转。
    func testRetryIsThrottled() {
        var b = book()
        XCTAssertTrue(b.retryDue(now: at(0)))
        b.markRetried(now: at(0))
        XCTAssertFalse(b.retryDue(now: at(4)))
        XCTAssertTrue(b.retryDue(now: at(5)))
    }

    func testBookSurvivesPersistence() throws {
        var b = book()
        _ = b.enqueue(block(0), day: "d1", path: "p0", now: at(5), battery: 0.5)
        b.markRetried(now: at(6))
        let back = try JSONDecoder().decode(WatchLink.Book.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(back, b)
    }

    func testFirstBatchWaitsFifteenMinutesAndPinsClosedBlocks() {
        var b = book()
        _ = b.enqueue(LedgerEntry(at: at(0), mark: .sessionStarted), day: "d1",
                      path: "start.json", now: at(0), battery: nil)
        for seq in 0..<2 {
            _ = b.enqueue(block(seq), day: "d1", path: "p\(seq)",
                          now: at(Double(seq + 1) * 5), battery: nil)
        }
        XCTAssertFalse(b.batchDue(now: at(5)))
        XCTAssertFalse(b.batchDue(now: at(10)))
        XCTAssertFalse(b.batchDue(now: at(15).addingTimeInterval(-0.001)))
        XCTAssertTrue(b.batchDue(now: at(15)))
        XCTAssertEqual(b.inflightBlocks, 2)
        XCTAssertEqual(b.pinnedPaths, ["start.json", "p0", "p1"])
    }

    func testBatchCommitPersistsThrottleAcrossRelaunchAndReconnect() throws {
        var b = book()
        let m = b.enqueue(block(0), day: "d1", path: "p0", now: at(0), battery: nil)
        var persisted: Data?
        b = try b.committingBatch(now: at(15)) { persisted = try JSONEncoder().encode($0) }
        let back = try JSONDecoder().decode(WatchLink.Book.self, from: XCTUnwrap(persisted))
        XCTAssertEqual(back, b)
        for minute in [15.0, 16.0, 20.0, 29.99] { XCTAssertFalse(back.batchDue(now: at(minute))) }
        XCTAssertTrue(back.batchDue(now: at(30)))
        XCTAssertEqual(back.needsResend(outstanding: []).map(\.message), [m])
        XCTAssertEqual(back.pinnedPaths, ["p0"])
    }

    func testBatchPersistenceFailureLeavesOriginalAndFilesPinned() {
        var b = book()
        _ = b.enqueue(block(0), day: "d1", path: "p0", now: at(0), battery: nil)
        let original = b
        XCTAssertThrowsError(try b.committingBatch(now: at(15)) { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        XCTAssertEqual(b, original)
        XCTAssertNil(b.lastBatchAt)
        XCTAssertEqual(b.pinnedPaths, ["p0"])
        XCTAssertTrue(b.batchDue(now: at(15)))
    }

    func testLegacyBookWithoutBatchFieldKeepsMessagesAndSchedule() throws {
        var b = book()
        _ = b.enqueue(block(0), day: "d1", path: "p0", now: at(0), battery: nil)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(b)) as? [String: Any])
        object.removeValue(forKey: "lastBatchAt")
        let old = try JSONDecoder().decode(WatchLink.Book.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old, b)
        XCTAssertNil(old.lastBatchAt)
        XCTAssertFalse(old.batchDue(now: at(10)))
        XCTAssertTrue(old.batchDue(now: at(15)))
        XCTAssertEqual(old.pinnedPaths, ["p0"])
    }

    func testIdleThenNewRecordingGetsNewBatchWindow() throws {
        var b = book()
        let old = b.enqueue(block(0), day: "d1", path: "p0", now: at(0), battery: nil)
        b = try b.committingBatch(now: at(15)) { _ in }
        b.delivered(old.msgSeq)
        XCTAssertFalse(b.batchDue(now: at(120)))
        _ = b.enqueue(LedgerEntry(at: at(120), mark: .sessionStarted), day: "d2",
                      path: "new.json", now: at(120), battery: nil)
        XCTAssertFalse(b.batchDue(now: at(120)))
        XCTAssertFalse(b.batchDue(now: at(134.99)))
        XCTAssertTrue(b.batchDue(now: at(135)))
    }

    func testEarlyManualOrStopBatchResetsAutomaticWindow() throws {
        var b = book()
        _ = b.enqueue(block(0), day: "d1", path: "p0", now: at(0), battery: nil)
        XCTAssertFalse(b.batchDue(now: at(5)))
        b = try b.committingBatch(now: at(5)) { _ in }
        XCTAssertFalse(b.batchDue(now: at(15)))
        XCTAssertTrue(b.batchDue(now: at(20)))
        XCTAssertEqual(b.inflightBlocks, 1, "发起批次不代表已收到，原件必须保留")
    }

    func testDeliveredStartOrPreviousBatchDoesNotDelayNextBatch() throws {
        var b = book()
        let start = b.enqueue(LedgerEntry(at: at(0), mark: .sessionStarted), day: "d1",
                              path: "start.json", now: at(0), battery: nil)
        b = try b.committingBatch(now: at(0)) { _ in }
        b.delivered(start.msgSeq)
        let m = b.enqueue(block(0), day: "d1", path: "p0", now: at(5), battery: nil)
        XCTAssertFalse(b.batchDue(now: at(14.99)))
        XCTAssertTrue(b.batchDue(now: at(15)), "持续录音按上一批计时，不因首块晚切多等5分钟")
        b = try b.committingBatch(now: at(15)) { _ in }
        b.delivered(m.msgSeq)
        _ = b.enqueue(block(3), day: "d1", path: "p3", now: at(20), battery: nil)
        XCTAssertTrue(b.batchDue(now: at(30)))
    }

    func testAuthorizedStopBatchContinuesAfterActiveFileWithoutTakingNewBlocks() throws {
        var b = book()
        _ = b.enqueue(block(0), day: "d1", path: "p0", now: at(0), battery: nil)
        var queue = WatchLink.LiveBatch()
        queue.admit(b.needsResend(outstanding: []))
        XCTAssertEqual(queue.takeNext()?.path, "p0")
        let unapproved = b.enqueue(block(1), day: "d1", path: "p1", now: at(5), battery: nil)
        XCTAssertTrue(queue.pending.isEmpty, "落账不会自动混进正在发的批次")
        let end = b.enqueue(LedgerEntry(at: at(6), mark: .sessionEnded), day: "d1",
                            path: "end.json", now: at(6), battery: nil)
        queue.admit(b.needsResend(outstanding: []))
        XCTAssertEqual(queue.pending.count, 2, "正在发的p0不能重复加入")
        XCTAssertNil(queue.takeNext(), "在发时不能另取一个文件")
        queue.finish()
        XCTAssertEqual(queue.takeNext()?.message, unapproved)
        queue.finish()
        XCTAssertEqual(queue.takeNext()?.message, end)
        queue.finish()
        XCTAssertNil(queue.takeNext())
        XCTAssertEqual(b.inflightBlocks, 2, "授权和发起都不能提前释放原件")
    }

    func testLiveBatchFailureDropsAttemptsButKeepsBookForNextBatch() {
        var b = book()
        _ = b.enqueue(block(0), day: "d1", path: "p0", now: at(0), battery: nil)
        _ = b.enqueue(block(1), day: "d1", path: "p1", now: at(5), battery: nil)
        var queue = WatchLink.LiveBatch()
        queue.admit(b.needsResend(outstanding: []))
        _ = queue.takeNext()
        queue.cancelWaiting()
        queue.finish()
        XCTAssertNil(queue.takeNext(), "失败后不连续尝试未传文件")
        XCTAssertEqual(b.pinnedPaths, ["p0", "p1"])
        queue.admit(b.needsResend(outstanding: []))
        XCTAssertEqual(queue.takeNext()?.path, "p0", "下个批次保留原号重试")
    }

    func testPartialDisconnectKeepsAuthorizationAndResumesMissingFileFirst() throws {
        var b = book()
        _ = b.enqueue(block(0), day: "d1", path: "p0", now: at(0), battery: nil)
        _ = b.enqueue(block(1), day: "d1", path: "p1", now: at(5), battery: nil)
        var queue = WatchLink.LiveBatch()
        queue.admit(b.needsResend(outstanding: []))
        let current = try XCTUnwrap(queue.takeNext())
        queue.finish(retrying: current)
        XCTAssertEqual(queue.pending.count, 2)
        XCTAssertEqual(queue.takeNext()?.message, current.message, "重连先接被中断的缺号")
        queue.finish()
        XCTAssertEqual(queue.takeNext()?.path, "p1")
    }

    func testKeyIncludesInstall() {
        let m = WatchMessage(v: 1, installID: "A", msgSeq: 3, day: "d", entry: block(0),
                             sentAt: at(0), watchBattery: nil)
        let n = WatchMessage(v: 1, installID: "B", msgSeq: 3, day: "d", entry: block(0),
                             sentAt: at(0), watchBattery: nil)
        XCTAssertNotEqual(m.key, n.key, "两次安装的同号不能落在同一个名字上")
    }

    // MARK: - 编码

    func testMetadataRoundTrip() throws {
        let marks: [LedgerEntry] = [
            LedgerEntry(at: at(0), mark: .sessionStarted, source: SessionSource.watch),
            block(0),
            LedgerEntry(at: at(7), mark: .interrupted),
            LedgerEntry(at: at(9), mark: .sessionEnded),
        ]
        for (i, e) in marks.enumerated() {
            let m = WatchMessage(v: WatchLink.version, installID: "A", msgSeq: i,
                                 day: "2026-10-12", entry: e,
                                 sentAt: at(Double(i)), watchBattery: i == 0 ? nil : 0.5)
            XCTAssertEqual(try WatchLink.message(fromMetadata: WatchLink.metadata(m)), m)
        }
    }

    func testMissingMetadataThrows() {
        XCTAssertThrowsError(try WatchLink.message(fromMetadata: nil)) {
            XCTAssertEqual($0 as? WatchLink.Failure, .noMetadata)
        }
        XCTAssertThrowsError(try WatchLink.message(fromMetadata: [WatchLink.metadataKey: Data("{}".utf8)]))
    }

    /// 开场那条必须带着 `watch` 来源一路到手机 —— 手机按账本同步场次时,
    /// 来源取自这一条(`BlockLedger.sessions`),丢了就会被当成手机录的。
    func testWatchSourceSurvivesIntoSessions() throws {
        let entries = [
            LedgerEntry(at: at(0), mark: .sessionStarted, source: SessionSource.watch),
            block(0),
            LedgerEntry(at: at(6), mark: .sessionEnded),
        ]
        let sessions = BlockLedger.sessions(entries: entries)
        XCTAssertEqual(sessions.map(\.source), [SessionSource.watch])
        XCTAssertEqual(sessions.first?.blockCount, 1)
    }

    // MARK: - 手表侧:哪些还没发

    func testUnsentIsTheTail() {
        let entries = [block(0), block(1), block(2)]
        XCTAssertEqual(WatchLink.unsent(entries, sentCount: 1).map(Array.init), [block(1), block(2)])
        XCTAssertEqual(WatchLink.unsent(entries, sentCount: 3).map(Array.init), [])
    }

    func testShrunkLedgerSendsNothing() {
        XCTAssertNil(WatchLink.unsent([block(0)], sentCount: 2),
                     "账本行数比已发的还少 = 文件被换过,照新文件重发会发错场次")
    }
}
