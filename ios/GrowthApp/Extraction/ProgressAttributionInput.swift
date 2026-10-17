import Foundation
import GRDB

/// 进展归属 V1 的**输入层**(M2-B3):把一场的新材料与当前活跃的事裁成一份比对计划。
///
/// 判决在 `ProgressTiering`(不碰 IO),写库在写路径那一侧。这里只做三件事:
/// **读、裁、预筛**。
///
/// ## 规格出处
///
/// 技术方案 §4.5.1(输入裁剪,照刀五把参数写死)、PRD §4.3.6(四类信号)。
enum ProgressAttributionInput {

    /// 一件事进模型的那份材料。
    struct MatterContext: Equatable {
        let matterID: Int64
        let title: String
        /// **未关**悬点(`closed_at IS NULL`)。已关的不进 —— 它们已经不是未决点了。
        let openQuestions: [(id: Int64, text: String)]
        /// 最近 `timelineWindow` 条脉络。
        let recentTimeline: [String]
        /// 这件事的参与人(用于 PRD §4.3.6 信号②)。
        let people: Set<Int64>

        static func == (a: Self, b: Self) -> Bool {
            a.matterID == b.matterID && a.title == b.title
                && a.openQuestions.map(\.id) == b.openQuestions.map(\.id)
                && a.recentTimeline == b.recentTimeline && a.people == b.people
        }
    }

    /// 这一场进模型的那份材料。
    ///
    /// 🔴 **整份逐字稿不进** —— 它在抽取那一步已经烧过一次,再塞一遍是重复付费
    /// (技术方案 §4.5.1 原话)。进的是抽取产出(表态/承诺/悬点)与它们各自的 `quote`。
    struct SessionContext: Equatable {
        let sessionID: Int64
        struct Item: Equatable {
            let lineID: Int64
            /// `表态` / `承诺` / `悬点`
            let kind: String
            let text: String
            let quote: String
        }
        let items: [Item]
        /// 本场说话人(信号②的另一半)。
        let speakers: Set<Int64>
    }

    /// 被预筛掉的事 —— **带着分数**,不是只留个数。
    ///
    /// 🔴 阈值现在是**未校准的默认值**(`ProgressTiering` 里写明了)。
    /// 校准要跑准召曲线,而曲线要的正是「每件事当时得了多少分」。
    /// 只记「筛掉了 3 件」的话,那份数据永远补不回来 —— 要重跑才有。
    struct Skipped: Equatable {
        let matterID: Int64
        let lexical: Double
        let people: Double
    }

    struct Plan: Equatable {
        let session: SessionContext
        /// 进模型的。
        let compare: [MatterContext]
        /// 预筛掉的(¥0 就排除了)。
        let skipped: [Skipped]
        /// **超 token 上限被砍掉的**。
        /// 🔴 不记的话「这一场没有产生进展」与「这一场有 8 件事没被比对」
        /// 长得一模一样(技术方案 §4.5.1 原话)。
        let droppedForBudget: [Int64]
        /// 估算的输入 token(见 `estimatedTokens` 对精度的说明)。
        let estimatedInputTokens: Int
    }

    // MARK: - 写死的参数(照刀五)

    /// 每件事带最近几条脉络(技术方案 §4.5.1)。
    static let timelineWindow = 10

    /// 单场比对总输入上限(技术方案 §4.5.1「硬上限 ≤2 万 token」)。
    static let inputTokenBudget = 20_000

    /// 超上限时只比最相关的几件(同上)。
    static let degradedCompareCount = 5

    /// 估算 token 数。
    ///
    /// ⚠️ **这是估算,不是真实分词。** 按「1 个字符 ≈ 1 token」算 ——
    /// 中文实际约 1 token 覆盖 1–1.5 个字,英文约 4 个字符一个 token,
    /// ⇒ 这个估法**系统性偏高**。
    ///
    /// 🔴 **偏高是刻意选的方向**:它守的是一条**预算上限**,
    /// 偏高只会让我们比正常更早降级(少比几件事,而且会记日志);
    /// 偏低则会真的超预算,而超预算的表现是**上游截断** ——
    /// 那正是 `M1-27` 里最贵的那种失败(截断恰好落在合法 JSON 边界上 ⇒ 静默残缺)。
    /// ⚠️ 接上真实记账之后可以用 `usage.jsonl` 的输入 token 回归这个系数,
    /// **在那之前别把它当实测值引用**。
    static func estimatedTokens(_ text: String) -> Int { text.count }

