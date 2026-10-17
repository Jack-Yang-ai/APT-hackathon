import Foundation
import CoreFoundation

/// 独立个人行动产物，不改变 v1 纪要的校验／归属口径。
enum ActionExtraction {
    static let protocolVersion = "personal-actions/v1"
    static let kinds: Set<String> = ["accepted", "request", "follow_up"]
    struct TerminalFailure: Error { let message: String }

    static func validate(_ payload: [String: Any], lines: [ExtractValidate.Line]) throws -> [String: Any] {
        if payload["terminal"] as? Bool == true { throw TerminalFailure(message: "个人行动识别失败，请重新识别这场录音。") }
        if payload["action_protocol"] == nil && payload["personal_actions"] == nil { return [:] }
        guard payload["action_protocol"] as? String == protocolVersion,
              let items = payload["personal_actions"] as? [[String: Any]] else {
            throw ExtractValidate.Failure.schema("个人行动协议或数组缺失")
        }
        let byID = Dictionary(lines.map { ($0.lineID, $0) }, uniquingKeysWith: { first, _ in first })
        var clean: [[String: Any]] = []
        var seen = Set<String>()
        for item in items {
            guard let kind = item["kind"] as? String, kinds.contains(kind),
                  let title = item["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let id = integer(item["line_id"]), let line = byID[id],
                  let quote = item["quote"] as? String,
                  let evidence = item["evidence"] as? [[String: Any]], !evidence.isEmpty else {
                throw ExtractValidate.Failure.schema("个人行动缺类别、标题、责任行或上下文证据")
            }
            if ["who", "person_id", "owner"].contains(where: { item[$0] != nil }) {
                throw ExtractValidate.Failure.schema("个人行动归属只能来自原话归属层")
            }
            guard TextNormalize.isVerbatim(quote: quote, source: line.text), evidence.contains(where: { integer($0["line_id"]) == id }) else {
                throw ExtractValidate.Failure.schema("个人行动证据缺责任发言")
            }
            for e in evidence {
                guard let eid = integer(e["line_id"]), let source = byID[eid], !source.isGap,
                      let text = e["quote"] as? String, TextNormalize.isVerbatim(quote: text, source: source.text) else {
                    throw ExtractValidate.Failure.schema("个人行动证据不存在或非原文")
                }
            }
            for field in ["condition_text", "deadline_text", "collaborators_text"] where !(item[field] is String) {
                throw ExtractValidate.Failure.schema("个人行动缺 \(field)")
            }
            if let hint = item["speaker_hint"] as? String, let tag = line.clusterTag, hint != tag {
                throw ExtractValidate.Failure.schema("个人行动责任行与簇标签不一致")
            }
            let key = "\(id):\(TextNormalize.normalize(title))"
            guard seen.insert(key).inserted else { throw ExtractValidate.Failure.schema("重复的个人行动") }
            var out = item.filter { !["speaker_hint", "pending"].contains($0.key) }
            out["pending"] = line.personID == nil
            clean.append(out)
        }
        return ["action_protocol": protocolVersion, "personal_actions": clean]
    }

    static func integer(_ value: Any?) -> Int64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n == NSNumber(value: n.int64Value) else { return nil }
        return n.int64Value
    }
}

private let actionPrompt = """

个人行动（独立于纪要的 commitments / pendings）：
另输出 "action_protocol": "personal-actions/v1" 和 "personal_actions": []。
personal_actions 每条结构：
{"kind":"accepted","title":"把方案发给对方","line_id":1,"quote":"我明天发方案",
 "evidence":[{"line_id":1,"quote":"我明天发方案"}],
 "condition_text":"","deadline_text":"明天","collaborators_text":"对方"}
没有期限的个人安排同样是行动，例如：
{"kind":"accepted","title":"预约复诊","line_id":2,"quote":"我得预约复诊，这件事还没安排",
 "evidence":[{"line_id":2,"quote":"我得预约复诊，这件事还没安排"}],
 "condition_text":"","deadline_text":"","collaborators_text":""}

准入逐条判断，不用纪要类别代替判断：
1. 只提尚未完成、需要后续具体动作的事情。没有期限也可以，不补造条件、期限或对象。
   “我得预约复诊，还没安排”已表达具体个人意图，属于 accepted；不需要再等日期或对谁承诺。
2. accepted：发言者自己明确承诺或决定要做，包括“我要／我得／我需要”处理一件具体未办的事。条件承诺保留原条件。
   request：向发言者提出的具体请求，发言者回应但还未接下。标题写“确认是否……”，不能改成已承诺。
   对方请求分享／交付，回应“我先看看时间，还没决定”必须保留为 request，不因未接下而漏掉。
   follow_up：发言者已有明确目标，别人的进展阻塞该目标，尚未说自己会跟进；写成建议找谁对齐什么。
   已有目标被具体依赖阻塞、还没承诺自己跟进时，标题落到“找谁对齐哪项依赖”，kind 为 follow_up。
   不要只重复目标并写为 accepted。例如“这周要提交设计，但图稿在同事那里，没收到无法定稿”，
   应建议“找同事确认图稿交付”，不能用“提交设计”掩盖眼下需要对齐的依赖。
   若已说“我得找他对齐交付时间”，是明确的本人动作，应为 accepted；不能降成 Agent 建议。
3. line_id 必须指向承担／考虑动作的人自己的发言，quote 逐字引用该行。
   不输出 who 或 person_id，不猜本人身份：客户端按该行的真实归属筛出用户自己的事情。
   请求没有接收者发言、依赖没有发言者自己的目标依据时，不猜负责人。
4. 必须结合前后文判断谁做、为谁做、现在是否仍需做。
   “要不要给你加水？”→“行”是接受对方服务，不是答应自己给对方加水，且当场服务不构成后续待办。
   “你下周发一下方案？”→“行，我来发”才是回应者接下未来动作。
5. 信息不知道、随口疑问、愿望、假设、引用／转述他人、媒体播报、过去经历、当场已经处理的事不提。
   询问售价后回答不知道，没有接下查价任务，就不提“确认售价”。回忆过去收到邀请不提“是否接受邀请”。
   后文已完成、拒绝、取消或改变决定时，按最终状态排除旧动作。
6. evidence 必须包含本条的 line_id，并列出判断责任、条件和最终状态所依赖的相关原话行；每行 quote 逐字照抄。
   简短回应必须附带其回应的请求以及必要后文，不能只用“行”证明承担责任。
7. 输出前逐个检查每段的具体个人安排，不固定输出条数；“尚未安排”表示还未完成，不能因此丢掉。
   无期限、无协作人、生活或健康安排都不构成排除理由。逐段检查后，一条都不符合时 personal_actions 给空数组。
   不要为了凑行动而把悬点或别人的事项放进去。

"""

extension ActionExtraction { static var prompt: String { actionPrompt } }
