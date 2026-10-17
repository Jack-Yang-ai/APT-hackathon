import Foundation
import GRDB

/// 把主库投影成「人」这一层(PRD §4.4)。与 `HomeProjection` 同构:
/// **SQL 只在这里,界面一句 SQL 都不写**——分开才测得动。
///
/// ## 「人」是谁:`persons` 表里的行,不含只有簇标签的说话人
///
/// 归属层有两种身份(`SpeakerNaming.keyExpr` 那张表):`person_id` 是**全局**的,
/// `cluster_tag` **只在一场之内有效**。分人模型每处理一个文件都从头编号——
/// 这一场的 `S0` 和下一场的 `S0` **是不同的人**。
///
/// 所以簇不进人列表,它们走「待确认说话人」。把簇摆进跨场次的人列表,
/// 等于替用户宣称两场的 `S0` 是同一个人,而那个判断只有声纹或用户做得了。
///
/// ## 排序:PRD 的权重只实现得了一半,这里如实降级
///
/// PRD §4.4.2 定的是「距上次见面时长 × **未兑现承诺数**」。后一半算不出来:
/// `summary_commitments` 只有 `what` / `to_whom_text`,**既没有方向(他→你 / 你→他)
/// 也没有兑现状态**(施工规格 §2.3)。缺方向的话「他答应你的」和「你答应他的」
/// 分不开,乘出来的权重是个看起来很合理的错数。
///
/// ⇒ 只按上次见面倒序。**这不是简化,是缺数据源**——`commitment_tracking`
/// 那张表建起来之后要回到这里把乘数补上。
enum PeopleProjection {

    // MARK: - 人列表

    static func peopleList(today: String, in reader: some DatabaseReader) throws -> PeopleList {
        try reader.read { db in
            let naming = try SpeakerNaming.labels(in: db)
            let aggregates = try personAggregates(in: db)
            let meIdentified = try SpeakerNaming.meIsIdentified(in: db)

            let me = aggregates.first { $0.id == SpeakerNaming.mePersonID }
            let others = aggregates
                .filter { $0.id != SpeakerNaming.mePersonID }
                .map { row(from: $0, today: today, naming: naming) }
                // 上次见面倒序;从没见过的沉到最后(nil 不是「很久以前」,是「没有」)。
                // 同一天见过的按 id 定序 —— 不定序的话两次打开顺序会变,
                // 而用户会以为列表在动。
                .sorted {
                    switch ($0.lastMetDay, $1.lastMetDay) {
                    case let (a?, b?): return a == b ? $0.id < $1.id : a > b
                    case (nil, _?):    return false
                    case (_?, nil):    return true
                    case (nil, nil):   return $0.id < $1.id
                    }
                }

            return PeopleList(
                me: SelfBlock(isConfirmed: meIdentified,
                              lineCount: me?.lineCount ?? 0,
                              sessionCount: me?.sessionCount ?? 0),
                pendingSpeakers: try pendingSpeakers(in: db).count,
                others: others)
        }
    }

    private static func row(from a: Aggregate, today: String,
                            naming: [String: String]) -> PersonRow {
        let key = "p:\(a.id)"
        // 称呼只有一个出处。`labels()` 只收录**有归属行**的键,所以刚建出来、
        // 还没派到任何一行上的人查不到 —— 那种人一定有名字(`PersonStore.create`
        // 拒空名),所以退回 `a.name`;两边都没有才说「还没有名字」,不编号。
        let label = naming[key] ?? a.name ?? "还没有名字的人"
        return PersonRow(
            id: a.id,
            label: label,
            hasName: a.name != nil,
            lastMetDay: a.lastDay,
            daysAgo: a.lastDay.flatMap { daysBetween($0, and: today) },
            sessionCount: a.sessionCount,
            lineCount: a.lineCount)
    }

    // MARK: - 某个人的档案

