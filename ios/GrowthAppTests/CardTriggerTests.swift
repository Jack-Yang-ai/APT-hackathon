import XCTest
@testable import GrowthApp

/// PRD §4.6.2.2「触发器是变化,不是存在」的逐行判定测试(`M3-0b`)。
///
/// 🔴 **一行一条,共 8 条 = 表 7 行 + 表下那句「归一失败倾向不出卡」。**
/// 条目里原来写的是「六种」—— 照那个数写测试**必然静默漏掉两行**
/// (「立场变了→矛盾卡」「前提变了→前提推翻卡」是出卡分支,数的时候容易被当成
/// 「不出卡的情况」漏掉),而漏掉的表现是**测试全绿**。这就是假绿的形状。
///
/// ⚠️ 这一组守的是**便宜的那一边**:漏一次的代价是少问一个问题,
/// 多问一次的代价是用户被反复骚扰同一件事 —— 所以拿不准时一律不出卡。
final class CardTriggerTests: XCTestCase {

    // MARK: - 造样例

    private func fact(topic: String? = "产品定位",
                      direction: CardTrigger.Direction? = .oppose,
                      matter: String = "M1",
                      premise: String? = nil) -> CardTrigger.StanceFact {
        .init(topicKey: topic, direction: direction, matterID: matter, premiseKey: premise)
    }

    private func record(direction: CardTrigger.Direction = .oppose,
                        premise: String? = nil,
                        matters: Set<String> = ["M1"],
                        judged: Bool = false,
                        overturned: Bool = false) -> CardTrigger.StanceRecord {
        .init(direction: direction, premiseKey: premise, matterIDs: matters,
              userJudged: judged, judgmentOverturned: overturned)
    }

    private func decide(_ f: CardTrigger.StanceFact,
                        _ rs: [CardTrigger.StanceRecord],
                        exclusivity: Bool = true) -> CardTrigger.Decision {
        CardTrigger.decide(stance: f, sameTopic: rs, exclusivityScreenPassed: exclusivity)
    }

    // MARK: - 表第 1 行

    /// **重复表达同一立场 ⇒ 不出卡,静默追加一条证据。**
    ///
    /// 顺带钉住「第一次表达」那一格:同主题下一条记录都没有时才出立场卡 ——
    /// 这两格挨着,写反了的表现是「每说一次就被问一次」。
    func testRow1_RepeatedSameStanceAppendsEvidenceInsteadOfCard() {
        XCTAssertEqual(decide(fact(), [record()]), .appendEvidence)
        // 措辞不参与判定:归一按 (主题 × 方向),同一件事上重复说多少次都只追加。
        XCTAssertEqual(decide(fact(matter: "M1"), [record(matters: ["M1"])]), .appendEvidence)
        // 对照:第一次表达才出立场卡。
        XCTAssertEqual(decide(fact(), []), .card(.stance))
    }

    // MARK: - 表第 2 行

    /// **重复表达且跨到新的一件事 ⇒ 仍不出立场卡;因此满足「跨 ≥2 件事」时触发原则浮现卡。**
    ///
    /// 🔴 「**因此**满足」是关键:只在**跨过门槛的那一次**出卡。
    /// 第 3、第 4 件事再来时不该再出同一张 —— 那是「存在」不是「变化」,
    /// 而漏掉这个限定的表现是**同一个原则被反复问**,恰好是这一节要禁的事。
    func testRow2_CrossingToSecondMatterFiresPrincipleCardExactlyOnce() {
        // 记录只在 M1 上出现过,这次跨到 M2 ⇒ 刚好满 2 件 ⇒ 原则浮现卡
        XCTAssertEqual(decide(fact(matter: "M2"), [record(matters: ["M1"])]),
                       .card(.principleEmerging))
        // 已经跨过 2 件了,再来第 3 件 ⇒ 不再出卡
        XCTAssertEqual(decide(fact(matter: "M3"), [record(matters: ["M1", "M2"])]),
                       .appendEvidence)
        // 还是老那件事 ⇒ 没跨 ⇒ 不出卡
        XCTAssertEqual(decide(fact(matter: "M1"), [record(matters: ["M1"])]),
                       .appendEvidence)
        // 🔴 排他性粗筛没过 ⇒ 不出卡。粗筛这一层算不出来,所以它是入参;
        //    若写成内部恒 true,「跨了 2 件事的口头禅」会被立成原则,而没有任何东西会红。
        XCTAssertEqual(decide(fact(matter: "M2"), [record(matters: ["M1"])], exclusivity: false),
                       .appendEvidence)
    }

    // MARK: - 表第 3 行(**出卡**分支)

    /// **立场变了(与已记录的不一致)⇒ 出矛盾卡。**
    ///
    /// 同一主题下并存两个方向是合法的(矛盾卡的「场景不同」出口就会造出这种记录),
    /// 所以判定要看**有没有同方向的那一条**,不是「有没有记录」。
    func testRow3_ChangedStanceFiresContradictionCard() {
        XCTAssertEqual(decide(fact(direction: .support), [record(direction: .oppose)]),
                       .card(.contradiction))
        // 同主题下已并存两个方向,这次说的是第三种 ⇒ 仍是变化
        XCTAssertEqual(decide(fact(direction: .conditional),
                              [record(direction: .oppose), record(direction: .support)]),
                       .card(.contradiction))
        // 同主题下并存两个方向,而这次与其中一个一致 ⇒ 是重复,不是变化
        XCTAssertEqual(decide(fact(direction: .support),
                              [record(direction: .oppose), record(direction: .support)]),
                       .appendEvidence)
    }

