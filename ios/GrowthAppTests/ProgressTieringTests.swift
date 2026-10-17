import XCTest
@testable import GrowthApp

/// 进展归属 V1 的判决核心(M2-B3)。
///
/// 这里钉的**全是「错了也不会有人发现」的那种事**:
/// 档位判错 → 该给用户看的东西静默进了内容库;预筛写成 AND/OR 反了 →
/// 一整类事从此不参与比对,而输出只是「这一场没有进展」,与「一切正常」一模一样。
final class ProgressTieringTests: XCTestCase {

    // MARK: - 三档

    /// 高档 = 指认了悬点 + 三项校验全过。**V1 不要求双判一致**(2026-08-20 裁决)。
    func testHighTierNeedsAQuestionAndValidation() {
        let v = ProgressTiering.tier(lexicalHit: true, validated: true, questionID: 34)
        XCTAssertEqual(v.tier, .high)
        XCTAssertEqual(v.reason, .hitQuestionAndValidated)
    }

    /// 校验过了但没指到悬点 ⇒ **中档,出确认卡**,不许静默入库。
    ///
    /// 🔴 这条是三条里最要紧的:判错的后果是**一条模型「觉得相关」但指不出
    /// 具体悬点的东西,不经用户的眼睛就进了内容库**。
    func testNoQuestionMeansConfirmationCardNotSilentWrite() {
        let v = ProgressTiering.tier(lexicalHit: true, validated: true, questionID: nil)
        XCTAssertEqual(v.tier, .medium, """
            没指到悬点却判成 \(v.tier) —— 静默入库是唯一不经用户眼睛的路径,
            而这条连「命中哪个悬点」都说不出来。
            """)
        XCTAssertEqual(v.reason, .validatedButNoQuestion)
    }

    /// 校验没过 ⇒ 低档。**指认了悬点也不行** —— 校验是硬闸,不是加分项。
    func testFailedValidationIsLowEvenWithAQuestion() {
        let v = ProgressTiering.tier(lexicalHit: true, validated: false, questionID: 34)
        XCTAssertEqual(v.tier, .low)
        XCTAssertEqual(v.reason, .failedValidation)
    }

    /// 预筛就没进模型 ⇒ 低档,而且理由要与「校验没过」**分得开**。
    ///
    /// 🔴 两者都是 low,但含义完全不同:一个是「没花钱去看」,
    /// 一个是「花了钱、模型说了、但说的话对不上原文」。
    /// 判卷时把它们混成一档,就分不出「漏召回」和「模型在编」。
    func testPrefilteredOutIsLowWithItsOwnReason() {
        let v = ProgressTiering.tier(lexicalHit: false, validated: true, questionID: 34)
        XCTAssertEqual(v.tier, .low)
        XCTAssertEqual(v.reason, .prefilteredOut, "「没进模型」与「校验没过」必须分得开")
    }

    // MARK: - 本地预筛

    /// 🔴 **两个信号「都低」才排除(AND),不是「任一低」就排除(OR)。**
    ///
    /// PRD §4.3.6 原文:「词面重合度与人物重合度**都**低于阈值的事不进模型」。
    /// 写成 OR 的后果很具体:一件**换了措辞但还是这批人在谈**的事会被筛掉 ——
    /// 而那正是「进展」最典型的样子,事情推进时用词本来就会变。
    /// 这条测试就是那个照妖镜:把 `||` 写成 `&&` 它当场红。
    func testEitherSignalAloneIsEnoughToCompare() {
        let lex = ProgressTiering.lexicalThreshold
        let ppl = ProgressTiering.peopleThreshold
        XCTAssertTrue(ProgressTiering.shouldCompare(lexical: lex, people: 0), """
            词面够了但人不重合,就不比了 —— 一件事换了参与人继续推进时会被整个漏掉。
            """)
        XCTAssertTrue(ProgressTiering.shouldCompare(lexical: 0, people: ppl), """
            人重合但换了措辞,就不比了 —— 而事情推进时用词本来就会变,
            这正是「进展」最典型的样子。
            """)
        XCTAssertFalse(ProgressTiering.shouldCompare(lexical: lex - 0.01, people: ppl - 0.01),
                       "两个都低于阈值还去比,预筛就白做了(它存在的理由是省调用)")
    }

    /// 🔴 **谈得越久的事,词面分不许因此变低。**
    ///
    /// ~~上一版这条断的是反面(「长文本不许占便宜」,按 Jaccard 写)~~ ——
    /// **2026-08-20 作废,那条结论是错的**。Jaccard 的分母含着事的全部词面,
    /// 于是脉络越长分越低,而**漏召回是不可见的**:输出「这一场没有进展」
    /// 与一切正常一模一样。改成包含度之后,分母只取本场那一侧。
    ///
    /// 这条测试就是那次打脸的固化:它当时红在预算测试上
    /// (10 件标题里写着「压缩方式」的事,配长脉络后一件都没进模型)。
    func testLongHistoryDoesNotLowerTheScore() {
        let session: Set<String> = ["压缩", "方式", "确认"]
        let short: Set<String> = ["压缩", "方式"]
        let withHistory = short.union((0..<50).map { "脉络词\($0)" })
        XCTAssertEqual(
            ProgressTiering.lexicalOverlap(sessionTerms: session, matterTerms: withHistory),
            ProgressTiering.lexicalOverlap(sessionTerms: session, matterTerms: short),
            accuracy: 0.0001, """
            事的脉络变长之后词面分变了 —— 分母跑到事那一侧去了。
            后果是**谈得越久的事越比不上**,而漏召回没有任何东西会红。
            """)
    }

    /// 但**不相干就是不相干** —— 包含度不许把无关的事也放进来。
    /// 这条与上一条是一对:少了它,「分母只取本场」会退化成「什么都匹配」。
    func testUnrelatedMatterStillScoresLow() {
        let session: Set<String> = ["压缩", "方式", "确认"]
        let unrelated: Set<String> = ["招聘", "预算", "场地"]
        XCTAssertEqual(
            ProgressTiering.lexicalOverlap(sessionTerms: session, matterTerms: unrelated), 0)
    }

    /// 人物重合度的**分母是事的参与人**,不是并集。
    ///
    /// 问的是「这件事的人今天在不在场」,不是「今天在场的人有多少跟这件事有关」。
    /// 一场十个人的会里出现了这件事的全部两个参与人 —— 那是强信号,
    /// 不该被另外八个人稀释成 0.2。
    func testPeopleOverlapIsNotDilutedByCrowdSize() {
        let matterPeople: Set<Int64> = [1, 2]
        let smallMeeting: Set<Int64> = [1, 2]
        let bigMeeting: Set<Int64> = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        XCTAssertEqual(ProgressTiering.peopleOverlap(sessionPeople: smallMeeting,
                                                     matterPeople: matterPeople), 1.0)
        XCTAssertEqual(ProgressTiering.peopleOverlap(sessionPeople: bigMeeting,
                                                     matterPeople: matterPeople), 1.0, """
            人多的场次把信号稀释了 —— 分母取错成并集了。
            """)
    }

    /// 空集不许算出 NaN 或 1.0 —— 「没有参与人」不等于「全都重合」。
    func testEmptySetsScoreZeroNotOne() {
        XCTAssertEqual(ProgressTiering.peopleOverlap(sessionPeople: [1], matterPeople: []), 0)
        XCTAssertEqual(ProgressTiering.lexicalOverlap(sessionTerms: [], matterTerms: ["a"]), 0)
    }
}
