import XCTest
@testable import GrowthApp

/// 落盘块账本与空洞计算(§六 录音内核 · PRD §4.1.3「App 被系统回收」)。
///
/// 空洞这个数会直接变成给用户看的一句话,算错了没有任何机制会发现 ——
/// 所以这里逐个构造块尾时间戳去验算,而不是跑一遍看不报错就算过。
///
/// 最要紧的一条是 `testPauseIsNotCountedAsGap`:朴素算法(现在 − 最后一块块尾)
/// 会把用户自己按的暂停算成「录音中断」。报错的空洞和不报空洞一样坏。
final class BlockLedgerTests: XCTestCase {

    private let t0 = ISO8601DateFormatter().date(from: "2026-08-10T09:00:00Z")!
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func mark(_ m: SessionMark, _ minutes: Double) -> LedgerEntry {
        LedgerEntry(at: at(minutes), mark: m)
    }
    private func block(_ seq: Int, _ from: Double, _ to: Double) -> LedgerEntry {
        LedgerEntry(block: BlockRecord(seq: seq, startedAt: at(from), endedAt: at(to),
                                       hardCut: true, fileName: "block-\(seq).m4a"))
    }

    private func report(_ entries: [LedgerEntry], now: Double) throws -> RelaunchReport {
        try BlockLedger.relaunchReport(entries: entries, now: at(now))
    }

    // MARK: - 空洞算术

    func testKilledWhileRecordingReportsGapUntilNow() throws {
        // 09:00 起录,两块到 09:10,然后被 jetsam 杀掉,09:25 用户重开 App。
        // 空洞 = 15 分钟,**不是「最多丢一段(5 分钟)」**。
        let r = try report([mark(.sessionStarted, 0), block(0, 0, 5), block(1, 5, 10)], now: 25)
        XCTAssertEqual(r.gapMs, 15 * 60 * 1000)
        XCTAssertEqual(r.lastBlockSeq, 1)
        XCTAssertFalse(r.cleanShutdown)
        XCTAssertFalse(r.endedWhilePaused)
    }

    func testPauseIsNotCountedAsGap() throws {
        // 用户 09:05 按暂停,之后 App 死了,09:45 重开。
        // 朴素算法(now − 块尾)会报 40 分钟中断;实际用户根本没期待这段被录。
        let r = try report([mark(.sessionStarted, 0), block(0, 0, 5), mark(.paused, 5)], now: 45)
        XCTAssertEqual(r.gapMs, 0, "用户自己按的暂停不是空洞")
        XCTAssertTrue(r.endedWhilePaused, "文案要说「你暂停了」,不能说「被打断了」")
        XCTAssertFalse(r.cleanShutdown)
    }

    func testInterruptionIsCountedAsGap() throws {
        // 系统中断与用户暂停相反:用户以为还在录。这正是空洞的主要来源。
        let r = try report([mark(.sessionStarted, 0), block(0, 0, 5),
                            mark(.interrupted, 5)], now: 20)
        XCTAssertEqual(r.gapMs, 15 * 60 * 1000)
        XCTAssertFalse(r.endedWhilePaused)
    }

    func testPauseResumeThenDeathCountsOnlyTheIntendedWindow() throws {
        // 09:00 起录 → 09:05 暂停 → 09:35 继续 → 块1 到 09:40 → 死 → 09:50 重开。
        // 意图区间 = [0,5] + [35,50] = 20 分钟;落盘 = 10 分钟;空洞 = 10 分钟。
        let r = try report([mark(.sessionStarted, 0), block(0, 0, 5), mark(.paused, 5),
                            mark(.resumed, 35), block(1, 35, 40)], now: 50)
        XCTAssertEqual(r.gapMs, 10 * 60 * 1000)
        XCTAssertEqual(r.lastBlockSeq, 1)
    }

    func testCleanShutdownHasNoGap() throws {
        let r = try report([mark(.sessionStarted, 0), block(0, 0, 5),
                            mark(.sessionEnded, 5)], now: 60)
        XCTAssertTrue(r.cleanShutdown)
        XCTAssertEqual(r.gapMs, 0)
    }

