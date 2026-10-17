import Foundation
import GRDB

/// 卡片五页的展示模型(`M3-0e`,对 `docs/H5施工规格` §3.1–§3.5、PRD §4.6、技术方案 §4.6)。
///
/// ## 排序与合并的口径全在契约里,这里只**读**不重推
///
/// 重要度 = `card_kinds.priority`(播种自 `CardTrigger.Kind`,而它与 PRD §4.6.3
/// 那张表由 `eval/checks/test_card_kinds.py` 双向对撞);
/// 紧急度 = 关联「正在动的事」或今天出现过的人 ⇒ 2,其余 ⇒ 1;
/// 合并键 = (对象类型, 对象 id, 场次)。
/// **一个数都不在这里重新定义** —— 定义在 `docs/技术方案.md` §4.6.2 / §4.6.4。
///
/// 🔴 **「正在动的事」读 `MatterBoardProjection` 的口径,不另写一份判据。**
/// 那边的口径是「活跃 且 最近 `movingWindowDays` 天内有进展」——
/// 在这里照抄一遍 `7`,调那个窗口时就会有一半的紧急度算错,而不会有任何东西报错。
enum CardQueueProjection {

    /// 一张卡当前处在哪一态。**全部从判断库派生**,`cards` 上不落状态列 ——
    /// 落了就是同一件事两个出处,而对不上时用户会看到一张自己明明答过的卡又被问一遍。
    enum State: String, Equatable {
        case pending = "待判断"
        case accepted = "已确认"
        case declined = "已选择不记"
        /// 搁置。PRD §4.6.2:**永不再推送**,但永久留在产生它的页面。
        case held = "已先放着"
        /// 轻出口:否定的是**提问本身**,不是内容。进学习闭环对同类提问降权。
        case wrongQuestion = "这问题问得不对"

        /// 判断库里的 action 名 ↔ 态。**这是这一组取值的唯一出处。**
        static let byAction: [String: State] = [
            "card_accept": .accepted, "card_decline": .declined,
            "card_hold": .held, "card_wrong_question": .wrongQuestion,
        ]
    }

    struct Row: Equatable, Identifiable {
        let id: Int64
        let kind: String
        /// PRD §4.6.3 的「序」,1 最高。
        let priority: Int
        let objectKind: String
        let objectID: String
        let sessionID: Int64?
        /// 系统写的那句话。**与逐字原话分两列**(H5 §3.1 点名)——
        /// 「就地可改」改的是这一列,而原话是冻结层,一个字都不许动。
        let body: String
        let quote: String?
        let lineID: Int64?
        let createdAt: String
        let pushedAt: String?
        let state: State

        /// 重要度(技术方案 §4.6.2):`11 − 序`。
        var importance: Int { CardTrigger.Kind.allCases.count + 1 - priority }
    }

    /// 合并卡(PRD §4.6.2.1):同一对象在同一场次产生的卡片合并成一张。
    struct Merged: Equatable, Identifiable {
        let objectKind: String
        let objectID: String
        let sessionID: Int64?
        /// 展开后逐条处理的那几条。**最多 `mergeLimit` 条**。
        let rows: [Row]
        /// 超出上限、留在页面不推送的条数(§4.6.4)。
        let overflow: Int
        /// 紧急度:2 = 关联正在动的事或今天出现过的人。
        let urgency: Int

        var id: String { "\(objectKind)/\(objectID)/\(sessionID.map(String.init) ?? "-")" }
        /// **组内取最大,不取平均**(技术方案 §4.6.2)。取平均会把一张含
        /// 「进展确认卡」(序 1)的合并卡拉到「结案卡」后面,而它恰恰最该问。
        var importance: Int { rows.map(\.importance).max() ?? 0 }
        var score: Int { importance * urgency }
        /// 计入预算按**合并后**算 1 张(PRD §4.6.2.1)。
        var budgetCost: Int { 1 }
    }

    /// 一张合并卡最多装几条(PRD §4.6.2.1)。
    static let mergeLimit = 5
    /// 场次卡下最多挂几张(PRD §4.6.2「呈现量」)。
    static let onSessionLimit = 2
    /// 一场产生超过这么多张 ⇒ 一张都不推,记日志(PRD §4.6.4)。
    static let abnormalPerSession = 10

    // MARK: - 队列

