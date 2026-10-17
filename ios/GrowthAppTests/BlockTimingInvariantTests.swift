import XCTest
@testable import GrowthApp

/// 「块的位置只从账本取」这条不变式的**源码闸**。
///
/// ## 为什么要一道源码闸,而不是再补几条数据断言
///
/// 这条不变式 2026-08 被破了**三次**,每次都是新加一个消费方时重犯的:
/// · `TranscriptFreeze` 用 `blockSeq × 300_000` 拼场次时间轴(M1-13a);
/// · `LineAudio` / `SpeakerSegments` 用 `t_start_ms − blockSeq × 300_000` 反算块内偏移
///   —— 上游改成真值之后这个减法当场失效,而**三处里只改了一处比一处都不改更危险**:
///   之前它们一致地错,之后它们互相矛盾,而矛盾是静默的;
/// · `SessionMaintenance.refreeze` 拿 `?? seq * 300_000` 兜底(2026-08-18 复核抓到)。
///
/// 三次的共同点:**都不报错**。块跑满 330 秒(`BlockCutPolicy` 的窗口是 270–330)
/// 是常态,而算错之后每一行仍有一个看起来合理的时间戳 ——
/// 表现只是「跳原话跳到别人那句」「认人取到别人的声音」。
///
/// 数据断言挡不住第四个消费方。所以扫源码。
final class BlockTimingInvariantTests: XCTestCase {

    /// 去掉行注释与文档注释,只留会被编译的部分。
    ///
    /// ⚠️ 不去掉的话这条断言恒红 —— 上面那几段说明里全是 `300_000`,
    /// 而**「解释为什么不许这么写」和「这么写了」必须分得开**。
    private func code(of source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let r = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<r.lowerBound])
            }
            .joined(separator: "\n")
    }

    func testNobodyDerivesBlockPositionsFromTheNominalLength() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? [])
            .map { (rel: $0.path.replacingOccurrences(of: root.path + "/", with: ""), url: $0) }
            .filter { $0.rel.hasPrefix("GrowthApp/") }
        XCTAssertGreaterThan(files.count, 10, "一个 .swift 都没扫到,这条断言是空转的")

        // `BlockCutPolicy` 是**定义**名义块长的地方 —— 它有权写这个数,
        // 别人只能从账本读真值。这是仅有的豁免。
        let exempt = ["GrowthApp/Recording/BlockCutPolicy.swift"]
        // 乘或除:`× 300_000` 是「算块起点」,`/ 300_000` 是「反推块号」。
        // 两种都禁 —— 它们是同一个错误的两个方向。
        let patterns = ["* 300_000", "/ 300_000", "*300_000", "/300_000",
                        "* 300000", "/ 300000", "*300000", "/300000"]

        var offenders: [String] = []
        for f in files where !exempt.contains(f.rel) {
            let src = code(of: try String(contentsOf: f.url, encoding: .utf8))
            if patterns.contains(where: { src.contains($0) }) { offenders.append(f.rel) }
        }
        XCTAssertEqual(offenders, [],
                       "这些文件自己拿名义块长算块的位置 —— 块跑满 330 秒时会取到"
                       + "另一个人的音频,而且不报错。真值在账本里,走 `BlockTiming`:\(offenders)")
    }

    /// 这条断言**自己得能红**:上面那段去注释的处理不能把代码也吃掉。
    func testTheCommentStripperKeepsCode() {
        XCTAssertTrue(code(of: "let x = a * 300_000  // 说明").contains("* 300_000"))
        XCTAssertFalse(code(of: "// 不许写 a * 300_000").contains("* 300_000"))
        XCTAssertFalse(code(of: "/// `blockSeq * 300_000` 是错的").contains("* 300_000"))
    }
}

/// 闭集取值**只有一个出处**的源码闸。
///
/// ## 它挡的是哪种失败
///
/// `line_speakers.source` 与 `sessions.status` 都是**闭集**,而闭集的取值同时长在
/// 三个地方:Swift 枚举、库里的 CHECK 约束、以及各处 SQL 里的字面量。
///
/// 🔴 **前两处对不上会被 DB 当场拒绝(那是好事,失败可见);
/// 而第三处对不上是静默的** —— `WHERE source = '用户确认'` 在取值改名之后
/// 一行都匹配不到,于是「还有几个待确认」变成 0、界面说「都认过了」,
/// 而一个都没确认过。M1-12e 就是这个形状(那次是算法分叉,这次是字面量分叉)。
///
/// 所以字面量只准出现在**定义它的地方**,别处一律插值。
final class ClosedSetLiteralTests: XCTestCase {

