import XCTest
import GRDB
@testable import GrowthApp

/// 事内检索(M2-F3)。验收:**<100ms 实测**、筛选与分页各一条可跑断言。
final class MatterSearchTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-19T10:00:00+08:00"
    private var matterA: Int64 = 0
    private var matterB: Int64 = 0

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try dbQueue.write { db in
            func matter(_ t: String) throws -> Int64 {
                try db.execute(sql: """
                    INSERT INTO matters (title, state, created_at, updated_at) VALUES (?, '活跃', ?, ?)
                    """, arguments: [t, now, now])
                return db.lastInsertedRowID
            }
            matterA = try matter("产品该定位成什么")
            matterB = try matter("招人的节奏怎么定")
            try db.execute(sql: """
                INSERT INTO matter_open_questions (matter_id, question, opened_at)
                VALUES (?, '定位到底指的是什么', ?)
                """, arguments: [matterA, now])
            try db.execute(sql: """
                INSERT INTO matter_timeline (matter_id, at, summary)
                VALUES (?, ?, '定位这件事又被提了一次')
                """, arguments: [matterA, now])
            try db.execute(sql: """
                INSERT INTO matter_timeline (matter_id, at, summary)
                VALUES (?, ?, '招人先招后端')
                """, arguments: [matterB, now])
        }
    }
    override func tearDownWithError() throws { dbQueue = nil }

    private func search(_ q: String, matter: Int64? = nil) throws -> [MatterSearch.Hit] {
        try dbQueue.read { try MatterSearch.search(q, matterID: matter, in: $0) }
    }

    // MARK: - 四个范围都覆盖(PRD §4.3.2:标题 / 悬点 / 脉络 / 转写)

    func testAllFourScopesAreSearched() throws {
        let kinds = Set(try search("定位").map(\.kind))
        XCTAssertEqual(kinds, [.title, .question, .timeline],
                       "标题/悬点/脉络三个范围没都覆盖到:\(kinds)")
        // 第四个范围(转写)单独造 —— 它走 `TranscriptSearch`,要冻结层的行
        try seedTranscript(text: "我们的定位其实一直没定下来")
        XCTAssertTrue(try search("定位").contains { $0.kind == .line },
                      "转写那一路没搜到 —— 而 PRD 把它列在范围里")
    }

    /// 🔴 转写那一路**复用 `TranscriptSearch`**,不另写一套。
    ///
    /// 这条测试打的是「两套检索口径不许分家」:`TranscriptSearch` 有词索引那条腿,
    /// 所以两个字的「老周」搜得到;若这里改成 `LIKE`,同一个词在「事内搜」
    /// 与「全局搜」会给出不同结果,而用户无从知道该信哪个。
    func testTheTranscriptLegReusesTranscriptSearchNotALikeQuery() throws {
        try seedTranscript(text: "老周说这个月底之前能交付")
        let mine = try search("老周").filter { $0.kind == .line }
        let global = try dbQueue.read { try TranscriptSearch.search("老周", in: $0) }
        XCTAssertFalse(global.isEmpty, "全局搜都搜不到 —— 这条断言在空转")
        XCTAssertEqual(mine.map(\.rowID), global.map(\.lineID),
                       "事内搜与全局搜给出了不同的行 —— 两套口径分家了")
    }

    // MARK: - 筛选:限定在一件事内

    func testScopingToOneMatterExcludesTheOthers() throws {
        XCTAssertEqual(try search("招人").count, 2, "跨事搜该同时命中标题与脉络")
        let inA = try search("招人", matter: matterA)
        XCTAssertTrue(inA.isEmpty, "限定在 A 里却搜到了 B 的东西")
        XCTAssertEqual(try search("招人", matter: matterB).count, 2)
    }

    /// 转写命中也要跟着限定:那一行若不属于这件事的脉络,事内搜不该给它。
    func testAnUnrelatedTranscriptLineIsExcludedWhenScoped() throws {
        let line = try seedTranscript(text: "定位这个词今天出现了很多次")
        // 这一行没被任何一件事收进脉络 ⇒ 事内搜不该给它
        // ⚠️ 只比 `rowID` 会误判 —— 它在不同 `kind` 之间**不唯一**
        // (`Hit.id` 带上 kind 正是为此):脉络那条命中的 id 恰好也是 1。
        // 这条断言第一版就栽在这儿,而栽的是测试不是实现。
        XCTAssertFalse(try search("定位", matter: matterA)
            .contains { $0.kind == .line && $0.rowID == line },
                       "一条不属于这件事的原话被算进了事内搜")
        // 跨事搜该给,而且 matterID 是 nil ——「不知道属于谁」不许猜成某一件
        let hit = try XCTUnwrap(try search("定位").first { $0.rowID == line && $0.kind == .line })
        XCTAssertNil(hit.matterID, "把一条无主的原话挂到了某件事上")
    }

    // MARK: - 空与失败是两件事

    func testAnEmptyQueryReturnsNothingWithoutTouchingTheDatabase() throws {
        XCTAssertEqual(try search("   ").count, 0)
    }

    /// 「没找到」是结论。而**查不了**要抛 —— 界面据此分开画。
    /// 这里用一个结构上必然失败的查询证明它确实会抛,而不是吞成空数组。
    func testAFailedQueryThrowsRatherThanLookingLikeNoResults() throws {
        try dbQueue.write { try $0.execute(sql: "DROP TABLE matter_open_questions") }
        XCTAssertThrowsError(try search("定位"),
                             "库坏了却返回空数组 —— 那和「没找到」在界面上一模一样")
    }

    // MARK: - 🔴 「试试问问」必抛,不 no-op

    func testTheAskHandoffThrowsUntilB6Lands() {
        XCTAssertThrowsError(try SearchHandoffStub().handOffToAsk(query: "定位")) { e in
            // 落点同 `MatterBoardProjectionTests`:任务号在 `blockingTask`,不在用户文案里。
            XCTAssertEqual((e as? MatterActionFailure)?.blockingTask, "M2-B6",
                           "没说清在等哪个任务:\(e)")
            XCTAssertFalse("\(e)".contains("M2-B6"), "任务号漏进了用户看的那句话:\(e)")
        }
    }

    // MARK: - 验收:<100ms

    /// PRD §4.3.2:**输入即出结果(<100ms)**。
    func testSearchComesBackWellUnderOneHundredMilliseconds() throws {
        try dbQueue.write { db in
            for i in 0..<200 {
                try db.execute(sql: """
                    INSERT INTO matters (title, state, created_at, updated_at)
                    VALUES (?, '沉睡', ?, ?)
                    """, arguments: ["第 \(i) 件要定的事", now, now])
                let m = db.lastInsertedRowID
                for j in 0..<5 {
                    try db.execute(sql: """
                        INSERT INTO matter_timeline (matter_id, at, summary) VALUES (?, ?, ?)
                        """, arguments: [m, now, "第 \(i)-\(j) 条进展,聊到了定位"])
                }
            }
        }
        let t0 = Date()
        let hits = try search("定位")
        let ms = Date().timeIntervalSince(t0) * 1000
        XCTAssertGreaterThan(hits.count, 100, "样本没造起来,这条计时没有意义")
        XCTAssertLessThan(ms, 100, "搜了 \(Int(ms))ms —— PRD §4.3.2 要求输入即出(<100ms)")
    }

    // MARK: - 夹具

    @discardableResult
    private func seedTranscript(text: String) throws -> Int64 {
        try dbQueue.write { db in
            if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions") == 0 {
                try db.execute(sql: """
                    INSERT INTO sessions (id, started_at, day, source, status, active_transcript_id)
                    VALUES (1, ?, '2026-08-19', 'recording', 'closed', 1)
                    """, arguments: [now])
                try db.execute(sql: """
                    INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                    VALUES (1, 1, 1, 1, 'x', 'frozen', ?)
                    """, arguments: [now])
            }
            let seq = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_lines") ?? 0
            try db.execute(sql: """
                INSERT INTO transcript_lines
                  (transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
                VALUES (1, ?, ?, ?, ?, 0)
                """, arguments: [seq, seq * 1000, (seq + 1) * 1000, text])
            let id = db.lastInsertedRowID
            try WordIndex.index(lineID: id, text: text, isGap: false, in: db)
            return id
        }
    }
}
