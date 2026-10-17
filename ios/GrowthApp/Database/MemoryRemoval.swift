import Foundation
import GRDB

/// 「移出记忆」= 唯一受控的 redact 通道(§3.1.7,判 3)。
///
/// 这是**全库唯一**允许改动 `transcript_lines` 的代码路径。别处任何 UPDATE 都会被
/// A1 触发器 ABORT——通道之所以能过,是因为它写出的变更恰好符合触发器放行的那一种形状
/// (`redacted` 0→1、`text` 置墓碑、其余列一字不动),而不是因为它有什么特权开关。
///
/// 两件事的顺序是刻意的:**先提交数据库,再删音频**。
/// 反过来的话,一旦落库失败,音频已经没了却没有墓碑,数据对不上且不可逆。
enum MemoryRemoval {
    static let changed = Notification.Name("GrowthMemoryRemoved")

    /// 脱敏占位文本。§3.1.7 只说「置脱敏占位」,没规定具体字样,这里定死一个常量,
    /// 免得各处各写一个、将来没法用一条断言查「哪些行是墓碑」。
    static let tombstoneText = "〔已移出记忆〕"

    /// **「这一场已经被移出记忆」的唯一判据**(M1-22)。
    ///
    /// 用户拍板卡片不保留 ⇒ 首页列表、日期计数、任何「有哪些场次」的地方
    /// 都要按它过滤。**三处以上会用到,所以定义只放这一份**(铁律 4)。
    ///
    /// 🔴 ~~判据是「有行,而且全是墓碑」(纯派生,不加列 —— 加列就是第二个出处)~~
    /// **2026-08-19 作废,用户实机报「删不掉」。**
    ///
    /// 那个判据挡住了**一场根本没转写出行的录音**:删它 ⇒ 0 行置墓碑 ⇒
    /// 判据永远不成立 ⇒ **卡片永远在**。而转写失败、卡住、录废了的那些
    /// 恰恰最需要能删。
    ///
    /// ⚠️ **我当时援引铁律 4 反对加列,那是把它用错了地方。** 铁律 4 管的是
    /// 「同一个事实存了两份而对不上时不报错」;而**「用户删过这一场」不是一个
    /// 能从内容推出来的事实** —— 没有内容可推。删除是判断,不是派生量。
    /// 加「有行」那个条件本身没错(不加的话正在处理中的场次会凭空消失),
    /// 错的是试图从内容里推出一个用户动作。
    ///
    /// 现在的判据只看 `removed_at`(v21):**它由 `removeSession` 在同一个事务里写**,
    /// 与置墓碑一起成功或一起失败,所以不存在「删了内容却没写标记」的中间态。
    static let removedSessionPredicate = "s.removed_at IS NOT NULL"

    struct Outcome: Equatable {
        /// 本次真正立成墓碑的行数(已经是墓碑的不重复计)
        let redactedLines: Int
        /// 本次物理删除的音频文件数
        let deletedAudioFiles: Int
    }

    enum Failure: Error, CustomStringConvertible {
        case audioStillOnDisk([URL])
        case watchSessionStillOpen

        var description: String {
            switch self {
            case .watchSessionStillOpen:
                return "手表这场录音尚未结束,先在手表上结束并同步收尾后再删除"
            case .audioStillOnDisk(let urls):
                return "移出记忆失败:转写已立墓碑,但音频仍在磁盘上 —— \(urls.map(\.lastPathComponent))"
            }
        }
    }

    // MARK: - 派生内容一起立墓碑(M1-22,用户 2026-08-19 拍板「三档全清」)

