import Foundation
import GRDB

/// 进展归属 V1 的**调用与判定**(M2-B3):拼 prompt → 调模型 → 解析 → 三项校验 → 判档。
///
/// **这一层不写库。** 写路径单独一层 —— `matter_timeline` 今天**一个写方都没有**
/// (`AssignSpeaker.swift:139` 记着这件事),所以 M2-B3 会是它的第一个写方,
/// 那是个要单独想清楚的决定(铁律 3 的形状:该有唯一入口),不混在这一层里做。
///
/// ## 规格出处
///
/// 技术方案 §4.5.2(输出 JSON)、§4.5.3(三项校验,复用 `ExtractValidate`)、
/// §4.5.4(三档);PRD §4.3.6。
enum ProgressAttributionRunner {
    /// 这条腿在任务表里的 kind。
    ///
    /// 🔴 **它存在的唯一理由是让「谁花钱」有一个能被机器检查的出处**(`M2-审7`)。
    /// 这个 `run` 收 `call:` —— 先花钱、再解析,解析一抛就等于原价再买一次
    /// ⇒ 它必须落在 `TaskQueue.paidRetryKinds` 里。漏了不会有任何东西报错,
    /// 所以有一道源码对撞盯着这一对:`eval/checks/test_paid_retry_kinds.py`。
    /// ⚠️ 引用 `ProcessingOrchestrator.Kind`,**不另写字面量** —— 写死就是第二个出处。
    static let taskKind = ProcessingOrchestrator.Kind.progress


    /// 模型指认出来的一条进展(技术方案 §4.5.2 的形状)。
    struct Progress: Equatable {
        let matterID: Int64
        /// 命中的悬点。`nil` = 认为相关但指不出具体悬点 ⇒ 按 §4.5.4 走中档。
        let questionID: Int64?
        let lineID: Int64
        let quote: String
        let kind: String
        let summary: String
    }

    /// 一条进展的处置。
    ///
    /// 🔴 **`held` 不是第四档,是「还判不了」。**
    /// 三档是 PRD 的**产品语义**;而 `ExtractValidate` 的 `.pending`
    /// (归属未定 / 簇标签与 `speaker_hint` 对不上)是**实现状态** ——
    /// 它既不该静默入库(校验没全过),**也不该弹确认卡去打扰用户**:
    /// 归属到位之后它自己就判得了了,现在问等于问一个马上会自己有答案的问题。
    /// 抽取那边同一个形状的处置就是「挂起不丢弃,归属到位后自动翻回来」
    /// (`ExtractionStore.recomputePending`),这里照同一条走。
    /// ⚠️ 混进三档的后果是**判卷失真**:`M2-L4` 判的是静默档判准率,
    /// 而一条「还没判」的东西被算进任何一档,那个数就不是它自称的意思了。
    enum Disposition: Equatable {
        case tiered(ProgressTiering.Verdict)
        case held(String)
    }

    struct Judged: Equatable {
        let progress: Progress
        let disposition: Disposition
    }

    struct Outcome: Equatable {
        let judged: [Judged]
        /// 🔴 **校验失败要计数并可见,不静默丢**(§3.2 纪律,本条验收点名)。
        let validationFailures: Int
        /// 失败的理由,逐条留着 —— 只有一个数的话,排查时无从下手。
        let failureReasons: [String]
        /// 挂起的条数(归属未定等,会自己好)。
        let heldCount: Int
        /// 预筛掉几件、超预算砍掉几件 —— 见 `ProgressAttributionInput.Plan`。
        let skippedMatters: Int
        let droppedForBudget: [Int64]
        let estimatedInputTokens: Int
    }

    enum Failure: Error, CustomStringConvertible {
        case badJSON(String)
        var description: String {
            switch self {
            case .badJSON(let s): return "模型输出不是约定的 JSON:\(s)"
            }
        }
    }

    // MARK: - prompt

    /// 拼 prompt。**要求模型指认,不问「相关吗」**(技术方案 §4.5.2:
    /// 可校验字段越多越难糊弄)。
    static func buildPrompt(_ plan: ProgressAttributionInput.Plan) -> String {
        var out = """
        你在把一场录音的新材料与若干件"事"比对,找出这一场推进了哪些事。

        **不要回答"相关吗"。** 每条产出必须指认:命中哪件事、哪个悬点、
        引用哪一行(line_id)、以及那一行里的**逐字原话**(quote)。
        指不出悬点时 question_id 填 null,不要猜一个。
        quote 必须是那一行文本的**逐字子串**,一个字都不能改。

        只输出 JSON:{"items":[{"matter_id":1,"question_id":2,"line_id":3,
        "quote":"…","kind":"悬点关闭|立场变化|前提变化|承诺兑现","summary":"…"}]}

        ## 这一场的新材料

        """
        out += plan.session.items
            .map { "line_id=\($0.lineID) [\($0.kind)] \($0.text)\n  原话:\($0.quote)" }
            .joined(separator: "\n")
        out += "\n\n## 待比对的事\n\n"
        for m in plan.compare {
            out += "matter_id=\(m.matterID) 《\(m.title)》\n"
            out += m.openQuestions.map { "  未关悬点 question_id=\($0.id):\($0.text)" }
                .joined(separator: "\n")
            if !m.recentTimeline.isEmpty {
                out += "\n  最近脉络:" + m.recentTimeline.joined(separator: " / ")
            }
            out += "\n\n"
        }
        return out
    }

    // MARK: - 解析

