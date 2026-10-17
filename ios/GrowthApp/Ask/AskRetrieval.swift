import Foundation
import GRDB

// 自由提问的第一层检索(PRD §4.7.3「检索分两层」的**手机本地**那一层)。
//
// ## 为什么不能直接把问题丢给 `TranscriptSearch.search`
//
// `search()` 是**字面短语**检索:`wordQuery` 把输入切词后拼成一个短语字面量再加 `*`,
// 要求这些词**相邻**出现。这对「事列表搜索」是对的(用户输什么就搜什么),
// 但对一句自然语言提问必然搜空 —— 「他上次到底同意了没有」不会有哪一行原文
// 恰好是这十个字连着。
//
// ## 所以这一层做的事只有一件:把问题拆成几个查询,再把结果并起来
//
// **它不新写检索路径**,每个查询仍然走 `TranscriptSearch.search` ——
// 另写一条 SQL 就是第二份实现,而两份检索迟早给出不一样的结果
// (仓里刚记下一条同形态的教训:「在旁边另写一份对的,原址一直没动」)。
enum AskRetrieval {

    /// 喂给模型的行数上限。§4.7.3 定:「单轮只喂检索到的 **top-N** 材料,不喂全库」,
    /// 而「对话是成本模型里的最大变量」(§6.2.3)。
    ///
    /// 取 40 的算术:一行转写中位约 30 字 ≈ 20 token,40 行 ≈ 800 token 输入。
    /// 按 flash 的输入单价这是**不到一分钱**的量级,而再多也提不了准 ——
    /// 字面检索命中到第 40 条时相关性已经很薄。
    static let topN = 40
    static let characterBudget = 6000
    static let lineCharacterLimit = 1000

    static func bounded(_ input: [Material]) -> [Material] {
        var remaining = characterBudget
        var seen = Set<Int64>()
        var output: [Material] = []
        for m in input where remaining > 0 && output.count < topN {
            guard seen.insert(m.hit.lineID).inserted else { continue }
            let text = String(m.hit.text.prefix(min(remaining, lineCharacterLimit)))
            guard !text.isEmpty else { continue }
            remaining -= text.count
            let hit = TranscriptSearch.Hit(lineID: m.hit.lineID, sessionID: m.hit.sessionID,
                sessionStartedAt: m.hit.sessionStartedAt, atMillis: m.hit.atMillis,
                text: text, snippet: text, foldedCount: m.hit.foldedCount)
            output.append(Material(hit: hit, matchedTerms: m.matchedTerms, inDateRange: m.inDateRange))
        }
        return output
    }

    /// 参与检索的查询词上限。每个词一次 `search()`(实测 <100ms),
    /// 而首字 ≤3 秒是硬要求 —— 6 次 ≈ 600ms,留得出余量给云端那一跳。
    static let maxTerms = 6

    /// 短于这个长度的词不参与检索。
    ///
    /// ⚠️ **这是一条刻意不做停用词表的决定。** 「的 / 了 / 吗 / 是 / 他」这些
    /// 全是单字,而中文的实词绝大多数 ≥2 字 —— 按长度筛掉它们,效果和停用词表
    /// 差不多,却不需要维护一张会过期、会漏、会因人而异的表。
    /// 如果将来实测发现漏掉了重要的单字词(比如人名的姓),再回来改这一条,
    /// **但那时要有实测,不是凭感觉加表**。
    static let minTermLength = 2

    /// ⚠️ **已知边界:两字查询词可能什么都搜不到,而且不报错。**
    ///
    /// 实测踩到的:问「主路径」时,切词给出「主」+「路径」,单字被上面那条规则丢掉,
    /// 只剩「路径」——而两条腿都够不着它:
    /// · **词索引那条腿是前缀匹配**,`"路径"*` 匹不上索引里的整词「主路径」;
    /// · **trigram 那条腿要求 ≥3 字**(`TranscriptSearch.trigramMinimumLength`),两字进不去。
    ///
    /// 后果是「搜不到」而不是「报错」,它长得和「库里真的没有」一模一样。
    /// 现在**不修**,因为修法有三种(整词也存前缀 / trigram 降到 2 / 查询词再做二次切分),
    /// 每一种都动到 `TranscriptSearch` 这个多消费方的共享件,该由实测来选 ——
    /// 而实测要等真机上问几十个真问题之后才有意义。**先写在这里,别让它变成一个谜。**

