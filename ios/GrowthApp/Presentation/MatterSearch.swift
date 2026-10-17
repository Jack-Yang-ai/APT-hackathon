import Foundation
import GRDB

/// 事内检索(PRD §4.3.2 搜索规则,M2-F3)。
///
/// ## 四个范围,一趟查完
///
/// 规格原话:「范围含**标题、悬点、脉络、转写**」。前三个在 M2 的新表里,
/// 第四个是冻结层 —— **转写那一路直接复用 `TranscriptSearch`,不另写一套**。
///
/// 🔴 另写一套的后果不是多写代码,是**两套检索的口径会分家**:
/// `TranscriptSearch` 那边有两条腿(trigram + 词索引)、有折叠、有多取再折的补偿,
/// 而这里若只写个 `LIKE %x%`,同一个词在「事内搜」与「全局搜」会给出不同结果,
/// 而用户无从知道该信哪个。
///
/// ## 「没找到」与「搜不了」是两件事
///
/// PRD 说无结果时显示「没找到,试试问问」。而**查询本身失败**(库读不出来)
/// 与「确实没有」在界面上一模一样 —— 所以这里把后者做成 `throws`,
/// 由界面分开画(同一形状 2026-08-18 已在 `MattersView` 上栽过一次)。
enum MatterSearch {

    /// 一条命中。`kind` 说清它是从哪个范围来的 —— 界面要分组显示,
    /// 而「标题命中」与「某句原话命中」对用户的意义完全不同。
    struct Hit: Equatable, Identifiable {
        enum Kind: String { case title = "事", question = "悬点", timeline = "脉络", line = "原话" }
        var id: String { "\(kind.rawValue)#\(rowID)" }
        let kind: Kind
        let rowID: Int64
        /// 归属的那件事。`nil` = 转写命中,而那一行还没被任何一件事收进脉络。
        let matterID: Int64?
        let text: String
    }

    /// 转写那一路一次最多取几条。**事内搜的重点是事**,原话是补充 ——
    /// 不设上限的话,一个常见词会让几百条原话把标题与悬点的命中挤出屏幕。
    static let transcriptLimit = 20

    /// 搜。`matterID` 为 nil = 跨全部事搜(事列表那个常驻搜索框)。
    ///
    /// - Throws: 库读不出来时抛 —— **不吞成空结果**,「没找到」是结论、「搜不了」不是。
    static func search(_ raw: String, matterID: Int64? = nil,
                       in db: Database) throws -> [Hit] {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let like = "%\(q)%"
        var out: [Hit] = []

        // ① 标题 ② 悬点 ③ 脉络 —— 三张新表,`LIKE` 够用:
        // 它们是**短文本**(标题 ≤30 字、悬点 ≤40 字),没有分词的必要,
        // 而且量级是几十到几百条,不是二十万行的逐字稿。
        func scoped(_ sql: String) -> String {
            matterID == nil ? sql : sql + " AND m.id = \(matterID!)"
        }
        for row in try Row.fetchAll(db, sql: scoped("""
            SELECT m.id, m.title FROM matters m WHERE m.title LIKE ?
            """), arguments: [like]) {
            out.append(Hit(kind: .title, rowID: row["id"], matterID: row["id"],
                           text: row["title"]))
        }
        for row in try Row.fetchAll(db, sql: scoped("""
            SELECT q.id, q.question, m.id AS mid FROM matter_open_questions q
              JOIN matters m ON m.id = q.matter_id
             WHERE q.question LIKE ?
            """), arguments: [like]) {
            out.append(Hit(kind: .question, rowID: row["id"], matterID: row["mid"],
                           text: row["question"]))
        }
        for row in try Row.fetchAll(db, sql: scoped("""
            SELECT t.id, t.summary, m.id AS mid FROM matter_timeline t
              JOIN matters m ON m.id = t.matter_id
             WHERE t.summary LIKE ?
            """), arguments: [like]) {
            out.append(Hit(kind: .timeline, rowID: row["id"], matterID: row["mid"],
                           text: row["summary"]))
        }

        // ④ 转写 —— **复用 `TranscriptSearch`,不另写一套**。
        // 它带着两条腿(trigram + 词索引)、折叠、多取再折的补偿;
        // 这里若只写个 LIKE,同一个词在「事内搜」与「全局搜」会给出不同结果。
        let lines = try TranscriptSearch.search(q, limit: transcriptLimit, in: db)
        for h in lines {
            // 这一行被哪件事收进脉络了?没有就是 nil —— **不猜**。
            let owner = try Int64.fetchOne(db, sql: """
                SELECT matter_id FROM matter_timeline WHERE line_id = ? LIMIT 1
                """, arguments: [h.lineID])
            if let m = matterID, owner != m { continue }   // 事内搜:只留这件事的
            out.append(Hit(kind: .line, rowID: h.lineID, matterID: owner, text: h.text))
        }
        return out
    }
}

/// 「没找到,试试问问」那个一键转交(PRD §4.3.2)。
///
/// 🔴 **依赖 `M2-B6`(问问 L2 语义腿),没到 ⇒ 必抛,不 no-op。**
/// no-op 的形态是:用户点了「试试问问」,界面收起搜索框、什么也没发生 ——
/// 而他以为问题已经被送过去了。
protocol SearchHandoff {
    func handOffToAsk(query: String) throws
}

struct SearchHandoffStub: SearchHandoff {
    func handOffToAsk(query: String) throws {
        throw MatterActionFailure.notImplementedYet(action: "试试问问",
                                                    blockedBy: "问问的语义检索",
                                                    task: "M2-B6")
    }
}
