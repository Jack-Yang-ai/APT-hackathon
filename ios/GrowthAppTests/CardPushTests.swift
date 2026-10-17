import XCTest
import GRDB
@testable import GrowthApp

/// 卡片的推送时机(`M3-B2`,PRD §4.6.2「就位不催」+ §4.1.8 免打扰)。
///
/// 🔴 **这一组守的两条,违反了界面完全正常**:
/// ① 免打扰时段**不补推**(不是攒到早上);② `pushed_at` **推了才记**。
final class CardPushTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let iso = ISO8601DateFormatter.growth
    private var now: Date { iso.date(from: "2026-08-25T14:00:00+08:00")! }

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, '2026-08-25T09:00:00+08:00', '2026-08-25', ?, ?)
                """, arguments: [SessionBridge.Source.recording, SessionBridge.Status.closed])
            try db.execute(sql: """
                INSERT INTO matters (id, title, state, created_at, updated_at)
                VALUES (1, '产品定位', '活跃', '2026-08-25', '2026-08-25')
                """)
            try db.execute(sql: """
                INSERT INTO matter_timeline (matter_id, at, summary)
                VALUES (1, '2026-08-25T10:00:00+08:00', '今天动过')
                """)
            for i in 0..<4 {
                try db.execute(sql: """
                    INSERT INTO cards (kind, object_kind, object_id, session_id, body, created_at)
                    VALUES (?, '事', ?, 1, ?, ?)
                    """, arguments: [CardTrigger.Kind.stance.rawValue, "\(i)",
                                     "第 \(i) 张", "2026-08-25T1\(i):00:00+08:00"])
            }
        }
    }

    override func tearDownWithError() throws { dbQueue = nil }

    private func plan(hour: Int) throws -> CardPush.Plan {
        try dbQueue.read { db in try CardPush.plan(now: self.now, hour: hour, in: db) }
    }

    // MARK: - 🔴 免打扰:不推,而且不补推

    /// 22:00–08:00 之间**一张都不推**,而且**不排队等早上** ——
    /// 卡片推送有效期只有 1 天,攒到早上推的是一批**昨天的**卡。
    func testQuietHoursPushNothingAndDoNotQueueForMorning() throws {
        for h in [22, 23, 0, 3, 7] {
            let p = try plan(hour: h)
            XCTAssertTrue(p.push.isEmpty, "\(h) 点推了 \(p.push.count) 组")
            XCTAssertTrue(p.why.contains("不补推"),
                          "没说清「不补推」—— 攒到早上推的是昨天的卡")
        }
        XCTAssertFalse(try plan(hour: 8).push.isEmpty, "8 点该恢复推送")
        XCTAssertFalse(try plan(hour: 21).push.isEmpty, "21 点还不该静音")
    }

    /// 边界精确:`22` 静、`21` 不静;`7` 静、`8` 不静。
    func testTheQuietWindowBoundariesAreExact() {
        XCTAssertFalse(CardPush.isQuiet(hour: CardPush.quietFrom - 1))
        XCTAssertTrue(CardPush.isQuiet(hour: CardPush.quietFrom))
        XCTAssertTrue(CardPush.isQuiet(hour: CardPush.quietUntil - 1))
        XCTAssertFalse(CardPush.isQuiet(hour: CardPush.quietUntil))
    }

    // MARK: - 预算

    /// 取前 B 张:预算说几张就几组。
    func testThePlanTakesAtMostTheBudget() throws {
        try dbQueue.write { db in
            try CardBudget.save(.init(value: 2, raisedStreak: 0, paused: false, why: ""),
                                now: "2026-08-25T09:00:00+08:00", in: db)
        }
        XCTAssertEqual(try plan(hour: 14).push.count, 2)
    }

    /// 暂停时不推,但**要说清卡片还在页面上** —— 否则用户会以为它们没了。
    func testPausedMeansNoPushButTheCardsAreStillThere() throws {
        try dbQueue.write { db in
            try CardBudget.save(.init(value: 3, raisedStreak: 0, paused: true, why: ""),
                                now: "2026-08-25T09:00:00+08:00", in: db)
        }
        let p = try plan(hour: 14)
        XCTAssertTrue(p.push.isEmpty)
        XCTAssertTrue(p.why.contains("仍在页面上"))
    }

    // MARK: - 🔴 pushed_at 推了才记

    /// 记早了会让「推送有效期 1 天」从**卡片产生**那一刻开始算,
    /// 于是**没推过的卡第二天就自己过期了** —— 而它一次都没被看见过。
    func testPushedAtIsOnlyStampedOnCardsActuallyPushed() throws {
        try dbQueue.write { db in
            try CardBudget.save(.init(value: 1, raisedStreak: 0, paused: false, why: ""),
                                now: "2026-08-25T09:00:00+08:00", in: db)
        }
        let p = try plan(hour: 14)
        let n = try dbQueue.write { db in
            try CardPush.markPushed(p, now: "2026-08-25T14:00:00+08:00", in: db)
        }
        XCTAssertEqual(n, 1, "只该给推出去的那张盖章")
        let stamped = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards WHERE pushed_at IS NOT NULL") ?? 0
        }
        XCTAssertEqual(stamped, 1, "给没推的卡也盖了章 —— 它们明天会自己过期,而一次都没被看见")
    }

    /// 免打扰时段调 `markPushed` 也不该盖任何章(计划是空的)。
    func testNothingIsStampedDuringQuietHours() throws {
        let n = try dbQueue.write { db in
            try CardPush.markPushed(try CardPush.plan(now: self.now, hour: 23, in: db),
                                    now: "2026-08-25T23:00:00+08:00", in: db)
        }
        XCTAssertEqual(n, 0)
    }

    // MARK: - 喂给预算的三个数

    /// 「处理」含搁置与「这问不对」 —— 它量的是**打扰的接受度**,不是提问质量。
    func testHandledCountsEveryExitIncludingHoldAndWrongQuestion() throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE cards SET pushed_at = '2026-08-25T10:00:00+08:00'")
            for (i, action) in ["card_accept", "card_hold", "card_wrong_question"].enumerated() {
                try db.execute(sql: """
                    INSERT INTO judgments (decided_at, actor, action, target_kind, target_id)
                    VALUES ('2026-08-25T11:00:00+08:00', 'user', ?, 'card', ?)
                    """, arguments: [action, "\(i + 1)"])
            }
        }
        let input = try dbQueue.read { db in try CardPush.budgetInput(now: self.now, in: db) }
        XCTAssertEqual(input.pushed, 4)
        XCTAssertEqual(input.handled, 3, "搁置或「这问不对」没被算成处理 —— "
                       + "那会让用户老老实实反馈反而把预算顶高")
    }

    /// 🔴 **一次都没处理过 ≠ 零天**:要从第一次推送算起,
    /// 否则一个从来没点过卡片的用户**永远等不到暂停**。
    func testIdleDaysCountFromFirstPushWhenNothingWasEverHandled() throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE cards SET pushed_at = '2026-07-01T10:00:00+08:00'")
        }
        let input = try dbQueue.read { db in try CardPush.budgetInput(now: self.now, in: db) }
        XCTAssertGreaterThan(input.idleDays, CardBudget.pauseAfterIdleDays,
                            "从没处理过却算成 0 天 —— 那种用户永远等不到暂停")
    }
}