    /// - Returns: 库里没有这个人时返回 nil。**不返回一个空档案** ——
    ///   「查无此人」和「这个人还没材料」是两件事,后者要按 PRD §4.4.8 如实说明,
    ///   前者说明调用方拿了个不存在的 id,该露出来。
    static func profile(personID: Int64, today: String,
                        recentSessionLimit: Int = 10,
                        in reader: some DatabaseReader) throws -> PersonProfile? {
        try reader.read { db in
            guard let aggregate = try personAggregates(in: db).first(where: { $0.id == personID })
            else { return nil }
            let naming = try SpeakerNaming.labels(in: db)

            let lastMet = try lastMeeting(personID: personID, today: today, in: db)
            return PersonProfile(
                person: row(from: aggregate, today: today, naming: naming),
                brief: PersonBrief(
                    lastMet: lastMet,
                    lastTopic: try lastMet.flatMap {
                        try lastTopic(personID: personID, sessionID: $0.sessionID, in: db)
                    }),
                recurringTopics: try recurringTopics(personID: personID, in: db),
                recentSessions: try recentSessions(personID: personID,
                                                   limit: recentSessionLimit, in: db))
        }
    }

    // MARK: - 待确认的说话人

    /// 还叫不出名字的说话人。
    ///
    /// ⚠️ **这是「待确认」的唯一定义,人列表的角标与确认页的候选都读它。**
    /// 上一版两处各算各的:引导页算的是「总数 − 用户确认过的数」,确认页算的是
    /// 「没有任何一条用户确认的键」。同一个人身上既有确认行又有未确认行时两者不等,
    /// 于是角标说「还有 1 个」,点进去却说「都过了一遍」——而两边的代码都「跑通了」。
    ///
    /// ⚠️ **刻意不按转写版本过滤。** 重跑转写产生新版本之后,旧版本那些行仍然真实
    /// 存在于归属层,它们的归属也仍然没被确认过。这一点与 `personAggregates`
    /// (按最新版本统计,免得重跑一次句数翻倍)不同,是因为两者回答的问题不同:
    /// 那边问「这个人说了多少」,这边问「还有哪些归属没人认过」。
    /// 🔴 **「待确认」的唯一定义。三个消费方都读它。**
    ///
    /// 这段话是从 `GuideViews.swift` 搬来的(那个文件 2026-08-17 整个删掉了,
    /// 而它是当时唯一记着这件事的地方 —— 留在死代码里等于没记)。
    ///
    /// 曾经的错法:引导页算「总数 − 用户确认过的数」,确认页算「没有任何一条
    /// 用户确认的键」。同一个人身上既有确认行又有未确认行时两者不等 ——
    /// 角标说「还有 1 个」,点进去却说「都过了一遍」,**而两边的代码都跑通了**。
    ///
    /// ⚠️ 收口那天我写下「现在两处都读它,只有一个定义」——**那句话当天就是假的**:
    /// 统一的只有两个消费方,`SettingsView` 那个「N 个待确认」还是旧算法,漏掉了
    /// (M1-12e 修的就是它)。差别不是理论上的:这里会丢掉「整键的行全是
    /// 空洞/抹除行」的键,设置页不会 ⇒ **那种数据下设置页比确认页多报几个**。
    ///
    /// 现在由 `PeopleProjectionTests.testNobodyElseDefinesPendingSpeakers` 扫源码守着 ——
    /// 「两处行为一致」的数据断言挡不住第三处,而这条 BUG 的形态正是「又写了一个」。
    static func pendingSpeakers(in db: Database) throws -> [PendingSpeaker] {
        // 🔴 **点过「说不准」的不再问**(`M2-认11`)。不拿掉的话退出去再进来
        // 它原封不动排在原位 —— 用户的意思是「我判不了」,不是「翻一页」。
        // ⚠️ 只从这一屏拿掉,仍然挂在 `skippedSpeakers` 上,随时能回去认。
        let skipped = try SpeakerSkips.keys(in: db)
        return try speakers(confirmed: false, in: db).filter { !skipped.contains($0.key) }
    }

    static func skippedSpeakers(in reader: some DatabaseReader) throws -> [PendingSpeaker] {
        try reader.read { try skippedSpeakers(in: $0) }
    }

