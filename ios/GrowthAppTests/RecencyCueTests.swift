import XCTest
@testable import GrowthApp

/// 「问的是近况还是属性」(`M2-检2` §1.1)。
///
/// 反例比正例重要:这一刀存在的全部理由,就是**属性题不许被判成近况题** ——
/// 长期属性的正确答案天然是旧的,判错了会把对的那条罚下去(VoiceMem 实测,
/// 「我在哪读书」的正确答案因此从第一掉到第六)。
final class RecencyCueTests: XCTestCase {

    private let bundle = Bundle(for: RecencyCueTests.self)

    private func wants(_ q: String) -> Bool { RecencyCue.wantsRecency(q, bundle: bundle) }

    /// 🔴 词表没进 target 时判据恒 false,而那和「这些都是属性题」长得一模一样。
    func testTheLexiconIsActuallyInTheBundle() {
        XCTAssertFalse(RecencyCue.cues(bundle: bundle).isEmpty,
                       "recency_cues.json 没进测试 target(project.yml 里补一行)")
    }

    // MARK: - 近况题(该向新的倾斜)

    func testRecencyQuestions() {
        for q in ["最近在忙什么", "这阵子他怎么样", "今天说了什么", "昨天谁提到交付",
                  "刚才那个数是多少", "目前进展怎么样", "上周的会讨论了什么",
                  "这段时间团队在推什么", "最新的排期是哪天", "这两天有什么新的进展"] {
            XCTAssertTrue(wants(q), "「\(q)」该判成近况题")
        }
    }

    func testEnglishRecencyQuestionsAreCaseInsensitive() {
        for q in ["What did we discuss LATELY", "Recent updates?", "what is he doing Right Now"] {
            XCTAssertTrue(wants(q), "「\(q)」该判成近况题(大小写不该影响)")
        }
    }

    // MARK: - 属性题(不许被判成近况题)

    /// 这一组是这一刀存在的理由。判错了,正确答案会因为「旧」被罚下去。
    func testAttributeQuestionsAreNotRecency() {
        for q in ["我在哪读书", "他对什么过敏", "老周是哪个部门的", "我的老家在哪",
                  "他一般怎么做决定", "这个项目的目标是什么", "谁负责交付",
                  "我说过我不喜欢什么", "他的电话是多少", "这件事的来龙去脉"] {
            XCTAssertFalse(wants(q), "「\(q)」是属性题,不该按时间倾斜")
        }
    }

    /// 空问句不判。
    func testEmptyQuestionIsNotRecency() {
        XCTAssertFalse(wants(""))
    }

    /// 读不到词表时恒 false —— 不崩(增强件不阻塞主线),但**计数必须涨**。
    ///
    /// 🔴 断言的是「涨了」而不是「计数为 0」:计数是全局的,谁先跑谁后跑会变,
    /// 拿绝对值断言等于让这条测试依赖执行顺序(第一版就是这么红的)。
    func testAMissingLexiconYieldsFalseAndIsCounted() {
        let before = RecencyCue.lexiconLoadFailures
        XCTAssertFalse(RecencyCue.wantsRecency("最近怎么样", bundle: Bundle(for: XCTestCase.self)))
        XCTAssertGreaterThan(RecencyCue.lexiconLoadFailures, before,
                             "词表读失败了却没留下计数 —— 那就是静默失败(仓规 6)")
    }

    // MARK: - 与 relative_dates.json 的分工

    /// 🔴 两份词表**不是一回事**,故意有交叠也故意有分歧:
    /// `relative_dates` 要的是确定边界(所以不收「最近」),这份要的是倾向信号
    /// (所以「最近」是主力)。谁把它们合成一份,这条会红。
    func testTheTwoLexiconsAreDeliberatelyDifferent() {
        let table = RelativeDates.lexicon(bundle: bundle)
        XCTAssertTrue(wants("最近怎么样"), "「最近」该是近况信号")
        XCTAssertNil(table.days["最近"], "「最近」没有确定边界,不该进 relative_dates")
        XCTAssertNil(table.weeks["最近"])

        // 交叠的那部分:「今天」两边都有,各起各的作用。
        XCTAssertTrue(wants("今天说了什么"))
        XCTAssertNotNil(table.days["今天"])
    }
}
