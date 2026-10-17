import XCTest
import GRDB
@testable import GrowthApp

/// 录音账本 → `sessions` 表的桥。
///
/// 这座桥在 M0 结束时是**断的**:录音写账本文件,首页读 `sessions` 表,中间没人接。
/// 所以这组测试的重点不是「能插进去」,而是**反复调用不会插重**
/// —— 那才是重复的场次行污染下游的入口。
final class SessionBridgeTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let day = "2026-08-12"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
    }
    override func tearDownWithError() throws { dbQueue = nil }

    private func session(_ startMin: Int, endMin: Int?, blocks: Int = 2)
        -> BlockLedger.SessionSummary {
        let base = Date(timeIntervalSince1970: 1_786_000_000)
        return BlockLedger.SessionSummary(
            startedAt: base.addingTimeInterval(TimeInterval(startMin * 60)),
            endedAt: endMin.map { base.addingTimeInterval(TimeInterval($0 * 60)) },
            blocks: fakeBlocks(blocks), recordedSeconds: 300)
    }

    private func rows() throws -> [(String, String?, String)] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT started_at, ended_at, status FROM sessions ORDER BY started_at
                """).map { ($0["started_at"], $0["ended_at"], $0["status"]) }
        }
    }

    func testRecordedSessionsLandInTheTable() throws {
        let r = try SessionBridge.sync([session(0, endMin: 30), session(60, endMin: 95)],
                                       day: day, in: dbQueue)
        XCTAssertEqual(r.inserted, 2)
        XCTAssertEqual(try rows().count, 2)
        XCTAssertEqual(try rows().map(\.2), ["closed", "closed"])
    }

    /// **反复同步不会插重。** 这是这座桥唯一真正危险的地方 ——
    /// 每次进前台都会调一次,靠调用方记得去重迟早会漏。
    func testSyncingTwiceDoesNotDuplicate() throws {
        let s = [session(0, endMin: 30)]
        try SessionBridge.sync(s, day: day, in: dbQueue)
        let second = try SessionBridge.sync(s, day: day, in: dbQueue)
        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(second.updated, 1)
        XCTAssertEqual(try rows().count, 1)
    }

    /// 还开着的那场先落一行 `recording`,封场后同一行变成 `closed` ——
    /// **不是新增一行**。新增的话首页上同一场会出现两次。
    func testOpenSessionIsUpdatedInPlaceWhenItCloses() throws {
        try SessionBridge.sync([session(0, endMin: nil)], day: day, in: dbQueue)
        XCTAssertEqual(try rows().map(\.2), ["recording"])
        XCTAssertNil(try rows()[0].1)

        try SessionBridge.sync([session(0, endMin: 30)], day: day, in: dbQueue)
        XCTAssertEqual(try rows().count, 1, "封场不该新增一行")
        XCTAssertEqual(try rows()[0].2, "closed")
        XCTAssertNotNil(try rows()[0].1)
    }

    /// 唯一索引挡的是**绕过本文件**的直接插入 —— 幂等由数据库保证,不靠调用方自觉。
    func testDatabaseItselfRejectsADuplicateOrigin() throws {
        try SessionBridge.sync([session(0, endMin: 30)], day: day, in: dbQueue)
        let started = try rows()[0].0
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (started_at, day, source, status)
                VALUES (?, ?, ?, 'closed')
                """, arguments: [started, day, SessionBridge.source])
        })
    }

    /// 导入来路与录音来路可以同起点,互不相顶 —— 键是 (source, started_at) 不是单时间。
    func testAnotherSourceMayShareTheSameStartTime() throws {
        try SessionBridge.sync([session(0, endMin: 30)], day: day, in: dbQueue)
        let started = try rows()[0].0
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (started_at, day, source, status)
                VALUES (?, ?, 'import', 'closed')
                """, arguments: [started, day])
        }
        XCTAssertEqual(try rows().count, 2)
    }

    // MARK: - 崩在录音中的场次(M1-14c)

    /// 🔴 **验收:造一个跨天的未收尾场次,断言它能被收尾并排进处理队列。**
    ///
    /// 进程被杀时账本没有 `sessionEnded` ⇒ `status='recording'` ⇒
    /// 首页无条件显示「录音中」(那个态压过一切),而入队只捞 `closed`
    /// ⇒ **永远没有人处理它**。当天再录一场有账本那条补救,
    /// 但**跨天之后账本不再被读** —— 就永久钉住了。
    func testAnAbandonedSessionFromAnEarlierDayIsClosedAndQueued() throws {
        let day = "2026-08-11"                       // 「今天」之外的某一天
        let base = Date(timeIntervalSince1970: 1_786_000_000)
        let dir = ProcessingPump.recordingsRoot.appendingPathComponent(day)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        // 账本里只有开始与两个块,**没有 sessionEnded** —— 这就是被杀的形状
        let ledger = dir.appendingPathComponent("ledger.jsonl")
        try BlockLedger.append(LedgerEntry(at: base, mark: .sessionStarted), to: ledger)
        for seq in 0..<2 {
            try BlockLedger.append(LedgerEntry(block: BlockRecord(
                seq: seq,
                startedAt: base.addingTimeInterval(Double(seq) * 300),
                endedAt: base.addingTimeInterval(Double(seq + 1) * 300),
                hardCut: true, fileName: "block-\(seq).m4a")), to: ledger)
        }
        let entries = try BlockLedger.read(from: ledger).0
        try SessionBridge.sync(BlockLedger.sessions(entries: entries), day: day, in: dbQueue)

        // 前提:它现在就是那个「永久录音中」的样子
        XCTAssertEqual(try rows().map(\.2), [SessionBridge.Status.open])

        let closed = try SessionBridge.closeAbandoned(in: dbQueue)
        XCTAssertEqual(closed.count, 1)

        let row = try XCTUnwrap(rows().first)
        XCTAssertEqual(row.2, SessionBridge.Status.closed)
        // 收尾时间取**最后一个块的结束时刻**,不是「现在」——
        // 填「现在」会把一场 10 分钟的录音说成横跨好几天。
        XCTAssertEqual(row.1, SessionBridge.iso(base.addingTimeInterval(600)))

        // 而且真的排得进队 —— 只收尾不入队等于换了个说法继续不处理
        let id = try XCTUnwrap(closed.first)
        XCTAssertTrue(try ProcessingOrchestrator.enqueueSession(
            id, now: "x", in: dbQueue), "收尾了却排不进队")
    }

    /// 一个块都没有的场次:用起点收口,长度为零,如实呈现「开了但没录上」。
    /// 不许拿「现在」去填 —— 那是编一个没有证据的时长。
    func testASessionThatRecordedNothingIsClosedAtItsOwnStart() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (started_at, day, source, status)
                VALUES ('2026-08-11T10:00:00+08:00', '2026-08-11', 'recording', 'recording')
                """)
        }
        XCTAssertEqual(try SessionBridge.closeAbandoned(in: dbQueue).count, 1)
        let row = try XCTUnwrap(rows().first)
        XCTAssertEqual(row.1, row.0, "没有块就该用起点收口")
        XCTAssertEqual(row.2, SessionBridge.Status.closed)
    }

    /// 已经收尾的场次一个都不许碰 —— 重复调用要幂等。
    func testClosingAbandonedSessionsIsIdempotent() throws {
        try SessionBridge.sync([session(0, endMin: 30)], day: day, in: dbQueue)
        XCTAssertTrue(try SessionBridge.closeAbandoned(in: dbQueue).isEmpty)
        XCTAssertEqual(try rows().first?.1, SessionBridge.iso(
            Date(timeIntervalSince1970: 1_786_000_000).addingTimeInterval(30 * 60)),
            "已收尾场次的 ended_at 被改了")
    }
}
