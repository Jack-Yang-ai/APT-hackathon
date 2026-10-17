import XCTest
import GRDB
@testable import GrowthApp

/// 缺块必须在逐字稿里留下洞(M1-14a)。
///
/// 🔴 **这一条守的是本仓最贵的那种错法**:`TranscriptFreeze` 的 `missing:` 参数
/// 一直存在、一直有默认值,而**生产唯一调用点从来没传过它** ——
/// 于是上传层跳过的坏块、转写失败的块、报文解不开的块,三条来路的洞
/// 全被静默抹平:转写照样标 `frozen`、卡片照样显示「好了」,
/// 而逐字稿里那几分钟**凭空消失,时间轴上看不出洞**。
///
/// 所以这组测试打的是 `ProcessingPump.dependencies(in:).freeze` 那个**真闭包**,
/// 不是 `TranscriptFreeze` 本身 —— 后者一直是对的,错的是没人给它传参。
final class PartialFreezeTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let day = "2026-08-16"
    private let base = Date(timeIntervalSince1970: 1_786_000_000)
    private var dir: URL!

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)

        // 账本:三块,每块 300 秒。**账本是「这一场到底录了哪些块」的唯一真相源**,
        // 缺块就是拿它作差算出来的。
        dir = ProcessingPump.recordingsRoot.appendingPathComponent(day)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }

        let ledger = dir.appendingPathComponent("ledger.jsonl")
        try BlockLedger.append(LedgerEntry(at: base, mark: .sessionStarted), to: ledger)
        for seq in 0..<3 {
            try BlockLedger.append(LedgerEntry(block: BlockRecord(
                seq: seq,
                startedAt: base.addingTimeInterval(Double(seq) * 300),
                endedAt: base.addingTimeInterval(Double(seq + 1) * 300),
                hardCut: true, fileName: "block-\(seq).m4a")), to: ledger)
        }
        try BlockLedger.append(
            LedgerEntry(at: base.addingTimeInterval(900), mark: .sessionEnded), to: ledger)

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, ended_at, day, source, status)
                VALUES (1, ?, ?, ?, 'recording', 'closed')
                """, arguments: [SessionBridge.iso(base),
                                 SessionBridge.iso(base.addingTimeInterval(900)), day])
        }
    }

    override func tearDownWithError() throws { dbQueue = nil }

    /// 一块的转写报文。行的时间戳是**块内**的 —— 冻结那一步自己加块起点。
    private func payload(_ text: String) -> String {
        #"{"data":{"result":[{"utterances":[{"start_time":1000,"end_time":4000,"text":"\#(text)","speaker":{"id":"speaker_0"}}]}]}}"#
    }

    private func job(_ seq: Int, text: String) -> ASRJobStore.Job {
        .init(sessionID: 1, blockSeq: seq, remoteID: "r\(seq)",
              state: .done, resultJSON: payload(text), lastError: nil,
              createdAt: "2026-08-08T16:00:00+08:00")
    }

    // MARK: - 验收:三块里第二块永久失败

    /// ① 逐字稿有占位行 ② 转写 status 是 `partial` ③ 卡片不显示「好了」。
    func testAMissingBlockLeavesAHoleAndTheCardDoesNotSayItIsFine() throws {
        // 第 1 块(块号 1)转写失败 —— 落 `asr_jobs` 的 failed,不进 `finished`
        try ASRJobStore.claim(sessionID: 1, blockSeq: 1, remoteID: "r1", now: "x", in: dbQueue)
        try ASRJobStore.fail(sessionID: 1, blockSeq: 1, error: "audio_download",
                             now: "x", in: dbQueue)

        // 生产传进来的就是「成功的那些」(`ASRJobStore.finished`)
        let done = [job(0, text: "第零块说了这句"), job(2, text: "第二块说了这句")]
        let r = try ProcessingPump.dependencies(in: dbQueue, trigger: .foreground)
            .freeze(1, done)

        // ② 转写 status 是 partial
        XCTAssertEqual(r.status, "partial", "缺了一块却自称完整 —— 这正是那个 BUG")

        try dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT status FROM transcripts WHERE session_id = 1
                """), "partial")

            // ① 逐字稿有占位行,而且**占在正确的位置上**(第 0 块之后、第 2 块之前)
            let rows = try Row.fetchAll(db, sql: """
                SELECT text, is_gap, t_start_ms, block_seq FROM transcript_lines ORDER BY seq
                """)
            let gaps = rows.filter { ($0["is_gap"] as Int) == 1 }
            XCTAssertEqual(gaps.count, 1, "洞没留下来:\(rows.map { $0["text"] as String })")
            XCTAssertEqual(gaps.first?["block_seq"] as Int?, 1)
            XCTAssertEqual(gaps.first?["t_start_ms"] as Int?, 300_000,
                           "占位行没落在缺块自己的位置上")
            // 行序不能出洞(A2):正常行 - 占位行 - 正常行
            XCTAssertEqual(rows.map { ($0["is_gap"] as Int) }, [0, 1, 0])
        }

        // ③ 卡片不显示「好了」
        let state = try dbQueue.read { db in
            try HomeProjection.displayState(taskState: nil, taskAttempts: 0, queuedAhead: 0,
                                            transcriptStatus: "partial", summary: nil, in: db)
        }
        XCTAssertNotEqual(state.presentation.label, "好了",
                          "缺了一块,卡片却说「好了」")
    }

    /// 缺块**要留痕**:事件表里说得出缺了哪几块。
    /// 不留的话「这一场本来就短」和「有几分钟没转出来」在库里长得一模一样。
    func testAMissingBlockIsRecordedInTheEventLog() throws {
        try ASRJobStore.claim(sessionID: 1, blockSeq: 1, remoteID: "r1", now: "x", in: dbQueue)
        try ASRJobStore.fail(sessionID: 1, blockSeq: 1, error: "audio_download",
                             now: "x", in: dbQueue)
        _ = try ProcessingPump.dependencies(in: dbQueue, trigger: .foreground)
            .freeze(1, [job(0, text: "有的"), job(2, text: "也有")])
        let outcomes = try ProcessingEvents.recent(limit: 20, in: dbQueue).map(\.outcome)
        XCTAssertTrue(outcomes.contains { $0.contains("缺 1 块") }, "\(outcomes)")
    }

    /// 三块都成功时**不许**平白冒出占位行,status 也该是 `frozen`。
    /// (没有这一条,上面那条可以靠「永远标 partial」作弊通过。)
    func testAllBlocksPresentStaysFrozenWithNoGaps() throws {
        let r = try ProcessingPump.dependencies(in: dbQueue, trigger: .foreground).freeze(
            1, [job(0, text: "一"), job(1, text: "二"), job(2, text: "三")])
        XCTAssertEqual(r.status, "frozen")
        try dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM transcript_lines WHERE is_gap = 1
                """), 0, "什么都没缺却造了个洞")
        }
    }
}
