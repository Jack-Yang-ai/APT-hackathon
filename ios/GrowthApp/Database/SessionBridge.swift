import Foundation
import GRDB

/// 录音账本 → `sessions` 表的桥。
///
/// ## 为什么需要它
///
/// M0 结束时有一个断裂:录音把块写进**账本文件**(`BlockLedger`),而首页要读的是
/// **`sessions` 表** —— 而**没有任何代码在写那张表**。所以在接上这座桥之前,
/// 把 `HomeProjection` 接到界面上只会渲染一个永远为空的列表:看着像功能,其实是装饰。
///
/// ## 幂等由数据库保证,不靠调用方自觉
///
/// 这座桥会被反复调用(每次进前台、每次录完)。靠调用方记得「先查再插」迟早出重复,
/// 而重复的场次行会一路污染下游(旧仓实测悬空 1979 条就是这么来的)。
/// 所以 `sessions(source, started_at)` 上有唯一索引(迁移 v8),重复插入由 **DB 挡**。
/// 同一个道理已经用在 `voiceprints.instruction_id`(§1.3 的幂等键)上。
///
/// ## 两条来路,一个写函数
///
/// 🔴 ~~「`source` 固定 `recording`。导入的历史音频由导入那条链自己写 ——
/// 两条来路共用一个写函数,就没法在唯一索引上把它们分开。」~~
/// **2026-08-17 作废(仓规 5:标注,不删)。** 那句话的后半是错的:
/// 唯一索引本来就是 `(source, started_at)` —— `source` 作为参数传进来,
/// 两条来路在索引上**天生分得开**,反而是各写一个 INSERT 才会让
/// 「sessions 的写方是谁」出现第二个答案。
///
/// 所以 `source` 现在是入参(闭集见 `Source`),录音与导入共用这一个写方。
///
/// 🔴 ~~「`source` 现在是**入参**」~~ **2026-08-24 作废(`M2-审6`,仓规 5:标注不删)。**
/// 上面那段推理只走了一半:它论证了「两条来路在索引上分得开」,却没有回答
/// **谁有资格说这一场是哪条来路**。做成入参的后果是由**谁在读**决定 ——
/// 而账本是两条来路共用的一本,于是同一场被两个读者各写一行,
/// 而下游 `blocks(of:)` 只按 `started_at` 找块,两行指向同一批块
/// ⇒ **同一段音频转写两次,真花两笔钱**。
/// 现在来源写在账本条目上(`LedgerEntry.source`),`sync` 从每条 summary 上取,
/// **入参已经删掉**。
enum SessionBridge {

    /// 录音场次在 `sessions.source` 里的取值。
    static let source = Source.recording

    /// `sessions.source` 的闭集。**来路必须分得开**(手机录、导入、手表录),否则账对不上:
    /// 「今天录了几场」「这个月的转写花了多少钱」都要按来路分开算,
    /// 而导入一段五小时的老录音会把当天的成本曲线整个抬起来。
    ///
    /// ⚠️ 与 `Status` 同一个处境:**库里还没有 CHECK 约束**(v1 的 DDL
    /// `source TEXT NOT NULL` 没有闭集)。这里先把事实记下来,免得下一处
    /// 写代码的人再猜一遍;真要定成契约得在 §3.1.2 里写死并加一条迁移。
    /// 取值定义在 `SessionSource`(手表 target 也要用,不能挂在带 GRDB 的这里)。
    typealias Source = SessionSource

    /// `sessions.grade` 的闭集,逐条对应 PRD §4.1.6 的四档。
    ///
    /// ⚠️ **这四个字面量与迁移 v9 的 CHECK 约束是同一份契约的两半。**
    /// 改这里而不改迁移,写入会在运行时被 DB 拒绝(这是好事 —— 失败可见);
    /// 改迁移而不改这里,则老库里会留下这一侧读不出来的值。**两边一起改,或者都别改。**
    ///
    /// 没有 `case ungraded`:「还没评级」是 `grade IS NULL`。
    /// 给它一个字面量会让「没评过」和「评过了是某档」挤进同一个取值空间。
    enum Grade: String, CaseIterable {
        case full            = "full"              // 完整:出纪要五块 + 进事与人
        case light           = "light"             // 轻量:只出要点
        case transcriptOnly  = "transcript_only"   // 只转写:可搜索,首页折进「零碎」
        case discard         = "discard"           // 丢弃:不转写、不存
    }

    /// `sessions.grade_source` 的取值:要么是判它的模型 id,要么是这个字面量。
    ///
    /// 存在的理由是全局规则 G1 —— **新写入的判断 100% 带来源与依据**。
    /// 「这一场不值得花钱」是一个判断,判错了会静默吞掉一场真会议,
    /// 事后必须查得出是规则判的还是某个模型判的。
    static let gradeSourceRule = "rule"

    /// `sessions.status` 的两个取值。**这是本仓当前的事实口径**:
    /// `ContentAndTaskTests` 造数用的就是 `closed`,文档只写了「场次状态机」没有枚举值。
    /// ⚠️ 真要定成契约,得在 §3.1.2 里写死并加 CHECK —— 现在只是把事实记下来,
    /// 免得下一处写代码的人再猜一遍。
    enum Status {
        static let open = "recording"     // 还在录,没封场
        static let closed = "closed"      // 已封场
    }