    func testClosedSetValuesAreNotRetypedInSQL() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? [])
            .map { (rel: $0.path.replacingOccurrences(of: root.path + "/", with: ""), url: $0) }
            .filter { $0.rel.hasPrefix("GrowthApp/") }
        XCTAssertGreaterThan(files.count, 10, "一个 .swift 都没扫到,这条断言是空转的")

        // 定义处 + 建表迁移 —— 仅有的豁免,按相对路径写。
        let exempt: [String: [String]] = [
            "'\(AttributionSource.userConfirmed.rawValue)'":
                ["GrowthApp/Database/AssignSpeaker.swift", "GrowthApp/Database/AppDatabase.swift"],
            "'\(SessionBridge.Status.open)'":
                ["GrowthApp/Database/SessionBridge.swift", "GrowthApp/Database/AppDatabase.swift",
                 // `sessions.status` 的 'recording' 与 `sessions.source` 的
                 // 'recording' 是**两个不同列的两个取值**,恰好同字。
                 // 导入那条链写的是 source,不是 status。
                 "GrowthApp/Recording/ImportIngest.swift"],
        ]
        var offenders: [String] = []
        for (literal, allowed) in exempt {
            for f in files where !allowed.contains(f.rel) {
                let src = try String(contentsOf: f.url, encoding: .utf8)
                // 只查 SQL 里的**带引号字面量**,注释里提到不算
                for line in src.split(separator: "\n") where line.contains(literal) {
                    let code = line.range(of: "//").map { String(line[line.startIndex..<$0.lowerBound]) }
                                ?? String(line)
                    if code.contains(literal) { offenders.append("\(f.rel):\(literal)") }
                }
            }
        }
        XCTAssertEqual(offenders.sorted(), [],
                       "闭集取值被又敲了一遍 —— 取值改名之后这些查询会静默匹配不到:"
                       + "\(offenders.sorted())")
    }
}


/// 🔴 **色点旁边必须有字。**
///
/// `DesignSystem` 自己写着:
///
/// > 2026-08-14 起 `sceneColor` 几乎不携带信息了 —— 除「在动/出错」走 danger 外
/// > 其余场景同色。**任何只画色点不画 `sceneLabel` 的界面,从此就是没信息的界面。**
/// > 深色版里这还只是无障碍建议,现在它是唯一的区分手段。
///
/// 它把要求写清楚了,**而没有任何东西守着**(第 14 次同形状,见 TASKS `M1-审4`)。
///
/// ## 为什么现在就加,而不是等第一个消费方
///
/// 今天 `sceneColor` 与 `sceneLabel` **在生产代码里都是零引用** ——
/// M1 的界面一个场景色点都没画。**趁没人用的时候把闸装上是最便宜的时机**:
/// 等 M2 画发现/卡片时才想起来,那时要么已经画错、要么得回头改一批界面。
final class SceneColorNeedsLabelTests: XCTestCase {

    func testEveryViewThatPaintsASceneDotAlsoRendersItsLabel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? [])
            .map { (rel: $0.path.replacingOccurrences(of: root.path + "/", with: ""), url: $0) }
            // 定义处豁免;`_legacy/` 与测试不编译进 App
            .filter { ($0.rel.hasPrefix("GrowthApp/") || $0.rel == "DesignSystem.swift"
                       || $0.rel == "TimelineComponents.swift" || $0.rel == "RootView.swift")
                      && $0.rel != "DesignSystem.swift" }
        XCTAssertGreaterThan(files.count, 10, "一个 .swift 都没扫到,这条断言是空转的")

        var offenders: [String] = []
        for f in files {
            let src = try String(contentsOf: f.url, encoding: .utf8)
            // 去注释:说明「为什么必须配标签」的那些话不算违规
            let code = src.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    guard let r = line.range(of: "//") else { return String(line) }
                    return String(line[line.startIndex..<r.lowerBound])
                }
                .joined(separator: "\n")
            if code.contains("sceneColor"), !code.contains("sceneLabel") {
                offenders.append(f.rel)
            }
        }
        XCTAssertEqual(offenders, [],
                       "这些界面画了场景色点却没画 `sceneLabel` —— 而 2026-08-14 降级之后"
                       + "除「在动/出错」外其余场景同色,**色点已经不携带信息了**:\(offenders)")
    }

    /// 反过来单用 `sceneLabel` 是**允许**的 —— 只有字没有色点,信息不丢。
    /// 写这条是为了说明上面那条**不是「两个必须成对出现」**,而是单向依赖。
    func testUsingOnlyTheLabelIsFine() {
        XCTAssertFalse(DS.sceneLabel("会议").isEmpty)
    }
}
