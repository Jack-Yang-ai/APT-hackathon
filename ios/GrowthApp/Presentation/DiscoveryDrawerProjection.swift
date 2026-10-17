import Foundation
import GRDB

/// 发现抽屉与详情的展示模型(`M3-0e`,对 `docs/H5施工规格` §4.1–§4.2 与 PRD §4.5.4–§4.5.5)。
///
/// ## 一条纪律:三个「时间态」全部在这里派生,库里一列都不落
///
/// PRD §4.5.4 给了三种状态,而它们都是**从时间戳算出来的**:
///
/// | 态 | 判据 | 派生自 |
/// |---|---|---|
/// | 新 | 7 天内有新材料触及,且没被移除 | `last_touched_at` |
/// | 旧 | 7 天没有新材料触及 ⇒ 移到「更早」折叠区,**不计入「有 N 条新发现」** | `last_touched_at` |
/// | 沉底 | 14 天未读 ⇒ 沉入历史,**不删除**,仍可搜索 | `read_at` 为空 + `created_at` |
///
/// 落一列 `state` 的后果是同一件事两个出处,而**对不上时不会报错** ——
/// 首页那句「有 N 条新发现」会显示一个谁都解释不了的数。
///
/// ## 「未判卷」必须一路带到界面上
///
/// `M3-0g` 用户拍板「带风险先做」,代价是**停止线 3(发现合规率)一次都没验过**。
/// 条件是:产出的发现一律带「未判卷」标注。⇒ 这个标不是可选装饰,
/// 它是那次拍板的兑现物;掉在半路上,界面就在把未经检验的判断当成定论呈现。
enum DiscoveryDrawerProjection {

    /// 抽屉里的一条。
    struct Row: Equatable, Identifiable {
        let id: Int64
        /// 发现类型(`DiscoveryKind` 的 rawValue)。
        let kind: String
        /// 挂在「事」还是「人」上 —— 抽屉按对象分组(PRD §4.5.4)。
        let subject: String
        let objectID: String
        let summary: String
        /// 依据形态。**界面须标注**(PRD §4.5.4)——
        /// 「有原话」与「没出现」的可验证性不一样,混着显示等于把统计出来的说成他说过。
        let evidenceForm: String
        /// 「没出现」类的可复算统计口径;有原话类为 nil。
        let statBasis: String?
        /// 证据条数。**默认折叠**(PRD §4.5.4),所以列表只要这个数。
        let evidenceCount: Int
        /// 这条发现所属批次的判卷结论:`未判卷` / `达标` / `未达标`。
        ///
        /// 🔴 **带的是原值,不是一个布尔。** 三种取值在界面上要说三句不同的话
        /// (「还没验过」/ 什么都不说 /「这一批没达标」),压成布尔就再也分不开了。
        let verdict: String

        /// 要不要在界面上加一句提醒。**判据是「不等于达标」,不是「等于未判卷」** ——
        /// `未达标` 同样不该被当成定论呈现,而写成 `== "未判卷"` 会把它放过去。
        /// (`M3-0g` 用户拍板「带风险先做」,代价就是这个标。)
        var needsCaveat: Bool { verdict != "达标" }
        let lastTouchedAt: String
        let readAt: String?
    }

    /// 一整屏抽屉。
    struct Drawer: Equatable {
        /// 「新」的,按对象分组、组内时间倒序。
        let fresh: [Row]
        /// 「更早」折叠区。
        let older: [Row]

        /// 首页提示条那句「有 N 条新发现」。**派生,不另存。**
        /// 🔴 **只数 `fresh`** —— PRD §4.5.4 明写降为「旧」之后不再计入这个数。
        var freshCount: Int { fresh.count }
    }

    /// 降为「旧」的天数。唯一副本是 `DiscoveryPolicy`,这里不另写一个数。
    static var staleAfterDays: Int { DiscoveryPolicy.staleAfterDays }
    /// 沉入历史的天数。同上。
    static var sinkAfterDays: Int { DiscoveryPolicy.sinkAfterDays }

    /// 抽屉。**沉底的与撤回的都不进来**(前者进历史仍可搜,后者依据没了)。
    static func drawer(now: Date, in db: Database) throws -> Drawer {
        let rows = try fetchLive(db)
        let staleCut = now.addingTimeInterval(-Double(staleAfterDays) * 86_400)
        let iso = ISO8601DateFormatter.growth
        var fresh: [Row] = [], older: [Row] = []
        for r in rows {
            // 解不出时间戳的当成「旧」,不当成「新」——
            // 猜成「新」会让它去顶首页那个计数,而它到底新不新根本没人知道。
            let touched = iso.date(from: r.lastTouchedAt)
            if let t = touched, t >= staleCut { fresh.append(r) } else { older.append(r) }
        }
        return Drawer(fresh: fresh, older: older)
    }

    /// 「最近移除」:24 小时内左滑掉的,可找回(PRD §4.5.5)。
    ///
    /// 🔴 **它读的是判断库,不是内容库的某一列。**
    /// 左滑是**用户动作**,而判断库是全库唯一的「用户说过什么」的账本(§3.3)。
    /// 在 `discoveries` 上再落一个 `removed_at`,就是同一件事两个出处 ——
    /// 而两者对不上时,「最近移除」里会有一条抽屉里也还在的发现。
    static func recentlyRemoved(now: Date, in db: Database) throws -> [Row] {
        let cutoff = ISO8601DateFormatter.growth
            .string(from: now.addingTimeInterval(-24 * 3600))
        return try fetchLive(db, extraWhere: """
            AND EXISTS (SELECT 1 FROM judgment_current jc
                          JOIN judgments j ON j.id = jc.judgment_id
                         WHERE jc.target_kind = 'discovery'
                           AND jc.target_id = CAST(d.id AS TEXT)
                           AND j.action = 'discovery_dismiss'
                           AND j.decided_at >= ?)
            """, arguments: [cutoff])
    }

