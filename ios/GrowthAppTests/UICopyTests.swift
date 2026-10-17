import XCTest

/// 界面文案的闸。
///
/// ## 为什么现在才有
///
/// 禁止词表在 `docs/前端-设计哲学.md` 里躺了很久(「历轮评审阵亡名单」),
/// **一直没有任何东西守着它** —— 仓规 9 那三问的第三问「哪道闸守着它?」没答。
/// 结果 2026-09-01 模拟器实拍当场撞见:
///   · 人页写着「那一层在 **M3**。」—— 里程碑编号印在用户脸上;
///   · 设置页写着「它们在 **PRD §4.1.10** 里」—— 文档章节号;
///   · 认人页写着「这几句的声音会进**声纹**底库」—— 阵亡名单上的词;
///   · 五处桩的报错文案带着 `M3-B2/F2` 这种任务号,而 `Notice.error` 会把 Error
///     **原样插进用户看的那句话**。
///
/// 编号对用户是**零信息**:他不知道 M3 是什么时候、PRD §4.1.10 写了什么。
/// 对开发者有用 —— 所以规矩是**编号留在注释里,不进字符串**。
///
/// ## 为什么只守这几个词
///
/// 阵亡名单上还有「待办 / 催 / 过期 / n=」。它们**机械查不了**:
/// 「只记不催」「不是待办」这种否定式用法是合规的,按子串拦会拦掉正确的文案,
/// 而假红比没有闸更糟(它会训练人去绕闸)。那几个词仍然是纪律,只是靠人看。
/// **这里只收机械上没有歧义的那一批。**
final class UICopyTests: XCTestCase {

    /// 只扫界面层。`Database/` `Upload/` `Voiceprint/` 里说「声纹」「置信」是本分。
    private static let uiDirs = ["GrowthApp/Presentation", "GrowthApp/Ask"]
    private static let uiFiles = ["TimelineComponents.swift", "RootView.swift"]

    /// (词, 为什么不许出现在界面上)
    private static let banned: [(String, String)] = [
        ("声纹",   "机器语言。用户认的是「声音」「谁在说」,不是声纹"),
        ("置信",   "把模型内部的分数搬到脸上"),
        ("supersede", "英文内部术语"),
        ("信道",   "工程内部概念"),
        ("金标",   "评测内部术语"),
        ("非因果", "评测内部术语"),
        ("语气分歧值", "评测内部术语"),
        ("听原声", "拍板过:出处到「看原话」为止,不做试听入口"),
        ("atom#",  "内部标识"),
    ]

    /// 任务号 / 文档章节号。
    private static let codePatterns: [(String, String)] = [
        (#"\bM[0-4](-[A-Z0-9]+)?\b"#, "里程碑或任务号(M2-B2 这种)"),
        (#"PRD"#,                     "文档名"),
        (#"§"#,                       "文档章节号"),
        (#"[判审走]\s?\d"#,            "评审/走查条目号"),
    ]

    func testUIStringsCarryNoInternalCodesOrBannedWords() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()   // ios/

        var urls: [URL] = Self.uiFiles.map { root.appendingPathComponent($0) }
        for d in Self.uiDirs {
            let dir = root.appendingPathComponent(d)
            urls += (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" } ?? [])
        }
        XCTAssertGreaterThan(urls.count, 10, "一个界面文件都没扫到,这条断言是空转的")

        var offenders: [String] = []
        var literals = 0
        for url in urls {
            let src = try String(contentsOf: url, encoding: .utf8)
            for (i, rawLine) in src.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                // 去注释:讲「为什么不许写」的那些话本身不算违规
                var line = String(rawLine)
                if let r = line.range(of: "//") { line = String(line[line.startIndex..<r.lowerBound]) }
                guard line.contains("\"") else { continue }

                // 任务号绑在**给开发者的字段**上是允许的 —— 那正是 2026-09-01 拆分的落点:
                // 人话进 `blockedBy`(会显示),编号进 `blockingTask` / `task:`(不显示)。
                // ⚠️ 这是**按行**放行,不是按绑定关系放行 —— 真想绕,把编号写在一行
                // 提到 `task:` 的用户文案里就能溜过去。判据放宽到这里为止:
                // 再准就要解析 Swift 了,而那道成本换来的是一个几乎不会发生的绕法。
                let isDeveloperChannel = line.contains("blockingTask") || line.contains("task: \"")

                for lit in Self.stringLiterals(in: line) {
                    literals += 1
                    for (w, why) in Self.banned where lit.contains(w) {
                        offenders.append("\(url.lastPathComponent):\(i + 1) 「\(w)」—— \(why)")
                    }
                    guard !isDeveloperChannel else { continue }
                    for (p, why) in Self.codePatterns
                    where lit.range(of: p, options: .regularExpression) != nil {
                        offenders.append("\(url.lastPathComponent):\(i + 1) \(why):\(lit)")
                    }
                }
            }
        }

        XCTAssertGreaterThan(literals, 100, "扫到的字符串太少,取字面量的写法是不是坏了?")
        XCTAssertEqual(offenders.sorted(), [],
                       "这些界面文案里带着用户读不懂的东西。编号留注释里,别进字符串 ——"
                       + "`Notice.error` 会把 Error 的 description 原样插进用户看的那句话:\n"
                       + offenders.sorted().joined(separator: "\n"))
    }

    /// 取一行里的字符串字面量。转义引号在本仓的界面层没出现过,
    /// 真出现了这里会少取一段 —— 那是漏报不是误报,闸只会变松不会假红。
    private static func stringLiterals(in line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inside = false
        for ch in line {
            if ch == "\"" { if inside { out.append(cur); cur = "" }; inside.toggle(); continue }
            if inside { cur.append(ch) }
        }
        return out
    }
}