    static func pendingReviews(in reader: some DatabaseReader) throws -> [PendingReview] {
        try reader.read { try pendingReviews(in: $0) }
    }

    /// 待二次确认的句子(`M2-认16`)。**一句一条**,不是一簇一条 ——
    /// 问的是「这一句是不是他」,而不是「这一簇是谁」。
    ///
    /// ⚠️ 与待确认那一屏同一条纪律:**放不出声的不出现**。
    /// 这一屏问的是「这句像不像他」,而人是照着声音回答的;给文字让他猜,
    /// 猜错的代价是把一条对的行踢出簇(或把一条错的留下)。
    static func pendingReviews(in db: Database) throws -> [PendingReview] {
        let named = try PersonStore.names(in: db)
        var offsetsBySession: [Int64: [Int: Int]] = [:]
        func offsets(_ sessionID: Int64) -> [Int: Int] {
            if let hit = offsetsBySession[sessionID] { return hit }
            let o = BlockTiming.offsets(sessionID: sessionID, in: db)
            offsetsBySession[sessionID] = o
            return o
        }
        return try Row.fetchAll(db, sql: """
            SELECT r.line_id AS line_id, r.person_id AS pid, r.score AS score,
                   l.text AS text, t.session_id AS sid,
                   l.block_seq AS blk, l.t_start_ms AS s, l.t_end_ms AS e,
                   ss.day AS day, ss.source AS source
              FROM speaker_reviews  r
              JOIN transcript_lines l  ON l.line_id = r.line_id
              JOIN transcripts      t  ON t.id = l.transcript_id
              JOIN sessions        ss  ON ss.id = t.session_id
             WHERE r.state = ? AND l.is_gap = 0 AND l.redacted = 0
             ORDER BY r.score ASC
            """, arguments: [SpeakerReviews.State.pending.rawValue])
        .compactMap { row -> PendingReview? in
            guard case .success = LineAudio.resolve(blockSeq: row["blk"],
                                                    startMs: row["s"], endMs: row["e"],
                                                    day: row["day"], source: row["source"],
                                                    offsets: offsets(row["sid"]))
            else { return nil }
            let pid = row["pid"] as Int64
            return PendingReview(lineID: row["line_id"], personID: pid,
                                 personName: named[pid] ?? "这个人",
                                 score: row["score"], text: (row["text"] as String?) ?? "")
        }
    }

    /// 点过「说不准」的说话人 —— 「改一改」那一屏要带上它们,否则那些行永久失踪。
    static func skippedSpeakers(in db: Database) throws -> [PendingSpeaker] {
        let skipped = try SpeakerSkips.keys(in: db)
        guard !skipped.isEmpty else { return [] }
        return try speakers(confirmed: false, in: db).filter { skipped.contains($0.key) }
    }

    /// **已经认过的**说话人 —— 给「改一改认过的」用(用户 2026-08-31:「判过的得能让我重改」)。
    ///
    /// 🔴 **它存在的理由是「点错了要有救」。** 这一屏点下去写的是 `用户确认`,
    /// 而 `assignSpeaker` 从此不许任何自动来源改它 —— 数据层允许用户自己再确认一次,
    /// 但**界面上没有任何路径能再看到它**(`pendingSpeakers` 把有确认行的键整个滤掉)。
    /// 于是一次误触 = 一整簇话永久记在错的人名下。用户实机反馈的
    /// 「人和人之间按钮很接近,容易点错」说的就是这个的另一半。
    static func confirmedSpeakers(in db: Database) throws -> [PendingSpeaker] {
        try speakers(confirmed: true, in: db)
    }

    static func confirmedSpeakers(in reader: some DatabaseReader) throws -> [PendingSpeaker] {
        try reader.read { try confirmedSpeakers(in: $0) }
    }

