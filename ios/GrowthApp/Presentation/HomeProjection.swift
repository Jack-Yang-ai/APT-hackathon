import Foundation
import GRDB

/// 把主库投影成首页(PRD §4.2.2)。
///
/// **纪要为什么是入参而不是从库里读**:主库现在只有冻结层与归属层(M0-2a),
/// 还没有承接抽取产出的内容表——`one_liner` / `key_points` 目前在库里无处可落。
/// 所以这一层先由调用方把纪要传进来;等内容层落库,把 `summaries` 换成一次查询即可,
/// **本函数签名与所有展示模型都不用动**。
///
/// 这样写而不是先塞个占位表,是因为占位表会变成第二个「纪要在哪」的答案。
enum HomeProjection {

    /// 投影某一天的首页。
    /// - Parameters:
    ///   - day: `sessions.day`,形如 `2026-08-08`
    ///   - summaries: 已出纪要的场次,按 session id 索引;没有条目 = 这场还没纪要
    ///   - earlierDayLimit: 「更早」最多回溯几天。
    ///     ⚠️ **默认 14,不是 30。** PRD §4.2.6 与 M1 交付清单两处都写死
    ///     「M1 只显示最近 14 天,不做按天分页加载」,而这里原来是 30 ——
    ///     两个数并存时没人说得出哪个算数(而且 30 那个还带着「下滑加载」的注释,
    ///     那是 M2 的 §4.2.6)。按 PRD 收到 14。
    /// - Parameter summaries: 传 nil 就**自己从库里读**(生产走这条)。
    ///   ⚠️ 这个参数原来默认 `[:]`,而生产没有任何调用方注入过 —— 结果是场次卡
    ///   **永远走不到「好了」那一档**,已经出了纪要的场次一直显示「整理中」。
    ///   退出码全绿、测试全绿,因为测试都自己传了字典。
    static func homeFeed(day: String,
                         summaries: [Int64: SessionSummary]? = nil,
                         banner: HomeBanner? = nil,
                         earlierDayLimit: Int = 14,
                         in reader: some DatabaseReader) throws -> HomeFeed {

        let resolved = try summaries ?? storedSummaries(day: day, in: reader)
        let all = try sessionCards(day: day, summaries: resolved, in: reader)

        // PRD §4.2.2 折叠规则:分级为「只转写」的、以及无要点无进展无发现无卡片的,折进零碎。
        //
        // ⚠️ 只能执行后半条。前半条要 §4.1.6 的场次分级,而分级结果目前没有落库的地方
        //    (sessions 表没有这一列),所以「只转写」级别的场次现在折不进来。
        //    这不是漏写,是缺数据源;补上分级列之后这里要一并改。
        let foldable = all.filter { card in
            guard let s = card.state.summary else { return false }   // 还在处理的不折
            return s.keyPoints.isEmpty && card.attachments.isEmpty
        }
        let foldableIDs = Set(foldable.map(\.id))

        let fragments = foldable.isEmpty
            ? nil
            : FragmentsFold(count: foldable.count, sessionIDs: foldable.map(\.id).sorted())

        return HomeFeed(
            // ⚠️ 从 `all` 数,不是从 `todayCards` —— 折进「零碎」的那些也处理过,
            // 也可能失败。只数没折起来的,会漏掉正好被折叠的那一段失败,
            // 而首页上「今天全好了」和「有一段没成」长得完全不一样。
            digest: ProcessingDigest.make(from: all),
            banner: banner,
            todayCards: all.filter { !foldableIDs.contains($0.id) },
            fragments: fragments,
            earlier: try earlierDays(before: day, limit: earlierDayLimit, in: reader),
            recordedCards: all,
            understood: try understoodEvents(day: day, in: reader)
        )
    }