    /// 把账本里的场次同步进 `sessions`。→ (新建了几条, 更新了几条)
    ///
    /// - Parameter day: `sessions.day`,形如 `2026-08-08`。账本一个目录一天,
    ///   所以这个值由调用方按目录给,不从时间戳反推(反推会在跨零点那场上出错)。
    @discardableResult
    static func sync(_ sessions: [BlockLedger.SessionSummary], day: String,
                     in writer: some DatabaseWriter) throws -> (inserted: Int, updated: Int) {
        var inserted = 0, updated = 0
        try writer.write { db in
            for s in sessions {
                let proposedStart = iso(s.startedAt)
                // 🔴 **来源取自这一场自己,不是入参**(`M2-审6`,2026-08-24)。
                // 原来 `source` 是整个调用的入参,于是「这一场是谁写的」由
                // **谁在读**决定:导入读整本按 `import` 写,首页刷新读同一本
                // 按 `recording` 写,同一场落两行。现在参数没了 ⇒
                // **「整本账按一个来源同步」在类型上不可表达**,不是「现在没人这么干」。
                let source = s.source
                // ISO偏移是展示信息,身份是同一时刻。保留第一次落库的钟面字面串。
                let existingStart = try String.fetchOne(db, sql: """
                    SELECT started_at FROM sessions WHERE source = ?
                       AND strftime('%s', started_at) = strftime('%s', ?)
                     ORDER BY id LIMIT 1
                    """, arguments: [source, proposedStart])
                let startedAt = existingStart ?? proposedStart
                let existed = existingStart != nil

                // ⚠️ 只更新 ended_at 与 status。**day 与 started_at 不在更新列里** ——
                // 它们是这一行的身份,改了就等于把一场偷偷变成另一场。
                try db.execute(sql: """
                    INSERT INTO sessions (started_at, ended_at, day, source, status)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(source, started_at) DO UPDATE SET
                      ended_at = excluded.ended_at,
                      status   = excluded.status
                    """, arguments: [startedAt, s.endedAt.map(iso), day, source,
                                     s.isOpen ? Status.open : Status.closed])
                if existed { updated += 1 } else { inserted += 1 }
            }
        }
        return (inserted, updated)
    }

    /// 进程刚起来:把**上一次没收尾的场次**收掉。→ 被收掉的场次 id
    ///
    /// ## 不收的话它永远出不来
    ///
    /// 进程被杀时账本里没有 `sessionEnded` ⇒ `isOpen == true` ⇒ 这里写
    /// `status = 'recording'`。于是两件事同时发生:
    /// · 首页**无条件**显示「录音中 N 分钟」(那个态压过一切)
    /// · `enqueueClosedSessions` 只捞 `closed` ⇒ **永远不入队**
    ///
    /// 当天再录一场时 `BlockLedger.sessions` 有一条补救(「上一场没收尾就先结掉」),
    /// 但**跨天之后账本不再被读**(只读今天的目录)—— 那一场就永久钉在「录音中」,
    /// 音频好好躺在盘上,而永远没有人处理它。
    ///
    /// ## 判据是「进程刚起来」,不是超时
    ///
    /// 与 `TaskQueue.reclaimInterrupted` 同一条:进程刚起来的那一刻,
    /// 按定义没有任何场次正在录 —— 所以不需要「多久算废弃」这个参数,
    /// 也不会误伤真在录的那一场。
    ///
    /// ## `ended_at` 填什么才诚实
    ///
    /// **最后一个块的结束时刻** —— 那是我们最后一次有证据证明它还在录
    /// (与 `BlockLedger.sessions` 里那条补救同一个口径,不另立一套)。
    /// 一个块都没有的场次说明它什么都没录到,用起点收口,长度为零,
    /// 如实呈现「开了但没录上」。**不填「现在」** —— 那会把一场 3 分钟的录音
    /// 说成横跨两天。
    @discardableResult
    static func closeAbandoned(in db: DatabaseQueue) throws -> [Int64] {
        let open = try db.read { d in
            try Row.fetchAll(d, sql: """
                SELECT id, started_at FROM sessions WHERE status = ? AND source != ?
                """, arguments: [Status.open, Source.watch])
        }
        guard !open.isEmpty else { return [] }

        var closed: [Int64] = []
        for row in open {
            guard let id = row["id"] as Int64?,
                  let startedAt = row["started_at"] as String? else { continue }
            // 块清单从账本来(`ProcessingPump.blocks` 按**这一场自己的日期**找目录),
            // 所以跨多少天都读得到。
            let blocks = ProcessingPump.blocks(of: id, ext: "m4a", in: db)
            let endedAt: String
            if let last = blocks.max(by: { $0.offsetMs < $1.offsetMs }),
               let start = ISO8601DateFormatter.growth.date(from: startedAt) {
                endedAt = iso(start.addingTimeInterval(Double(last.offsetMs + last.durationMs) / 1000))
            } else {
                endedAt = startedAt
            }
            try db.write { d in
                try d.execute(sql: """
                    UPDATE sessions SET status = ?, ended_at = ? WHERE id = ? AND status = ?
                    """, arguments: [Status.closed, endedAt, id, Status.open])
            }
            closed.append(id)
        }
        return closed
    }

    /// 本地时区 ISS8601,与 §3.1.2 一致 —— `started_at` 存的就是**当时用户看到的钟点**,
    /// 转成 UTC 会让首页上的「14:00」在别的时区变成另一个数。
    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }
}