    /// 一条命中,外加它是被几个查询词命中的。
    struct Material: Equatable {
        let hit: TranscriptSearch.Hit
        /// 命中它的查询词数。一行同时含「首页」「优先级」
        /// 显然比只含「首页」的更可能是用户要找的那条。
        let matchedTerms: Int
        /// 这条命中所在的场次,落在问句点名的那段日子里吗(`M2-检2` §1.2)。
        /// 问句里没有相对时间词时恒为 false。
        var inDateRange: Bool = false
    }

    /// 问题 → 喂给模型的材料。
    ///
    /// **空结果是一个正常答案**,不是失败:它的意思是「库里没有相关记录」,
    /// 而那时该回「这个我没有记录」(P5),不是编一个。所以这里不抛。
    static func materials(for question: String, limit: Int = topN,
                          now: Date = Date(), bundle: Bundle = .main,
                          in db: Database) throws -> [Material] {
        let terms = queryTerms(question)
        guard !terms.isEmpty else { return [] }

        // 问句点名的那段日子(「上周谁提到交付」)。**只用来重排,不用来过滤** ——
        // 见下面排序处那段。
        let window = RelativeDates.resolve(question, today: now, bundle: bundle)

        // line_id → (命中它的词数, 命中本身)
        var merged: [Int64: (count: Int, hit: TranscriptSearch.Hit)] = [:]
        for term in terms {
            // 单个词搜不出来是常态(用户随口提到的词库里没有),不该让整次提问失败
            guard let hits = try? TranscriptSearch.search(term, limit: limit, in: db) else { continue }
            for h in hits {
                if let old = merged[h.lineID] {
                    merged[h.lineID] = (old.count + 1, old.hit)
                } else {
                    merged[h.lineID] = (1, h)
                }
            }
        }

        // 排序三级:**在不在问句点名的那段日子里** → 命中了几个词 → 时间新的在前。
        // 末一级是 `TranscriptSearch` 自己的理由:「最近一次是什么时候说的」
        // 恰恰是这个产品里最常见的问法。
        //
        // 🔴 日期这一级是**重排,不是过滤**。理由是「上周」这个词在问句里不一定是
        // 时间范围 —— 「上周那版方案后来怎么样了」问的不是上周发生了什么。
        // 过滤会把答案直接删掉而界面显示「没找到」,那是**骗人**;重排最坏只是
        // 把顺序排得不那么好,而正确答案仍然在材料里。
        // (同 §1.1 的口径:只重排不改召回。)
        let scored = merged.values.map { entry -> (Material, String) in
            let day = RelativeDates.day(ofSessionStartedAt: entry.hit.sessionStartedAt)
            let inRange = window.map { RelativeDates.contains($0, day: day) } ?? false
            return (Material(hit: entry.hit, matchedTerms: entry.count, inDateRange: inRange),
                    entry.hit.sessionStartedAt)
        }
        return scored
            .sorted { a, b in
                if a.0.inDateRange != b.0.inDateRange { return a.0.inDateRange }
                if a.0.matchedTerms != b.0.matchedTerms { return a.0.matchedTerms > b.0.matchedTerms }
                return a.1 > b.1
            }
            .prefix(limit)
            .map(\.0)
    }

    /// 把一句问题切成用来检索的词。
    ///
    /// 长的词排前面:词越长越具体,而 `maxTerms` 会砍掉尾巴 ——
    /// 砍掉「今天」比砍掉「信息优先级」代价小得多。
    static func queryTerms(_ question: String) -> [String] {
        var seen = Set<String>()
        return ChineseTokenizer.tokens(question)
            .filter { $0.count >= minTermLength && seen.insert($0).inserted }
            .sorted { $0.count > $1.count }
            .prefix(maxTerms)
            .map { $0 }
    }
}