    static func parse(_ raw: String) throws -> [Progress] {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["items"] as? [[String: Any]]
        else { throw Failure.badJSON(String(raw.prefix(200))) }
        return items.compactMap { it in
            guard let mid = (it["matter_id"] as? NSNumber)?.int64Value,
                  let lid = (it["line_id"] as? NSNumber)?.int64Value
            else { return nil }
            return Progress(matterID: mid,
                            questionID: (it["question_id"] as? NSNumber)?.int64Value,
                            lineID: lid,
                            quote: it["quote"] as? String ?? "",
                            kind: it["kind"] as? String ?? "",
                            summary: it["summary"] as? String ?? "")
        }
    }

    // MARK: - 判

    /// 逐条过三项校验再判档。
    ///
    /// - Parameter comparedMatters: 真的进了模型的事。**模型指到别的事上要丢弃** ——
    ///   它可能指一件预筛掉的、甚至一件不存在的事,而那条进展没有任何依据。
    static func judge(_ items: [Progress], lines: [Int64: ExtractValidate.Line],
                      comparedMatters: Set<Int64>) -> (judged: [Judged], failures: [String]) {
        var judged: [Judged] = []
        var failures: [String] = []
        for p in items {
            guard comparedMatters.contains(p.matterID) else {
                failures.append("指到了没进模型的事 matter_id=\(p.matterID)")
                continue
            }
            let payload: [String: Any] = ["line_id": p.lineID, "quote": p.quote]
            switch ExtractValidate.check(payload, line: lines[p.lineID]) {
            case .passed:
                judged.append(Judged(progress: p, disposition: .tiered(
                    ProgressTiering.tier(lexicalHit: true, validated: true,
                                         questionID: p.questionID))))
            case .pending(let why):
                judged.append(Judged(progress: p, disposition: .held(why)))
            case .discarded(let why):
                failures.append("matter_id=\(p.matterID) line_id=\(p.lineID):\(why)")
                judged.append(Judged(progress: p, disposition: .tiered(
                    ProgressTiering.tier(lexicalHit: true, validated: false,
                                         questionID: p.questionID))))
            }
        }
        return (judged, failures)
    }

    // MARK: - 跑一场

    /// - Parameter call: 注入的模型调用。生产传云代理那条;测试传假货(不联网不花钱)。
    static func run(sessionID: Int64, call: (String) async throws -> String,
                    in writer: some DatabaseWriter) async throws -> Outcome {
        let plan = try await writer.read {
            try ProgressAttributionInput.build(sessionID: sessionID, in: $0)
        }
        guard !plan.compare.isEmpty else {
            return Outcome(judged: [], validationFailures: 0, failureReasons: [],
                           heldCount: 0, skippedMatters: plan.skipped.count,
                           droppedForBudget: plan.droppedForBudget,
                           estimatedInputTokens: plan.estimatedInputTokens)
        }
        let raw = try await call(buildPrompt(plan))
        let items = try parse(raw)
        let lines = try await writer.read { db in try validationLines(sessionID: sessionID, in: db) }
        let (judged, failures) = judge(items, lines: lines,
                                       comparedMatters: Set(plan.compare.map(\.matterID)))
        return Outcome(judged: judged, validationFailures: failures.count,
                       failureReasons: failures,
                       heldCount: judged.filter { if case .held = $0.disposition { return true }
                                                  else { return false } }.count,
                       skippedMatters: plan.skipped.count,
                       droppedForBudget: plan.droppedForBudget,
                       estimatedInputTokens: plan.estimatedInputTokens)
    }

    /// 校验要用的行。**`LEFT JOIN`,不是 `JOIN`** —— 与 `ExtractionRunner.lines` 同一条理由:
    /// 没有归属行的转写行必须出现在结果里(它们只是 `personID` 为空 → 引用它们的条目挂起),
    /// 用内连接会让这些行整个消失,而"查不到行号"与"这一行没归属"处置完全不同。
    ///
    /// 🔴 **只读当前生效的那一版**(`M2-审8`)。与 `sessionContext` 同一条理由,
    /// 而这里漏掉更毒:校验行是「这个 `line_id` 存不存在」的判据 ——
    /// 带上 v1 就等于**承认旧版本的行号仍然有效**,于是模型指着一句
    /// 已经被重整改掉的话,三项校验照样放行。
    static func validationLines(sessionID: Int64, in db: Database) throws
        -> [Int64: ExtractValidate.Line] {
        let active = try SessionDetailProjection.activeTranscripts(db, sessionID: sessionID)
        // 一版都没有 ⇒ 没有合法行号。**返回空表,不退化成「全都算数」** ——
        // 空表会让每一条引用都校验失败并被记下来,而退化会让它们静默通过。
        guard !active.isEmpty else { return [:] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT l.line_id, l.text, l.is_gap, ls.person_id, ls.cluster_tag
              FROM transcript_lines l
              LEFT JOIN line_speakers ls ON ls.line_id = l.line_id
             WHERE l.transcript_id IN (\(ProgressAttributionInput.placeholders(active.count)))
            """, arguments: StatementArguments(active.map { $0 as (any DatabaseValueConvertible) }))
        var out: [Int64: ExtractValidate.Line] = [:]
        for r in rows {
            let id: Int64 = r["line_id"]
            out[id] = ExtractValidate.Line(lineID: id, text: r["text"],
                                           isGap: (r["is_gap"] as Int? ?? 0) == 1,
                                           personID: r["person_id"],
                                           clusterTag: r["cluster_tag"])
        }
        return out
    }
}
