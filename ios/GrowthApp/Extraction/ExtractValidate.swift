import Foundation

/// 抽取产出的 schema 校验 + 三项校验。**`worker/extract.py` 里 `validate()` 的手机侧实现。**
///
/// 契约里最要紧的两条(改之前先回去看技术方案 §4.2):
///
/// · **没有 `who`。**「谁说的」一律由归属层派生,不接受模型输出。三项校验里的
///   「说话人一致」正是拿模型那份和归属层那份对撞 —— 契约里同时存在两份,
///   这项校验就变成自己校验自己了。
/// · **`speaker_hint` 只用于校验、永不落库。** 它是模型看到的簇标签,用来发现
///   「行号存在但挂错行」;校验完必须剥掉,所以 `validate` 返回的条目里没有它。
///
/// ## 失败率为什么和结果绑在一起返回
///
/// 这个仓最贵的事故形态是**静默丢弃** —— 丢了多少、为什么丢,账面上看不见。
/// 这里返回 `(clean, stats)` 二元组,**拿不到结果就拿不到计数,拿到了就必然同时拿到**,
/// 想忽略都没处忽略。
enum ExtractValidate {

    // MARK: - 输入

    /// 校验要用到的转写行。**不是 `transcript_lines` 的全部列**,只是这一层要的那几个。
    struct Line: Equatable {
        let lineID: Int64
        let text: String
        /// 占位行(A6:占位行不可被引用为证据)
        let isGap: Bool
        /// 归属。`nil` = 还没定 → 引用它的条目**挂起**,不丢弃
        let personID: Int64?
        /// 这一场里的簇标签,拿来和模型的 `speaker_hint` 对撞
        let clusterTag: String?
        let startSeconds: Double?
        let endSeconds: Double?

        init(lineID: Int64, text: String, isGap: Bool = false,
             personID: Int64? = nil, clusterTag: String? = nil,
             startSeconds: Double? = nil, endSeconds: Double? = nil) {
            self.lineID = lineID; self.text = text; self.isGap = isGap
            self.personID = personID; self.clusterTag = clusterTag
            self.startSeconds = startSeconds; self.endSeconds = endSeconds
        }
    }

    // MARK: - 失败

    enum Failure: Error, CustomStringConvertible {
        /// 模型输出不合契约。**抛出去,不要当成「这场没抽到内容」。**
        case schema(String)
        /// 输出被截断。§4.2 明列的静默失败模式:必须报错,不得当成空结果。
        case truncated(String)

        var description: String {
            switch self {
            case .schema(let w):    return "抽取产出不合契约:\(w)"
            case .truncated(let w): return "抽取输出被截断:\(w)"
            }
        }
    }

    // MARK: - 账本

    /// 一场的校验账本。丢了多少、为什么丢,必须能看见。
    struct Stats: Equatable {
        var total = 0
        var passed = 0
        var pending = 0
        var discarded = 0
        var discardReasons: [String: Int] = [:]
        var pendingReasons: [String: Int] = [:]
        var normalizerVersion = TextNormalize.version
        var promptVersion = ExtractPrompt.version
        /// 事件(`M5-1`)里标题或摘要为空、被跳过的条数。**跳过而不是整份拒收**:
        /// 整份拒收的话这场已经花钱的抽取会被同一份产物永久挡住(重试拿回的还是它)。
        /// ⚠️ 不进 `asDict()`:那个字典要与 Python `as_dict()` 同形状;这两个数由调用方单独记事件。
        var eventsDropped = 0
        /// 事件的行范围不合法(只有一头 / 首尾颠倒 / 指到本转写以外)而被去掉范围的条数。
        var eventRangesDropped = 0

        /// 被丢弃的占比。**没有可校验条目时是 nil,不是 0** ——
        /// 0 会被读成「一条都没丢,质量很好」,而真相是「没东西可量」。
        var failureRate: Double? { total == 0 ? nil : round4(Double(discarded) / Double(total)) }
        var pendingRate: Double? { total == 0 ? nil : round4(Double(pending) / Double(total)) }

        /// 和 Python 侧 `as_dict()` 同形状 —— 两边的账要能并起来看。
        func asDict() -> [String: Any] {
            [
                "total": total, "passed": passed, "pending": pending, "discarded": discarded,
                "failure_rate": failureRate as Any, "pending_rate": pendingRate as Any,
                "discard_reasons": discardReasons, "pending_reasons": pendingReasons,
                "normalizer_version": normalizerVersion, "prompt_version": promptVersion,
            ]
        }

