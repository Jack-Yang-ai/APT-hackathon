import XCTest
import GRDB
@testable import GrowthApp

/// 场次分级落表(迁移 v9)。
///
/// 这组测试的重点**不是**「能写进去」,而是「写错了会不会被挡住」。
///
/// 分级决定一场值不值得花钱出纪要。若拼错一个档位不报错,它会变成一个
/// 永远匹配不上任何规则的孤儿值 —— 而行数照涨、日志照绿、exit code 全绿。
/// 这正是本仓最贵的那种事故形态:**成功地写进了错的地方**。
/// CHECK 约束就是为这一条存在的,所以它必须有测试盯着。
final class SessionGradeTests: XCTestCase {

    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
    }
    override func tearDownWithError() throws { dbQueue = nil }

    @discardableResult
    private func insert(startedAt: String, grade: String?, source: String?) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (started_at, day, source, status, grade, grade_source)
                VALUES (?, '2026-08-12', 'recording', 'closed', ?, ?)
                """, arguments: [startedAt, grade, source])
            return db.lastInsertedRowID
        }
    }

    // MARK: - 闭集必须被数据库挡住,不靠调用方自觉

    /// 四个合法档位全部写得进去。**逐个试,不抽样** —— 只试一个的话,
    /// CHECK 里漏打一个档位这种错会一直活到线上。
    func testAllFourGradesAreAccepted() throws {
        for (i, g) in SessionBridge.Grade.allCases.enumerated() {
            try insert(startedAt: "2026-08-12T1\(i):00:00+08:00",
                       grade: g.rawValue, source: "deepseek-v4-flash")
        }
        let n = try dbQueue.read { try Int.fetchOne($0, sql:
            "SELECT COUNT(*) FROM sessions WHERE grade IS NOT NULL") }
        XCTAssertEqual(n, SessionBridge.Grade.allCases.count)
    }

    /// 闭集之外的值必须被拒。**这是这一列存在 CHECK 的全部理由。**
    func testGradeOutsideTheClosedSetIsRejected() {
        for bad in ["FULL", "完整", "transcriptonly", "partial", ""] {
            XCTAssertThrowsError(
                try insert(startedAt: "2026-08-12T20:00:00+08:00", grade: bad, source: "rule"),
                "「\(bad)」被写进去了 —— CHECK 没挡住,分级就等于没有闭集"
            )
        }
    }

    /// NULL 合法,它表示「还没评级」—— 一个真实存在的状态(刚落盘、还没进处理链)。
    func testNullMeansNotGradedYet() throws {
        try insert(startedAt: "2026-08-12T09:00:00+08:00", grade: nil, source: nil)
        let n = try dbQueue.read { try Int.fetchOne($0, sql:
            "SELECT COUNT(*) FROM sessions WHERE grade IS NULL") }
        XCTAssertEqual(n, 1)
    }

    // MARK: - Swift 侧的闭集与迁移里的 CHECK 是同一份契约的两半

    /// 若有人在 `Grade` 里加了一档而没改迁移,这条会红。
    /// 反过来(改了迁移没改 Grade)测不到 —— 那种情况的症状是「某个档位读不出来」,
    /// 得靠上面 `testAllFourGradesAreAccepted` 逐个试来暴露。
    func testSwiftEnumMatchesTheDatabaseCheck() throws {
        for g in SessionBridge.Grade.allCases {
            XCTAssertNoThrow(
                try insert(startedAt: "2026-08-13T\(g.rawValue.count):00:00+08:00",
                           grade: g.rawValue, source: SessionBridge.gradeSourceRule),
                "Grade.\(g) 的字面量「\(g.rawValue)」不在迁移 v9 的 CHECK 里"
            )
        }
    }

    // MARK: - 老库升上来不能炸,也不能被填上假的分级

    /// v8 时代写进去的场次,升到 v9 之后 `grade` 必须是 NULL。
    ///
    /// **不能给它填一个默认档位** —— 那些场次究竟该是哪一档我们并不知道,
    /// 填 'full' 等于替它们撒谎,而且会让它们混进「值得花钱」的集合里。
    /// 同一个道理已经用在 `voiceprints.model` 的 'unknown-pre-v7' 上,
    /// 只是这里更干脆:NULL 本身就表达「不知道」。
    func testRowsFromBeforeV9StayUngraded() throws {
        let legacy = try DatabaseQueue()
        let upToV8 = AppDatabase.makeMigrator()
        try upToV8.migrate(legacy, upTo: "v8_session_identity")
        try legacy.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (started_at, day, source, status)
                VALUES ('2026-08-01T10:00:00+08:00', '2026-08-01', 'recording', 'closed')
                """)
        }
        try upToV8.migrate(legacy)   // 补跑到最新

        let grade = try legacy.read { db in
            try Optional<String>.fetchOne(db, sql: "SELECT grade FROM sessions") ?? nil
        }
        XCTAssertNil(grade, "老场次被填上了分级 —— 那是替它撒谎")
    }

    /// 分级不是场次身份的一部分:改分级不该影响 `SessionBridge` 的幂等。
    /// (身份键是 `(source, started_at)`,见迁移 v8。)
    func testGradeSurvivesABridgeResync() throws {
        let base = Date(timeIntervalSince1970: 1_786_000_000)
        let s = BlockLedger.SessionSummary(startedAt: base, endedAt: nil,
                                           blocks: fakeBlocks(1), recordedSeconds: 300)
        try SessionBridge.sync([s], day: "2026-08-12", in: dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE sessions SET grade = ?, grade_source = ?",
                           arguments: [SessionBridge.Grade.light.rawValue, "deepseek-v4-flash"])
        }

        // 再同步一次(每次进前台都会发生)
        let closed = BlockLedger.SessionSummary(startedAt: base,
                                                endedAt: base.addingTimeInterval(1800),
                                                blocks: fakeBlocks(6), recordedSeconds: 1800)
        try SessionBridge.sync([closed], day: "2026-08-12", in: dbQueue)

        let row = try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT grade, grade_source, status FROM sessions")
        }
        XCTAssertEqual(row?["grade"], SessionBridge.Grade.light.rawValue,
                       "重新同步把分级冲掉了 —— 桥只该更新 ended_at 与 status")
        XCTAssertEqual(row?["grade_source"], "deepseek-v4-flash")
        XCTAssertEqual(row?["status"], SessionBridge.Status.closed)
    }
}
