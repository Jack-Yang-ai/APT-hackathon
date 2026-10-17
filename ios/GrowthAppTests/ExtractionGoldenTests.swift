import XCTest
@testable import GrowthApp

/// 抽取口径的**跨运行时一致性**测试(M1-4b)。
///
/// 读的是 `eval/checks/golden/extract_golden.json` —— 由 Python 侧
/// (`shared/text_normalize.py` + `worker/extract.py`)生成,两边测试**共读同一个文件**。
///
/// ## 为什么要这么测
///
/// 抽取的校验口径现在有两份实现:Python 那份是判分尺子用的,Swift 这份是手机上
/// 真正跑的。两份实现会漂,而**漂移不报错** —— 它只让「尺子量的」和「生产跑的」
/// 悄悄变成两回事。仓规:评测的尺子与被测对象必须同一条路由,否则测的不是生产。
///
/// 所以断言不是「Swift 自己自洽」,是「Swift 与 Python 逐字节相同」。
/// 谁先改口径谁先红,而红就是要的:改口径必须是一个显式动作(判 4)。
///
/// 重新生成:`python3 eval/checks/gen_extract_golden.py`
final class ExtractionGoldenTests: XCTestCase {

    /// 相对仓库根的固定路径。`#filePath` 是 ios/GrowthAppTests/…,往上两级是仓库根。
    /// (照 `SchemaFixtureTests` 的先例。)
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func golden() throws -> [String: Any] {
        let url = repoRoot.appendingPathComponent("eval/checks/golden/extract_golden.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - 版本

    func testVersionsMatchThePythonSide() throws {
        let g = try Self.golden()
        // 版本号对不上意味着某一侧改了规则而另一侧没跟 —— 那正是判 4 要防的
        XCTAssertEqual(g["normalizer_version"] as? String, TextNormalize.version)
        XCTAssertEqual(g["prompt_version"] as? String, ExtractPrompt.version)
    }

    // MARK: - 归一

    /// 40 个例子,全是「两个运行时可能给不同答案」的字:
    /// 全半角、连字、组合字符、词尾 σ、ß、各种 Unicode 分类的符号。
    func testNormalizeMatchesPythonCharacterForCharacter() throws {
        let cases = try XCTUnwrap(try Self.golden()["normalize"] as? [[String: String]])
        XCTAssertGreaterThan(cases.count, 30, "金标变小了 —— 是不是生成脚本被改瘦了")
        for c in cases {
            let input = try XCTUnwrap(c["in"]), expected = try XCTUnwrap(c["out"])
            XCTAssertEqual(TextNormalize.normalize(input), expected,
                           "归一漂了:输入 \(input.debugDescription)")
        }
    }

    /// ⚠️ 这一条单独拎出来,因为它是**实测踩到的**:
    /// `lowercased()` 在 50 例里错 4 个(ß 不展开、词尾 ς 不归一),
    /// 只有 `folding(.caseInsensitive)` 与 Python 的 `casefold()` 一致。
    /// 谁哪天顺手把它改回 `lowercased()`,这里要红。
    func testCaseFoldingIsFoldingNotLowercasing() {
        XCTAssertEqual(TextNormalize.normalize("Straße"), "strasse")
        XCTAssertEqual(TextNormalize.normalize("σοφος"), TextNormalize.normalize("ΣΟΦΟΣ"))
    }

    // MARK: - 逐字

    func testVerbatimMatchesPython() throws {
        let cases = try XCTUnwrap(try Self.golden()["verbatim"] as? [[String: Any]])
        for c in cases {
            let q = try XCTUnwrap(c["quote"] as? String)
            let s = try XCTUnwrap(c["source"] as? String)
            let ok = try XCTUnwrap(c["ok"] as? Bool)
            XCTAssertEqual(TextNormalize.isVerbatim(quote: q, source: s), ok,
                           "逐字判定漂了:quote=\(q.debugDescription) source=\(s.debugDescription)")
        }
    }

    /// 归一后才变空的 quote 也算没给引文。
    /// 这个洞两侧一起修的(2026-08-14):原来 `is_verbatim("。", 任意)` 返回 true,
    /// 后果是一条编造的条目**静默通过**逐字校验 —— 而逐字通过率正是 R4
    /// 用来决定「要不要先修抽取」的那个数。
    func testQuoteThatNormalizesToNothingIsNotVerbatim() {
        for junk in ["。", "  ", "……!?", "~+=°"] {
            XCTAssertFalse(TextNormalize.isVerbatim(quote: junk, source: "随便什么原文"),
                           "\(junk.debugDescription) 通过了逐字校验")
        }
    }

    // MARK: - prompt

    /// 逐字节比对。改一个标点两边就都得改 —— 这是刻意的:
    /// prompt 里每一条硬要求都对应校验里的一项,单边改会让「模型被要求做的」
    /// 和「校验在查的」错开,而那种错开只表现为通过率悄悄变化,不报错。
    func testRenderedPromptIsByteIdenticalToPython() throws {
        let expected = try String(contentsOf: Self.repoRoot
            .appendingPathComponent("eval/checks/golden/extract_prompt_v1.txt"),
                                  encoding: .utf8)
        let rendered = ExtractPrompt.render(lines: try Self.goldenLines())
        XCTAssertEqual(rendered, expected, "prompt 与 Python 侧不一致")
    }

    func testUnattributedLinesRenderAsTheSameWordAsPython() {
        // Python:`line.get('cluster_tag') or '未分人'`。用别的词就是一处口径差,
        // 而模型看到的是不同的输入 —— 抽取结果会跟着变,而没人会想到是这里。
        let rendered = ExtractPrompt.render(lines: [
            .init(lineID: 1, text: "谁说的不知道", clusterTag: nil)])
        XCTAssertTrue(rendered.hasSuffix("1 | 未分人 | 谁说的不知道\n"), rendered.suffix(60).description)
    }

    // MARK: - 三项校验

    /// 十个用例,五种判定(通过 / 行号不存在 / 占位行 / 非原文 / 归属未定 / hint 不一致)
    /// 全覆盖,连计数和 `failure_rate` 的小数位都对撞。
    func testValidateMatchesPythonOnEveryCase() throws {
        let cases = try XCTUnwrap(try Self.golden()["validate"] as? [[String: Any]])
        let lines = try Self.goldenLines()
        XCTAssertGreaterThanOrEqual(cases.count, 10)

        for c in cases {
            let name = (c["name"] as? String) ?? "?"
            let payload = try XCTUnwrap(c["payload"] as? [String: Any], name)
            let (clean, stats) = try ExtractValidate.validate(payload, lines: lines)

            let wantStats = try XCTUnwrap(c["stats"] as? [String: Any], name)
            XCTAssertEqual(stats.total, wantStats["total"] as? Int, "[\(name)] total")
            XCTAssertEqual(stats.passed, wantStats["passed"] as? Int, "[\(name)] passed")
            XCTAssertEqual(stats.pending, wantStats["pending"] as? Int, "[\(name)] pending")
            XCTAssertEqual(stats.discarded, wantStats["discarded"] as? Int, "[\(name)] discarded")
            XCTAssertEqual(stats.discardReasons, wantStats["discard_reasons"] as? [String: Int],
                           "[\(name)] 丢弃原因")
            XCTAssertEqual(stats.pendingReasons, wantStats["pending_reasons"] as? [String: Int],
                           "[\(name)] 挂起原因")
            // 空分母给 nil 不给 0 —— 0 会被读成「一条都没丢,质量很好」
            XCTAssertEqual(stats.failureRate, wantStats["failure_rate"] as? Double,
                           "[\(name)] failure_rate")
            XCTAssertEqual(stats.pendingRate, wantStats["pending_rate"] as? Double,
                           "[\(name)] pending_rate")

            let wantClean = try XCTUnwrap(c["clean"] as? [String: Any], name)
            assertSameJSON(clean, wantClean, name)
        }
    }

    /// schema 不合的**必须抛**,不许「宽容地当成空结果」——
    /// 那会让一份结构错的产出静默变成「这场没抽到内容」。
    func testSchemaRejectsMatchPython() throws {
        let cases = try XCTUnwrap(try Self.golden()["schema_rejects"] as? [[String: Any]])
        let lines = try Self.goldenLines()
        XCTAssertGreaterThanOrEqual(cases.count, 7)
        for c in cases {
            let name = (c["name"] as? String) ?? "?"
            let payload = try XCTUnwrap(c["payload"] as? [String: Any], name)
            XCTAssertThrowsError(try ExtractValidate.validate(payload, lines: lines),
                                 "[\(name)] Python 侧拒了,这边放过去了")
        }
    }

    // MARK: - 解析

    func testTruncatedOutputThrowsInsteadOfReturningEmpty() {
        // 「被截断」与「这场没内容」在下游长得一模一样,而前者要重试、后者不要
        XCTAssertThrowsError(try ExtractValidate.parseModelOutput(""))
        XCTAssertThrowsError(try ExtractValidate.parseModelOutput("   \n "))
        XCTAssertThrowsError(try ExtractValidate.parseModelOutput(#"{"one_liner": "被切"#))
        XCTAssertThrowsError(try ExtractValidate.parseModelOutput("[1,2,3]"), "顶层不是对象要抛")
    }

    /// ⚠️ **不剥代码围栏。** prompt 里明写了「不要代码围栏」,单边加宽容
    /// 就是两份实现的第一处漂移。要放宽,`worker/extract.py` 必须同时放宽。
    func testFencedOutputIsNotSilentlyAccepted() {
        XCTAssertThrowsError(try ExtractValidate.parseModelOutput("```json\n{\"a\":1}\n```"))
    }

    // MARK: - 零件

    private static func goldenLines() throws -> [ExtractValidate.Line] {
        let raw = try XCTUnwrap(try golden()["lines"] as? [[String: Any]])
        return raw.map {
            ExtractValidate.Line(
                lineID: Int64($0["line_id"] as? Int ?? 0),
                text: $0["text"] as? String ?? "",
                isGap: ($0["is_gap"] as? Int ?? 0) == 1,
                personID: ($0["person_id"] as? Int).map(Int64.init),
                clusterTag: $0["cluster_tag"] as? String)
        }
    }

    /// 两份 JSON 结构等价。序列化成 sorted-keys 再比,免得字典序不同就红。
    private func assertSameJSON(_ a: [String: Any], _ b: [String: Any], _ name: String) {
        func dump(_ d: [String: Any]) -> String {
            (try? String(data: JSONSerialization.data(withJSONObject: d,
                                                      options: [.sortedKeys]), encoding: .utf8)) ?? "?"
        }
        XCTAssertEqual(dump(a), dump(b), "[\(name)] 产出与 Python 侧不一致")
    }
}