    /// 两个列表**共用一份实现**,只差 `HAVING` 那一条。
    /// 分开写的话「能不能听」「样本句怎么挑」「怎么排序」会各漂各的,
    /// 而漂了的表现是「待确认里听得见,改一改里听不见」——两边都「跑得通」。
    /// 待二次确认的一句。
    struct PendingReview: Identifiable, Equatable {
        var id: Int64 { lineID }
        let lineID: Int64
        let personID: Int64
        let personName: String
        /// 与这个人底库的相似度。**只用来排序,不用来判定** ——
        /// 真机上同簇里两个人的分数分布重叠得很厉害(`SpeakerReviews` 的注释)。
        let score: Double
        let text: String
    }

    private static func speakers(confirmed: Bool, in db: Database) throws -> [PendingSpeaker] {
        let naming = try SpeakerNaming.labels(in: db)
        let named = try PersonStore.names(in: db)
        // ⚠️ **定序**:按全库首次出现,与 `SpeakerNaming.labels()` 的编号规则同一条。
        // 不定序的话 SQLite 返回什么顺序没有承诺 —— 加个索引换了查询计划顺序就变,
        // 而那时用户看到的是「说话人 2 排在说话人 1 前面」,像是列表在自己动。
        let keys = try String.fetchAll(db, sql: """
            SELECT \(SpeakerNaming.keyExpr(session: "t.session_id")) AS who
              FROM line_speakers ls
              JOIN transcript_lines l ON l.line_id = ls.line_id
              JOIN transcripts      t ON t.id = l.transcript_id
              JOIN sessions         s ON s.id = t.session_id
             GROUP BY who
            HAVING who IS NOT NULL
               AND SUM(CASE WHEN ls.source = '\(AttributionSource.userConfirmed.rawValue)'
                        THEN 1 ELSE 0 END) \(confirmed ? "> 0" : "= 0")
             -- 🔴 **最近的场次排最前**(2026-08-31 用户拍板)。
             -- 原来是 `ORDER BY MIN(s.started_at)` —— 最老的排最前,而最老的数据
             -- 恰恰是音频最可能已经不在盘上的。实测(用户真机库,235 个候选):
             -- 前 41 个一个都听不了,第一个能听的排在第 42 位、还只有 1 句话。
             -- 用户的体感是「我没办法听声音判断哪个是我」,而根因就是这一行排序。
             ORDER BY MAX(s.started_at) DESC, MIN(l.seq)
            """)

        // 每场的块起点读一次账本就够 —— 逐行去读会把这一屏拖成秒级。
        var offsetsBySession: [Int64: [Int: Int]] = [:]
        func offsets(_ sessionID: Int64) -> [Int: Int] {
            if let hit = offsetsBySession[sessionID] { return hit }
            let o = BlockTiming.offsets(sessionID: sessionID, in: db)
            offsetsBySession[sessionID] = o
            return o
        }

        return try keys.compactMap { key in
            let rows = try Row.fetchAll(db, sql: """
                SELECT ls.line_id AS line_id, l.text AS text, t.session_id AS sid,
                       l.block_seq AS blk, l.t_start_ms AS s, l.t_end_ms AS e,
                       ss.day AS day, ss.source AS source
                  FROM line_speakers ls
                  JOIN transcript_lines l ON l.line_id = ls.line_id
                  JOIN transcripts      t ON t.id = l.transcript_id
                  JOIN sessions        ss ON ss.id = t.session_id
                 WHERE \(SpeakerNaming.keyExpr(session: "t.session_id")) = ?
                   AND l.is_gap = 0 AND l.redacted = 0
                """, arguments: [key])
            guard !rows.isEmpty else { return nil }
            // 🔴 **听不了的候选整个不出现**(2026-08-31 用户拍板)。
            //
            // 这一屏问的是「哪个是你」,而人是**照着声音**回答的 —— 只给文字让他猜,
            // 猜错就是一次不可逆的错归属(`source='用户确认'` 之后声纹再也修不回来)。
            // 所以放不出声的候选不是「体验差一点」,是**这一屏对它无解**。
            //
            // ⚠️ 代价照实说:音频已经清掉的那些说话人从此**没有任何入口能确认**,
            // 他们名下的承诺与表态会一直挂在「归属未定」。用户 2026-08-31 知情拍板。
            //
            // 判据只有一个出处:`LineAudio.resolve`,与「听一下这句」那个按钮同一份。
            let playable = rows.filter { row in
                if case .success = LineAudio.resolve(blockSeq: row["blk"],
                                                     startMs: row["s"], endMs: row["e"],
                                                     day: row["day"], source: row["source"],
                                                     offsets: offsets(row["sid"])) { return true }
                return false
            }
            // 拿最长的一句当样本 —— 短句认不出人,而确认页全部的作用就是让人认出来。
            // ⚠️ **只在放得出声的行里挑**:样本句与它的音频必须是同一行,
            // 而挑一句听不了的等于把这个候选变成又一个「看得见听不着」。
            // ⚠️ **把它的 `line_id` 一起留下**(见 `PendingSpeaker.sampleLineID`)。
            guard let longest = playable.max(by: {
                (($0["text"] as String?) ?? "").count < (($1["text"] as String?) ?? "").count
            }) else { return nil }
            let sample = (longest["text"] as String?) ?? ""
            return PendingSpeaker(
                key: key,
                label: naming[key] ?? key,
                sample: sample,
                sampleLineID: longest["line_id"] as Int64?,
                lineIDs: rows.map { $0["line_id"] },
                sessionCount: Set(rows.map { $0["sid"] as Int64 }).count,
                // 簇键(`c:…`)没有 person,`personID` 为 nil ⇒ 恒无名字。
                hasName: SpeakerNaming.personID(of: key).map { named[$0] != nil } ?? false)
        }
    }

