import XCTest
@testable import GrowthApp

/// 回答里的出处(M1-17 第 1 条)。
///
/// 🔴 **在这之前有三处文字在承诺一个不存在的交互**:会话页上写着
/// 「点回答里的编号跳原话」、`AskPrompt` 的注释写着「界面据此把 `[#123]`
/// 渲染成可点的出处」、`answerView` 自己的注释写着「这里出现的每一条都点得开」——
/// 而界面是 `Text(turn.answer ?? "")` 一句纯文本。
///
/// 出处不是装饰:答案是模型生成的,`[#123]` 是它**唯一可核对的锚**。
final class AnswerTextTests: XCTestCase {

    func testACitationBecomesItsOwnPiece() {
        let p = AnswerText.pieces(of: "他说过[#12]这件事。", cited: [12])
        XCTAssertEqual(p, [.text("他说过"), .citation(lineID: 12, raw: "[#12]"), .text("这件事。")])
    }

    /// 🔴 **不在名单里的当普通文字,不渲染成链接。**
    ///
    /// 模型编出来的 `[#99999]` 已经在 `AskPrompt.citedLineIDs` 里被丢掉了。
    /// 这里再挡一道:渲染成一个点了没反应的链接,正好长得像「出处功能坏了」。
    func testAFabricatedCitationStaysPlainText() {
        let p = AnswerText.pieces(of: "他说过[#99999]。", cited: [12])
        XCTAssertEqual(p, [.text("他说过[#99999]。")])
    }

    /// 连着两条出处之间不该凭空多出一个空的文字片段。
    func testAdjacentCitationsDoNotProduceEmptyGaps() {
        let p = AnswerText.pieces(of: "[#1][#2]", cited: [1, 2])
        XCTAssertEqual(p, [.citation(lineID: 1, raw: "[#1]"), .citation(lineID: 2, raw: "[#2]")])
    }

    /// 一条出处都没有时,原样一段文字 —— 不做任何切分。
    func testAnAnswerWithoutCitationsIsOnePiece() {
        XCTAssertEqual(AnswerText.pieces(of: "就这样。", cited: []), [.text("就这样。")])
        XCTAssertEqual(AnswerText.pieces(of: "", cited: [1]), [])
    }

    /// 中文与标点不会被切错位(`NSString` 与 `String` 的索引口径不同,
    /// 这里一路用 `NSString` —— 混用会在有 emoji 或组合字符时切歪)。
    func testChineseAroundCitationsIsNotMangled() {
        let answer = "会上他答应周三之前给文档[#100],但没说给谁[#101]。"
        let joined = AnswerText.pieces(of: answer, cited: [100, 101]).map { p -> String in
            switch p {
            case .text(let s): return s
            case .citation(_, let raw), .inputCitation(_, let raw): return raw
            }
        }.joined()
        XCTAssertEqual(joined, answer, "拼回去和原文不一样 —— 有字被切没了")
    }

    // MARK: - 链接

    /// 🔴 **scheme 必须是 App 外打不开的那种。**
    /// 用 `https://` 的话,漏掉一次拦截就是**把用户踢去浏览器**;
    /// 自定义 scheme 漏了只是没反应。两种失败的代价不一样。
    func testTheSchemeCannotEscapeTheApp() {
        XCTAssertEqual(AnswerText.url(lineID: 42)?.scheme, AnswerText.scheme)
        XCTAssertNotEqual(AnswerText.scheme, "https")
        XCTAssertNotEqual(AnswerText.scheme, "http")
    }

    func testLineIDRoundTripsThroughTheURL() throws {
        let url = try XCTUnwrap(AnswerText.url(lineID: 12345))
        XCTAssertEqual(AnswerText.lineID(from: url), 12345)
    }

    /// 别人的 URL 不认 —— 不猜。
    func testAForeignURLIsNotMistakenForACitation() throws {
        XCTAssertNil(AnswerText.lineID(from: try XCTUnwrap(URL(string: "https://example.com/7"))))
    }
}