    // MARK: - 取数

    private static func fetchLive(_ db: Database, extraWhere: String = "",
                                  arguments: StatementArguments = StatementArguments()) throws -> [Row] {
        try GRDB.Row.fetchAll(db, sql: """
            SELECT d.id, d.kind, k.subject, k.evidence_form, d.object_id, d.summary,
                   d.stat_basis, d.last_touched_at, d.read_at,
                   (SELECT COUNT(*) FROM discovery_evidence e WHERE e.discovery_id = d.id) AS n,
                   (SELECT b.verdict FROM generation_batches b WHERE b.batch_id = d.batch_id) AS verdict
              FROM discoveries d
              JOIN discovery_kinds k ON k.kind = d.kind
             WHERE d.withdrawn_at IS NULL AND d.sunk_at IS NULL \(extraWhere)
             ORDER BY d.last_touched_at DESC, d.id DESC
            """, arguments: arguments).map { r in
            Row(id: r["id"], kind: r["kind"], subject: r["subject"], objectID: r["object_id"],
                summary: r["summary"], evidenceForm: r["evidence_form"], statBasis: r["stat_basis"],
                evidenceCount: r["n"],
                verdict: r["verdict"],
                lastTouchedAt: r["last_touched_at"], readAt: r["read_at"])
        }
    }
}

/// 发现三页的**真 DDL 夹具**(照 `MatterFixtures.inMemoryBoard` 的模式)。
///
/// 🔴 **不手写 JSON。** 手写 JSON 想写什么字段就有什么字段,而库里根本没有那一列,
/// 直到联调那天才炸。走真 DDL 的话,库表一改前端线**当场编译红**。
enum DiscoveryFixtures {

    /// 灌好假数据的内存库:两条「新」、一条「旧」、一条已沉底、一条已撤回。
    /// `now` 定死,免得夹具随跑的时间变。
    static func inMemoryDrawer(now: Date) throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(q)
        let iso = ISO8601DateFormatter.growth
        func at(_ daysAgo: Int) -> String {
            iso.string(from: now.addingTimeInterval(-Double(daysAgo) * 86_400))
        }
        try q.write { db in
            // ⚠️ 闭集取值**读常量,不再敲一遍**。敲一遍的后果是取值改名之后
            // 这条 INSERT **静默写进一个没人认识的值**,而 `ClosedSetLiteralTests`
            // 就是为此存在的 —— 它在这条夹具第一版上当场红了。
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, ?, '2026-08-01', ?, ?)
                """, arguments: [at(30), SessionBridge.Source.recording,
                                 SessionBridge.Status.closed])
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (1, 1, 1, 1, 'step-asr-v1', 'frozen', ?)
                """, arguments: [at(30)])
            for i in 0..<4 {
                try db.execute(sql: """
                    INSERT INTO transcript_lines (line_id, transcript_id, seq, t_start_ms, t_end_ms,
                                                  text, char_offset)
                    VALUES (?, 1, ?, ?, ?, ?, ?)
                    """, arguments: [10 + i, i, i * 1000, (i + 1) * 1000,
                                     "第 \(i + 1) 句原话", i * 6])
            }
            // 🔴 批次的 verdict 留默认「未判卷」—— `M3-0g` 那次拍板的兑现物,
            //    夹具里也不许偷偷写成「达标」,否则界面上那个标就永远测不到。
            try db.execute(sql: """
                INSERT INTO generation_batches (batch_id, producer, prompt_version, model_id, created_at)
                VALUES ('b1', '发现', 'discovery/v1', 'deepseek-v4-flash', ?)
                """, arguments: [at(30)])

            // (类型, 对象, 摘要, 几天前被触及, 统计口径, 沉底了没, 撤回了没)
            let rows: [(DiscoveryKind, String, String, Int, String?, Bool, Bool)] = [
                (.argumentShift,       "m1", "争论从「要不要做」转到了「谁来做」",  0, nil, false, false),
                (.repeatedConcern,     "p7", "他连续 4 次会议都提到交付时间",       1, nil, false, false),
                (.stalledReason,       "m2", "每次卡住都停在同一个悬点上",
                    9, "近 4 次讨论该悬点均未关闭", false, false),
                (.suspendedCommitment, "p8", "他 6 周前答应的事,之后没再提过",
                    20, "近 6 周内该承诺再未被任一说话人提及", true, false),
                (.attitudeChange,      "p7", "依据失效的一条(认错了人)",           2, nil, false, true),
            ]
            for (kind, obj, summary, days, basis, sunk, withdrawn) in rows {
                try db.execute(sql: """
                    INSERT INTO discoveries (kind, object_id, summary, stat_basis, batch_id,
                                             created_at, last_touched_at, sunk_at, withdrawn_at)
                    VALUES (?, ?, ?, ?, 'b1', ?, ?, ?, ?)
                    """, arguments: [kind.rawValue, obj, summary, basis, at(30), at(days),
                                     sunk ? at(days) : nil, withdrawn ? at(days) : nil])
                let id = db.lastInsertedRowID
                // 有原话类 2 处;「没出现」类 1 处锚点 —— 与 §4.7.4 的门槛一致
                let n = kind.evidenceForm == .absence ? 1 : 2
                for i in 0..<n {
                    try db.execute(sql: """
                        INSERT INTO discovery_evidence (discovery_id, line_id, form, seq)
                        VALUES (?, ?, ?, ?)
                        """, arguments: [id, 10 + i,
                                         kind.evidenceForm == .absence ? "anchor" : "quote", i])
                }
            }
        }
        return q
    }
}
