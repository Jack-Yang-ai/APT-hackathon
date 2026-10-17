import XCTest
import GRDB
@testable import GrowthApp

/// 事的 schema 与状态机(M2-0c)。
///
/// 验收要的不是「表建出来了」,是**每处「一件事两个出处」都有一道能自动跑的对撞**
/// (铁律 4)。这个文件里最后三节就是那三道。
final class MatterSchemaTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-18T20:00:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
    }

    override func tearDownWithError() throws { dbQueue = nil }

    @discardableResult
    private func makeMatter(_ state: String = "候选") throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO matters (title, state, created_at, updated_at)
                VALUES ('产品该定位成什么', ?, ?, ?)
                """, arguments: [state, now, now])
            return db.lastInsertedRowID
        }
    }

    private func state(_ id: Int64) throws -> String? {
        try dbQueue.read { try String.fetchOne($0, sql: "SELECT state FROM matters WHERE id = ?",
                                               arguments: [id]) }
    }

    // MARK: - 六态闭集

    /// PRD §4.3.4 定死六态。**多一个少一个都算规格漂移**。
    func testExactlyTheSixStatesFromThePRD() throws {
        let states = try dbQueue.read {
            try String.fetchAll($0, sql: "SELECT state FROM matter_states ORDER BY state")
        }
        XCTAssertEqual(Set(states), ["候选", "活跃", "沉睡", "已结案", "已拒绝", "已合并"],
                       "六态与 PRD §4.3.4 对不上了 —— 多一态少一态都是规格漂移")
    }

    /// 不在闭集里的状态**插不进去**。这就是「做成表 + 外键」买到的东西:
    /// 加一个态却忘了配套,在插入时被挡下,而不是渲染出一个空白状态。
    func testAnUnknownStateCannotBeInserted() {
        XCTAssertThrowsError(try makeMatter("推进中"),
                             "自创的状态被写进去了 —— 那一刻起状态机有两套语义")
    }

    /// 只有「活跃」占名额、参与比对。**这四栏是 PRD 那张表的四列,不是我编的口径。**
    ///
    /// 存在表里而不是散成 switch:比对取数、容量闸、搜索过滤三个消费方各读一次,
    /// 散开就是三份各存一份,而**漏改一份不会报错**。
    func testOnlyTheActiveStateTakesASlotAndJoinsComparison() throws {
        try dbQueue.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql:
                "SELECT state FROM matter_states WHERE takes_slot = 1"), ["活跃"])
            XCTAssertEqual(try String.fetchAll(db, sql:
                "SELECT state FROM matter_states WHERE in_comparison = 1"), ["活跃"])
            // PRD 特意把「已拒绝」的可搜索标了粗:拒绝过的要能找回来
            XCTAssertEqual(try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM matter_states WHERE searchable = 0"), 0,
                "有状态被判成搜不到 —— PRD 六态全部可搜索,「已拒绝」还特意标了粗")
        }
    }

    // MARK: - 🔴 对撞三:流转只走合法的那些

    /// 先留痕再改状态(v20 的要求),PRD 里有的流转走得通。
    ///
    /// ⚠️ 这个文件测的是 **v19 那道「合法性」闸**,所以每次都得先把 v20 要的
    /// 判断记录写上 —— 否则拦下来的是 v20,而本节想验的是 v19。
    /// 两道闸不隔离开测,分不清是谁拦的。
    private func withJudgment(_ id: Int64, to target: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO judgments (decided_at, actor, action, target_kind, target_id)
                VALUES (?, 'user', ?, 'matter', ?)
                """, arguments: [now, "matter_to_\(target)", "\(id)"])
            try db.execute(sql: "UPDATE matters SET state = ? WHERE id = ?", arguments: [target, id])
        }
    }

    func testALegalTransitionGoesThrough() throws {
        let m = try makeMatter("候选")
        try withJudgment(m, to: "活跃")
        XCTAssertEqual(try state(m), "活跃")
    }

    /// 🔴 PRD 里**没有**的流转,数据库层就写不进去。
    ///
    /// 「活跃 → 候选」在 §4.3.4 那张表里根本不存在。只靠代码约定的话,
    /// 哪天有人写一句 `UPDATE matters SET state = ...`,状态机从那一刻起有两套语义,
    /// 而**没有任何东西会红**。这是铁律 3 的同一形状 ——
    /// 旧仓归属没有统一入口,实测悬空 1979 条。
    func testAnUndocumentedTransitionIsRefusedByTheDatabase() throws {
        let m = try makeMatter("候选")
        try withJudgment(m, to: "活跃")
        // 🔴 **连 v20 要的判断记录也一并写上** —— 这样拦下来的只可能是 v19 那道
        // 「合法性」闸。不写的话 v20 会先拦,而这条测试就变成在验另一件事。
        XCTAssertThrowsError(try withJudgment(m, to: "候选"),
                             "「活跃 → 候选」规格里没有,却写进去了")
        XCTAssertEqual(try state(m), "活跃", "整条 UPDATE 该被 ABORT,一个字节都不该落")
    }

    /// 「仅用户」那几条在表里标着 `user`,系统那几条标 `system` ——
    /// **分不开的话,「系统悄悄把一件事结了案」没有任何东西挡得住。**
    func testClosingIsUserOnlyPerThePRD() throws {
        let bys = try dbQueue.read {
            try String.fetchAll($0, sql: """
                SELECT DISTINCT by FROM matter_transitions WHERE to_state = '已结案'
                """)
        }
        XCTAssertEqual(bys, ["user"], "PRD 写的是结案**仅用户**,而表里给了系统一条路")
    }

    /// 状态没变的 UPDATE 不该被闸拦下(改标题、改 updated_at 是日常操作)。
    /// 少了这条,把触发器写成「任何 UPDATE 都 ABORT」也能让上面那条绿。
    func testUpdatingSomethingOtherThanStateIsNotBlocked() throws {
        let m = try makeMatter("候选")
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE matters SET title = '改个标题' WHERE id = ?", arguments: [m])
        }
        XCTAssertEqual(try state(m), "候选")
    }

    /// 「已合并」与 `merged_into` 必须同生共死 —— 一个有一个没有就是半个状态。
    func testMergedStateAndPointerMustAgree() throws {
        XCTAssertThrowsError(try makeMatter("已合并"), "已合并却没说并进了哪一件")
        let a = try makeMatter("候选")
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "UPDATE matters SET merged_into = ? WHERE id = ?", arguments: [a, a])
        }, "不是已合并却填了 merged_into")
    }

    // MARK: - 🔴 对撞二:局面数字全部派生,一列都不许落

    /// 悬点数、脉络条数这类**能从别的表数出来**的东西,不许在 `matters` 上落列。
    ///
    /// 落成列就是同一件事两个出处,而**对不上时不会报错** ——
    /// 只会让局面那一屏显示一个谁都解释不了的数,而且没人知道该信哪个。
    ///
    /// ⚠️ 扫的是**列名**,不是数据。数据断言只能证明「今天两处一致」,
    /// 挡不住第三个消费方(复核清单 §五)。
    func testNoDerivedCountersAreStoredOnTheMatterRow() throws {
        let cols = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(matters)").map { $0["name"] as String }
        }
        let smells = cols.filter { c in
            ["count", "_num", "total", "n_"].contains { c.lowercased().contains($0) }
        }
        XCTAssertEqual(smells, [],
                       "`matters` 上出现了看起来是计数的列 \(smells) —— "
                       + "局面数字必须从悬点/脉络表派生。落成列之后两处对不上不会报错")
        // 反面:那些数**确实数得出来**,不然上面那条只是禁止了一个没人需要的东西
        let m = try makeMatter("活跃")
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO matter_open_questions (matter_id, question, opened_at)
                VALUES (?, '定位到底是什么', ?)
                """, arguments: [m, now])
            try db.execute(sql: """
                INSERT INTO matter_open_questions (matter_id, question, opened_at, closed_at)
                VALUES (?, '这个已经定了', ?, ?)
                """, arguments: [m, now, now])
        }
        XCTAssertEqual(try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM matter_open_questions WHERE matter_id = ? AND closed_at IS NULL
                """, arguments: [m])
        }, 1, "还悬着的悬点数派生不出来 —— 那上面那条禁令就没有意义")
    }

    // MARK: - 🔴 对撞一:target_kind 的闭集里,每个值都得对应一张真表

    /// `judgments.target_kind` 说「这条判断是对什么下的」。M2 之后它要扩到
    /// matter / 悬点 / 进展。
    ///
    /// 🔴 **闭集里出现一个没有对应表的值,是最难查的那种坏**:
    /// 写入照常成功、`judgment_current` 照常维护,而**回看时那条判断指向一个不存在的东西**——
    /// 界面上的表现是「这条判断没有上下文」,与「上游没给上下文」一模一样。
    ///
    /// ⚠️ 这道对撞**扫源码,不比数据**(铁律 4):库里今天没有 matter 类型的判断,
    /// 比数据只会一片绿,而它要挡的恰恰是「将来有人加了一个值却没建表」。
    func testEveryTargetKindInTheClosedSetNamesARealTable() throws {
        // 闭集的**唯一出处**。加一个值就要在这里加,而加了没建表下面立刻红。
        let kinds: [String: String] = [
            "line":     "transcript_lines",
            "person":   "persons",
            "matter":   "matters",
            "question": "matter_open_questions",
            "progress": "matter_timeline",
            // M3-0c v26。`principle` 等 `self_principles` 建出来那一步再加 ——
            // 现在加就是「闭集里有个值指向不存在的表」,而这道断言正是为它设的。
            "discovery": "discoveries",
            "card":      "cards",
            // 用户可以直接编辑一条原则(PRD §4.4.9),那次编辑是一条对**原则本身**的判断。
            "principle": "self_principles",
        ]
        let tables = try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
        let orphans = kinds.filter { !tables.contains($0.value) }
        XCTAssertEqual(orphans, [:],
                       "target_kind 闭集里这些值指向不存在的表:\(orphans) —— "
                       + "写入会照常成功,而回看时那条判断指向一个不存在的东西")
        XCTAssertTrue(tables.contains("judgments"), "连 judgments 都没有 —— 这条断言在空转")
    }

    /// 上面那条**自己得能红**:给一个不存在的表名,它必须报出来。
    /// 没有这一条,把 `tables` 读空、或把 filter 写反,它都会一直绿着。
    func testTheTargetKindScannerActuallyDetectsAnOrphan() throws {
        let tables = try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
        XCTAssertFalse(tables.contains("matter_feelings"),
                       "这张表居然存在了 —— 换一个确定不存在的名字,不然这条对照是假的")
        XCTAssertEqual(["mood": "matter_feelings"].filter { !tables.contains($0.value) }.count, 1,
                       "扫描逻辑抓不出孤儿 —— 那上面那条是空转的")
    }
}