        private func round4(_ d: Double) -> Double { (d * 10000).rounded() / 10000 }

        /// 把另一块的账并进来(M1-27 分块跑)。
        /// ⚠️ **比率不并** —— 它们是从 total/discarded 现算的(计算属性),
        /// 并完之后自动就是全场的比率。手工去并比率会得到「比率的平均」,那是另一个数。
        mutating func add(_ other: Stats) {
            total += other.total; passed += other.passed
            pending += other.pending; discarded += other.discarded
            for (k, v) in other.discardReasons { discardReasons[k, default: 0] += v }
            for (k, v) in other.pendingReasons { pendingReasons[k, default: 0] += v }
        }
    }

    // MARK: - 契约

    /// 带 line_id + quote、能跑三项校验的四类。
    static let itemKinds = ["key_points", "commitments", "stances", "pendings"]
    /// 六类产出里能被 schema 校验的全部(`topic_keys` 没有 quote,跑不了逐字)。
    static let allKinds = itemKinds + ["topic_keys"]

    private static let requiredFields: [String: [String]] = [
        "key_points":  ["point", "quote", "line_id"],
        "commitments": ["what", "quote", "line_id"],
        "stances":     ["stance", "quote", "line_id"],
        "pendings":    ["issue", "quote", "line_id"],
        "topic_keys":  ["key", "line_ids"],
    ]

    /// 校验完必须剥掉的字段:只用于校验、永不落库。
    private static let stripFields = ["speaker_hint"]

    // MARK: - 解析

