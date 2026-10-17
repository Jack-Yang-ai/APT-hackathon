import XCTest
@testable import GrowthApp

/// 提名判据与排序(M2-B1 不花钱的那一半)。
///
/// 这些是**纯函数**,所以能离线打 —— 而那正是把判据从 LLM 调用里独立出来的理由:
/// 混在一起的话,「这条该不该提名」与「模型这次答得好不好」就再也分不开了。
final class NominationRulesTests: XCTestCase {

    private func s(myStances: Int = 0, myCommitments: Int = 0, openPoints: Int = 0,
                   sessions: Int = 1, daysSinceLatest: Int = 0) -> NominationRules.Signals {
        .init(myStances: myStances, myCommitments: myCommitments, openPoints: openPoints,
              sessions: sessions, daysSinceLatest: daysSinceLatest)
    }

    // MARK: - PRD §4.3.5 的两个条件「同时满足」

    func testBothConditionsAreRequired() {
        // 卷入了,但没有未决内核
        XCTAssertFalse(s(myStances: 3, openPoints: 0).qualifies)
        // 有未决内核,但用户压根没卷入 —— 这是「别人的事」,不该提名给他
        XCTAssertFalse(s(openPoints: 5).qualifies)
        // 两个都有
        XCTAssertTrue(s(myStances: 1, openPoints: 1).qualifies)
    }

    /// 未决内核要**近 14 天内有新材料**;放太久的不再提名。
    func testAStaleOpenCoreDoesNotQualify() {
        XCTAssertTrue(s(myStances: 1, openPoints: 2, daysSinceLatest: 14).qualifies)
        XCTAssertFalse(s(myStances: 1, openPoints: 2, daysSinceLatest: 15).qualifies,
                       "\(NominationRules.freshMaterialDays) 天是线上的,第 15 天就该出局")
    }

    /// 承诺也算「卷入」——PRD 列的是「表过态 / 许下或收到承诺 / …」
    func testACommitmentAloneCountsAsInvolvement() {
        XCTAssertTrue(s(myCommitments: 1, openPoints: 1).qualifies)
    }

    // MARK: - 排序:四项相乘

    /// 🔴 **相乘而不是相加** —— 任何一项为 0 就出局,这正是「同时满足」的算术形态。
    ///
    /// 相加的后果:一个四场都提到、未决点很多、而**用户根本没卷入**的话题
    /// 会排到前面去 —— 那是「别人的事」,提名给他就是打扰。
    func testAMissingFactorZeroesTheScoreRatherThanJustLoweringIt() {
        XCTAssertEqual(NominationRules.score(s(myStances: 9, openPoints: 0, sessions: 9)), 0)
        XCTAssertEqual(NominationRules.score(s(openPoints: 9, sessions: 9)), 0,
                       "用户没卷入却拿到了分 —— 相加式打分就是这么把别人的事推给他的")
    }

    /// 近期活跃度是**衰减的**,不是布尔:3 天前和 13 天前不该同分。
    func testRecencyDecaysInsteadOfBeingABoolean() {
        let fresh = NominationRules.score(s(myStances: 1, openPoints: 1, daysSinceLatest: 3))
        let old = NominationRules.score(s(myStances: 1, openPoints: 1, daysSinceLatest: 13))
        XCTAssertGreaterThan(fresh, old, "14 天线内是连续的,不该只有「在线内 / 不在线内」两档")
        XCTAssertGreaterThan(old, 0, "还在线内却已经是 0 分")
    }

    /// 跨场次广度参与排序:同样的卷入与未决点,跨 4 场的该排在只有 1 场的前面。
    func testBreadthAcrossSessionsRanksHigher() {
        XCTAssertGreaterThan(
            NominationRules.score(s(myStances: 2, openPoints: 2, sessions: 4)),
            NominationRules.score(s(myStances: 2, openPoints: 2, sessions: 1)))
    }

    // MARK: - 节流档位(PRD 第三层)

    func testThrottleStartsAtThreeAndMovesWithAcceptance() {
        typealias T = NominationRules.Throttle
        XCTAssertEqual(T.perWeek(recentAcceptance: nil, activeCount: 3), T.initialPerWeek,
                       "还没有 4 周数据时该用初始档,而不是猜一个")
        XCTAssertEqual(T.perWeek(recentAcceptance: 0.8, activeCount: 3), T.boostedPerWeek)
        XCTAssertEqual(T.perWeek(recentAcceptance: 0.3, activeCount: 3), T.dampedPerWeek)
        XCTAssertEqual(T.perWeek(recentAcceptance: 0.5, activeCount: 3), T.initialPerWeek)
    }

    /// 接受率够高但**活跃已经 7 件**时不升档 —— PRD 那两个条件是并列的。
    /// 少了这条,只看接受率的实现也能让上面那条绿。
    func testAFullBoardBlocksTheBoostEvenWithHighAcceptance() {
        typealias T = NominationRules.Throttle
        XCTAssertEqual(T.perWeek(recentAcceptance: 0.9, activeCount: T.boostActiveCeiling),
                       T.initialPerWeek, "活跃已经满 7 件还升档 —— 那是往一个已经装不下的地方塞")
    }

    // MARK: - 冷启动:宁缺毋滥

    func testColdStartWaitsWhenThereAreTooFewCandidates() {
        let why = NominationRules.coldStartDeferral(scores: [5, 5, 5])
        XCTAssertNotNil(why)
        XCTAssertTrue(why!.contains("不足"), "推迟了却没说清为什么:\(why!)")
    }

    /// 🔴 质量线打的是**中位数**,不是「每条都要高于」。
    ///
    /// 后者会被一条垫底的候选把整屏否掉,而 PRD 要的是「这一屏整体值不值得看」。
    func testQualityIsJudgedByTheMedianSoOneWeakCandidateDoesNotVetoThePage() {
        let withOneWeak = [0.1, 2.0, 2.0, 2.0, 2.0]
        XCTAssertNil(NominationRules.coldStartDeferral(scores: withOneWeak),
                     "一条垫底的候选把整屏否掉了 —— 线打的是中位数")
        let mostlyWeak = [0.1, 0.2, 0.3, 0.4, 5.0]
        XCTAssertNotNil(NominationRules.coldStartDeferral(scores: mostlyWeak),
                        "整体很弱却还是出了这一屏")
    }

    // MARK: - 🔴 漏掉的条件要说出来,不许装作全覆盖

    /// PRD 条件一列了五种「卷入」,而库里今天只有两种有信号。
    ///
    /// 这条测试不验行为,验**注释里把漏掉的那三种写下来了** ——
    /// 不写的话,下一个人读到 `userIsInvolved` 会以为条件一已经全覆盖,
    /// 而实际上「提过问题 / 主动问过它 / 传过相关材料」三种一条都没接。
    /// 声明比实现宽而没人知道,是复核清单 §八点名的形状。
    func testTheUncoveredInvolvementSignalsAreWrittenDown() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("GrowthApp/Database/NominationRules.swift"), encoding: .utf8)
        for missing in ["提过问题", "主动问过它", "传过相关材料"] {
            XCTAssertTrue(src.contains(missing),
                          "PRD 条件一里的「\(missing)」今天没有信号,而代码里没写明这一点 —— "
                          + "下一个人会以为条件一已经全覆盖")
        }
    }

    /// 「本人」的 id 只有一个出处。
    func testTheSelfPersonIDIsNotDuplicated() {
        XCTAssertEqual(NominationRules.mePersonID, MatterSituation.mePersonID)
    }
}