    /// 转写正文之外,**还有几份内容是从它派生出来的**。删除必须一起清,
    /// 否则「移出记忆」没有做到它说的事。
    ///
    /// 🔴 **这个仓早就知道 `quote` 是重复的**:`TranscriptRevision.quoteTables` 就是
    /// 这四张表 —— 改一个错字时会去同步改写 quote,注释还写着「新增第五张带引文的表时
    /// 三处都要加」。**改字会同步,删除不会同步** —— 三处消费方里,删除那一处
    /// 从来没被算进去,而那正是 2026-08-19 用户实机问出来的。
    ///
    /// ⚠️ **`MemoryRemoval` 自己的注释里为音频那半写过一模一样的判断**
    ///(「只立墓碑、音频留着 —— 那句话还在盘上」),那条推理当时只用在音频上。
    /// quote 是同一个形状:正文之外的第二份逐字副本。
    ///
    /// ## 为什么自由文本也清(第二档)
    ///
    /// 用户拍板:「我既然要删除肯定有删除的理由」。
    /// **半清比不清更危险** —— 逐字原话没了而概括还在,用户会以为删干净了。
    ///
    /// - Parameter lineFilter: 命中哪些行的 SQL 条件(用 `line_id` 那一列)。
    static func tombstoneDerived(sql lineFilter: String, arguments: StatementArguments,
                                 in db: Database) throws -> Int {
        try AskStore.removeDependentAnswers(lineFilter: lineFilter, arguments: arguments, in: db)
        var n = 0
        // 整场判断的证据可跨 part；移出任一上下文行都清这场的 AI 原话副本。
        for table in ["action_candidates", "action_assessments"] {
            try db.execute(sql: """
                DELETE FROM \(table) WHERE transcript_id IN (
                  SELECT id FROM transcripts WHERE session_id IN (
                    SELECT session_id FROM transcripts WHERE id IN (
                      SELECT transcript_id FROM transcript_lines WHERE \(lineFilter))))
                """, arguments: arguments)
            n += db.changesCount
        }
        // 四张带 line_id + quote 的表。**列名各不相同,所以逐张写** ——
        // 硬凑一个统一形状会让「新增第五张表」更容易被漏掉,而不是更难。
        let tables: [(String, [String])] = [
            ("summary_key_points",  ["text", "quote"]),
            ("summary_commitments", ["what", "to_whom_text", "quote"]),
            ("summary_stances",     ["stance", "premise", "quote"]),
            ("summary_pendings",    ["issue", "parties_text", "quote"]),
        ]
        for (table, columns) in tables {
            // 已经是墓碑的不重复计 —— 与 `removeSession` 的幂等口径一致。
            let sets = columns.map { "\($0) = ?" }.joined(separator: ", ")
            let guardClause = columns.map { "\($0) IS NOT ?" }.joined(separator: " OR ")
            // 🔴 **参数按 SQL 里占位符出现的顺序拼:SET → 子查询 → 守卫。**
            // 第一版写成 SET → 守卫 → 子查询,于是 `session_id = ?` 收到的是墓碑文本
            // ⇒ 一行都不匹配,**而 UPDATE 成功返回、changesCount = 0** ——
            // 「删了」和「没删成」在返回值上一模一样。测试当场抓到的就是它。
            let stamps: [DatabaseValueConvertible?] = columns.map { _ in tombstoneText }
            try db.execute(sql: """
                UPDATE \(table) SET \(sets)
                 WHERE line_id IN (SELECT line_id FROM transcript_lines WHERE \(lineFilter))
                   AND (\(guardClause))
                """, arguments: StatementArguments(stamps) + arguments + StatementArguments(stamps))
            n += db.changesCount
        }
        // 事的脉络:进展摘要也是从那几行派生的。
        try db.execute(sql: """
            UPDATE matter_timeline SET summary = ?
             WHERE line_id IN (SELECT line_id FROM transcript_lines WHERE \(lineFilter))
               AND summary IS NOT ?
            """, arguments: [tombstoneText] + arguments + [tombstoneText])
        n += db.changesCount
        // 事件(`M5-1`,详情页的段落):摘要是那一段的**概括**,删掉的话很可能就写在里面。
        // 范围盖到任何一行被删的行 ⇒ 整段标题与摘要一起清(半清比不清更危险,见上)。
        // 老产物没有范围(两端为 NULL)⇒ 不知道盖没盖到,**按盖到处理** —— 隐私上宁可多清。
        // ⚠️ 与整场的一句话不同:一句话在删几行时不动(见 `removeLines`),
        // 因为它太短、几乎不会逐字带出某一句;事件摘要是一到几段,会。
        try db.execute(sql: """
            UPDATE summary_events SET title = ?, summary = ?
             WHERE EXISTS (SELECT 1 FROM transcript_lines
                            WHERE (\(lineFilter))
                              AND transcript_lines.transcript_id = summary_events.transcript_id
                              AND (summary_events.first_line_id IS NULL
                                   OR summary_events.last_line_id IS NULL
                                   OR transcript_lines.line_id BETWEEN summary_events.first_line_id
                                                               AND summary_events.last_line_id))
               AND (title IS NOT ? OR summary IS NOT ?)
            """, arguments: [tombstoneText, tombstoneText] + arguments + [tombstoneText, tombstoneText])
        n += db.changesCount
        return n
    }