    /// 把模型返回的正文解析成字典。
    ///
    /// ⚠️ **解析不了就抛,绝不返回空字典。**「输出被截断」和「这场没内容」在下游
    /// 看起来一模一样,而前者要重试、后者不要。§4.2 把它单列为一种已发生过的
    /// 静默失败模式。
    static func parseModelOutput(_ raw: String) throws -> [String: Any] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw Failure.truncated("模型返回空正文(§4.2:max_tokens 不足时会这样,不是没抽到)")
        }
        // ⚠️ **不剥代码围栏。** prompt 里明写了「不要代码围栏」,单边加宽容
        // 就是两份实现的第一处漂移 —— 要放宽,`worker/extract.py` 必须同时放宽。
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw Failure.truncated("输出不是完整 JSON,极可能被截断:\(text.prefix(200))")
        }
        guard let dict = obj as? [String: Any] else {
            throw Failure.schema("顶层必须是对象")
        }
        return dict
    }

    // MARK: - schema 校验

    /// 只查结构,不查内容真假。**结构不对直接抛,不做兜底填充。**
    static func validateSchema(_ payload: [String: Any]) throws {
        guard let one = payload["one_liner"] else { throw Failure.schema("缺 one_liner") }
        guard one is String else { throw Failure.schema("one_liner 必须是字符串") }

        for kind in allKinds {
            guard let raw = payload[kind] else {
                throw Failure.schema("缺 \(kind)(抽不到就给空数组,不要省略)")
            }
            guard let items = raw as? [Any] else { throw Failure.schema("\(kind) 必须是数组") }
            for (i, any) in items.enumerated() {
                guard let item = any as? [String: Any] else {
                    throw Failure.schema("\(kind)[\(i)] 必须是对象")
                }
                for f in requiredFields[kind] ?? [] where item[f] == nil {
                    throw Failure.schema("\(kind)[\(i)] 缺字段 \(f)")
                }
                if item["who"] != nil {
                    throw Failure.schema(
                        "\(kind)[\(i)] 出现了 who —— 契约里没有这个字段(§4.2),归属只能有一个真相源")
                }
            }
        }
    }

    // MARK: - 三项校验

    enum Verdict: Equatable { case passed, pending(String), discarded(String) }

    /// 三项校验:行号命中 · 文本逐字 · 说话人一致。
    static func check(_ item: [String: Any], line: Line?) -> Verdict {
        // ① 行号命中:存在,且不是占位行(A6:占位行不可被引用为证据)
        guard let line else { return .discarded("行号不存在") }
        if line.isGap { return .discarded("指向占位行") }

        // ② 文本逐字:**只打 quote,不打自由文本**。
        //    自由文本(point / what / stance / issue)本来就允许压缩改写,拿它比对必然全红。
        guard TextNormalize.isVerbatim(quote: item["quote"] as? String ?? "", source: line.text)
        else { return .discarded("quote 非原文子串") }

        // ③ 说话人一致:归属未定则**挂起**(不丢弃),归属到位后由
        //    `ExtractionStore.recomputePending` 自动翻回来
        guard line.personID != nil else { return .pending("归属未定") }

        // speaker_hint 与派生簇标签不一致 → 挂起复核。这补的是「模型挂错行」——
        // 行号存在、引文也确实在那一行里,但那行根本不是它说的。
        if let hint = item["speaker_hint"] as? String, let tag = line.clusterTag, hint != tag {
            return .pending("簇标签与 speaker_hint 不一致")
        }
        return .passed
    }

    // MARK: - 一场

    /// 跑完 schema 校验 + 三项校验,返回 (可落库的产出, 账本)。
    ///
    /// 产出里:丢弃的条目已剔除;挂起的条目**保留**并带 `pending: true`
    /// (§4.2:挂起不丢弃,归属到位后自动出现);`speaker_hint` 一律剥掉。
    static func validate(_ payload: [String: Any],
                         lines: [Line]) throws -> (clean: [String: Any], stats: Stats) {
        try validateSchema(payload)
        var byID: [Int64: Line] = [:]
        for l in lines { byID[l.lineID] = l }

        var clean: [String: Any] = ["one_liner": payload["one_liner"] as? String ?? ""]
        var stats = Stats()

        for kind in itemKinds {
            var kept: [[String: Any]] = []
            for item in (payload[kind] as? [[String: Any]] ?? []) {
                stats.total += 1
                let line = lineID(of: item).flatMap { byID[$0] }
                switch check(item, line: line) {
                case .discarded(let why):
                    stats.discarded += 1
                    stats.discardReasons[why, default: 0] += 1
                    continue
                case .pending(let why):
                    stats.pending += 1
                    stats.pendingReasons[why, default: 0] += 1
                    var out = item.filter { !stripFields.contains($0.key) }
                    out["pending"] = true
                    kept.append(out)
                case .passed:
                    stats.passed += 1
                    kept.append(item.filter { !stripFields.contains($0.key) })
                }
            }
            clean[kind] = kept
        }

        // topic_keys 没有 quote,跑不了逐字校验;**只留行号确实存在的那些** ——
        // 留下不存在的行号就是新造一批悬空引用,而这个仓最著名的事故就是悬空归属。
        clean["topic_keys"] = (payload["topic_keys"] as? [[String: Any]] ?? []).map { t -> [String: Any] in
            var out = t
            out["line_ids"] = (t["line_ids"] as? [Int] ?? []).filter { byID[Int64($0)] != nil }
            return out
        }
        // 事件(`M5-1`,两阶段才有)。🔴 **必须在这里透传** —— `clean` 是新建的字典,
        // 不写这一段的话 events 在落库之前就没了,而详情页会把每一场都说成「旧版整理的」
        //(2026-10-12 对抗审查抓到;那时 SummaryEventsTests 全绿,因为它绕过了 validate)。
        // 坏事件只跳这一条、坏范围只去掉范围,都计数,不整份拒收。
        if let events = payload["events"] as? [[String: Any]] {
            var kept: [[String: Any]] = []
            for ev in events {
                let title = (ev["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let summary = (ev["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !title.isEmpty, !summary.isEmpty else { stats.eventsDropped += 1; continue }
                var out: [String: Any] = ["title": title, "summary": summary]
                if let id = ev["event_id"] { out["event_id"] = id }
                if let prior = ev["continuation_id"] { out["continuation_id"] = prior }
                let a = (ev["line_from"] as? Int).map(Int64.init)
                let b = (ev["line_to"] as? Int).map(Int64.init)
                if let a, let b, a <= b, byID[a] != nil, byID[b] != nil {
                    out["line_from"] = Int(a); out["line_to"] = Int(b)
                } else if ev["line_from"] != nil || ev["line_to"] != nil {
                    stats.eventRangesDropped += 1
                }
                kept.append(out)
            }
            clean["events"] = kept
        }
        clean.merge(try ActionExtraction.validate(payload, lines: lines)) { _, new in new }
        return (clean, stats)
    }

    /// JSON 里的行号可能被读成 `Int` 也可能被读成 `NSNumber`/`Int64`,统一收口。
    private static func lineID(of item: [String: Any]) -> Int64? {
        switch item["line_id"] {
        case let i as Int:   return Int64(i)
        case let i as Int64: return i
        case let n as NSNumber: return n.int64Value
        default: return nil
        }
    }
}