    static func understoodEvents(day: String, in reader: some DatabaseReader) throws -> [UnderstoodEvent] {
        try reader.read { db in
            let heads = try Row.fetchAll(db, sql: "SELECT id, started_at, status FROM sessions s WHERE day = ? AND NOT (\(MemoryRemoval.removedSessionPredicate)) ORDER BY julianday(started_at) DESC", arguments: [day])
            var out: [(UnderstoodEvent, Double)] = []
            for head in heads {
                let sid: Int64 = head["id"]
                let tids = try SessionDetailProjection.activeTranscripts(db, sessionID: sid)
                guard !tids.isEmpty else { continue }
                let events = try SessionDetailProjection.detailEvents(db, transcriptIDs: tids, startedAt: head["started_at"], label: [:])
                let start = ISO8601DateFormatter.growth.date(from: head["started_at"])?.timeIntervalSince1970 ?? 0
                for event in events {
                    let ids=try SessionDetailProjection.eventLineIDs(event.id,transcriptIDs:tids,in:db)
                    let marks=Array(repeating:"?",count:ids.count).joined(separator:",")
                    let millis = ids.isEmpty ? 0 : try Int.fetchOne(db,sql:"SELECT MAX(t_end_ms) FROM transcript_lines WHERE line_id IN (\(marks)) AND is_gap=0",arguments:StatementArguments(Array(ids))) ?? 0
                    out.append((UnderstoodEvent(sessionID: sid, event: event,
                        sessionOpen: head["status"] as String == SessionBridge.Status.open, latestMillis: millis), start + Double(millis) / 1000))
                }
            }
            return out.sorted { $0.1 > $1.1 }.map(\.0)
        }
    }