    // MARK: - 表第 4 行(**出卡**分支,被 M3-0f 挡着:只测判定,不测出卡)

    /// **立场的前提变了 ⇒ 判定为前提推翻卡;而该卡型此刻必须仍被 `M3-0f` 挡着。**
    ///
    /// 🔴 **`nil` 是「没说前提」,不是「前提变了」。** 两侧任一为 nil 都不许出卡 ——
    /// PRD §4.6.3 明写前提锚不到就留空、不得由模型推断补写;
    /// 把 nil 当变化,等于让模型的**沉默**去触发一张卡。
    func testRow4_ChangedPremiseIsJudgedButStillBlocked() {
        XCTAssertEqual(decide(fact(premise: "预算不会批"), [record(premise: "预算会批")]),
                       .card(.premiseOverturned))
        // 判定归判定,出卡归出卡:前提召回率实测(M3-0f)出数前,这一型不许真的推给用户。
        XCTAssertTrue(CardTrigger.blockedPendingPremiseRecall.contains(.premiseOverturned))

        // 三种「拿不准」全部退回「重复」:旧的没锚到 / 新的没锚到 / 两边都没锚到
        XCTAssertEqual(decide(fact(premise: "预算不会批"), [record(premise: nil)]), .appendEvidence)
        XCTAssertEqual(decide(fact(premise: nil), [record(premise: "预算会批")]), .appendEvidence)
        XCTAssertEqual(decide(fact(premise: nil), [record(premise: nil)]), .appendEvidence)
        // 前提没变 ⇒ 就是重复
        XCTAssertEqual(decide(fact(premise: "预算会批"), [record(premise: "预算会批")]), .appendEvidence)
    }

    // MARK: - 表第 5 行

    /// **同一悬点被反复讨论但无进展 ⇒ 不出卡,走「停滞原因」发现,不占卡片预算。**
    ///
    /// 「攒够没攒够」的阈值**不在这一层**(属 `M3-0d`)—— 两处各写一个阈值,
    /// 调了一处不会有任何东西报错。
    func testRow5_StalledOpenQuestionGoesToDiscoveryNotCard() {
        XCTAssertEqual(CardTrigger.decide(.openQuestionRediscussedWithoutProgress),
                       .discovery(.stalledReason))
    }

    // MARK: - 表第 6 行

    /// **同一个人重复提同一件事 ⇒ 不出卡,走「反复关切」发现。**
    func testRow6_RepeatedPersonConcernGoesToDiscoveryNotCard() {
        XCTAssertEqual(CardTrigger.decide(.personRaisedSameMatterAgain),
                       .discovery(.repeatedConcern))
    }

    // MARK: - 表第 7 行

    /// **用户已对某条卡做过判断,同类事实再现 ⇒ 不再出同类卡;除非判断本身被推翻。**
    ///
    /// 🔴 只挡「重复」,不挡「变化」:用户确认过「我反对」之后又说「我支持」,
    /// 那是真的改主意了,矛盾卡照出 —— 否则用户一旦确认过一次,这个主题就再也问不动了。
    func testRow7_AlreadyJudgedFactIsDroppedUnlessJudgmentOverturned() {
        XCTAssertEqual(decide(fact(), [record(judged: true)]), .drop(.alreadyJudged))
        XCTAssertEqual(decide(fact(), [record(judged: true, overturned: true)]), .appendEvidence)
        // 已判断过的是「反对」,这次说「支持」⇒ 变化,不受这一行管
        XCTAssertEqual(decide(fact(direction: .support), [record(direction: .oppose, judged: true)]),
                       .card(.contradiction))
        // 🔴 两条**变化**分支的次序必须一致:前提变了同样压过「已判断过」。
        //    一条压得住、一条压不住,是最难查的那种不一致 —— 两条路都「有理有据」。
        XCTAssertEqual(decide(fact(premise: "预算不会批"),
                              [record(premise: "预算会批", judged: true)]),
                       .card(.premiseOverturned))
    }

    // MARK: - 表下那一句(第 8 条)

    /// **归一失败(拿不准是不是同一条)⇒ 倾向不出卡。**
    ///
    /// 归一失败只有两种机械形态:**主题拿不准**、**方向拿不准**。
    /// ⚠️ 它必须被记账(§3.2)—— 否则「归一老是失败所以一张卡都没出」
    /// 与「今天真的没什么可问」长得一模一样。
    func testRow8_UnnormalizableStanceIsDroppedNotGuessed() {
        XCTAssertEqual(decide(fact(topic: nil), []), .drop(.normalizationFailed))
        XCTAssertEqual(decide(fact(topic: ""), []), .drop(.normalizationFailed))
        XCTAssertEqual(decide(fact(direction: nil), []), .drop(.normalizationFailed))
        // 🔴 归一失败**先于**其余所有分支:哪怕同主题下有一条方向相反的记录,
        //    也不许因此出矛盾卡 —— 连是不是同一条都拿不准,更谈不上「变了」。
        XCTAssertEqual(decide(fact(topic: nil, direction: .support), [record(direction: .oppose)]),
                       .drop(.normalizationFailed))
    }
}
