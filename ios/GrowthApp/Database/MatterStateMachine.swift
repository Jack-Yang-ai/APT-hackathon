import Foundation
import GRDB

/// 事的状态机(M2-B2)。**全库唯一能改 `matters.state` 的路径。**
///
/// ## 「唯一」不是靠约定,是靠物理防线
///
/// 铁律 3 那条(归属只有一条路可写)在旧仓被违反过,代价是实测悬空 1979 条 ——
/// 根因就是只有代码约定、没有东西挡着。所以这里有两道:
///
/// | 谁 | 挡什么 |
/// |---|---|
/// | `matters_legal_transition_only`(v19) | PRD §4.3.4 里没有的流转 |
/// | `matters_transition_needs_judgment`(v20) | **没先写判断记录的流转** —— 直接 UPDATE 写不进去 |
///
/// 换句话说:绕过这个文件去改状态,数据库层就会 ABORT。
///
/// ## 自动流转「静默」= 不通知,不是不留痕
///
/// PRD 说候选 30 天过期、活跃 14 天沉睡都**静默**(不通知)。
/// 但它们照样写 `judgments`,`actor = 'system-cascade'` ——
/// 不写的话,用户某天发现一件事不见了,而**没有任何地方能回答「它是怎么没的」**。
enum MatterStateMachine {

    /// PRD §4.3.4:候选 30 天(初)未处理 → 静默拒绝。
    static let candidateExpiryDays = 30
    /// PRD §4.3.4:活跃 14 天(初)无新材料 → 静默沉睡。
    static let activeIdleDays = 14
    /// 满员时给用户看几件候选让位。PRD 原话「2–3 件最久未动的」。
    static let handoverSuggestions = 3

    // MARK: - 唯一写路径

    /// 走一次流转。**这是唯一入口。**
    ///
    /// - Parameter by: 触发方。它不是权限标签,是**事实**:PRD 明确区分了
    ///   「仅用户」的流转(结案)与系统静默做的那些。分不开的话,
    ///   「系统悄悄把一件事结了案」没有任何东西挡得住。
    @discardableResult
    static func transition(_ matterID: Int64, to target: String,
                           by: Actor, now: String,
                           basis: [Int64] = [], in db: Database) throws -> Int64 {
        guard let from = try String.fetchOne(db, sql:
                "SELECT state FROM matters WHERE id = ?", arguments: [matterID])
        else { throw MatterActionFailure.notFound(kind: "事", id: matterID) }

        // ① PRD 里有没有这条流转,而且这个触发方能不能做。
        //    数据库那道闸只查「有没有这条流转」,查不到触发方 —— 那一层在这里。
        let allowed = try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM matter_transitions
                            WHERE from_state = ? AND to_state = ? AND by = ?)
            """, arguments: [from, target, by.rawValue]) ?? false
        guard allowed else { throw MatterActionFailure.illegalTransition(from: from, to: target) }

        // ② 进活跃要占名额。**满员不许静默挤掉别人** —— PRD 要的是让用户选。
        if target == "活跃" {
            let used = try activeCount(in: db)
            if used >= MatterCapacity.activeLimit {
                throw MatterActionFailure.slotsFull(limit: MatterCapacity.activeLimit,
                                                    suggestions: try handoverCandidates(in: db))
            }
        }

        // ③ 先写判断,再改状态 —— 顺序不能反(v20 的触发器就是这么校验的)。
        try db.execute(sql: """
            INSERT INTO judgments
              (decided_at, actor, caused_by, undoes, action, target_kind, target_id,
               payload, basis_line_ids)
            VALUES (?, ?, NULL, NULL, ?, 'matter', ?, ?, ?)
            """, arguments: [now, by.judgmentActor, "matter_to_\(target)", "\(matterID)",
                             #"{"from":"\#(from)","to":"\#(target)"}"#,
                             basis.isEmpty ? nil : "[\(basis.map(String.init).joined(separator: ","))]"])
        let judgmentID = db.lastInsertedRowID

        try db.execute(sql: "UPDATE matters SET state = ?, updated_at = ? WHERE id = ?",
                       arguments: [target, now, matterID])
        return judgmentID
    }

    enum Actor: String {
        case user, system
        /// `judgments.actor` 的闭集只有 `user` / `system-cascade`(迁移 v1 的 CHECK)。
        /// 这里做映射而不是把闭集改宽 —— 那张表是全库的判断账本,不该为一个新模块动它。
        var judgmentActor: String { self == .user ? "user" : "system-cascade" }
    }

    // MARK: - 容量

    /// 占着活跃名额的件数。**派生,不落列。**
    /// 口径直接读 `matter_states.takes_slot`,不在这里再写一遍「哪些态占名额」——
    /// 写两遍就是两个出处,而漏改一处不会报错。
    static func activeCount(in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM matters m
              JOIN matter_states s ON s.state = m.state
             WHERE s.takes_slot = 1
            """) ?? 0
    }

    /// 让位候选:**最久未动的**几件活跃事。
    ///
    /// 口径定死在这里(H5 图纸没给):按「最近一条脉络的时刻」升序,**没有脉络的排最前** ——
    /// 一件立起来之后从没动过的事,正是最该让位的那一件。
    static func handoverCandidates(in db: Database) throws -> [Int64] {
        try Int64.fetchAll(db, sql: """
            SELECT m.id FROM matters m
              JOIN matter_states s ON s.state = m.state
             WHERE s.takes_slot = 1
             ORDER BY (SELECT MAX(t.at) FROM matter_timeline t WHERE t.matter_id = m.id) ASC NULLS FIRST,
                      m.updated_at ASC
             LIMIT ?
            """, arguments: [handoverSuggestions])
    }

    // MARK: - 自动流转(静默:不通知,但留痕)

    /// 跑一遍两条到期规则。→ 实际改了几件。
    ///
    /// ⚠️ **不通知**(PRD 明写),所以这里一条 `ProcessingEvents` 都不记给用户看;
    /// 但每一件都写了 `judgments`(`actor = system-cascade`),
    /// 「它是怎么没的」永远查得到。
    @discardableResult
    static func runExpiries(now: Date, in db: Database) throws -> Int {
        let iso = ISO8601DateFormatter.growth
        let nowStr = iso.string(from: now)
        func cutoff(_ days: Int) -> String {
            iso.string(from: now.addingTimeInterval(-Double(days) * 86_400))
        }
        var changed = 0

        // 候选:30 天没被处理 ⇒ 静默拒绝。仍可搜索找回(PRD 特意标粗)。
        for id in try Int64.fetchAll(db, sql: """
            SELECT id FROM matters WHERE state = '候选' AND created_at < ?
            """, arguments: [cutoff(candidateExpiryDays)]) {
            try transition(id, to: "已拒绝", by: .system, now: nowStr, in: db)
            changed += 1
        }

        // 活跃:14 天没有新材料 ⇒ 静默沉睡。
        // 🔴 判据是**最近一条脉络**,不是 `updated_at` —— 后者会被改标题之类的
        // 无关操作刷新,于是一件其实早就没动静的事永远不会沉睡,而活跃名额被它占着。
        for id in try Int64.fetchAll(db, sql: """
            SELECT m.id FROM matters m
             WHERE m.state = '活跃'
               AND COALESCE((SELECT MAX(t.at) FROM matter_timeline t WHERE t.matter_id = m.id),
                            m.created_at) < ?
            """, arguments: [cutoff(activeIdleDays)]) {
            try transition(id, to: "沉睡", by: .system, now: nowStr, in: db)
            changed += 1
        }
        return changed
    }
}