    // MARK: - 建计划

    static func build(sessionID: Int64, in db: Database) throws -> Plan {
        let session = try sessionContext(sessionID: sessionID, in: db)
        let matters = try activeMatters(in: db)

        let sessionTerms = terms(of: session)
        var compare: [(ctx: MatterContext, score: Double)] = []
        var skipped: [Skipped] = []

        for m in matters {
            let lex = ProgressTiering.lexicalOverlap(sessionTerms: sessionTerms,
                                                     matterTerms: terms(of: m))
            let ppl = ProgressTiering.peopleOverlap(sessionPeople: session.speakers,
                                                    matterPeople: m.people)
            if ProgressTiering.shouldCompare(lexical: lex, people: ppl) {
                // 排序分数用两者之和:**不加权**。加权会引入一个谁都说不清来源的系数,
                // 而这里只需要一个「谁更相关」的序,不需要一个有物理意义的数
                // (同 `M2-B4` 定推动者时的那条口径)。
                compare.append((m, lex + ppl))
            } else {
                skipped.append(Skipped(matterID: m.matterID, lexical: lex, people: ppl))
            }
        }
        compare.sort { $0.score > $1.score }

        // 预算:超了就只比最相关的几件,**并把砍掉的记下来**。
        var chosen = compare.map(\.ctx)
        var dropped: [Int64] = []
        var tokens = estimatedTokens(render(session)) + chosen.reduce(0) {
            $0 + estimatedTokens(render($1))
        }
        if tokens > inputTokenBudget && chosen.count > degradedCompareCount {
            dropped = chosen.dropFirst(degradedCompareCount).map(\.matterID)
            chosen = Array(chosen.prefix(degradedCompareCount))
            tokens = estimatedTokens(render(session)) + chosen.reduce(0) {
                $0 + estimatedTokens(render($1))
            }
        }
        return Plan(session: session, compare: chosen, skipped: skipped,
                    droppedForBudget: dropped, estimatedInputTokens: tokens)
    }

    // MARK: - 读

