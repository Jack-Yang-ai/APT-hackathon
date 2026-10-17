import XCTest
import GRDB
@testable import GrowthApp

/// `MatterWriting` 的真实现(M2-B2 第二段)。
///
/// 验收原文(M2-F4):**三键各按一次,`judgments` 增三行且 `actor='user'`** ——
/// 桩被替掉之后这条才做得了,所以在这里补上。
final class MatterStoreTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private var store: MatterStore!
    private let now = "2026-08-19T10:00:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        store = MatterStore(db: dbQueue)
    }
    override func tearDownWithError() throws { dbQueue = nil; store = nil }

    @discardableResult
    private func nominate(_ title: String = "产品该定位成什么", score: Double = 5) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO matter_nominations (title, score, evidence, created_at)
                VALUES (?, ?, '{}', ?)
                """, arguments: [title, score, now])
            return db.lastInsertedRowID
        }
    }

    private func judgments(_ matterID: Int64) throws -> [(String, String)] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT action, actor FROM judgments
                 WHERE target_kind = 'matter' AND target_id = ? ORDER BY id
                """, arguments: ["\(matterID)"]).map { ($0["action"], $0["actor"]) }
        }
    }

    private func state(_ id: Int64) throws -> String? {
        try dbQueue.read { try String.fetchOne($0, sql: "SELECT state FROM matters WHERE id = ?",
                                               arguments: [id]) }
    }

    // MARK: - 三键各按一次

    /// 「单独盯着它」:建一件候选 → 提到活跃。**两步都留痕**,
    /// 于是账本上能看出「它生为候选、被你提上来」。
    func testPromoteCreatesTheMatterAsCandidateThenActivatesIt() throws {
        let n = try nominate()
        let m = try store.promote(nomination: n, now: now)
        XCTAssertEqual(try state(m), "活跃")
        XCTAssertEqual(try judgments(m).map(\.0), ["matter_to_活跃"])
        XCTAssertEqual(try judgments(m).map(\.1), ["user"], "actor 必须是 user")
        // 提名行指向它了 —— 逐张队列据此不再重复问
        XCTAssertEqual(try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT matter_id FROM matter_nominations WHERE id = ?",
                               arguments: [n])
        }, m)
    }

    /// 「不用」→ 已拒绝。**必须建 `matters` 行** —— PRD 要求拒绝过的仍可搜索找回。
    func testDismissLeavesASearchableRejectedMatter() throws {
        let n = try nominate()
        try store.dismiss(nomination: n, now: now)
        let m = try XCTUnwrap(try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT matter_id FROM matter_nominations WHERE id = ?",
                               arguments: [n])
        })
        XCTAssertEqual(try state(m), "已拒绝")
        XCTAssertEqual(try dbQueue.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT searchable FROM matter_states WHERE state = '已拒绝'
                """)
        }, true, "拒绝过的该还能搜到 —— PRD 特意标了粗")
    }

    /// 🔴 「说不准」**状态不变,但必须留痕**。
    ///
    /// 「看过并决定先不决定」与「还没看过」是两件事,而 30 天静默拒绝那条规则
    /// 要靠这个区分 —— 不写的话,一条用户主动搁置的候选会在第 30 天
    /// 被系统当成「没人管」悄悄拒掉。
    func testDeferKeepsTheStateButStillLeavesAJudgment() throws {
        let n = try nominate()
        try store.defer_(nomination: n, now: now)
        let m = try XCTUnwrap(try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT matter_id FROM matter_nominations WHERE id = ?",
                               arguments: [n])
        })
        XCTAssertEqual(try state(m), "候选", "「说不准」不该改状态")
        XCTAssertEqual(try judgments(m).map(\.0), ["matter_defer"],
                       "「说不准」没留痕 —— 30 天后它会被当成「没人管」悄悄拒掉")
    }

    /// 三键各按一次 ⇒ `judgments` 里恰好三行、全是 `user`(F4 验收原文)。
    func testThreeKeysProduceThreeUserJudgments() throws {
        let a = try nominate("甲"), b = try nominate("乙"), c = try nominate("丙")
        _ = try store.promote(nomination: a, now: now)
        try store.dismiss(nomination: b, now: now)
        try store.defer_(nomination: c, now: now)
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT action, actor FROM judgments WHERE target_kind = 'matter' ORDER BY id
                """)
        }
        XCTAssertEqual(rows.count, 3, "三键各按一次该恰好三行:\(rows.map { $0["action"] as String })")
        XCTAssertEqual(Set(rows.map { $0["actor"] as String }), ["user"])
    }

    // MARK: - 墨菲:拿边界打自己

    /// 重复点不该造出两件事(网络慢时用户会点两下)。
    func testAdoptingTheSameNominationTwiceReusesTheSameMatter() throws {
        let n = try nominate()
        let first = try store.promote(nomination: n, now: now)
        try store.sleep(matter: first, now: now)
        // 再点一次「单独盯着它」—— 该是把同一件唤醒,不是新建一件
        let second = try store.promote(nomination: n, now: now)
        XCTAssertEqual(first, second, "重复点造出了第二件事")
        XCTAssertEqual(try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM matters")
        }, 1)
    }

    /// 🔴 满员被拒时,**上一步建的候选行要随事务回滚** ——
    /// 否则库里会留下一个用户从没同意过的半吊子候选。
    func testAFullBoardRollsBackTheJustCreatedCandidate() throws {
        for i in 0..<MatterCapacity.activeLimit {
            _ = try store.promote(nomination: try nominate("第 \(i) 件"), now: now)
        }
        let extra = try nominate("第 11 件")
        XCTAssertThrowsError(try store.promote(nomination: extra, now: now))
        XCTAssertEqual(try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM matters")
        }, MatterCapacity.activeLimit, "满员被拒之后库里多了一件 —— 事务没回滚")
        XCTAssertNil(try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT matter_id FROM matter_nominations WHERE id = ?",
                               arguments: [extra])
        }, "提名行被指向了一件根本没建成的事")
    }

    /// 关悬点:写判断 + 投影到 `closed_at`,而且**只关还开着的**。
    func testClosingAQuestionWritesAJudgmentAndProjectsIt() throws {
        let n = try nominate()
        let m = try store.promote(nomination: n, now: now)
        let q = try dbQueue.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO matter_open_questions (matter_id, question, opened_at)
                VALUES (?, '定位到底是什么', ?)
                """, arguments: [m, now])
            return db.lastInsertedRowID
        }
        try store.closeQuestion(q, now: now)
        XCTAssertEqual(try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT closed_at FROM matter_open_questions WHERE id = ?",
                               arguments: [q])
        }, now)
        XCTAssertEqual(try dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT action FROM judgments WHERE target_kind = 'question' AND target_id = ?
                """, arguments: ["\(q)"])
        }, "close_question", "关悬点没进判断库 —— 用户动作一律写 judgments(缺口 B)")
        // 已经关了的再关一次要抛,而不是静默改一遍 closed_at
        XCTAssertThrowsError(try store.closeQuestion(q, now: now))
    }

    /// 找不到的提名 / 事,抛「找不到」而不是静默 no-op。
    func testMissingTargetsThrowInsteadOfDoingNothing() {
        XCTAssertThrowsError(try store.promote(nomination: 999, now: now))
        XCTAssertThrowsError(try store.close(matter: 999, now: now))
        XCTAssertThrowsError(try store.closeQuestion(999, now: now))
    }
}
