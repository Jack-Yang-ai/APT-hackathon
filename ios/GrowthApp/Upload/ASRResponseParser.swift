import Foundation

/// StepFun 文件端点的回复 → `ASRLine`(M1-4)。
///
/// ## 为什么单独一层,而且是纯函数
///
/// 报文形状是**探出来的**(2026-08-13 六轮 4xx),而且以后还会变。
/// 把解析埋进编排里,形状一变就只能靠跑真端点(**花钱**)来验;
/// 拆出来之后拿存下来的原始报文就能测 —— 这也正是 `asr_jobs.result_json`
/// 存原始报文而不是解析结果的原因。
///
/// ## ⚠️ 解不出来要抛,不许返回空数组
///
/// 返回空数组的后果是「冻结一份 0 行的转写」,而冻结是**终态** ——
/// 用户看到「好了」而里面什么都没有,重转还要显式走 v2。
/// 报文变了就该在这里炸,不该悄悄产出一份空的。
enum ASRResponseParser {

    enum Failure: Error, CustomStringConvertible {
        case notJSON(String)
        case noUtterances(String)

        var description: String {
            switch self {
            case .notJSON(let s):
                return "转写回复不是 JSON:\(s.prefix(200))"
            case .noUtterances(let s):
                return "转写回复里没有分句 —— 报文形状可能变了:\(s.prefix(200))"
            }
        }
    }

    /// 分句所在的键。`show_utterances: true` 时 StepFun 给的就是这个。
    /// 列成数组是因为它出现过在两层里(顶层与 `result` 下),两处都试。
    private static let utteranceKeys = ["utterances", "sentences", "segments"]

    /// 解析一块的回复。时间戳在**裁剪后**的时间轴上(VAD 挖掉静音之后),
    /// 还原成块内原始毫秒是 `TranscriptFreeze` 的活,这里不碰。
    /// 这份报文是不是**降级产物**(走了 SSE 兜底 ⇒ 没有分人)。
    ///
    /// 🔴 **它是一个必须被看见的事实,不是元数据。**
    /// 没有分人的一批行会让「上游没给」「写失败」「这一场只有一个人说话」
    /// 在库里长得一模一样 —— 而下游(提名条件一、「人」那三类发现)会拿它当真去算,
    /// 结果是这一场**静默地**从分母里掉出去。用户 2026-08-19 拍板「要看见」。
    ///
    /// 标记由 `mac/asr_fallback.py::as_file_endpoint_shape` 写进报文顶层。
    /// ⚠️ 读不出来时返回 `false` 而不是抛 —— 老报文没有这个键是正常的,
    /// 而把「老报文」判成「降级」会让一堆正常场次显示成无分人。
    static func isDegraded(rawJSON json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (root["growth_no_speaker"] as? Bool) == true
    }

    static func lines(fromRaw json: String) throws -> [ASRLine] {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw Failure.notJSON(json) }

        guard let raw = utterances(in: root) else { throw Failure.noUtterances(json) }