    func testDeathBeforeFirstBlockLandsStillReportsAGap() throws {
        // 一块都没落盘就被杀。「按最后一块的块尾算」在这里没有块可用 ——
        // 退回场次开始时间,而不是报 0。
        let r = try report([mark(.sessionStarted, 0)], now: 3)
        XCTAssertEqual(r.gapMs, 3 * 60 * 1000)
        XCTAssertNil(r.lastBlockSeq)
    }

    func testUnflushedTailIsCountedAsLost() throws {
        // 块 1 开在 09:05,写到一半进程没了 —— 账本里没有它。
        // 那 5 分钟确实丢了,不能因为「文件可能还在」就当它录到了。
        let r = try report([mark(.sessionStarted, 0), block(0, 0, 5)], now: 10)
        XCTAssertEqual(r.gapMs, 5 * 60 * 1000)
        XCTAssertEqual(r.lastBlockSeq, 0)
    }

    // MARK: - 账本本身出问题时不能装作没事

    func testEmptyLedgerThrowsInsteadOfReportingFine() throws {
        XCTAssertThrowsError(try report([], now: 1)) { error in
            XCTAssertEqual(error as? LedgerError, .emptyLedger)
        }
    }

    func testOutOfOrderEntriesThrow() throws {
        XCTAssertThrowsError(try report([mark(.sessionStarted, 10), block(0, 0, 5)], now: 20))
    }

    // MARK: - 落盘读写

    private func tempLedger() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("ledger.jsonl")
    }

    func testAppendThenReadRoundTrips() throws {
        let url = tempLedger()
        let entries = [mark(.sessionStarted, 0), block(0, 0, 5), mark(.sessionEnded, 5)]
        for e in entries { try BlockLedger.append(e, to: url) }

        let (read, truncated) = try BlockLedger.read(from: url)
        XCTAssertEqual(read, entries)
        XCTAssertFalse(truncated)
        XCTAssertEqual(try BlockLedger.relaunchReport(entries: read, now: at(9)).gapMs, 0)
    }

    func testTornLastLineIsToleratedNotFatal() throws {
        // App 被 jetsam 杀在 append 中间 —— 最后一行只写了一半。这是常态,
        // 丢掉半行不影响任何结论(那条事件本来就没完成)。
        let url = tempLedger()
        try BlockLedger.append(mark(.sessionStarted, 0), to: url)
        try BlockLedger.append(block(0, 0, 5), to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        try (text + "{\"at\":\"2026-08-10T09:0").write(to: url, atomically: true, encoding: .utf8)

        let (read, truncated) = try BlockLedger.read(from: url)
        XCTAssertTrue(truncated)
        XCTAssertEqual(read.count, 2)
        XCTAssertEqual(try BlockLedger.relaunchReport(entries: read, now: at(10)).gapMs,
                       5 * 60 * 1000, "尾行残缺不该影响前面已完整的记录")
    }

    func testCorruptMiddleLineThrows() throws {
        // 中间的行坏了跳过去,结果是少算一段空洞 —— 而少算出来的报告看着完全正常。
        let url = tempLedger()
        try BlockLedger.append(mark(.sessionStarted, 0), to: url)
        try BlockLedger.append(block(0, 0, 5), to: url)
        try BlockLedger.append(mark(.sessionEnded, 5), to: url)
        var lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        lines[1] = "{ 半截"
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try BlockLedger.read(from: url)) { error in
            guard case .corruptLine(let n, _)? = error as? LedgerError else {
                return XCTFail("应当是 corruptLine,实际 \(error)")
            }
            XCTAssertEqual(n, 2)
        }
    }
}

// MARK: - 今天录了什么(点完结束总得看见自己录了什么)

extension BlockLedgerTests {