    /// 从库里读某一天各场的纪要。
    ///
    /// ~~`title` 恒为空~~ **2026-10-12 `M5-1` 作废**:两阶段抽取的事件有标题了(`summary_events`),
    /// 标题 = 第一个还有内容的事件标题,规则唯一出处 `SessionDetailProjection.sessionTitle`。
    /// 没有事件的老场次仍是空串 —— 编一个标题出来会让人以为模型给这一场起过名字。
    static func storedSummaries(day: String, in reader: some DatabaseReader) throws
        -> [Int64: SessionSummary] {
        try reader.read { db in
            // ⚠️ **必须限定 version,而且要定序。** 上一版没有 ORDER BY 也没有版本过滤:
            // 一场三个 part 就返回三行,字典里只剩「最后遍历到」的那条 ——
            // 而 SQLite 从未承诺这个顺序,加个索引换了查询计划结果就变。
            // 更糟的是它与 `SessionDetailProjection` 是两套「哪一版算数」,
            // 首页卡和详情页会显示不同的一句话。
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.id AS sid, m.one_liner AS one_liner, m.transcript_id AS tid
                  FROM sessions s
                  JOIN transcripts t ON t.session_id = s.id
                  JOIN summaries   m ON m.transcript_id = t.id
                 WHERE s.day = ?
                   AND m.one_liner <> ?
                   AND t.version = (SELECT MAX(version) FROM transcripts
                                     WHERE session_id = s.id)
                 ORDER BY s.id, t.part
                """, arguments: [day, MemoryRemoval.tombstoneText])

            var out: [Int64: SessionSummary] = [:]
            var titles: [Int64: [String]] = [:]
            for row in rows {
                let sid: Int64 = row["sid"]
                titles[sid, default: []] += try String.fetchAll(db, sql: """
                    SELECT title FROM summary_events WHERE transcript_id = ? ORDER BY seq
                    """, arguments: [row["tid"] as Int64])
                // 一句话取第一块那条,要点按 part 顺序累加 —— 一场三小时的会
                // 是**一张卡**(PRD §4.2.2),不能只显示最后一块的要点。
                let tid: Int64 = row["tid"]
                let points = try Row.fetchAll(db, sql: """
                    SELECT text, quote, line_id, (SELECT t_start_ms FROM transcript_lines
                                                   WHERE line_id = summary_key_points.line_id) AS at_ms
                      FROM summary_key_points WHERE transcript_id = ? ORDER BY seq
                    """, arguments: [tid]).map {
                    KeyPoint(text: $0["text"], quote: $0["quote"],
                             lineID: $0["line_id"], atMillis: $0["at_ms"] ?? 0)
                }
                if let existing = out[sid] {
                    out[sid] = SessionSummary(title: existing.title,
                                              oneLiner: existing.oneLiner,
                                              keyPoints: existing.keyPoints + points)
                } else {
                    out[sid] = SessionSummary(title: "", oneLiner: row["one_liner"],
                                              keyPoints: points)
                }
            }
            for (sid, s) in out {
                let t = SessionDetailProjection.sessionTitle(eventTitles: titles[sid] ?? []) ?? ""
                out[sid] = SessionSummary(title: t, oneLiner: s.oneLiner, keyPoints: s.keyPoints)
            }
            return out
        }
    }

    // MARK: - 场次卡

    /// 某一天的**全部**场次卡,**不折叠**。
    ///
    /// 折叠是给「今天」那条流用的 —— 它要保持干净,所以零碎收成一行。
    /// 而翻回某一天时,用户要的恰恰是「那天到底有什么」:再折一次
    /// 就等于把他刚点开的东西又藏起来。
    ///
    /// ⚠️ 「零碎」那一行点开之后也走这里(按 id 过滤)——
    /// 两处各查一次库的话,同一场在两个入口下会长得不一样。
    static func cards(day: String, in reader: some DatabaseReader) throws -> [SessionCard] {
        try sessionCards(day: day, summaries: storedSummaries(day: day, in: reader), in: reader)
    }

    private static func sessionCards(day: String,
                                     summaries: [Int64: SessionSummary],
                                     in reader: some DatabaseReader) throws -> [SessionCard] {
        // 时长取该场次转写行的最大 t_end_ms —— 它是「场次内绝对毫秒」(§3.1.2),
        // 缺块的占位行也占着自己那段时间,所以这个数就是整场时长,不必排除占位行。
        return try reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.id                                AS id,
                       s.started_at                        AS started_at,
                       s.source                            AS source,
                       -- 时长优先取转写行的最大 t_end_ms;**没有转写行时退回墙钟跨度**。
                       -- 不退回的话,刚录完还没转写的场次会显示「0 分钟」——
                       -- 那不是「不知道」,那是一个看起来很正常的错数。
                       -- ended_at 为空(还在录)时两条都取不到,就是 0,由界面决定不显示。
                       -- ⚠️ 墙钟跨度用 strftime('%s') 的**整数秒**算,不用 julianday。
                       -- julianday 是浮点:47 分钟算出来是 2819999.99…,CAST 截断成
                       -- 2819999 ms,再除 60000 就是 **46 分**。少一分钟不会有人发现,
                       -- 但它是错的 —— 测试 testDurationFallsBackToWallClock… 钉的就是这个。
                       COALESCE(NULLIF(MAX(l.t_end_ms), 0),
                                (strftime('%s', s.ended_at) - strftime('%s', s.started_at))
                                     * 1000,
                                0)                         AS span_ms,
                       -- 这场是不是还在录。**它压过下面所有状态** —— 见 map 里的注释。
                       -- 判据用 `status` 而不是 `ended_at IS NULL`:status 是场次状态机
                       -- 自己的列(`SessionBridge.Status.open`),而 ended_at 为空是它的
                       -- 副作用。拿副作用当判据,哪天有一条只写了 status 的路径就会判错。
                       (s.status = '\(SessionBridge.Status.open)')  AS is_open,
                       (strftime('%s', 'now') - strftime('%s', s.started_at)) / 60
                                                           AS open_minutes,
                       -- ⚠️ **对该 version 的全部 part 做聚合,不取排序第一行。**
                       -- 上一版 `ORDER BY version DESC, part DESC LIMIT 1`:
                       -- part1=partial(缺块超时仍落库)+ part2/3=frozen → 返回 frozen
                       -- → 判成「好了」,而这场真的缺了一块内容。
                       -- 反向也错:part3=pending 会把前两块能看的纪要整场藏起来。
                       -- 口径:有 pending 则未完成 > 有 partial 则 partial > 全 frozen 才 frozen。
                       (SELECT CASE
                                 WHEN SUM(t.status = 'pending') > 0 THEN 'pending'
                                 WHEN SUM(t.status = 'partial') > 0 THEN 'partial'
                                 ELSE MIN(t.status) END
                          FROM transcripts t
                         WHERE t.session_id = s.id
                           AND t.version = (SELECT MAX(version) FROM transcripts
                                             WHERE session_id = s.id)) AS transcript_status,
                       -- 最新一条任务行:内部态与重试次数从这儿来(§1.3)
                       (SELECT k.state    FROM tasks k WHERE k.session_id = s.id
                         ORDER BY CASE k.state WHEN 'dead' THEN 0 WHEN 'degraded' THEN 1 WHEN 'retrying' THEN 2
                           WHEN 'waiting_network' THEN 3 WHEN 'running' THEN 4 WHEN 'queued' THEN 5 ELSE 6 END,
                           k.task_id DESC LIMIT 1) AS task_state,
                       (SELECT k.attempts FROM tasks k WHERE k.session_id = s.id
                         ORDER BY CASE k.state WHEN 'dead' THEN 0 WHEN 'degraded' THEN 1 WHEN 'retrying' THEN 2
                           WHEN 'waiting_network' THEN 3 WHEN 'running' THEN 4 WHEN 'queued' THEN 5 ELSE 6 END,
                           k.task_id DESC LIMIT 1) AS task_attempts
                  FROM sessions s
                  -- 🔴 **必须带版本过滤。** 重转写/重整会落新的一版,而**旧版的行
                  -- 永远留在库里**(冻结层只增不改,§3.1.4)。不过滤的话
                  -- `MAX(l.t_end_ms)` 会跨版本取到旧那版 —— 而首页卡上那个时长
                  -- 正是用户判断「修好没有」的**唯一可见信号**。
                  -- 实测形态(2026-08-18,`M1-13b-1` 收活时由子 Agent 发现):
                  -- 某场次 真实 155 秒、旧版坏行落在 1800 秒;重整出 v2 之后
                  -- 事件表说「好了」、体检页也不再报它,而首页照样显示 30 分钟。
                  -- 同一个文件里纪要(:82)与转写状态(:170)两处子查询**都带**了
                  -- 这个过滤 —— 说明这里是漏的,不是有意的。
                  LEFT JOIN transcripts      t ON t.session_id    = s.id
                   AND t.version = (SELECT MAX(version) FROM transcripts
                                     WHERE session_id = s.id)
                  LEFT JOIN transcript_lines l ON l.transcript_id = t.id
                 WHERE s.day = ?
                   -- M1-22:移出记忆的场次不再出现在列表里(用户拍板「卡片肯定不要保留」)。
                   -- 判据只有一个出处,见 `MemoryRemoval.removedSessionPredicate`。
                   AND NOT (\(MemoryRemoval.removedSessionPredicate))
                 GROUP BY s.id
                 ORDER BY s.started_at DESC
                """, arguments: [day])

            // 「排队中,前面还有 N 段」——真去数,不写死
            let ahead = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tasks WHERE state IN ('queued', 'retrying')
                """) ?? 0

            return try rows.map { row in
                let id: Int64 = row["id"]

                // ⚠️ **还在录的场次一律是「录音中」,不看任务表也不看转写状态。**
                //
                // 实测踩到过(2026-08-14 模拟器):正在录的那一场卡面显示「整理中」——
                // 因为它既没有任务行也没有转写行,而 `displayState` 把
                // 「transcriptStatus 为 nil」一律当成「还没冻结 → 处理中」。
                // 那句话对**录完了还没转写**的场次成立,对**正在录**的不成立。
                //
                // 这也正是 PRD §4.1.7 并发优先级把「录音中」排在最前的原因:
                // 录音期间块是边录边传的,底下真的可能同时挂着一个 uploading 任务,
                // 但用户该看到的是「还在录」。
                if row["is_open"] == true {
                    let watch = row["source"] as String == SessionSource.watch
                    let received = watch ? ProcessingPump.blocks(of: id, ext: "m4a", in: db) : []
                    let minutes = watch ? received.reduce(0) { $0 + $1.durationMs } / 60_000 : Int(row["open_minutes"] as Int64? ?? 0)
                    let failed = watch ? (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asr_jobs WHERE session_id = ? AND state = 'failed'", arguments: [id]) ?? 0) : 0
                    let state: SessionDisplayState
                    if failed > 0 { state = .partialFailure(missing: "\(failed) 个片段没转出来，可重试") }
                    else if watch, ["dead", "degraded", "retrying"].contains(row["task_state"] as String? ?? "") {
                        state = try displayState(taskState: row["task_state"], taskAttempts: row["task_attempts"] ?? 0,
                            queuedAhead: max(0, ahead - 1), transcriptStatus: row["transcript_status"], summary: summaries[id], in: db)
                    } else { state = .recording(elapsedMinutes: minutes) }
                    return SessionCard(
                        id: id,
                        startTime: clockTime(fromISO: row["started_at"]),
                        durationMinutes: minutes,
                        state: state,
                        attachments: .none,
                        source: row["source"],
                        recordedIntervals: received.map { .init(offsetMs: $0.offsetMs, durationMs: $0.durationMs) },
                        isCaptureOpen: true)
                }

                let received = row["source"] as String == SessionSource.watch ? ProcessingPump.blocks(of: id, ext: "m4a", in: db) : []
                return SessionCard(
                    id: id,
                    startTime: clockTime(fromISO: row["started_at"]),
                    durationMinutes: row["source"] as String == SessionSource.watch ? received.reduce(0) { $0 + $1.durationMs } / 60_000 : Int((row["span_ms"] as Int64) / 60_000),
                    state: try displayState(taskState: row["task_state"],
                                            taskAttempts: row["task_attempts"] ?? 0,
                                            queuedAhead: max(0, ahead - 1),
                                            transcriptStatus: row["transcript_status"],
                                            summary: summaries[id],
                                            in: db),
                    // M1 恒空:PRD 写明只预留容器位、不产出内容
                    attachments: .none,
                    source: row["source"],
                    recordedIntervals: received.map { .init(offsetMs: $0.offsetMs, durationMs: $0.durationMs) }
                )
            }
        }
    }

    /// 内部态 → PRD §4.1.7 展示态。
    ///
    /// 任务表在(M0-2e)之后,这里**查映射表**而不是在代码里 switch —— §1.3 要的
    /// 就是一张映射表,而且 `tasks.state` 有外键指着它:加一个内部态却忘了给它映射,
    /// 插入时就被挡下,不会渲染出空白状态。
    ///
    /// 没有任务行时(比如导入的历史场次)退回按 `transcripts.status` 判。
    static func displayState(taskState: String?,
                             taskAttempts: Int,
                             queuedAhead: Int,
                             transcriptStatus: String?,
                             summary: SessionSummary?,
                             in db: Database) throws -> SessionDisplayState {

        if let taskState, let display = try TaskQueue.displayState(forTaskState: taskState, in: db) {
            switch display {
            case "waitingForNetwork":   return .waitingForNetwork
            case "queued":              return .queued(ahead: queuedAhead)
            case "processing":          return .processing
            case "attributionPending":
                // ⚠️ 取不到纪要时**显式落到「整理中」**,不许掉出 switch。
                // 上一版 `if let summary { return … }` 不成立就掉到下面那段
                // `transcriptStatus` 的 switch —— `partial` 会把它判成
                // `.degraded`(灰色终态、告诉用户不会自己好),而底下的归属任务正在跑。
                // PRD §4.1.7 的并发优先级里「说话人整理中」本来就高于「降级」。
                return summary.map { .attributionPending($0) } ?? .processing
            case "failed":
                // 🔴 映射表把 `retrying` 与 `dead` 都收进 `failed`(那张表不动,
                // `tasks.state` 有外键指着它)。**「会不会再试」只有原始态知道**,
                // 所以这里回头看 `taskState` —— 不是绕过映射表,是补它丢掉的那一位。
                return .failed(attempt: taskAttempts, willRetry: taskState != "dead")
            case "degraded":            return .degraded
            case "done":
                // ⚠️ **任务 done 但没有纪要,是「只转写」档的正常形态**,不是还在处理。
                // PRD §4.1.6:「只转写 = 短对话/寒暄 → 存转写,可搜索,¥0」——
                // ¥0 就是不跑抽取,所以 `summaries` 本来就没有这一行。
                // 上一版掉出 switch 后被判成 `.processing`,而任务已经 done、
                // 不会再有任何东西推动它 —— **永久转圈**,同时因为没有 summary
                // 也折不进「零碎」,就那么挂在主流里转。
                return summary.map { .done($0) } ?? .degraded
            case "uploading":
                // ⚠️ §1.3 的任务表没有进度列,百分比目前没有来源。
                //    做上传层时要么加一列,要么把这个展示态改掉 —— 现在它恒为 0。
                return .uploading(percent: 0)
            default: break
            }
        }

        switch transcriptStatus {
        case nil, "pending":
            return .processing                        // 还没冻结,谈不上纪要
        case "partial":
            // 缺块超时仍落库(§3.1.6):转写在、内容不全 —— 对上 PRD 的「只保留了文字记录」
            return .degraded
        case "frozen":
            guard let summary else { return .processing }   // 冻结了但还没抽取
            return .done(summary)
        default:
            return .processing
        }
    }

    /// `2026-08-08T14:00:00+08:00` → `14:00`。
    ///
    /// 刻意按字面截取而不是过 DateFormatter:`started_at` 存的就是**本地时区 ISO**
    /// (§3.1.2),字面上的钟点正是当时用户看到的钟点。再过一次时区转换只会把它弄错。
    /// 格式不认识就原样返回,不猜。
    static func clockTime(fromISO iso: String) -> String {
        guard let t = iso.firstIndex(of: "T") else { return iso }
        let after = iso.index(after: t)
        let hhmm = iso[after...].prefix(5)
        guard hhmm.count == 5, hhmm[hhmm.index(hhmm.startIndex, offsetBy: 2)] == ":" else { return iso }
        return String(hhmm)
    }

    // MARK: - 有录音的日子(「我」页日历,`M5-1`)

    /// 哪些天有场次。判据与「更早」按天计数**同一条**(`removedSessionPredicate`)——
    /// 日历上有点而点进去一场都没有,两边都不会报错(铁律 4 的形状)。
    static func recordedDays(in reader: some DatabaseReader) throws -> Set<String> {
        try reader.read { db in
            try Set(String.fetchAll(db, sql: """
                SELECT DISTINCT day FROM sessions s
                 WHERE NOT (\(MemoryRemoval.removedSessionPredicate))
                """))
        }
    }

    /// 日历的点只标当前版本中仍有效的事件，与事件列表使用同一删除口径。
    static func eventDays(in reader: some DatabaseReader) throws -> Set<String> {
        try reader.read { db in
            try Set(String.fetchAll(db, sql: """
                SELECT DISTINCT s.day FROM sessions s JOIN transcripts t ON t.session_id=s.id
                  JOIN summary_events e ON e.transcript_id=t.id
                 WHERE NOT (\(MemoryRemoval.removedSessionPredicate))
                   AND t.version=(SELECT MAX(version) FROM transcripts WHERE session_id=s.id)
                   AND e.title != ? AND e.summary != ?
                """,arguments:[MemoryRemoval.tombstoneText,MemoryRemoval.tombstoneText]))
        }
    }

    // MARK: - 更早

    private static func earlierDays(before day: String,
                                    limit: Int,
                                    in reader: some DatabaseReader) throws -> [EarlierDay] {
        try reader.read { db in
            try Row.fetchAll(db, sql: """
                -- M1-22:计数要与列表用同一个判据,否则「这天 3 场」而只列出 2 场,
                -- 而两边都不报错(铁律 4 的形状)。
                SELECT day, COUNT(*) AS n FROM sessions s
                 WHERE day < ? AND NOT (\(MemoryRemoval.removedSessionPredicate))
                 GROUP BY day ORDER BY day DESC LIMIT ?
                """, arguments: [day, limit])
                .map { EarlierDay(day: $0["day"], sessionCount: Int($0["n"] as Int64)) }
        }
    }
}
