import XCTest
import GRDB
@testable import GrowthApp

/// 事的状态机(M2-B2)。
///
/// 验收原文两条:**六态全覆盖的流转测试**,以及
/// **人为造非法流转(直改)必须被拒 —— 墨菲:造脏数据打自己的实现**。
final class MatterStateMachineTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-18T20:00:00+08:00"
    private let nowDate = ISO8601DateFormatter.growth.date(from: "2026-08-18T20:00:00+08:00")!

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
    }
    override func tearDownWithError() throws { dbQueue = nil }

    @discardableResult
    private func make(_ state: String = "候选", title: String = "产品该定位成什么",
                      createdDaysAgo: Int = 0) throws -> Int64 {
        let at = ISO8601DateFormatter.growth.string(
            from: nowDate.addingTimeInterval(-Double(createdDaysAgo) * 86_400))
        return try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO matters (title, state, created_at, updated_at) VALUES (?, ?, ?, ?)
                """, arguments: [title, state, at, at])
            return db.lastInsertedRowID
        }
    }

    private func state(_ id: Int64) throws -> String? {
        try dbQueue.read { try String.fetchOne($0, sql: "SELECT state FROM matters WHERE id = ?",
                                               arguments: [id]) }
    }

    private func go(_ id: Int64, _ to: String,
                    by: MatterStateMachine.Actor = .user) throws {
        try dbQueue.write { try MatterStateMachine.transition(id, to: to, by: by, now: now, in: $0) }
    }

    // MARK: - 六态全覆盖

    /// PRD §4.3.4 那张流转表逐条走一遍,**六个态每一个都被进入过**。
    func testEveryOneOfTheSixStatesIsReachable() throws {
        var seen: Set<String> = ["候选"]

        let a = try make("候选")
        try go(a, "活跃");   seen.insert(try state(a)!)
        try go(a, "沉睡");   seen.insert(try state(a)!)
        try go(a, "活跃")
        try go(a, "已结案"); seen.insert(try state(a)!)
        try go(a, "活跃")            // 新材料出现后确认复活

        let b = try make("候选")
        try go(b, "已拒绝"); seen.insert(try state(b)!)
        try go(b, "候选")            // 从候选区历史里找回

        // 已合并要有并入目标,单独造
        let c = try make("候选")
        try go(c, "活跃")
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO judgments (decided_at, actor, action, target_kind, target_id)
                VALUES (?, 'user', 'matter_to_已合并', 'matter', ?)
                """, arguments: [now, "\(c)"])
            try db.execute(sql: "UPDATE matters SET merged_into = ?, state = '已合并' WHERE id = ?",
                           arguments: [a, c])
        }
        seen.insert(try state(c)!)

        XCTAssertEqual(seen, ["候选", "活跃", "沉睡", "已结案", "已拒绝", "已合并"],
                       "有状态一次都没被进入过 —— 那一档的流转没被测到")
    }

    /// PRD 里没有的流转,在这一层就被人话拒掉(而不是抛一句 SQL 报错)。
    func testAnUndocumentedTransitionIsRefusedWithAReadableReason() throws {
        let m = try make("候选")
        try go(m, "活跃")
        XCTAssertThrowsError(try go(m, "候选")) { e in
            guard case MatterActionFailure.illegalTransition(let f, let t) = e else {
                return XCTFail("抛的不是「这条流转不存在」:\(e)")
            }
            XCTAssertEqual([f, t], ["活跃", "候选"])
        }
    }

    /// 结案**仅用户**。系统走同一条路会被触发方那一层拦下 ——
    /// 分不开的话,「系统悄悄把一件事结了案」没有任何东西挡得住。
    func testTheSystemCannotCloseAMatter() throws {
        let m = try make("候选")
        try go(m, "活跃")
        XCTAssertThrowsError(try go(m, "已结案", by: .system),
                             "系统把一件事结了案 —— PRD 写的是仅用户")
        try go(m, "已结案", by: .user)
        XCTAssertEqual(try state(m), "已结案")
    }

    // MARK: - 🔴 造脏数据打自己:绕过写路径必须写不进去

    /// 验收原文点名的那条:**直接 UPDATE 改状态**。
    ///
    /// 这条流转本身是合法的(已合并 → 活跃,PRD 允许 30 天内拆回),
    /// 所以 v19 那道闸放行 —— 拦它的是 v20:**没有对应的判断记录就改不动**。
    /// 两道闸各管一件事,少任何一道这条测试都会绿。
    func testADirectUpdateBypassingTheWritePathIsRefused() throws {
        let m = try make("候选")
        try go(m, "活跃")
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "UPDATE matters SET state = '沉睡' WHERE id = ?", arguments: [m])
        }, "绕过状态机直接改状态成功了 —— 那「唯一写路径」就只是一句注释")
        XCTAssertEqual(try state(m), "活跃", "整条 UPDATE 该被 ABORT,一个字节都不该落")
    }

    /// 判断记录不许被重放:活跃→沉睡→活跃 之后两条记录都在,
    /// 再直接改一次仍然必须被拒(v18 踩过同一个坑)。
    func testAnOldJudgmentCannotBeReplayedToSneakATransitionThrough() throws {
        let m = try make("候选")
        try go(m, "活跃")
        try go(m, "沉睡")
        try go(m, "活跃")
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "UPDATE matters SET state = '沉睡' WHERE id = ?", arguments: [m])
        }, "旧那条「改成沉睡」的判断被重放了 —— 这次改动在账本里没有痕迹")
    }

    /// 每一次流转都在判断库里留了痕,而且写清了从哪到哪。
    func testEveryTransitionLeavesAnAuditableJudgment() throws {
        let m = try make("候选")
        try go(m, "活跃")
        let row = try dbQueue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT action, actor, payload FROM judgments
                 WHERE target_kind = 'matter' AND target_id = ? ORDER BY id DESC LIMIT 1
                """, arguments: ["\(m)"])
        }
        let r = try XCTUnwrap(row)
        XCTAssertEqual(r["action"] as String, "matter_to_活跃")
        XCTAssertEqual(r["actor"] as String, "user")
        XCTAssertTrue((r["payload"] as String).contains("\"from\":\"候选\""), "没写清从哪来")
    }

    // MARK: - 容量:满员不许静默挤人

    func testAFullBoardRefusesAndHandsBackHandoverCandidates() throws {
        for i in 0..<MatterCapacity.activeLimit {
            let id = try make("候选", title: "第 \(i) 件")
            try go(id, "活跃")
        }
        let extra = try make("候选", title: "第 11 件")
        XCTAssertThrowsError(try go(extra, "活跃")) { e in
            guard case MatterActionFailure.slotsFull(let limit, let s) = e else {
                return XCTFail("满员却没抛 slotsFull:\(e)")
            }
            XCTAssertEqual(limit, MatterCapacity.activeLimit)
            XCTAssertEqual(s.count, MatterStateMachine.handoverSuggestions,
                           "PRD 要的是给 2–3 件最久未动的让用户选,不是让系统自己挑一件挤掉")
        }
        XCTAssertEqual(try state(extra), "候选", "被拒之后不该有任何副作用")
    }

    // MARK: - 自动流转:静默,但留痕

    /// 候选 30 天 → 静默拒绝;活跃 14 天无新材料 → 静默沉睡。
    func testTheTwoSilentExpiriesFire() throws {
        let stale = try make("候选", title: "放了 31 天的候选", createdDaysAgo: 31)
        let fresh = try make("候选", title: "昨天刚提名的", createdDaysAgo: 1)
        let idle  = try make("候选", title: "活跃但 20 天没动", createdDaysAgo: 20)
        try go(idle, "活跃")

        let changed = try dbQueue.write { try MatterStateMachine.runExpiries(now: nowDate, in: $0) }
        XCTAssertEqual(changed, 2)
        XCTAssertEqual(try state(stale), "已拒绝")
        XCTAssertEqual(try state(fresh), "候选", "才 1 天就被过期掉了")
        XCTAssertEqual(try state(idle), "沉睡")

        // 静默 = 不通知,**不是不留痕**
        XCTAssertEqual(try dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT actor FROM judgments WHERE target_kind = 'matter' AND target_id = ?
                 ORDER BY id DESC LIMIT 1
                """, arguments: ["\(stale)"])
        }, "system-cascade", "系统流转没留痕 —— 用户某天发现事没了,而没人能回答它是怎么没的")
    }

    /// 🔴 活跃是否闲置,判据是**最近一条脉络**,不是 `updated_at`。
    ///
    /// 用 `updated_at` 的话,改个标题就把它刷新了 —— 于是一件其实早没动静的事
    /// 永远不会沉睡,而活跃名额被它一直占着。
    func testIdlenessIsMeasuredByProgressNotByRowTouches() throws {
        let m = try make("候选", title: "20 天没进展", createdDaysAgo: 20)
        try go(m, "活跃")   // 这一步刚刚把 updated_at 刷成了「现在」
        let changed = try dbQueue.write { try MatterStateMachine.runExpiries(now: nowDate, in: $0) }
        XCTAssertEqual(changed, 1, "updated_at 被流转刷新了,而它不该影响「有没有新材料」的判断")
        XCTAssertEqual(try state(m), "沉睡")

        // 反面:有一条新脉络就不该沉睡,否则上面那条靠「永远沉睡」也能过
        let n = try make("候选", title: "20 天前立的但昨天有进展", createdDaysAgo: 20)
        try go(n, "活跃")
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO matter_timeline (matter_id, at, summary) VALUES (?, ?, '昨天聊到了')
                """, arguments: [n, ISO8601DateFormatter.growth.string(
                    from: nowDate.addingTimeInterval(-86_400))])
        }
        try dbQueue.write { try MatterStateMachine.runExpiries(now: nowDate, in: $0) }
        XCTAssertEqual(try state(n), "活跃", "昨天还有进展却被判成闲置")
    }
}