    /// 推送队列:合并 → 排序 → 取前 `budget` 张。
    ///
    /// 🔴 **合并在排序取前 B 之前**(技术方案 §4.6.4)。反过来先取前 B 再合并,
    /// `B` 就成了「合并前的张数」,而 PRD 写的是合并后算 1 张。
    static func pushQueue(now: Date, budget: Int, in db: Database) throws -> [Merged] {
        // ⚠️ 不用 `filter { try! … }` —— 那是「查库出错就崩」。
        // 崩在这里的表现是**打开 App 直接闪退**,而真因是一句 SQL。
        var eligible: [Row] = []
        for r in try fetch(db) where try isPushable(r, now: now, db: db) { eligible.append(r) }
        let merged = try merge(eligible, now: now, in: db)
        // 🔴 **全序**:同分按最早产生时间正序(先发生的先问)。
        // 不定 tie-break 的后果不是「顺序随便」,是每次取前 B 张**取到的不是同一批** ——
        // 用户看到的「今天这几张」会漂,而不会有任何东西报错。
        return merged.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            let a = $0.rows.map(\.createdAt).min() ?? "", b = $1.rows.map(\.createdAt).min() ?? ""
            return a != b ? a < b : $0.id < $1.id
        }.prefix(budget).map { $0 }
    }

    /// 场次卡下挂的(最多 2 张);其余在详情页,不限量。
    static func onSession(_ sessionID: Int64, now: Date, in db: Database) throws -> [Merged] {
        try Array(merge(fetch(db).filter { $0.sessionID == sessionID },
                        now: now, in: db).prefix(onSessionLimit))
    }

    // MARK: - 资格

    /// 能不能进**推送**队列。资格问题,不是排序问题(技术方案 §4.6.2)。
    static func isPushable(_ r: Row, now: Date, db: Database) throws -> Bool {
        guard r.state == .pending else { return false }        // 搁置 = 永不再推送
        guard let kind = CardTrigger.Kind(rawValue: r.kind) else { return false }
        // 地基卡默认不推送(升格由 M3-B2 判);收尾卡不占预算、即时出
        guard kind != .identity, kind != .wrapUp else { return false }
        // 推送有效期 1 天:当天没点的次日收进页面,不再进队列
        if let pushed = ISO8601DateFormatter.growth.date(from: r.pushedAt ?? ""),
           now.timeIntervalSince(pushed) > 86_400 { return false }
        // 一场产生 >10 张 ⇒ 一张都不推(异常量本身是信号)
        if let s = r.sessionID {
            let n = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM cards WHERE session_id = ? AND withdrawn_at IS NULL
                """, arguments: [s]) ?? 0
            if n > abnormalPerSession { return false }
        }
        return true
    }

    // MARK: - 取数

    static func fetch(_ db: Database) throws -> [Row] {
        try GRDB.Row.fetchAll(db, sql: """
            SELECT c.id, c.kind, k.priority, c.object_kind, c.object_id, c.session_id,
                   c.body, c.quote, c.line_id, c.created_at, c.pushed_at,
                   (SELECT j.action FROM judgment_current jc
                      JOIN judgments j ON j.id = jc.judgment_id
                     WHERE jc.target_kind = 'card' AND jc.target_id = CAST(c.id AS TEXT)) AS action
              FROM cards c
              JOIN card_kinds k ON k.kind = c.kind
             WHERE c.withdrawn_at IS NULL
             ORDER BY c.created_at, c.id
            """).map { r in
            Row(id: r["id"], kind: r["kind"], priority: r["priority"],
                objectKind: r["object_kind"], objectID: r["object_id"], sessionID: r["session_id"],
                body: r["body"], quote: r["quote"], lineID: r["line_id"],
                createdAt: r["created_at"], pushedAt: r["pushed_at"],
                state: State.byAction[(r["action"] as String?) ?? ""] ?? .pending)
        }
    }

    // MARK: - 合并

    static func merge(_ rows: [Row], now: Date, in db: Database) throws -> [Merged] {
        var groups: [String: [Row]] = [:]
        var order: [String] = []
        for r in rows {
            let key = "\(r.objectKind)/\(r.objectID)/\(r.sessionID.map(String.init) ?? "-")"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(r)
        }
        let moving = try movingMatterIDs(now: now, in: db)
        let seenToday = try personsSeenToday(now: now, in: db)
        return try order.map { key in
            // 装哪 5 条:**按同一把尺子取前 5**(技术方案 §4.6.4),不是随机、不是产生顺序 ——
            // 否则「留下的恰好是最不重要的 5 条」也不会有任何东西报错。
            let all = groups[key]!.sorted {
                $0.importance != $1.importance ? $0.importance > $1.importance
                                               : $0.createdAt < $1.createdAt
            }
            let head = groups[key]!.first!
            let hot = head.objectKind == "事" ? moving.contains(head.objectID)
                                              : seenToday.contains(head.objectID)
            return Merged(objectKind: head.objectKind, objectID: head.objectID,
                          sessionID: head.sessionID,
                          rows: Array(all.prefix(mergeLimit)),
                          overflow: max(0, all.count - mergeLimit),
                          urgency: hot ? 2 : 1)
        }
    }

    /// 「正在动的事」。**读 `MatterBoardProjection` 的口径,不另写判据。**
    private static func movingMatterIDs(now: Date, in db: Database) throws -> Set<String> {
        Set(try MatterBoardProjection.board(now: now, in: db).moving.map { String($0.id) })
    }

    /// 今天出现过的人。
    private static func personsSeenToday(now: Date, in db: Database) throws -> Set<String> {
        let day = AudioRetention.dayKey(now)
        return Set(try String.fetchAll(db, sql: """
            SELECT DISTINCT CAST(ls.person_id AS TEXT)
              FROM line_speakers ls
              JOIN transcript_lines tl ON tl.line_id = ls.line_id
              JOIN transcripts t ON t.id = tl.transcript_id
              JOIN sessions s ON s.id = t.session_id
             WHERE s.day = ?
            """, arguments: [day]))
    }
}

/// 卡片五页的**真 DDL 夹具**(照 `MatterFixtures.inMemoryBoard` 的模式,不手写 JSON)。
enum CardFixtures {

    /// 一场里同一件事三张卡(该合并)+ 另一件事一张 + 一张地基卡(不该进队列)。
    static func inMemoryQueue(now: Date) throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(q)
        let iso = ISO8601DateFormatter.growth
        func at(_ minutesAgo: Int) -> String {
            iso.string(from: now.addingTimeInterval(-Double(minutesAgo) * 60))
        }
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, ?, ?, ?, ?)
                """, arguments: [at(120), AudioRetention.dayKey(now),
                                 SessionBridge.Source.recording, SessionBridge.Status.closed])
            // 一件「正在动的」事(今天有进展)与一件停了很久的
            for (id, title, stalledDays) in [(1, "产品定位", 0), (2, "办公室要不要换", 40)] {
                try db.execute(sql: """
                    INSERT INTO matters (id, title, state, created_at, updated_at)
                    VALUES (?, ?, '活跃', ?, ?)
                    """, arguments: [id, title, at(60 * 24 * 60), at(60)])
                try db.execute(sql: """
                    INSERT INTO matter_timeline (matter_id, at, summary) VALUES (?, ?, ?)
                    """, arguments: [id,
                                     iso.string(from: now.addingTimeInterval(-Double(stalledDays) * 86_400)),
                                     "\(title) 有了新说法"])
            }
            // (卡型, 对象类型, 对象, 场次, 几分钟前)
            let cards: [(CardTrigger.Kind, String, String, Int64?, Int)] = [
                (.stance,          "事", "1", 1, 30),   // ↘ 同一对象同一场次
                (.progressConfirm, "事", "1", 1, 25),   // ↙ 三张该合并成一张
                (.nomination,      "事", "1", 1, 20),
                (.closing,         "事", "2", 1, 40),   // 另一件事:停了 40 天 ⇒ 不紧急
                (.identity,        "人", "7", 1, 10),   // 地基卡:默认不推送
                (.wrapUp,          "事", "1", 1,  5),   // 收尾卡:不占预算、即时出
            ]
            for (kind, ok, oid, sid, mins) in cards {
                try db.execute(sql: """
                    INSERT INTO cards (kind, object_kind, object_id, session_id, body, quote,
                                       created_at, pushed_at)
                    VALUES (?, ?, ?, ?, ?, '我不太认同', ?, NULL)
                    """, arguments: [kind.rawValue, ok, oid, sid,
                                     "\(kind.rawValue):要不要记下来?", at(mins)])
            }
        }
        return q
    }
}