    /// 整场的一句话与主题词。**按 transcript 清** —— 它们没有 `line_id`,
    /// 是整场的产物,而整场都被移出记忆了。
    static func tombstoneSessionLevel(sessionID: Int64, in db: Database) throws -> Int {
        var n = 0
        try db.execute(sql: """
            UPDATE summaries SET one_liner = ?
             WHERE transcript_id IN (SELECT id FROM transcripts WHERE session_id = ?)
               AND one_liner IS NOT ?
            """, arguments: [tombstoneText, sessionID, tombstoneText])
        n += db.changesCount
        // 主题词没有引文,但它本身就是内容的浓缩(「聊了什么」)。
        try db.execute(sql: """
            UPDATE summary_topic_keys SET key = ?
             WHERE transcript_id IN (SELECT id FROM transcripts WHERE session_id = ?)
               AND key IS NOT ?
            """, arguments: [tombstoneText, sessionID, tombstoneText])
        n += db.changesCount
        // 事件的标题与摘要(`M5-1`)。行级那条在整场删除时也会走到,这里再兜一次整场 ——
        // 两条都幂等,重复跑是 0 行。
        try db.execute(sql: """
            UPDATE summary_events SET title = ?, summary = ?
             WHERE transcript_id IN (SELECT id FROM transcripts WHERE session_id = ?)
               AND (title IS NOT ? OR summary IS NOT ?)
            """, arguments: [tombstoneText, tombstoneText, sessionID, tombstoneText, tombstoneText])
        n += db.changesCount
        return n
    }

