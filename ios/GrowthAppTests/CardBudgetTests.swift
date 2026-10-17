import XCTest
import GRDB
@testable import GrowthApp

/// 卡片推送预算的自适应(`M3-B2`,技术方案 §4.6.1)。
///
/// 🔴 **这一组守的四个边界,每一个漏了都只是「数字慢慢不对」,不会崩**:
/// 分母为 0、样本不足、非对称阻尼、30 天暂停时 B 要冻住。
final class CardBudgetTests: XCTestCase {

    private func adjust(_ current: Int, _ streak: Int,
                        pushed: Int, handled: Int, idle: Int = 0) -> CardBudget.Outcome {
        CardBudget.adjust(current: current, streak: streak,
                          input: .init(pushed: pushed, handled: handled, idleDays: idle))
    }

    // MARK: - 三档

    func testTheThreeBandsMoveTheBudgetAsDeclared() {
        // 低于下限 ⇒ 立即降
        XCTAssertEqual(adjust(3, 0, pushed: 10, handled: 3).value, 2)
        // 中间档 ⇒ 不变
        XCTAssertEqual(adjust(3, 0, pushed: 10, handled: 6).value, 3)
        // 够升档但只连续 1 天 ⇒ 先不动
        XCTAssertEqual(adjust(3, 0, pushed: 10, handled: 9).value, 3)
        // 连续第 2 天 ⇒ 升
        XCTAssertEqual(adjust(3, 1, pushed: 10, handled: 9).value, 4)
    }

    /// 🔴 **非对称阻尼:降立即,升要连续两天。**
    ///
    /// 两个方向的错误代价不对称 —— 少问一张只是慢一天,多问一张是实打实的打扰,
    /// 而打扰的代价由用户当场承担。做成对称的话,一个偶然的好日子就能把打扰顶上去。
    func testLoweringIsImmediateWhileRaisingNeedsTwoDays() {
        XCTAssertEqual(adjust(3, 0, pushed: 10, handled: 0).value, 2, "降档没有立即生效")
        let day1 = adjust(3, 0, pushed: 10, handled: 10)
        XCTAssertEqual(day1.value, 3, "第一天就升了 —— 阻尼没生效")
        XCTAssertEqual(day1.raisedStreak, 1)
        XCTAssertEqual(adjust(3, day1.raisedStreak, pushed: 10, handled: 10).value, 4)
    }

    /// 「连续」就是连续 —— 中间断一天要清零。
    func testTheRaiseStreakResetsWhenADayFallsShort() {
        XCTAssertEqual(adjust(3, 1, pushed: 10, handled: 6).raisedStreak, 0,
                       "中间档没有把连续计数清零 —— 那隔三差五够一次也能攒够,就不是连续了")
        XCTAssertEqual(adjust(3, 1, pushed: 10, handled: 1).raisedStreak, 0)
    }

    // MARK: - 🔴 四个边界

    /// **分母为 0 不是处理率 0。**
    ///
    /// 把「没推」读成「没处理」的话,B 会一路掉到下限再也起不来,
    /// 而现象只是「最近卡片好少」—— 没有任何东西会报错。
    func testNoPushesMeansNoAdjustmentNotAZeroRate() {
        let o = adjust(3, 1, pushed: 0, handled: 0)
        XCTAssertEqual(o.value, 3, "一张都没推却把 B 降了 —— 分母为 0 被当成了处理率 0")
        XCTAssertEqual(o.raisedStreak, 1, "连续计数也不该被清 —— 这一天根本没有信号")
        XCTAssertTrue(o.why.contains("分母为 0"))
    }

    /// 样本不足时不动 B —— 一张卡的 0/1 不该决定明天的预算。
    func testTooFewSamplesLeaveTheBudgetAlone() {
        XCTAssertEqual(adjust(3, 0, pushed: 2, handled: 0).value, 3)
        XCTAssertEqual(adjust(3, 0, pushed: CardBudget.minSample, handled: 0).value, 2,
                       "刚好够样本就该开始调了")
    }