    func testSessionsAreSplitPerRecording() throws {
        // 一个目录一天,一天可能录很多场。只看最后一条会把早上那场当成不存在。
        let entries = [mark(.sessionStarted, 0), block(0, 0, 5), mark(.sessionEnded, 5),
                       mark(.sessionStarted, 30), block(1, 30, 40), mark(.sessionEnded, 40)]
        let s = BlockLedger.sessions(entries: entries)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0].recordedSeconds, 5 * 60, accuracy: 1)
        XCTAssertEqual(s[1].recordedSeconds, 10 * 60, accuracy: 1)
        XCTAssertEqual(s.map(\.blockCount), [1, 1])
    }

    func testRecordedTimeExcludesPauses() throws {
        // 时长是**块时长之和**,不是首尾之差 —— 中间暂停的 25 分钟不该算进去。
        let entries = [mark(.sessionStarted, 0), block(0, 0, 5), mark(.paused, 5),
                       mark(.resumed, 30), block(1, 30, 35), mark(.sessionEnded, 35)]
        let s = BlockLedger.sessions(entries: entries)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].recordedSeconds, 10 * 60, accuracy: 1, "暂停的 25 分钟被算进去了")
    }

    func testUnclosedSessionIsMarkedOpenNotDropped() throws {
        // 被杀掉的那场没有 sessionEnded。丢掉它 = 用户看不到自己录过 ——
        // 而那场恰恰是最需要被看见的(它有空洞)。
        let s = BlockLedger.sessions(entries: [mark(.sessionStarted, 0), block(0, 0, 5)])
        XCTAssertEqual(s.count, 1)
        XCTAssertTrue(s[0].isOpen)
    }

    func testTwoStartsWithoutEndDoNotMergeIntoOneSession() throws {
        let s = BlockLedger.sessions(entries: [
            mark(.sessionStarted, 0), block(0, 0, 5),
            mark(.sessionStarted, 30), block(1, 30, 35)])
        XCTAssertEqual(s.count, 2, "两场被并成了一场")
    }

    // MARK: - 崩了重开:被顶掉的那一场不能还算「在录」

    /// `isOpen == (endedAt == nil)`,而 `endedAt` 会一路写成 `sessions.status`。
    /// 被后一场顶掉的场次若还填 nil,库里就留下「正在录音」的僵尸行 ——
    /// 2026-08-13 真机实测,App 崩三次留下 5 条,首页会显示成 5 条「正在录音」。
    func testSessionSupersededByANewStartIsNotStillOpen() throws {
        let t0 = Date(timeIntervalSince1970: 1_786_000_000)
        let entries: [LedgerEntry] = [
            LedgerEntry(at: t0, mark: .sessionStarted),
            LedgerEntry(block: BlockRecord(seq: 0, startedAt: t0, endedAt: t0 + 60,
                                           hardCut: true, fileName: "b0.m4a")),
            // 崩了,没有 sessionEnded,用户重开又点了开始
            LedgerEntry(at: t0 + 300, mark: .sessionStarted),
            LedgerEntry(block: BlockRecord(seq: 1, startedAt: t0 + 300, endedAt: t0 + 400,
                                           hardCut: true, fileName: "b1.m4a")),
            LedgerEntry(at: t0 + 400, mark: .sessionEnded),
        ]
        let out = BlockLedger.sessions(entries: entries)
        XCTAssertEqual(out.count, 2)
        XCTAssertFalse(out[0].isOpen, "被顶掉的那一场还算「在录」—— 库里会留下僵尸行")
        XCTAssertEqual(out[0].endedAt, t0 + 60, "收尾时刻应该是最后一个块的结束时刻")
        XCTAssertFalse(out[1].isOpen)
    }

    /// 一个块都没录到就被顶掉:长度为零,如实呈现「开了但没录上」。
    func testSupersededSessionWithNoBlocksClosesAtItsOwnStart() throws {
        let t0 = Date(timeIntervalSince1970: 1_786_000_000)
        let out = BlockLedger.sessions(entries: [
            LedgerEntry(at: t0, mark: .sessionStarted),
            LedgerEntry(at: t0 + 8, mark: .sessionStarted),
        ])
        XCTAssertEqual(out.count, 2)
        XCTAssertFalse(out[0].isOpen)
        XCTAssertEqual(out[0].endedAt, t0, "什么都没录到,却报了一段时长")
    }

    /// **最后那一场必须还能是「在录」** —— 修上面那条别把这条也改掉了。
    func testTheLastSessionStaysOpenWhileStillRecording() throws {
        let t0 = Date(timeIntervalSince1970: 1_786_000_000)
        let out = BlockLedger.sessions(entries: [LedgerEntry(at: t0, mark: .sessionStarted)])
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].isOpen, "正在录的那一场被收口了 —— 界面会显示成已结束")
    }
}
