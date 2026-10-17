import XCTest
import GRDB
@testable import GrowthApp

/// 判断库(§3.3):append-only + judgment_current 由触发器维护。
///
/// undo 的求值只看 `undoes`(被撤的那条),`caused_by` 只管审计链——
/// 拆开之前这两件事挤在一个字段里,级联 undo 因此谁也撤不掉(2026-08-08 拍板修的)。
final class JudgmentStoreTests: XCTestCase {

    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
    }

    override func tearDownWithError() throws { dbQueue = nil }

    @discardableResult
    private func insert(_ action: String,
                        kind: String,
                        target: String,
                        actor: String = "user",
                        causedBy: Int? = nil,
                        undoes: Int? = nil) throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO judgments (decided_at, actor, caused_by, undoes, action, target_kind, target_id)
                VALUES ('2026-08-08T16:00:00+08:00', ?, ?, ?, ?, ?, ?)
                """, arguments: [actor, causedBy, undoes, action, kind, target])
            return Int(db.lastInsertedRowID)
        }
    }

    /// 当前有效判断的 id;没有则 nil。
    private func current(kind: String, target: String) throws -> Int? {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT judgment_id FROM judgment_current WHERE target_kind = ? AND target_id = ?
                """, arguments: [kind, target])
        }
    }

    // MARK: - 验收第一条:UPDATE judgments 抛错

    func testJudgmentsAreAppendOnly() throws {
        let id = try insert("accept_nomination", kind: "thing", target: "42")

        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "UPDATE judgments SET action = 'reject_nomination' WHERE id = ?", arguments: [id])
        }, "判断库只追加,UPDATE 必须 ABORT")

        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM judgments WHERE id = ?", arguments: [id])
        }, "判断库只追加,DELETE 必须 ABORT")

        // 落对没落对:确认那条记录原封不动还在
        let action = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT action FROM judgments WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(action, "accept_nomination")
    }

    // MARK: - 验收第二条:写入 undo 后 judgment_current 正确翻转

    func testUndoFlipsCurrent() throws {
        let accept = try insert("accept_nomination", kind: "thing", target: "42")
        XCTAssertEqual(try current(kind: "thing", target: "42"), accept, "写入后应成为当前判断")

        try insert("undo", kind: "thing", target: "42", undoes: accept)
        XCTAssertNil(try current(kind: "thing", target: "42"), "撤销后该目标不该再有有效判断")
    }

    /// 撤销后再写一条新判断,当前状态应指向新的那条。
    func testNewJudgmentAfterUndoBecomesCurrent() throws {
        let accept = try insert("accept_nomination", kind: "thing", target: "42")
        try insert("undo", kind: "thing", target: "42", undoes: accept)
        let reject = try insert("reject_nomination", kind: "thing", target: "42")

        XCTAssertEqual(try current(kind: "thing", target: "42"), reject)
    }

    /// 目标之间互不串台。
    func testTargetsAreIsolated() throws {
        let a = try insert("accept_nomination", kind: "thing", target: "42")
        let b = try insert("accept_nomination", kind: "thing", target: "43")
        try insert("undo", kind: "thing", target: "42", undoes: a)

        XCTAssertNil(try current(kind: "thing", target: "42"))
        XCTAssertEqual(try current(kind: "thing", target: "43"), b, "撤销 42 不该影响 43")
    }

    /// actor 是闭集。
    func testActorIsClosedSet() throws {
        XCTAssertThrowsError(try insert("undo", kind: "thing", target: "42", actor: "robot"))
    }

    // MARK: - undo 链与级联(拍板后新增 undoes 字段)

    /// undo 指向另一条 undo:撤销那次撤销,原判断**恢复效力**。
    /// §3.3.3 括注写的就是这个结果;`undoes` 定死之后它才算得出来。
    func testUndoOfUndoRestoresOriginal() throws {
        let accept = try insert("accept_nomination", kind: "thing", target: "42")
        let undo1  = try insert("undo", kind: "thing", target: "42", undoes: accept)
        XCTAssertNil(try current(kind: "thing", target: "42"), "第一次撤销之后没有有效判断")

        try insert("undo", kind: "thing", target: "42", undoes: undo1)
        XCTAssertEqual(try current(kind: "thing", target: "42"), accept,
                       "撤销被撤销,原判断该恢复")
    }

    /// 再撤一次:链长 3,又变回无效。
    func testUndoChainParity() throws {
        let accept = try insert("accept_nomination", kind: "thing", target: "42")
        let u1 = try insert("undo", kind: "thing", target: "42", undoes: accept)
        let u2 = try insert("undo", kind: "thing", target: "42", undoes: u1)
        try insert("undo", kind: "thing", target: "42", undoes: u2)
        XCTAssertNil(try current(kind: "thing", target: "42"))
    }

    /// 一条记录只能被撤销一次。要再撤,去撤那条 undo ——
    /// 这条约束让 undo 关系是一条简单链,求值才等价于链长奇偶。
    func testARecordCanOnlyBeUndoneOnce() throws {
        let accept = try insert("accept_nomination", kind: "thing", target: "42")
        try insert("undo", kind: "thing", target: "42", undoes: accept)
        XCTAssertThrowsError(try insert("undo", kind: "thing", target: "42", undoes: accept),
                             "同一条记录被撤两次必须被唯一索引拦下")
    }

    /// 级联撤销:`undoes` 指被撤的那条,`caused_by` 只回链到触发它的用户判断。
    /// 拆开之前这里是撤不掉东西的 —— caused_by 指着触发源,求值却按被撤记录理解。
    func testCascadeUndoVoidsItsTarget() throws {
        let keep    = try insert("keep_stance", kind: "stance", target: "88")
        let trigger = try insert("assign_speaker", kind: "line", target: "1001")
        try insert("undo", kind: "stance", target: "88",
                   actor: "system-cascade", causedBy: trigger, undoes: keep)

        XCTAssertNil(try current(kind: "stance", target: "88"), "级联 undo 必须真的撤掉 stance=88")
        // 触发源自己不受影响:它是 line 的判断,不是 stance 的
        XCTAssertEqual(try current(kind: "line", target: "1001"), trigger)
    }

    /// v3 必须能加到一个**已经停在 v2、而且已有数据**的库上。
    ///
    /// 拍板写明「已发布的 migration 不可回改」,所以 undoes 是加列而不是改 v2。
    /// 只跑全新库证明不了这件事——全新库是 v1→v2→v3 一路建下来的,
    /// 真正要验的是「旧库升级」这条路:老记录还在,新列为 NULL,触发器换了新的。
    func testV3AppliesOnTopOfAnExistingV2Database() throws {
        let old = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(old, upTo: "v2_judgments")

        // v2 时代写进去的判断,那时还没有 undoes 这一列
        try old.write { db in
            try db.execute(sql: """
                INSERT INTO judgments (decided_at, actor, action, target_kind, target_id)
                VALUES ('2026-08-01T10:00:00+08:00', 'user', 'accept_nomination', 'thing', '7')
                """)
        }
        let oldID = try old.read { db in
            try Int.fetchOne(db, sql: "SELECT id FROM judgments") ?? -1
        }
        XCTAssertGreaterThan(oldID, 0)

        // 升级
        try migrator.migrate(old)

        // 老记录原样还在,新列是 NULL
        let (kept, undoes) = try old.read { db -> (Int, Int?) in
            let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM judgments") ?? -1
            let u = try Int.fetchOne(db, sql: "SELECT undoes FROM judgments WHERE id = ?", arguments: [oldID])
            return (n, u)
        }
        XCTAssertEqual(kept, 1, "升级不该动老记录")
        XCTAssertNil(undoes)

        // 新触发器在升级后的库上照常工作
        try old.write { db in
            try db.execute(sql: """
                INSERT INTO judgments (decided_at, actor, undoes, action, target_kind, target_id)
                VALUES ('2026-08-08T10:00:00+08:00', 'user', ?, 'undo', 'thing', '7')
                """, arguments: [oldID])
        }
        let current = try old.read { db in
            try Int.fetchOne(db, sql: """
                SELECT judgment_id FROM judgment_current WHERE target_kind = 'thing' AND target_id = '7'
                """)
        }
        XCTAssertNil(current, "升级后写 undo,老判断照样能被撤掉")
    }

    /// 审计链仍然可追:任何 system-cascade 记录都能回链到一条 actor=user 的记录。
    func testCascadeKeepsAuditChain() throws {
        let keep    = try insert("keep_stance", kind: "stance", target: "88")
        let trigger = try insert("assign_speaker", kind: "line", target: "1001")
        let cascade = try insert("undo", kind: "stance", target: "88",
                                 actor: "system-cascade", causedBy: trigger, undoes: keep)

        let (causedBy, undoes, rootActor) = try dbQueue.read { db -> (Int?, Int?, String?) in
            let row = try Row.fetchOne(db, sql: "SELECT caused_by, undoes FROM judgments WHERE id = ?",
                                       arguments: [cascade])
            let cb: Int? = row?["caused_by"]
            let ud: Int? = row?["undoes"]
            let actor = try String.fetchOne(db, sql: "SELECT actor FROM judgments WHERE id = ?",
                                            arguments: [cb])
            return (cb, ud, actor)
        }
        XCTAssertEqual(causedBy, trigger)
        XCTAssertEqual(undoes, keep)
        XCTAssertEqual(rootActor, "user", "级联必须回链到一条用户判断(G2 审计链)")
    }
}