    static func pendingSpeakers(in reader: some DatabaseReader) throws -> [PendingSpeaker] {
        try reader.read { try pendingSpeakers(in: $0) }
    }

    // MARK: - 聚合

    struct Aggregate {
        let id: Int64
        let name: String?
        let sessionCount: Int
        let lineCount: Int
        let lastDay: String?
    }

    /// 每个人的出场统计。
    ///
    /// ⚠️ **只统计最新版本的转写。** 不过滤的话,一场重跑过转写的录音里
    /// 同一个人的话会被数两遍 —— 而「他说了 84 句」翻倍成 168 句不会报错,
    /// 只是个看起来很正常的错数(与 `HomeProjection.storedSummaries` 同一条纪律)。
    ///
    /// ⚠️ **`persons` 走 LEFT JOIN,一个人都不漏。** 内连接会把「刚建出来、
    /// 还没派到任何一行上」的人从列表里抹掉 —— 而命名屏刚建的人正是这种,
    /// 用户会看到自己刚起的名字凭空消失。没有往来记录是一种**要显示的状态**
    /// (PRD §4.4.8),不是一种不存在。
    static func personAggregates(in db: Database) throws -> [Aggregate] {
        try Row.fetchAll(db, sql: """
            SELECT p.id                      AS id,
                   p.name                    AS name,
                   COALESCE(a.n_sessions, 0) AS n_sessions,
                   COALESCE(a.n_lines, 0)    AS n_lines,
                   a.last_day                AS last_day
              FROM persons p
              LEFT JOIN (
                  SELECT ls.person_id                  AS pid,
                         COUNT(DISTINCT t.session_id)  AS n_sessions,
                         COUNT(*)                      AS n_lines,
                         MAX(s.day)                    AS last_day
                    FROM line_speakers   ls
                    JOIN transcript_lines l ON l.line_id = ls.line_id
                    JOIN transcripts      t ON t.id = l.transcript_id
                    JOIN sessions         s ON s.id = t.session_id
                   WHERE ls.person_id IS NOT NULL
                     AND t.version = (SELECT MAX(version) FROM transcripts
                                       WHERE session_id = t.session_id)
                   GROUP BY ls.person_id
              ) a ON a.pid = p.id
             ORDER BY p.id
            """).map {
            Aggregate(id: $0["id"], name: $0["name"],
                      sessionCount: Int($0["n_sessions"] as Int64),
                      lineCount: Int($0["n_lines"] as Int64),
                      lastDay: $0["last_day"])
        }
    }

    // MARK: - 简报(PRD §4.4.5)

