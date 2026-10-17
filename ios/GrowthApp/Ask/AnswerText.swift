import Foundation

/// 把回答切成「普通文字」与「可点的出处」两种片段。
///
/// ## 为什么要有这一层
///
/// `AskPrompt` 的注释写着「界面据此把 `[#123]` 渲染成可点的出处」,
/// 会话页上也写着「点回答里的编号跳原话」—— 而界面里是
/// `Text(turn.answer ?? "")` 一句纯文本,`[#123]` 按字面渲染。
/// **三处文字都在承诺一个不存在的交互。**
///
/// 出处不是装饰:自由提问的答案是模型生成的,`[#123]` 是它**唯一可核对的锚**。
/// 点不开就等于「相信我」——而这个产品全部的价值在于「你可以去看原话」。
///
/// ## 只认真的出处
///
/// 模型编出来的 `[#99999]` 已经在 `AskPrompt.citedLineIDs` 里被丢掉了,
/// 所以这里再拿 `cited` 过一遍:**不在名单里的按普通文字渲染**,
/// 而不是渲染成一个点了没反应的链接 —— 后者正好长得像「出处功能坏了」。
enum AnswerText {

    enum Piece: Equatable {
        case text(String)
        /// 可点的出处。`raw` 是原样的 `[#123]`,渲染时照它显示。
        case citation(lineID: Int64, raw: String)
        case inputCitation(localID: Int64, raw: String)
    }

    /// 出处链接用的自定义 scheme。
    ///
    /// ⚠️ **必须是个 App 外打不开的 scheme。** 万一哪天 `openURL` 那个拦截漏了,
    /// 系统会因为「没人处理这个 scheme」而什么都不做 —— 而如果用 `https://`,
    /// 漏掉的表现是**把用户踢去浏览器**。前者是没反应,后者是把人送走。
    static let scheme = "growth-line"

    static func url(lineID: Int64) -> URL? { URL(string: "\(scheme)://\(lineID)") }

    static func inputURL(localID: Int64) -> URL? { URL(string: "growth-input://\(localID)") }
    static func inputID(from url: URL) -> Int64? {
        guard url.scheme == "growth-input" else { return nil }
        return Int64(url.host() ?? "")
    }

    /// 从出处链接里取回 `line_id`。认不出来返回 nil —— 不猜。
    static func lineID(from url: URL) -> Int64? {
        guard url.scheme == scheme else { return nil }
        return Int64(url.host() ?? "")
    }

    /// - Parameter cited: `ask_turns.cited_line_ids` —— 校验过的那一份。
    static func pieces(of answer: String, cited: [Int64], inputCited: [Int64] = []) -> [Piece] {
        guard !answer.isEmpty else { return [] }
        let allowed = Set(cited)
        guard let re = try? NSRegularExpression(pattern: #"\[([#@])(\d+)\]"#) else {
            return [.text(answer)]
        }
        let ns = answer as NSString
        var out: [Piece] = []
        var cursor = 0

        for m in re.matches(in: answer, range: NSRange(location: 0, length: ns.length)) {
            guard let id = Int64(ns.substring(with: m.range(at: 2))) else { continue }
            // 不在名单里的**当普通文字**:那是幻觉,不是出处。
            let input = ns.substring(with: m.range(at: 1)) == "@"
            guard input ? Set(inputCited).contains(id) : allowed.contains(id) else { continue }
            if m.range.location > cursor {
                out.append(.text(ns.substring(with:
                    NSRange(location: cursor, length: m.range.location - cursor))))
            }
            if input { out.append(.inputCitation(localID: id, raw: ns.substring(with: m.range))) }
            else { out.append(.citation(lineID: id, raw: ns.substring(with: m.range))) }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            out.append(.text(ns.substring(from: cursor)))
        }
        return out
    }
}
