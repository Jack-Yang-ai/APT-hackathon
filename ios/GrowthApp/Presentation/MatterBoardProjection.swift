import Foundation
import GRDB

/// 事列表的展示模型(M2-0e,对 `docs/H5施工规格` §1.1 的字段表)。
///
/// ## 一条纪律:局面数字**全部在这里派生**,库里一列都不落
///
/// §1.1 的字段表里有六个「派生」:活跃件数、未关悬点数、最近活动时间、
/// 停滞天数、唤醒标、待处理候选是否存在。它们**没有一个**存在 `matters` 上
/// (迁移 v19 的注释与 `MatterSchemaTests` 那道对撞守着这件事)。
///
/// 理由不是省一列:存下来就是同一件事两个出处,而**对不上时不会报错** ——
/// 只会让局面那一屏显示一个谁都解释不了的数,而且没人知道该信哪个。
///
/// ## 「有自由度」的口径在这里定死,不留给实现
///
/// M2-0e 的验收原话:「推动者」等有自由度的局面计数口径**在这里定死**。
/// 本文件里凡是带 `口径:` 的注释都是那种 —— 它们不是实现细节,是契约。
enum MatterBoardProjection {

    /// 列表上的一件事。
    struct Row: Equatable, Identifiable {
        let id: Int64
        let title: String
        let state: String
        /// 还悬着的悬点数。**口径:`closed_at IS NULL` 才算悬着** ——
        /// 不落 `is_open` 布尔列,因为那是同一件事的第二个出处。
        let openQuestions: Int
        /// 最近一条脉络的时刻。nil = 这件事还没有任何进展(**不是「今天」**,
        /// 拿 `created_at` 顶上去会让一件从没动过的事看起来刚动过)。
        let lastActivityAt: String?
        /// 停滞天数。**口径:`now − 最近一条进展`,没有进展则 nil** ——
        /// §1.1 写的是「18 天没推进」,而「从没推进过」与「18 天没推进」
        /// 是两种不同的话,不该被压成同一个数。
        let stalledDays: Int?
    }

    /// 一整屏。分档照 §1.1:正在动 / 其他活跃 / 沉睡。
    struct Board: Equatable {
        /// 「正在动的」。**口径:活跃 且 最近 `movingWindowDays` 天内有进展。**
        /// 这是 §1.1 里自由度最大的一处 —— 图纸只写了分档名,没给判据,
        /// 所以在这里定死,不留给 B4 各写一份。
        let moving: [Row]
        /// 其他活跃的(活跃,但窗口内没动静)
        let otherActive: [Row]
        let sleeping: [Row]
        /// 候选区有没有待处理的。§1.1:软入口靠它决定显不显示
        let hasPendingCandidates: Bool

        /// 头上那个「正在动的 · 4 件」。**派生,不另存。**
        var activeCount: Int { moving.count + otherActive.count }
    }

    /// 「最近有动静」的窗口。口径定死在这里,`MatterCapacity` 同理。
    static let movingWindowDays = 7

    /// 读一屏。`now` 传进来而不是取系统时间 —— 夹具与测试要能定死「今天是哪天」。
    static func board(now: Date, in db: Database) throws -> Board {
        let rows = try Row.fetchAll(db, now: now)
        let active = rows.filter { $0.state == "活跃" }
        let sleeping = rows.filter { $0.state == "沉睡" }
        let hasCandidates = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM matters WHERE state = '候选'
            """) ?? 0 > 0
        return Board(
            moving: active.filter { ($0.stalledDays ?? Int.max) < movingWindowDays },
            otherActive: active.filter { ($0.stalledDays ?? Int.max) >= movingWindowDays },
            sleeping: sleeping,
            hasPendingCandidates: hasCandidates)
    }
}

private extension MatterBoardProjection.Row {

    /// 一趟 SQL 把六个派生值一起算出来。
    ///
    /// ⚠️ **一趟,不是每件事再查一次悬点** —— N+1 在 200 件事上就是 200 次查询,
    /// 而 §4.2.6 那条 <100ms 的要求是全局的。
    static func fetchAll(_ db: Database, now: Date) throws -> [MatterBoardProjection.Row] {
        let iso = ISO8601DateFormatter.growth.string(from: now)
        return try Row.fetchAll(db, sql: """
            SELECT m.id, m.title, m.state,
                   (SELECT COUNT(*) FROM matter_open_questions q
                     WHERE q.matter_id = m.id AND q.closed_at IS NULL)   AS open_qs,
                   (SELECT MAX(t.at) FROM matter_timeline t
                     WHERE t.matter_id = m.id)                            AS last_at
              FROM matters m
             WHERE m.state IN ('活跃', '沉睡')
             ORDER BY last_at DESC, m.updated_at DESC
            """).map { row in
            let last: String? = row["last_at"]
            // 天数按**整数秒**算,不用 julianday —— 浮点会把 47 分钟算成 46 分,
            // 同一个坑 `HomeProjection` 的注释里记着。
            let stalled = last.flatMap { ISO8601DateFormatter.growth.date(from: $0) }
                              .map { Int(now.timeIntervalSince($0)) / 86_400 }
            _ = iso
            return .init(id: row["id"], title: row["title"], state: row["state"],
                         openQuestions: row["open_qs"],
                         lastActivityAt: last, stalledDays: stalled)
        }
    }
}

/// 夹具管道(M2-0e 验收:一条命令出全部页面的夹具,**手写 JSON 夹具零处**)。
///
/// 🔴 **真 DDL 建内存库 → 灌假行 → 跑真 projection 查询。**
///
/// 手写一份 JSON 当夹具是最容易的做法,也是 `M1-17`「界面承诺了不存在的东西」
/// 的成因:JSON 想写什么字段就有什么字段,而**库里根本没有那一列**,
/// 直到联调那天才炸。走真 DDL 的话,库表一改前端线**当场编译红**。
enum MatterFixtures {

    /// 建一个灌好假数据的内存库。`now` 定死,免得夹具随跑的时间变。
    static func inMemoryBoard(now: Date) throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(q)
        let iso = ISO8601DateFormatter.growth
        func at(_ daysAgo: Int) -> String {
            iso.string(from: now.addingTimeInterval(-Double(daysAgo) * 86_400))
        }
        try q.write { db in
            for (title, state, days, qs) in [
                ("产品到底该定位成什么", "活跃", 0,  2),   // 今天动过 ⇒ 正在动
                ("要不要自己做 ASR",     "活跃", 2,  1),
                ("招人的节奏怎么定",     "活跃", 18, 3),   // 18 天没推进 ⇒ 其他活跃
                ("办公室要不要换",       "沉睡", 40, 0),
                ("年底复盘怎么做",       "候选", 0,  0),   // 候选:只让软入口亮起来
            ] as [(String, String, Int, Int)] {
                try db.execute(sql: """
                    INSERT INTO matters (title, state, created_at, updated_at)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [title, state, at(60), at(days)])
                let id = db.lastInsertedRowID
                for i in 0..<qs {
                    try db.execute(sql: """
                        INSERT INTO matter_open_questions (matter_id, question, opened_at)
                        VALUES (?, ?, ?)
                        """, arguments: [id, "\(title) · 悬点 \(i + 1)", at(days)])
                }
                // 候选没有脉络 —— 它还没被立成一件事
                if state != "候选" {
                    try db.execute(sql: """
                        INSERT INTO matter_timeline (matter_id, at, summary)
                        VALUES (?, ?, ?)
                        """, arguments: [id, at(days), "\(title) 有了新说法"])
                }
            }
        }
        return q
    }
}