    /// 活跃的事。**沉睡的不参与**(PRD §4.3.6:「沉睡的事不参与,但新材料可唤醒」——
    /// 唤醒是另一条路,不在比对里做)。
    ///
    /// 🔴 **上限读 `MatterCapacity.activeLimit`,不在这里再写一个 10。**
    /// 技术方案 §4.5.5 原话:两处各写一份,调高容量时只改一处,
    /// 后果是「有几件事永远不参与比对」而**不会有任何东西报错**(铁律 4)。
    static func activeMatters(in db: Database) throws -> [MatterContext] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, title FROM matters
             WHERE state = '活跃' ORDER BY updated_at DESC LIMIT ?
            """, arguments: [MatterCapacity.activeLimit])
        return try rows.map { r in
            let id: Int64 = r["id"]
            let qs = try Row.fetchAll(db, sql: """
                SELECT id, question FROM matter_open_questions
                 WHERE matter_id = ? AND closed_at IS NULL ORDER BY id
                """, arguments: [id]).map { (id: $0["id"] as Int64, text: $0["question"] as String) }
            let tl = try String.fetchAll(db, sql: """
                SELECT summary FROM matter_timeline
                 WHERE matter_id = ? ORDER BY at DESC LIMIT ?
                """, arguments: [id, timelineWindow])
            // 参与人:这件事脉络里出现过的行,归属到谁。
            //
            // 🔴 **`person_id IS NOT NULL` 不是防御性代码,是这张表的常态。**
            // `line_speakers` 有簇没身份(拒识 / 还没认)时 `person_id` 就是 NULL,
            // 而拒识是**常态分支**(开集摆在那儿)。`Int64.fetchSet` 解不了 NULL 会抛,
            // 于是**任何一场有拒识簇的场次,进展归属必崩** —— 实测某场次
            // 从 2026-08-21 起崩到第 58 次,而它要到第 6 天才会 dead。
            let people = try Int64.fetchSet(db, sql: """
                SELECT DISTINCT ls.person_id FROM matter_timeline t
                  JOIN line_speakers ls ON ls.line_id = t.line_id
                 WHERE t.matter_id = ? AND t.line_id IS NOT NULL
                   AND ls.person_id IS NOT NULL
                """, arguments: [id])
            return MatterContext(matterID: id, title: r["title"], openQuestions: qs,
                                 recentTimeline: tl, people: people)
        }
    }

    /// 本场的抽取产出。**整份逐字稿不进**(见 `SessionContext` 的说明)。
    ///
    /// 🔴 **只读当前生效的那一版转写**(`M2-审8`,2026-08-24)。
    ///
    /// 原来两处都只按 `t.session_id = ?` 过滤,不限版本。而重整(`refreeze`)
    /// 产生 v2 之后**冻结原则要求 v1 保留** ⇒ 进展模型会同时看到两版材料:
    /// 同一句话以两个不同的 `line_id` 各判一次,已经改正或作废的旧文字
    /// 照样能进「事」的脉络和确认卡 —— 而两版都合法,**不会有任何东西报错**。
    ///
    /// ⚠️ 口径**复用** `SessionDetailProjection.activeTranscripts`(`MAX(version)`
    /// 的全部 part),不在这里再写一份判断 —— 那就是第三个出处(铁律 4)。
    /// 「查的和看的必须是同一份」:用户在逐字稿上看到的是哪一版,
    /// 进展就该只读哪一版。
    static func sessionContext(sessionID: Int64, in db: Database) throws -> SessionContext {
        let active = try SessionDetailProjection.activeTranscripts(db, sessionID: sessionID)
        // 一版都没有 ⇒ 这一场还没冻结,没有材料可读。**返回空壳,不退化成「全都读」** ——
        // 退化的后果恰恰是这次要修的那个形态。
        guard !active.isEmpty else {
            return SessionContext(sessionID: sessionID, items: [], speakers: [])
        }
        let holes = Self.placeholders(active.count)
        let ids = active.map { $0 as (any DatabaseValueConvertible) }

        var items: [SessionContext.Item] = []
        for (table, col, kind) in [("summary_stances", "stance", "表态"),
                                   ("summary_commitments", "what", "承诺"),
                                   ("summary_pendings", "issue", "悬点")] {
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.line_id, s.\(col) AS text, s.quote FROM \(table) s
                 WHERE s.transcript_id IN (\(holes)) ORDER BY s.seq
                """, arguments: StatementArguments(ids))
            items += rows.map { SessionContext.Item(lineID: $0["line_id"] ?? 0, kind: kind,
                                                    text: $0["text"] ?? "", quote: $0["quote"] ?? "") }
        }
        // 同上:有簇没身份的行 `person_id` 是 NULL,而那是常态,不是异常。
        let speakers = try Int64.fetchSet(db, sql: """
            SELECT DISTINCT ls.person_id FROM line_speakers ls
              JOIN transcript_lines l ON l.line_id = ls.line_id
             WHERE l.transcript_id IN (\(holes)) AND ls.person_id IS NOT NULL
            """, arguments: StatementArguments(ids))
        return SessionContext(sessionID: sessionID, items: items, speakers: speakers)
    }

    /// `IN (?, ?, …)` 的占位符。
    static func placeholders(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ",")
    }

    // MARK: - 词面

    /// 切词走 `ChineseTokenizer` —— 与词索引、搜索同一份切词器。
    /// 🔴 自己再写一份切法的话,「搜得到」与「比对命中」会对不上,而两边都不报错。
    static func terms(of s: SessionContext) -> Set<String> {
        Set(s.items.flatMap { ChineseTokenizer.tokens($0.text + " " + $0.quote) })
    }

    static func terms(of m: MatterContext) -> Set<String> {
        Set(ChineseTokenizer.tokens(
            ([m.title] + m.openQuestions.map(\.text) + m.recentTimeline).joined(separator: " ")))
    }

    // MARK: - 渲染(只为估 token;真正的 prompt 在调用层拼)

    static func render(_ s: SessionContext) -> String {
        s.items.map { "\($0.kind)|\($0.lineID)|\($0.text)|\($0.quote)" }.joined(separator: "\n")
    }

    static func render(_ m: MatterContext) -> String {
        ([m.title] + m.openQuestions.map { "\($0.id)|\($0.text)" } + m.recentTimeline)
            .joined(separator: "\n")
    }
}
