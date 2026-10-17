import Foundation
import GRDB

/// 局面面板(PRD §4.5.3,M2-B4)。**纯派生,一列都不落库,一个字都不写库。**
///
/// ## G6 与「算不出来」不是同一件事
///
/// PRD 说「某项无数据时该行隐藏」。但**「这件事没有悬点」与「悬点这项我算不出来」
/// 是两回事**,而在界面上它们长得一模一样(都是那一行不见了)。
/// 所以这里把后者单独收进 `unavailable`:界面照样隐藏(G6),
/// 而**为什么算不出来**留在结构里,不至于将来有人以为「一直没数据」。
///
/// ## 三处有自由度的口径,在这里定死(M2-0e 的验收要求)
///
/// PRD 那张表给的是「计算方式」的一句话,不是判据。下面凡带 `口径:` 的都是
/// 本文件定死的那部分 —— 它们是契约,不是实现细节,改之前先回来看。
enum MatterSituation {

    /// 一件事的局面。每一项都是 optional —— nil = 这一行不显示(G6)。
    struct Panel: Equatable {
        /// 「18 天没推进」。nil = 从没推进过(**不是 0 天**)。
        let stalledDays: Int?
        /// 「2 个悬点未解」。0 也照实给 —— 「一个悬点都没有」是有信息的。
        let openQuestions: Int
        /// 「你 3 周没表态」。
        let userSilentDays: Int?
        /// 「主要推动人:某某」。
        let driver: Driver?
        /// 「本周提到 4 次,上周 1 次」。
        let heat: Heat?
        /// 「3 条承诺」。**兑现比给不了**,见 `unavailable`。
        let commitments: Int?
        /// 算不出来的项 → 为什么。**界面照样隐藏,这里只是不让原因丢掉。**
        let unavailable: [String: String]

        /// 🔴 `name` 是 optional,因为 **`persons.name` 可以为空** ——
        /// 声纹认出一个人但用户还没给他起名时就是这个状态,而全时录音里这是常态。
        /// 按非空读会**直接崩**(2026-08-18 被测试当场打出来);
        /// 编一个「说话人 3」塞进来更糟 —— 那是把展示层的兜底混进了数据。
        /// 界面拿到 nil 自己决定怎么显示。
        struct Driver: Equatable { let personID: Int64; let name: String?; let weight: Int }
        struct Heat: Equatable { let thisWeek: Int; let lastWeek: Int }
    }

    /// 「本人」。**指回 `SpeakerNaming.mePersonID`,不在这里再写一个 `-1`。**
    ///
    /// ⚠️ 2026-08-18 照复核清单 §五扫出来的:我第一版在这里硬编码了 `-1`,
    /// 而全仓的定义早就在 `SpeakerNaming` 里 —— 那就是**第三份**。
    /// 这类重复的坏处不是多写一行,是**改的时候只会有人改到其中一处**,
    /// 而两处不一致时「局面面板算的是另一个人」不会报任何错。
    static let mePersonID = SpeakerNaming.mePersonID

    /// 口径:**推动者 = 该事材料里(表态数 + 承诺数)最多的人**,两者**等权**。
    ///
    /// PRD 原话只说「发言与承诺最多的人」。等权是本文件定的 —— 加权会引入一个
    /// 谁都说不清来源的系数,而这一项是给人看一眼的,不是排名。
    /// **平手时不给推动者**(返回 nil):硬选一个等于替用户断言了一件他没说过的事。
    static let driverWeightsAreEqual = true

    /// 口径:**热度按自然周计**,以传进来的 `now` 所在周为「本周」。
    /// 计的是**脉络条数**,不是提及次数 —— 提及要先有「提及」这个对象,而今天没有。
    static let heatWindowDays = 7