        return raw.compactMap { u -> ASRLine? in
            guard let text = (u["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return nil }        // 空句子跳过:它不是内容,是模型的呼吸
            let start = ms(u["start_time"] ?? u["start"] ?? u["begin_time"])
            let end   = ms(u["end_time"]   ?? u["end"]   ?? u["finish_time"])
            // 结束早于开始的句子**丢掉**,不硬凑 —— 硬凑出来的时间戳会让
            // 分人 spans 与行时长的重叠率抽查(A8)悄悄失真。
            guard end >= start else { return nil }
            return ASRLine(startMs: start, endMs: end, text: text,
                           speaker: speaker(of: u), words: words(of: u))
        }
    }

    /// 明确的零文字结果。坏 JSON、未知形状或有文字却时间无效，不能当作空段。
    static func isEmptyRecognition(rawJSON json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        // 容器可能并存。先查看整份报文，不能因先读到 [] 抹掉另一处的真实文字。
        func hasContentOrError(_ value: Any) -> Bool {
            if let object = value as? [String: Any] {
                if object["error"] != nil { return true }
                for key in ["text", "transcript", "transcription"] {
                    if let value = object[key] {
                        guard let text = value as? String else { return true }
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
                    }
                }
                return object.values.contains(where: hasContentOrError)
            }
            if let values = value as? [Any] { return values.contains(where: hasContentOrError) }
            return false
        }
        guard !hasContentOrError(root) else { return false }
        func empty(_ items: [[String: Any]]) -> Bool {
            items.allSatisfy { item in
                item.isEmpty || (item["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            }
        }
        func validate(_ object: [String: Any]) -> Bool {
            var recognized = false
            for key in utteranceKeys {
                if let value = object[key] {
                    guard let items = value as? [[String: Any]], empty(items) else { return false }
                    recognized = true
                }
            }
            for wrapper in ["result", "data"] {
                guard let value = object[wrapper] else { continue }
                if wrapper == "result", let blocks = value as? [[String: Any]] {
                    guard !blocks.isEmpty,
                          blocks.allSatisfy({ $0.isEmpty || validate($0) }) else { return false }
                } else {
                    guard let wrapped = value as? [String: Any], validate(wrapped) else { return false }
                }
                recognized = true
            }
            return recognized
        }
        return validate(root)
    }

    /// 分人标签:`enable_speaker_info` 开着时每个分句带的说话人。
    ///
    /// ⚠️ 这是**簇标签**(这一场里的第 N 个人),不是身份 ——
    /// 它只在这一场内有意义,跨场对不上(见 `SpeakerNaming`)。
    static func speakers(fromRaw json: String) -> [String?] {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = utterances(in: root) else { return [] }
        return raw.map(speaker(of:))
    }

    /// 一句里的逐词时间戳(M1-19 按词切行的依据)。
    ///
    /// 🔴 **上一版把它整个丢了** —— 只读整句的起止与文字。原始报文一直存在
    /// `asr_jobs.result_json` 里,所以没丢信息,但**下游拿不到它就只能按比例摊字**,
    /// 而摊出来的切口会落在字的中间:前半句最后一个字被劈成半个。
    ///
    /// 上游没给 `words` 时返回空数组 —— 调用方据此**拒绝切分**,不是猜一个切口。
    private static func words(of u: [String: Any]) -> [ASRWord] {
        guard let raw = u["words"] as? [[String: Any]] else { return [] }
        return raw.compactMap { w -> ASRWord? in
            guard let text = w["text"] as? String, !text.isEmpty else { return nil }
            let start = ms(w["start_time"] ?? w["start"])
            let end   = ms(w["end_time"]   ?? w["end"])
            // 与整句同一条纪律:倒挂的丢掉,不硬凑
            guard end >= start else { return nil }
            return ASRWord(startMs: start, endMs: end, text: text)
        }
    }

    /// 一句的说话人。
    ///
    /// 🔴 **真实形态是字典**:`"speaker": {"id": "speaker_0"}`(2026-08-17 真机抓的)。
    /// 原来只认字符串与整数,于是标签**全部落空** —— 13 行一个都没挂上,
    /// 而分人标签是走文件端点的**全部理由**(判 18:它在长句上 10% 错误率,
    /// 比 Mac 本地 pyannote 的 15% 更好)。
    /// 参考实现 `docs/evidence/p4a/run_asr_file.py::parse_utterances` 早就这么写了。
    ///
    /// 三种形态都认:上游改回扁平串或数字时不会突然又全部落空。
    private static func speaker(of u: [String: Any]) -> String? {
        if let d = u["speaker"] as? [String: Any] {
            return (d["id"] as? String) ?? (d["id"] as? Int).map(String.init)
        }
        return (u["speaker"] as? String)
            ?? (u["speaker"] as? Int).map(String.init)
            ?? (u["speaker_id"] as? String)
            ?? (u["speaker_id"] as? Int).map(String.init)
    }

    // MARK: - 零件

    /// 找分句。要认三种包装,顺序不能反。
    ///
    /// 🔴 **`result` 是数组,不是字典**(2026-08-17 实测 + `docs/evidence/p4a/run_asr_file.py`)。
    /// 真实回复形如 `{"duration":270.14,"result":[{"utterances":[…]}]}` ——
    /// 每块一个元素。原来这里只试了 `result` 作为字典的那一种,
    /// 于是**即使转写成功也解不出来**,一路抛「报文里没有分句」。
    ///
    /// 数组要**全部拼起来**,不能只取第一个:多块的回复会静默少掉后面几块,
    /// 而少掉的部分在下游长得就像「那段没人说话」。
    private static func utterances(in root: [String: Any]) -> [[String: Any]]? {
        let d = (root["data"] as? [String: Any]) ?? root

        for key in utteranceKeys {
            // 顶层
            if let a = d[key] as? [[String: Any]] { return a }
            // result 是数组:每块一个,拼起来
            if let blocks = d["result"] as? [[String: Any]] {
                let all = blocks.flatMap { ($0[key] as? [[String: Any]]) ?? [] }
                if !all.isEmpty { return all }
            }
            // result / data 是字典的老形状,留着 —— 上游改回去也不会突然解不出来
            for wrapper in ["result", "data"] {
                if let r = d[wrapper] as? [String: Any], let a = r[key] as? [[String: Any]] {
                    return a
                }
            }
        }
        // ⚠️ `result` 出现了但里面一条分句都没有(实测的 `[{}]`)——
        // 那是**「转完了,一个字都没有」**,和「报文看不懂」是两回事。
        // 返回空数组让它如实落成 0 行,而不是抛「形状变了」把人引向错误的方向。
        if let blocks = d["result"] as? [[String: Any]], !blocks.isEmpty { return [] }
        return nil
    }

    /// 时间戳可能是毫秒整数、也可能是秒的小数。**按量级判**,不按类型判 ——
    /// JSON 里 `1000` 与 `1000.0` 是同一个数,而 1 秒与 1000 秒差着三个量级。
    private static func ms(_ v: Any?) -> Int {
        switch v {
        case let i as Int:    return i
        case let d as Double: return d < 10_000 && d != d.rounded() ? Int(d * 1000) : Int(d)
        case let s as String: return Int(Double(s) ?? 0)
        default:              return 0
        }
    }
}
