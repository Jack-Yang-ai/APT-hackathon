import Foundation
import GRDB

/// 卡片**什么时候推、推哪几张**(`M3-B2`,PRD §4.6.2 与 §4.1.8)。
///
/// ## 🔴 「就位不催」是这一层的立意
///
/// PRD §4.6.2:**卡片随纪要产生即挂到页面,但推送延后到用户下一次打开 App。**
/// 理由写在 PRD 里:在用户已经进入这个上下文时问他,回答质量更高、打扰感更低。
///
/// ⇒ 这个模块**不由「卡片产生」触发**,而由「用户打开了 App」触发。
/// 做成产生即推的话,PRD 那句话就没有任何落点 —— 而界面上看不出区别。
///
/// ## 🔴 免打扰不是「晚点再推」,是「这一批不推了」
///
/// 22:00–08:00 不推送(R-D / §4.1.8)。而卡片**推送有效期只有 1 天** ——
/// 攒到早上再推的话,推的是一批**昨天的**卡,而它们本该已经收进页面了。
/// ⇒ 免打扰时段内**只挂页面,不进推送**,不排队、不补推。
enum CardPush {

    /// 免打扰:`[quietFrom, quietUntil)`,PRD §4.1.8「22:00–08:00」。
    static let quietFrom = 22
    static let quietUntil = 8

    /// 现在是不是免打扰时段。
    static func isQuiet(hour: Int) -> Bool { hour >= quietFrom || hour < quietUntil }

    /// 一次「用户打开 App」时该推什么。
    struct Plan: Equatable {
        /// 这一拍要推的合并卡(已按 §4.6.2 排序、取前 B)。
        let push: [CardQueueProjection.Merged]
        /// 为什么是这些 —— **没有「静默不推」这一档**。
        let why: String
    }

    /// 算这一拍的推送计划。**只算不写**,写在 `markPushed`。
    ///
    /// - Parameter hour: 当地小时。**没有默认值** —— 给一个默认值等于把
    ///   「现在不是睡前」这个假设藏进签名里,而 R-D 的全部意义就是不让它藏。
    static func plan(now: Date, hour: Int, in db: Database) throws -> Plan {
        if isQuiet(hour: hour) {
            return Plan(push: [], why: "\(quietFrom):00–0\(quietUntil):00 免打扰:"
                              + "卡片照常挂页面,**这一批不补推**(有效期只有 1 天,"
                              + "攒到早上推的是昨天的卡)")
        }
        let b = try CardBudget.load(db)
        if b.paused {
            return Plan(push: [], why: "推送已暂停(连续 \(CardBudget.pauseAfterIdleDays) 天零处理);"
                              + "卡片仍在页面上,用户处理任意一张即恢复")
        }
        let q = try CardQueueProjection.pushQueue(now: now, budget: b.value, in: db)
        return Plan(push: q, why: q.isEmpty
                    ? "队列里没有够格进推送的卡(搁置过的、地基卡、收尾卡、过期的都不进)"
                    : "预算 \(b.value) 张,取到 \(q.count) 组")
    }

    /// 落 `pushed_at`。**推了才记** —— 记早了会让「推送有效期 1 天」从
    /// 卡片产生那一刻开始算,于是没推过的卡第二天就自己过期了。
    @discardableResult
    static func markPushed(_ plan: Plan, now: String, in db: Database) throws -> Int {
        let ids = plan.push.flatMap { $0.rows.map(\.id) }
        guard !ids.isEmpty else { return 0 }
        let marks = ids.map { _ in "?" }.joined(separator: ",")
        try db.execute(sql: """
            UPDATE cards SET pushed_at = ?
             WHERE pushed_at IS NULL AND id IN (\(marks))
            """, arguments: StatementArguments([now] + ids.map { $0 as DatabaseValueConvertible? }))
        return db.changesCount
    }

    // MARK: - 喂给预算的那三个数

    /// 数出 `CardBudget.Input`(§4.6.1 的信号)。
    ///
    /// 🔴 **「处理」= 用户对推过的卡做了任意出口动作**,含搁置、含「这问题问得不对」。
    /// 它量的是**打扰的接受度**,不是提问质量 —— 提问质量走 §5.3 的降权通道。
    /// 混在一起的后果:用户老老实实点「这问不对」反而把 rate 顶高,系统于是问得更多。
    static func budgetInput(now: Date, windowDays: Int = 7, in db: Database) throws
        -> CardBudget.Input {
        let iso = ISO8601DateFormatter.growth
        let since = iso.string(from: now.addingTimeInterval(-Double(windowDays) * 86_400))
        let pushed = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM cards WHERE pushed_at IS NOT NULL AND pushed_at >= ?
            """, arguments: [since]) ?? 0
        let handled = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM cards c
             WHERE c.pushed_at IS NOT NULL AND c.pushed_at >= ?
               AND EXISTS (SELECT 1 FROM judgment_current jc
                            WHERE jc.target_kind = 'card'
                              AND jc.target_id = CAST(c.id AS TEXT))
            """, arguments: [since]) ?? 0
        // 「连续多少天零处理」:从最近一次处理算起。
        // 🔴 **一次都没处理过 ≠ 零天** —— 那种情况要从**第一次推送**算起,
        // 否则一个从来没点过卡片的用户永远等不到暂停。
        let lastHandled = try String.fetchOne(db, sql: """
            SELECT MAX(j.decided_at) FROM judgments j WHERE j.target_kind = 'card'
            """)
        let firstPushed = try String.fetchOne(db, sql: """
            SELECT MIN(pushed_at) FROM cards WHERE pushed_at IS NOT NULL
            """)
        var idle = 0
        if let anchor = lastHandled ?? firstPushed, let t = iso.date(from: anchor) {
            idle = max(0, Int(now.timeIntervalSince(t) / 86_400))
        }
        return .init(pushed: pushed, handled: handled, idleDays: idle)
    }
}