    private static func lastMeeting(personID: Int64, today: String,
                                    in db: Database) throws -> LastMeeting? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT s.id AS id, s.day AS day, s.started_at AS started_at
              FROM line_speakers   ls
              JOIN transcript_lines l ON l.line_id = ls.line_id
              JOIN transcripts      t ON t.id = l.transcript_id
              JOIN sessions         s ON s.id = t.session_id
             WHERE ls.person_id = ?
               AND t.version = (SELECT MAX(version) FROM transcripts
                                 WHERE session_id = t.session_id)
             ORDER BY s.started_at DESC
             LIMIT 1
            """, arguments: [personID]) else { return nil }

        let day: String = row["day"]
        return LastMeeting(sessionID: row["id"], day: day,
                           clock: HomeProjection.clockTime(fromISO: row["started_at"]),
                           daysAgo: daysBetween(day, and: today))
    }

    /// PRD §4.4.5 把这一行的出处定死了:**那场纪要已经产好的「一句话」**,
    /// 零模型调用、零网络往返。这里只是读它。
    private static func lastTopic(personID: Int64, sessionID: Int64,
                                  in db: Database) throws -> LastTopic? {
        // 版本口径与 `HomeProjection.storedSummaries` 一致:最新版本、按 part 定序取第一块。
        // 不定序的话 SQLite 返回哪一块没有承诺,首页卡与档案会显示不同的一句话。
        guard let oneLiner = try String.fetchOne(db, sql: """
            SELECT m.one_liner
              FROM transcripts t
              JOIN summaries   m ON m.transcript_id = t.id
             WHERE t.session_id = ?
               AND t.version = (SELECT MAX(version) FROM transcripts WHERE session_id = ?)
             ORDER BY t.part
             LIMIT 1
            """, arguments: [sessionID, sessionID]) else { return nil }

        // 「≤40 字必带原话跳转」(PRD §4.4.3 字段规则)。那一场他一句没说时留空,
        // 界面少一行,不编一句原话出来。
        let quote = try Row.fetchOne(db, sql: """
            SELECT l.line_id AS line_id, l.text AS text
              FROM line_speakers   ls
              JOIN transcript_lines l ON l.line_id = ls.line_id
              JOIN transcripts      t ON t.id = l.transcript_id
             WHERE ls.person_id = ? AND t.session_id = ?
               AND l.is_gap = 0 AND l.redacted = 0
             ORDER BY LENGTH(l.text) DESC, l.line_id
             LIMIT 1
            """, arguments: [personID, sessionID])

        return LastTopic(oneLiner: oneLiner,
                         quote: quote?["text"], quoteLineID: quote?["line_id"])
    }

    // MARK: - 反复关心的

    /// `summary_topic_keys.line_ids` ∩ 这个人的行。**PRD 要求 ≥2 次才显示**,
    /// 少于两次的不是「他关心的」,是一次偶然提到。
    ///
    /// ⚠️ 交集在 Swift 里算,不用 `json_each`。`line_ids` 存的是 `[1,2,3]` 这种
    /// JSON 数组(`ExtractionStore.swift`),而每场主题词只有个位数条 ——
    /// 为它引进一个 SQLite 编译选项上的依赖不划算,那种依赖缺席时的样子是
    /// 「查询抛错」而不是「少几个词」,踩上了才知道。
    private static func recurringTopics(personID: Int64,
                                        in db: Database) throws -> [TopicMention] {
        let mine = try Set(Int64.fetchAll(db, sql: """
            SELECT line_id FROM line_speakers WHERE person_id = ?
            """, arguments: [personID]))
        guard !mine.isEmpty else { return [] }

        var counts: [String: Int] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT k.key AS key, k.line_ids AS line_ids
              FROM summary_topic_keys k
              JOIN transcripts       t ON t.id = k.transcript_id
             WHERE t.version = (SELECT MAX(version) FROM transcripts
                                 WHERE session_id = t.session_id)
            """) {
            let key: String = row["key"]
            let hits = parseLineIDs(row["line_ids"]).filter(mine.contains).count
            if hits > 0 { counts[key, default: 0] += hits }
        }
        return counts
            .filter { $0.value >= 2 }
            .map { TopicMention(key: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.key < $1.key : $0.count > $1.count }
    }

    /// `"[1,2,3]"` → `[1, 2, 3]`。**认不出的原样丢掉,不抛**——
    /// 一个坏掉的主题词行不该让整张档案打不开;而它的后果是少显示一个词,
    /// 是可见的(不像静默写错地方那种)。
    static func parseLineIDs(_ raw: String) -> [Int64] {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .split(separator: ",")
            .compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: - 最近场次

    private static func recentSessions(personID: Int64, limit: Int,
                                       in db: Database) throws -> [PersonSession] {
        try Row.fetchAll(db, sql: """
            SELECT s.id         AS id,
                   s.day        AS day,
                   s.started_at AS started_at,
                   COUNT(*)     AS n_lines,
                   -- 整场时长,不是他说话的时长:取该场转写行的最大 t_end_ms
                   -- (场次内绝对毫秒),没有转写行就退回墙钟跨度。
                   -- ⚠️ 墙钟用 strftime('%s') 的整数秒算,不用 julianday ——
                   -- julianday 是浮点,47 分钟会被截成 46 分(HomeProjection 钉过这条)。
                   (SELECT COALESCE(NULLIF(MAX(l2.t_end_ms), 0),
                                    (strftime('%s', s.ended_at)
                                     - strftime('%s', s.started_at)) * 1000,
                                    0)
                      FROM transcript_lines l2
                      JOIN transcripts      t2 ON t2.id = l2.transcript_id
                     WHERE t2.session_id = s.id
                       AND t2.version = (SELECT MAX(version) FROM transcripts
                                          WHERE session_id = s.id)) AS span_ms,
                   (SELECT m.one_liner
                      FROM transcripts t3
                      JOIN summaries   m ON m.transcript_id = t3.id
                     WHERE t3.session_id = s.id
                       AND t3.version = (SELECT MAX(version) FROM transcripts
                                          WHERE session_id = s.id)
                     ORDER BY t3.part LIMIT 1)                       AS one_liner
              FROM line_speakers   ls
              JOIN transcript_lines l ON l.line_id = ls.line_id
              JOIN transcripts      t ON t.id = l.transcript_id
              JOIN sessions         s ON s.id = t.session_id
             WHERE ls.person_id = ?
               AND t.version = (SELECT MAX(version) FROM transcripts
                                 WHERE session_id = s.id)
             GROUP BY s.id
             ORDER BY s.started_at DESC
             LIMIT ?
            """, arguments: [personID, limit]).map {
            PersonSession(id: $0["id"],
                          day: $0["day"],
                          clock: HomeProjection.clockTime(fromISO: $0["started_at"]),
                          durationMinutes: Int(($0["span_ms"] as Int64) / 60_000),
                          relatedLineCount: Int($0["n_lines"] as Int64),
                          oneLiner: $0["one_liner"])
        }
    }

    // MARK: - 日期

    /// `2026-08-13` 与 `2026-08-17` → 4。认不出格式返回 nil(**不猜**)。
    ///
    /// ⚠️ 刻意用整数算,不过 `DateFormatter` / `Calendar`:`sessions.day` 是
    /// 一个**没有时区含义的日历日**(§3.1.2 存的是本地时区 ISO,day 是它的日期部分)。
    /// 交给日历组件就要先给它安一个时区,而安错的样子是「跨零点那几场差一天」——
    /// 一个只在半夜出现、白天复现不了的错。
    static func daysBetween(_ from: String, and to: String) -> Int? {
        guard let a = dayNumber(from), let b = dayNumber(to) else { return nil }
        return b - a
    }

    /// 公历日 → 天序号(Howard Hinnant 的 days-from-civil)。
    private static func dayNumber(_ day: String) -> Int? {
        let parts = day.prefix(10).split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        let yy = y - (m <= 2 ? 1 : 0)
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400                                  // [0, 399]
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1  // [0, 365]
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy           // [0, 146096]
        return era * 146_097 + doe - 719_468
    }
}