    /// 读一件事的局面。`now` 传进来,不取系统时间(测试与夹具要能定死今天)。
    ///
    /// ⚠️ **零写库**:本函数与它调用的一切都不许 INSERT/UPDATE。
    /// 「升格为事」那类动作是状态机语义,走 `MatterStateMachine`(M2-B2),
    /// 不在这一层 —— 审查抓过这一条。
    static func panel(matterID: Int64, now: Date, in db: Database) throws -> Panel {
        let iso = ISO8601DateFormatter.growth
        var unavailable: [String: String] = [:]

        // ① 停滞时长
        let lastProgress = try String.fetchOne(db, sql: """
            SELECT MAX(at) FROM matter_timeline WHERE matter_id = ?
            """, arguments: [matterID])
        let stalled = lastProgress.flatMap { iso.date(from: $0) }
                                  .map { Int(now.timeIntervalSince($0)) / 86_400 }
        if lastProgress == nil { unavailable["停滞时长"] = "这件事还没有任何进展" }

        // ② 悬点数
        let openQs = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM matter_open_questions WHERE matter_id = ? AND closed_at IS NULL
            """, arguments: [matterID]) ?? 0

        // 这件事的材料 = 脉络指到的那些行。**今天只有这一条链路** ——
        // 提名产出器(M2-B1)落地后会有更宽的材料集,那时回来扩这里。
        let lineIDs = try Int64.fetchAll(db, sql: """
            SELECT line_id FROM matter_timeline WHERE matter_id = ? AND line_id IS NOT NULL
            """, arguments: [matterID])
        let marks = lineIDs.isEmpty ? "NULL" : Array(repeating: "?", count: lineIDs.count)
            .joined(separator: ",")
        let args = StatementArguments(lineIDs)

        // ③ 用户缺席:本人最近一次**表态**距今。
        var silent: Int?
        if lineIDs.isEmpty {
            unavailable["用户缺席"] = "这件事的脉络还没有指向任何原话,材料集是空的"
        } else {
            let last = try String.fetchOne(db, sql: """
                SELECT MAX(l.t_start_ms || '') FROM summary_stances st
                  JOIN line_speakers ls ON ls.line_id = st.line_id
                  JOIN transcript_lines l ON l.line_id = st.line_id
                  JOIN transcripts t ON t.id = l.transcript_id
                  JOIN sessions s ON s.id = t.session_id
                 WHERE ls.person_id = ? AND st.line_id IN (\(marks))
                """, arguments: StatementArguments([mePersonID] as [any DatabaseValueConvertible])
                                + args)
            // 只用得到「有没有」,具体日期取那一行所在场次的起点
            if last == nil {
                unavailable["用户缺席"] = "这件事的材料里没有本人的表态(或本人身份还没确认)"
            } else {
                let at = try String.fetchOne(db, sql: """
                    SELECT MAX(s.started_at) FROM summary_stances st
                      JOIN line_speakers ls ON ls.line_id = st.line_id
                      JOIN transcript_lines l ON l.line_id = st.line_id
                      JOIN transcripts t ON t.id = l.transcript_id
                      JOIN sessions s ON s.id = t.session_id
                     WHERE ls.person_id = ? AND st.line_id IN (\(marks))
                    """, arguments: StatementArguments([mePersonID] as [any DatabaseValueConvertible])
                                    + args)
                silent = at.flatMap { iso.date(from: $0) }
                           .map { Int(now.timeIntervalSince($0)) / 86_400 }
            }
        }

        // ④ 推动者
        var driver: Panel.Driver?
        if lineIDs.isEmpty {
            unavailable["推动者"] = "材料集是空的"
        } else {
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.id, p.name, COUNT(*) AS w FROM (
                  SELECT line_id FROM summary_stances     WHERE line_id IN (\(marks))
                  UNION ALL
                  SELECT line_id FROM summary_commitments WHERE line_id IN (\(marks))
                ) x
                  JOIN line_speakers ls ON ls.line_id = x.line_id
                  JOIN persons p ON p.id = ls.person_id
                 GROUP BY p.id ORDER BY w DESC
                """, arguments: args + args)
            if rows.isEmpty {
                unavailable["推动者"] = "材料里没有表态也没有承诺"
            } else if rows.count > 1 && (rows[0]["w"] as Int) == (rows[1]["w"] as Int) {
                // 口径:**平手不给推动者**。硬选一个等于替用户断言了一件他没说过的事。
                unavailable["推动者"] = "并列第一,不硬选"
            } else {
                driver = .init(personID: rows[0]["id"], name: rows[0]["name"], weight: rows[0]["w"])
            }
        }

        // ⑤ 讨论热度:本周 vs 上周的**脉络条数**
        func count(from: Int, to: Int) throws -> Int {
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM matter_timeline WHERE matter_id = ? AND at >= ? AND at < ?
                """, arguments: [matterID,
                                 iso.string(from: now.addingTimeInterval(-Double(from) * 86_400)),
                                 iso.string(from: now.addingTimeInterval(-Double(to) * 86_400))]) ?? 0
        }
        let thisWeek = try count(from: heatWindowDays, to: 0)
        let lastWeek = try count(from: heatWindowDays * 2, to: heatWindowDays)
        let heat: Panel.Heat? = (thisWeek + lastWeek) > 0
            ? .init(thisWeek: thisWeek, lastWeek: lastWeek) : nil
        if heat == nil { unavailable["讨论热度"] = "最近两周都没有新进展" }

        // ⑥ 承诺状态
        //
        // 🔴 **兑现比给不了,而且要说清为什么。** PRD 写的是「3 条承诺,1 条已兑现」,
        // 而 `summary_commitments` 里**没有任何兑现状态列** —— 上游根本没这个字段。
        // 编一个(比如「有后续提及就算兑现」)会得到一个看着合理、实际没有依据的数,
        // 而用户会拿它做判断。⇒ 只给条数,兑现那半明说算不出来。
        var commitments: Int?
        if lineIDs.isEmpty {
            unavailable["承诺状态"] = "材料集是空的"
        } else {
            commitments = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM summary_commitments WHERE line_id IN (\(marks))
                """, arguments: args) ?? 0
            unavailable["承诺兑现比"] =
                "上游还没产出「兑现了没有」这一半,所以算不出比例"
        }

        return Panel(stalledDays: stalled, openQuestions: openQs, userSilentDays: silent,
                     driver: driver, heat: heat, commitments: commitments,
                     unavailable: unavailable)
    }
}