    /// 上下限夹住,而且**到边界之后不再动**。
    func testTheBudgetStaysWithinItsDeclaredRange() {
        XCTAssertEqual(adjust(CardBudget.minValue, 0, pushed: 10, handled: 0).value,
                       CardBudget.minValue, "降破了保底")
        XCTAssertEqual(adjust(CardBudget.maxValue, 1, pushed: 10, handled: 10).value,
                       CardBudget.maxValue, "升破了上限")
    }

    /// 🔴 **连续 30 天零处理 ⇒ 暂停,而 B 冻在暂停前的值。**
    ///
    /// 暂停期间照常算 rate 的话,恢复那天 B 已经掉到底了 —— 而用户什么都没做错。
    func testPausingFreezesTheBudgetInsteadOfGrindingItDown() {
        let o = adjust(5, 0, pushed: 10, handled: 0, idle: CardBudget.pauseAfterIdleDays)
        XCTAssertTrue(o.paused)
        XCTAssertEqual(o.value, 5, "暂停时把 B 也降了 —— 恢复那天用户会拿到一个被磨到底的预算")
    }

    /// 差一天不算暂停 —— 边界要精确,不然「29 天」和「30 天」的行为得靠猜。
    func testOneDayShortOfThePauseThresholdIsNotPaused() {
        XCTAssertFalse(adjust(3, 0, pushed: 10, handled: 0,
                              idle: CardBudget.pauseAfterIdleDays - 1).paused)
    }

    /// **没有「静默不动」这一档** —— 不动也要说出来是为什么。
    func testEveryOutcomeExplainsItself() {
        for o in [adjust(3, 0, pushed: 0, handled: 0),
                  adjust(3, 0, pushed: 2, handled: 1),
                  adjust(3, 0, pushed: 10, handled: 6),
                  adjust(3, 0, pushed: 10, handled: 1),
                  adjust(3, 0, pushed: 10, handled: 10, idle: 40)] {
            XCTAssertFalse(o.why.isEmpty, "有一档没说清为什么 —— 那和静默一样")
        }
    }

    // MARK: - 落库

    func testTheBudgetRowExistsAfterMigrationAndRoundTrips() throws {
        let q = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(q)
        let now = "2026-08-25T18:00:00+08:00"
        try q.read { db in
            let b = try CardBudget.load(db)
            XCTAssertEqual(b.value, CardBudget.initialValue,
                           "迁移没写初始行 —— 读的人只能自己编一个数")
            XCTAssertFalse(b.paused)
        }
        try q.write { db in
            try CardBudget.save(.init(value: 5, raisedStreak: 1, paused: false, why: ""),
                                now: now, in: db)
        }
        try q.read { db in
            let b = try CardBudget.load(db)
            XCTAssertEqual(b.value, 5)
            XCTAssertEqual(b.streak, 1)
        }
        // 暂停 → 恢复:`value` 全程不变
        try q.write { db in
            try CardBudget.save(.init(value: 5, raisedStreak: 0, paused: true, why: ""),
                                now: now, in: db)
        }
        XCTAssertTrue(try q.read { db in try CardBudget.load(db).paused })
        try q.write { db in
            try CardBudget.save(.init(value: 5, raisedStreak: 0, paused: false, why: ""),
                                now: now, in: db)
        }
        try q.read { db in
            let b = try CardBudget.load(db)
            XCTAssertFalse(b.paused)
            XCTAssertEqual(b.value, 5, "走了一圈暂停,B 变了 —— 它该冻住")
        }
    }

    /// 单行表:第二行写不进去。**「B 只准存一处」是物理保证,不是约定。**
    func testASecondBudgetRowIsRefusedByTheDatabase() throws {
        let q = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(q)
        XCTAssertThrowsError(try q.write { db in
            try db.execute(sql: """
                INSERT INTO card_budget (id, value, updated_at) VALUES (2, 6, '2026-08-25')
                """)
        }, "存进了第二个预算 —— 「今天到底几张」从此谁都说不清")
    }
}