    /// 把一个场次移出记忆。
    ///
    /// - 幂等:只挑 `redacted = 0` 的行动手,重复调用第二次是 0 行,不会撞 A1 触发器。
    /// - 音频删除做完会**回读一次**:只要还有文件在就抛。
    ///   「以为删了其实没删」在隐私上是最贵的一种静默失败,不能只看 removeItem 没报错。
    @discardableResult
    /// - Parameter now: 写进 `sessions.removed_at` 的时刻。默认取当下,
    ///   留成入参是为了测试能钉死一个值(与本仓其余写路径同一条口径)。
    static func removeSession(_ sessionID: Int64,
                              audioFiles: [URL],
                              now: String = ISO8601DateFormatter.growth.string(from: Date()),
                              fileManager: FileManager = .default,
                              in writer: some DatabaseWriter) throws -> Outcome {

        return try RecordingPaths.withFileAccess {
        let redacted = try writer.write { db -> Int in
            let openWatch = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = ? AND source = ? AND status = ?)",
                arguments: [sessionID, SessionSource.watch, SessionBridge.Status.open]) ?? false
            guard !openWatch else { throw Failure.watchSessionStillOpen }
            try db.execute(sql: """
                UPDATE transcript_lines
                   SET text = ?, redacted = 1
                 WHERE redacted = 0
                   AND transcript_id IN (SELECT id FROM transcripts WHERE session_id = ?)
                """, arguments: [tombstoneText, sessionID])
            let n = db.changesCount
            try blankRevisions(sql: """
                line_id IN (SELECT line_id FROM transcript_lines
                             WHERE transcript_id IN (SELECT id FROM transcripts
                                                      WHERE session_id = ?))
                """, arguments: [sessionID], in: db)
            // M1-22:派生内容跟着立墓碑。**同一个事务** ——
            // 分开写的话,中间失败会留下「正文没了而纪要还在」的半清状态,
            // 而那正是用户拍板时说的「比不清更危险」的那种。
            _ = try tombstoneDerived(
                sql: """
                transcript_id IN (SELECT id FROM transcripts WHERE session_id = ?)
                """, arguments: [sessionID], in: db)
            _ = try tombstoneSessionLevel(sessionID: sessionID, in: db)
            // 🔴 **标记与置墓碑同一个事务** —— 分开写会留下「内容删了而卡片还在」
            // 或者反过来的中间态,而两种在界面上都看不出异常。
            // 幂等:重复删第二次这里是同一个值,不会出错。
            try db.execute(sql: "UPDATE sessions SET removed_at = ? WHERE id = ? AND removed_at IS NULL",
                           arguments: [now, sessionID])
            return n
        }
        NotificationCenter.default.post(name: changed, object: nil)
        return try Outcome(redactedLines: redacted,
                           deletedAudioFiles: deleteAudio(audioFiles, fileManager))
        }
    }

    /// 把**几行**移出记忆(§4.1.5 的另一半:「录到不该录的东西」)。
    ///
    /// ## 🔴 音频删的是**整块**,不是那几秒
    ///
    /// 音频按 5 分钟一块存,**删不了半块**。三条路:
    /// · 重编码把那几秒静音掉 —— 时长会因帧对齐漂几十毫秒,而块时长是
    ///   `BlockTiming` / `LineAudio` 算块内偏移的依据 ⇒ **整块的跳原话会静默错位**;
    /// · 只立墓碑、音频留着 —— 那句话还在盘上,「移出记忆」没有做到它说的事;
    /// · **删掉那几行所在的整块** —— 同块的邻居丢音频(文字还在)。
    ///
    /// 选第三条,理由是本仓 §3.1.7 自己的口径:**音频是可以接受丢的那一半**
    /// (它已经转写完了),而「不该录的东西还在盘上」是不能接受的那一半。
    /// 何况音频本来就只留 7 天(`AudioRetention`)。
    ///
    /// ⚠️ **代价必须在二次确认里说出来**:同一块里别的话会听不了。
    /// 不说的话用户下次想听那段,只会以为「音频功能坏了」。
    @discardableResult
    static func removeLines(_ lineIDs: [Int64], audioFiles: [URL],
                            fileManager: FileManager = .default,
                            in writer: some DatabaseWriter) throws -> Outcome {
        guard !lineIDs.isEmpty else { return Outcome(redactedLines: 0, deletedAudioFiles: 0) }
        let redacted = try writer.write { db -> Int in
            // ⚠️ 只动 `text` 与 `redacted`,其余每一列都得与 OLD 相等 ——
            // A1 触发器的 WHEN 条件就是这么写的,借 redact 之名顺手改别的会被 ABORT。
            let marks = Array(repeating: "?", count: lineIDs.count).joined(separator: ",")
            try db.execute(sql: """
                UPDATE transcript_lines SET text = ?, redacted = 1
                 WHERE redacted = 0 AND line_id IN (\(marks))
                """, arguments: StatementArguments([tombstoneText] as [any DatabaseValueConvertible]
                                                   + lineIDs))
            let n = db.changesCount
            try blankRevisions(sql: "line_id IN (\(marks))",
                               arguments: StatementArguments(lineIDs), in: db)
            // M1-22:这几行派生出去的引文与摘要也要清。
            // ⚠️ **整场那两张(`summaries` / `summary_topic_keys`)这里不动** ——
            // 删几行不等于整场没了,把整场的一句话抹掉是超出用户要求的破坏。
            _ = try tombstoneDerived(sql: "line_id IN (\(marks))",
                                     arguments: StatementArguments(lineIDs), in: db)
            return n
        }
        NotificationCenter.default.post(name: changed, object: nil)
        return try Outcome(redactedLines: redacted,
                           deletedAudioFiles: deleteAudio(audioFiles, fileManager))
    }

    /// 🔴 **把修订表里的原话一起清掉 —— 同一个事务里。**
    ///
    /// `transcript_line_revisions.before` 存的是**改错字之前的原话**。
    /// 只清 `transcript_lines` 而把它留着,等于「移出记忆」没有做到它说的事:
    /// 一句「录到了不该录的东西」如果**之前恰好被改过一个错字**,原话仍然躺在库里。
    ///
    /// 这不是「留痕不可删」与「移出记忆」两条原则打架 —— 前者保的是
    /// **「这一行改过」这个事实**,不是原文本身。所以照冻结层那条 redact 的形状:
    /// 内容清空、**行留着**,谁在什么时候改过它仍然查得到。
    ///
    /// ⚠️ **必须与立墓碑在同一个事务里。** 分两步的话,中间崩一次就会留下
    /// 「行已经是墓碑、而原话还在修订表」的状态 —— 而那个状态**没有任何东西会报错**,
    /// 界面上和「删干净了」一模一样。
    private static func blankRevisions(sql predicate: String,
                                       arguments: StatementArguments,
                                       in db: Database) throws {
        try db.execute(sql: """
            UPDATE transcript_line_revisions SET before = '', after = ''
             WHERE (before <> '' OR after <> '') AND \(predicate)
            """, arguments: arguments)
    }

    // MARK: - 云端那一半(M2-审12)

    /// 还没把云端副本删干净的场次。**泵每一拍捡一次。**
    ///
    /// 🔴 判据是 `removed_at IS NOT NULL AND cloud_purged_at IS NULL` ——
    /// 「移出记忆了,但云上还在」。这个集合非空就是**界面上那句承诺还没兑现**。
    ///
    /// ⚠️ 为什么不是「删的时候顺手调一次就完」:删云端要联网,而移出记忆
    /// **不能因为没网就不让做**。一次性调用的后果是没网那次悄悄失败,
    /// 而用户已经看到「删掉了」—— 承诺与事实分叉,且再没有人会回来补。
    static func pendingCloudPurge(in db: Database) throws -> [Int64] {
        try Int64.fetchAll(db, sql: """
            SELECT id FROM sessions
             WHERE removed_at IS NOT NULL AND cloud_purged_at IS NULL
             ORDER BY id
            """)
    }

    /// 这一场在云上那些对象的「号」—— 手机才知道,云端反查不出来(见 `ProxyClient.purgeSession`)。
    static func cloudKeys(of sessionID: Int64, in db: Database) throws
        -> (transcripts: [Int64], tasks: [Int64]) {
        // ⚠️ **全部版本,不是活跃版本。** 这里要删的是「云上还有什么」,
        // 而重整产生的旧版本 v1 同样在云上留过产物 —— 只删活跃那版
        // 等于把旧版本的纪要永久留在云端,而界面说的是「都会删掉」。
        (transcripts: try Int64.fetchAll(
            db, sql: "SELECT id FROM transcripts WHERE session_id = ?", arguments: [sessionID]),
         tasks: try Int64.fetchAll(
            db, sql: "SELECT task_id FROM tasks WHERE session_id = ?", arguments: [sessionID]))
    }

    /// 云端确认删干净之后才落这一笔。**在此之前不许说「已删完」。**
    static func markCloudPurged(_ sessionID: Int64, at now: String,
                                in writer: some DatabaseWriter) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE sessions SET cloud_purged_at = ? WHERE id = ?",
                           arguments: [now, sessionID])
        }
    }

    /// 音频不留墓碑,物理删。已经不在的当删过,保持整个操作可重跑。
    ///
    /// **删完回读一次**:只要还有文件在就抛 ——
    /// 「以为删了其实没删」在隐私上是最贵的一种静默失败。
    private static func deleteAudio(_ urls: [URL], _ fm: FileManager) throws -> Int {
        var deleted = 0
        for url in urls where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
            deleted += 1
        }
        let survivors = urls.filter { fm.fileExists(atPath: $0.path) }
        guard survivors.isEmpty else { throw Failure.audioStillOnDisk(survivors) }
        return deleted
    }
}
