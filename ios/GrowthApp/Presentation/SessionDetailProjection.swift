import Foundation
import GRDB

/// 库表 → 场次详情(PRD §4.2.3)。
///
/// 和 `HomeProjection` 一样的纪律:**排序、过滤、隐藏规则全在这一层**,
/// 界面只负责画。规则散进界面就等于有了第二份实现,而两份迟早不一样。
enum SessionDetailProjection {

    /// **一场 = 该 version 的全部 part。**
    ///
    /// ⚠️ 这是本层唯一的「哪个 transcript 算数」的答案,四处 SQL 都必须用它。
    /// 上一版四处各写各的 `ORDER BY version DESC, part DESC LIMIT 1` ——
    /// 那只取到**最后一块**:三小时的场次只显示第三块的纪要与逐字稿,
    /// `lineCount` 只数第三块。而 `TranscriptSearch.swift` 早就把这个坑写下来了
    /// (「按 `active_transcript_id` 过滤会把前面所有 part 的内容搜没,
    /// 正确的口径是按 `(session_id, version)`」),这里换了个字段重犯了一次。
    static func activeTranscripts(_ db: Database, sessionID: Int64) throws -> [Int64] {
        try Int64.fetchAll(db, sql: """
            SELECT id FROM transcripts
             WHERE session_id = ?
               AND version = (SELECT MAX(version) FROM transcripts WHERE session_id = ?)
             ORDER BY part
            """, arguments: [sessionID, sessionID])
    }

    private static func placeholders(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ",")
    }

    /// 四块的表名与它们各自的主文列 / 副文列。
    /// 加一块只加一行 —— 下面的读取逻辑不用动。
    private static let blocks: [(table: String, lead: String, detail: String?)] = [
        ("summary_key_points",  "text",   nil),
        ("summary_commitments", "what",   "to_whom_text"),
        ("summary_stances",     "stance", "premise"),
        ("summary_pendings",    "issue",  "parties_text"),
    ]

    /// 取某一场的详情。这一场没有生效的转写就返回 nil —— **不返回一个空壳**,
    /// 空壳会被界面画成「五块都没内容」,而事实是「还没到有纪要的时候」。
    static func detail(sessionID: Int64, eventID: Int64? = nil, in reader: some DatabaseReader) throws -> SessionDetail? {
        try reader.read { db -> SessionDetail? in
            // ⚠️ **一场 = 该 version 的全部 part**,见 `activeTranscripts` 的注释。
            // 上一版 `ORDER BY version DESC, part DESC LIMIT 1` 只取到最后一块:
            // 三小时的场次只显示第三块的纪要与逐字稿,而且不报错。
            let tids = try activeTranscripts(db, sessionID: sessionID)
            guard !tids.isEmpty,
                  let head = try Row.fetchOne(db, sql: """
                    SELECT started_at, ended_at, source FROM sessions WHERE id = ?
                    """, arguments: [sessionID])
            else { return nil }

            let marks = placeholders(tids.count)
            let args = StatementArguments(tids)

            let lineCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM transcript_lines WHERE transcript_id IN (\(marks))
                """, arguments: args) ?? 0

            // 没有说话人的行(M1-34「要看见」)。**空洞行不算** ——
            // 它本来就没人说话,算进去会把每一场都显示成有缺失。
            let linesWithoutSpeaker = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM transcript_lines l
                 WHERE l.transcript_id IN (\(marks)) AND l.is_gap = 0 AND l.redacted = 0
                   AND NOT EXISTS (SELECT 1 FROM line_speakers ls
                                    WHERE ls.line_id = l.line_id
                                      AND (ls.person_id IS NOT NULL OR ls.cluster_tag IS NOT NULL))
                """, arguments: args) ?? 0

            // 认人任务的状态(M2-认6 的「界面上说出来」半,M2-认8 ④ 验收项):
            // 「还在整理(会自己好)」与「判完了但有些句子没认出(不会自己变)」
            // 对应完全不同的动作,不能都塌缩成一行「N 句没有说话人」。
            let voiceprintState = try String.fetchOne(db, sql: """
                SELECT state FROM tasks
                 WHERE session_id = ? AND kind = 'voiceprint'
                 ORDER BY task_id DESC LIMIT 1
                """, arguments: [sessionID])

            let spanMs = try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(t_end_ms), 0) FROM transcript_lines
                 WHERE transcript_id IN (\(marks))
                """, arguments: args) ?? 0

            // 称呼**全 App 一套**,见 `SpeakerNaming` ——
            // 这里曾经自己编过一遍,结果和本人确认页对不上,用户会确认错人。
            let speakers = try SpeakerNaming.inSession(db, transcriptIDs: tids)
            // 场内上下文 ⇒ 名字省掉场次前缀(见 `SpeakerNaming.Scope`)。
            let label = try SpeakerNaming.labels(in: db, scope: .session(sessionID))

            // 一句话取**第一块**那条(整场结论只写一次)。多块都有说明抽取写重了,
            // 那时取第一块比取「排序碰巧最后的那块」可复现。
            let oneLiner = try String.fetchOne(db, sql: """
                SELECT one_liner FROM summaries WHERE transcript_id IN (\(marks))
                 ORDER BY transcript_id LIMIT 1
                """, arguments: args)

            var read: [String: [SummaryItem]] = [:]
            for b in blocks {
                read[b.table] = try items(db, transcriptIDs: tids, block: b).map {
                    guard let raw = $0.speaker else { return $0 }
                    return SummaryItem(id: $0.id, lead: $0.lead, detail: $0.detail,
                                       quote: $0.quote, lineID: $0.lineID,
                                       atMillis: $0.atMillis, speaker: label[raw] ?? raw,
                                       pendingReason: $0.pendingReason)
                }
            }

            // 承诺的三要素:**谁 → 对谁 → 什么**。PRD 有两条看似冲突的条文,
            // 而它们针对的是**两种性质不同的空**:
            //
            //   §4.2.3「三要素缺一不列」 → 针对**抽取质量**:模型没抽出「对谁」,
            //       这条承诺本身就是残的,而且不会自己变好。
            //   §4.1.7「说话人整理中 → 正常查看(表态与承诺归属留空)」 → 针对**归属进度**:
            //       内容是齐的,只是还不知道谁说的,而这个**会自己好**
            //       (Mac / 声纹 / 用户确认任一到位就补上)。
            //
            // 上一版只认「空不空」不认「为什么空」,于是归属没跑时**所有承诺被清空** ——
            // 而归属没跑是 M1 的常态,PRD 自己又写着「漏掉承诺是纪要最贵的失误」。
            //
            // ⚠️ 声纹上线也不会让这个分支消失:开集拒识摆在那儿,
            // 匹配不上的行「谁」照样是空的。这是**常态分支**,不是过渡期补丁。
            func filled(_ t: String?) -> Bool {
                // 空白字符串也算缺。LLM 输出 " " / "\n" / "—" 很常见,
                // 只挡 "" 的话它们会以「三要素齐」的身份混进来。
                (t?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            }
            let allCommitments = read["summary_commitments"] ?? []
            let commitments = allCommitments.filter { filled($0.detail) && filled($0.lead) }

            // 我说的承诺(`M5-1`):`line_speakers.person_id = 本人`。按 id 认,不按称呼字符串认 ——
            // 称呼是给人看的,改个名字就对不上了。
            let startedAt: String = head["started_at"]
            let events = try detailEvents(db, transcriptIDs: tids, startedAt: startedAt, label: label)

            var out = SessionDetail(
                sessionID: sessionID,
                startTime: HomeProjection.clockTime(fromISO: head["started_at"]),
                durationMinutes: spanMs / 60_000,
                speakers: speakers,
                oneLiner: oneLiner,
                keyPoints: read["summary_key_points"] ?? [],
                commitments: commitments,
                stances: read["summary_stances"] ?? [],
                pendings: read["summary_pendings"] ?? [],
                commitmentsWithheld: allCommitments.count - commitments.count,
                lineCount: lineCount,
                linesWithoutSpeaker: linesWithoutSpeaker,
                voiceprintState: voiceprintState,
                // 「已确认为本人」= 这一场里有行归给了 `mePersonID`,
                // **而且是用户确认的**。声纹判出来的不算 —— PRD §4.2.3 要的是
                // 「已确认」,而自动来源随时可能被推翻。
                hasConfirmedMe: (try Bool.fetchOne(db, sql: """
                    SELECT 1 FROM line_speakers ls
                      JOIN transcript_lines l ON l.line_id = ls.line_id
                     WHERE l.transcript_id IN (\(marks))
                       AND ls.person_id = ? AND ls.source = '\(AttributionSource.userConfirmed.rawValue)'
                     LIMIT 1
                    """, arguments: args + [SpeakerNaming.mePersonID])) ?? false,
                source: head["source"])
            out.events = events
            // 标题取第一个**还有内容**的事件:被移出记忆的段落标题是墓碑字样,
            // 拿它当整场标题会让人以为整场都删了(2026-10-12 对抗审查)。
            out.title = sessionTitle(eventTitles: events.map(\.title))
            let personal = try PersonalActionStore.recognized(in: db).filter { $0.sessionID == sessionID && $0.isMine && $0.admissionKind == "accepted" }
            out.myCommitments = personal.enumerated().map { index, source in
                SummaryItem(id: -Int64(index + 1), lead: source.title, detail: source.detail,
                            quote: source.quote, lineID: source.lineID, atMillis: source.atMillis,
                            speaker: "本人", pendingReason: nil)
            }
            // 「另有 N 条没抽全、没有列出」里**减掉已经在「你要做的」里列出的** ——
            // 我说的承诺不做三要素过滤,它列出来了就不能再说「没有列出」。
            let personalLines = Set(personal.map(\.lineID))
            let listed = Set(allCommitments.filter { personalLines.contains($0.lineID) }.map(\.id)).union(commitments.map(\.id))
            out = SessionDetail(
                sessionID: out.sessionID, startTime: out.startTime,
                durationMinutes: out.durationMinutes, speakers: out.speakers,
                oneLiner: out.oneLiner, keyPoints: out.keyPoints, commitments: out.commitments,
                stances: out.stances, pendings: out.pendings,
                commitmentsWithheld: allCommitments.filter { !listed.contains($0.id) }.count,
                lineCount: out.lineCount, linesWithoutSpeaker: out.linesWithoutSpeaker,
                voiceprintState: out.voiceprintState, hasConfirmedMe: out.hasConfirmedMe,
                title: out.title, events: out.events, myCommitments: out.myCommitments,
                source: out.source)
            if let eventID {
                guard let event=events.first(where:{ $0.id==eventID }) else {
                    throw ContinuousIngestion.Failure.invalid("这件事已重新整理，请从最新事件列表打开")
                }
                let ids = try eventLineIDs(eventID, transcriptIDs: tids, in: db)
                let rows = ids.isEmpty ? [] : try Row.fetchAll(db,sql:"""
                    SELECT DISTINCT l.line_id,l.t_start_ms,l.t_end_ms,l.is_gap,ls.person_id,ls.cluster_tag,ls.source
                      FROM transcript_lines l
                      LEFT JOIN line_speakers ls ON ls.line_id=l.line_id
                     WHERE l.line_id IN (\(placeholders(ids.count))) AND l.redacted=0
                    """,arguments:StatementArguments(Array(ids)))
                let from=rows.map { $0["t_start_ms"] as Int }.min() ?? 0
                let to=rows.map { $0["t_end_ms"] as Int }.max() ?? from
                func selected(_ items:[SummaryItem])->[SummaryItem] { items.filter { ids.contains($0.lineID) } }
                let scopedAll=selected(allCommitments),scopedCommitments=selected(out.commitments),scopedMine=selected(out.myCommitments)
                let shownIDs=Set(scopedCommitments.map(\.id)).union(scopedAll.filter { item in scopedMine.contains { $0.lineID==item.lineID } }.map(\.id))
                return SessionDetail(sessionID:sessionID,startTime:event.clockRange?.components(separatedBy:"–").first ?? out.startTime,
                    durationMinutes:max(0,to-from)/60_000,speakers:event.speakers,oneLiner:event.summary,
                    keyPoints:selected(out.keyPoints),commitments:scopedCommitments,stances:selected(out.stances),pendings:selected(out.pendings),
                    commitmentsWithheld:scopedAll.filter { !shownIDs.contains($0.id) }.count,lineCount:rows.count,
                    linesWithoutSpeaker:rows.filter { ($0["is_gap"] as Int)==0 && ($0["person_id"] as Int64?)==nil && ($0["cluster_tag"] as String?)==nil }.count,
                    voiceprintState:out.voiceprintState,hasConfirmedMe:rows.contains { ($0["person_id"] as Int64?)==SpeakerNaming.mePersonID && ($0["source"] as String?)==AttributionSource.userConfirmed.rawValue },
                    title:event.title,events:[event],myCommitments:scopedMine,source:out.source)
            }
            return out
        }
    }

    /// 事件根身份可跨片延续；只取本场当前版本的有效片段，不用一个大区间夹入别的事件。
    static func eventLineIDs(_ eventID: Int64, transcriptIDs: [Int64], in db: Database) throws -> Set<Int64> {
        guard !transcriptIDs.isEmpty else { return [] }
        let fragments = try Row.fetchAll(db, sql: """
            SELECT id,transcript_id,first_line_id,last_line_id FROM summary_events
             WHERE transcript_id IN (\(placeholders(transcriptIDs.count))) AND title != ? AND summary != ?
            """, arguments: StatementArguments(transcriptIDs) + [MemoryRemoval.tombstoneText,MemoryRemoval.tombstoneText])
        var matched = false
        var ids = Set<Int64>()
        for fragment in fragments where try StreamContinuity.root(of: fragment["id"], in: db) == eventID {
            matched = true
            guard let first: Int64 = fragment["first_line_id"], let last: Int64 = fragment["last_line_id"] else { continue }
            ids.formUnion(try Int64.fetchAll(db, sql: "SELECT line_id FROM transcript_lines WHERE transcript_id=? AND line_id BETWEEN ? AND ? AND redacted=0",
                arguments: [fragment["transcript_id"] as Int64,first,last]))
        }
        guard matched else { throw ContinuousIngestion.Failure.invalid("这件事已重新整理，请从最新事件列表打开") }
        return ids
    }

    /// 一场的标题(`M5-1`):第一个**还有内容**的事件标题;一个都没有 ⇒ nil(界面退回一句话)。
    /// 🔴 **唯一出处** —— 此刻页列表行与详情页都走它,不然同一场两处长得不一样。
    static func sessionTitle(eventTitles: [String]) -> String? {
        eventTitles.first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0 != MemoryRemoval.tombstoneText
        }
    }

    /// 详情页的分段(`M5-1`)。起止钟点 = 场次开始 + 首行 / 末行的场内毫秒;
    /// 在场的人 = 这段行里出现过的说话人(读时现算,归属改了就跟着变);
    /// 话题 = `summary_topic_keys` 里行号落在这段里的。
    ///
    /// ⚠️ 老产物没有行范围:不编钟点、不编在场的人;话题只在**整场只有这一段**时挂上来
    /// (多段时分不清哪个话题属于哪段,宁可不挂)。
    static func detailEvents(_ db: Database, transcriptIDs tids: [Int64], startedAt: String,
                             label: [String: String]) throws -> [DetailEvent] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, transcript_id, title, summary, first_line_id, last_line_id, continuation_id
              FROM summary_events
             WHERE transcript_id IN (\(placeholders(tids.count))) AND title != ? AND summary != ?
             ORDER BY transcript_id, seq
            """, arguments: StatementArguments(tids)+[MemoryRemoval.tombstoneText,MemoryRemoval.tombstoneText])
        guard !rows.isEmpty else { return [] }
        let liveLineIDs = try Int64.fetchSet(db,sql:"SELECT line_id FROM transcript_lines WHERE transcript_id IN (\(placeholders(tids.count))) AND redacted=0 AND is_gap=0",arguments:StatementArguments(tids))

        // 话题:transcript → [(key, 行号)]
        var topicsByTranscript: [Int64: [(String, [Int64])]] = [:]
        for t in try Row.fetchAll(db, sql: """
            SELECT transcript_id, key, line_ids FROM summary_topic_keys
             WHERE transcript_id IN (\(placeholders(tids.count))) ORDER BY id
            """, arguments: StatementArguments(tids)) {
            let raw: String = t["line_ids"]
            let ids = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .split(separator: ",").compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }.filter { liveLineIDs.contains($0) }
            topicsByTranscript[t["transcript_id"], default: []].append((t["key"], ids))
        }

        // 钟点与页头同一个口径:**按 started_at 字面上的钟点加偏移**,不过时区转换 ——
        // 出差时设备时区与录音时区不同,换算一次页头写 14:00、这里写 15:00(2026-10-12 对抗审查)。
        let base = DayTimeline.minute(ofClock: HomeProjection.clockTime(fromISO: startedAt))
        func clock(_ ms: Int?) -> String? {
            guard let base, let ms else { return nil }
            let m = (base + ms / 60_000) % (24 * 60)
            return String(format: "%02d:%02d", m / 60, m % 60)
        }

        let fragments: [DetailEvent] = try rows.map { r in
            let tid: Int64 = r["transcript_id"]
            let first: Int64? = r["first_line_id"]
            let last: Int64? = r["last_line_id"]
            var range: String?
            var speakers: [String] = []
            var topics: [DetailEvent.Topic] = []
            if let first, let last {
                // 占位行(没录到的那段)时间戳落 0,不能拿来当起止 —— 取范围内真行的最小起点 / 最大终点。
                let span = try Row.fetchOne(db, sql: """
                    SELECT MIN(t_start_ms) AS a, MAX(t_end_ms) AS b FROM transcript_lines
                     WHERE transcript_id = ? AND line_id BETWEEN ? AND ? AND is_gap = 0 AND redacted=0
                    """, arguments: [tid, first, last])
                let a: Int? = span?["a"], b: Int? = span?["b"]
                if let s = clock(a), let e = clock(b) { range = s == e ? s : "\(s)–\(e)" }
                speakers = try String.fetchAll(db, sql: """
                    SELECT \(SpeakerNaming.keyExpr(session: "t.session_id")) AS speaker
                      FROM transcript_lines l
                      JOIN transcripts      t ON t.id = l.transcript_id
                      LEFT JOIN line_speakers ls ON ls.line_id = l.line_id
                     WHERE l.transcript_id = ? AND l.line_id BETWEEN ? AND ?
                       AND l.is_gap = 0 AND l.redacted = 0
                     GROUP BY speaker HAVING speaker IS NOT NULL
                     ORDER BY MIN(l.seq)
                    """, arguments: [tid, first, last]).map { label[$0] ?? $0 }
                for (key, ids) in topicsByTranscript[tid] ?? [] {
                    if let hit = ids.filter({ $0 >= first && $0 <= last }).min() {
                        topics.append(.init(key: key, firstLineID: hit))
                    }
                }
            } else if rows.count == 1 {
                for (key, ids) in topicsByTranscript[tid] ?? [] {
                    if let hit = ids.min() { topics.append(.init(key: key, firstLineID: hit)) }
                }
            }
            return DetailEvent(id: try StreamContinuity.root(of: r["id"], in: db), title: r["title"], summary: r["summary"],
                               clockRange: range, speakers: speakers, topics: topics)
        }
        var ordered: [DetailEvent] = []
        for event in fragments {
            if let i = ordered.firstIndex(where: { $0.id == event.id }) {
                let old = ordered[i]
                let start = old.clockRange?.components(separatedBy: "–").first
                let end = event.clockRange?.components(separatedBy: "–").last
                let range = start.flatMap { s in end.map { e in s == e ? s : "\(s)–\(e)" } } ?? old.clockRange ?? event.clockRange
                let title = old.title == MemoryRemoval.tombstoneText ? event.title : old.title
                let summaries = [old.summary, event.summary].filter { $0 != MemoryRemoval.tombstoneText }
                ordered[i] = DetailEvent(id: old.id, title: title,
                    summary: old.summary == event.summary ? old.summary : summaries.joined(separator: "\n\n"),
                    clockRange: range, speakers: NSOrderedSet(array: old.speakers + event.speakers).array as? [String] ?? [],
                    topics: Array(Set(old.topics + event.topics)).sorted { $0.firstLineID < $1.firstLineID })
            } else { ordered.append(event) }
        }
        return ordered.filter { $0.title != MemoryRemoval.tombstoneText && $0.summary != MemoryRemoval.tombstoneText }
    }

    private static func items(_ db: Database, transcriptIDs: [Int64],
                              block: (table: String, lead: String, detail: String?)) throws
        -> [SummaryItem] {
        let detailCol = block.detail.map { "x.\($0)" } ?? "NULL"
        let rows = try Row.fetchAll(db, sql: """
            SELECT x.id            AS id,
                   x.\(block.lead) AS lead,
                   \(detailCol)    AS detail,
                   x.quote         AS quote,
                   x.line_id       AS line_id,
                   l.t_start_ms    AS at_ms,
                   \(SpeakerNaming.keyExpr(session: "t.session_id")) AS speaker,
                   CASE WHEN x.pending = 1 THEN x.pending_reason END    AS pending_reason
              FROM \(block.table) x
              JOIN transcript_lines l ON l.line_id = x.line_id
              JOIN transcripts      t ON t.id = l.transcript_id
              LEFT JOIN line_speakers ls ON ls.line_id = x.line_id
             WHERE x.transcript_id IN (\(placeholders(transcriptIDs.count)))
             ORDER BY x.transcript_id, x.seq
            """, arguments: StatementArguments(transcriptIDs))

        return rows.map {
            SummaryItem(id: $0["id"], lead: $0["lead"], detail: $0["detail"],
                        quote: $0["quote"], lineID: $0["line_id"],
                        atMillis: $0["at_ms"], speaker: $0["speaker"],
                        pendingReason: $0["pending_reason"])
        }
    }

    // MARK: - 原话上下文

    /// PRD §4.2.5:前后各 3 句 + 本条高亮。
    ///
    /// 按 `seq` 取窗口而不是按时间 —— 时间上相邻的两行可能跨了一个空洞占位行,
    /// 而用户要看的是「这句话前后说了什么」。
    static func quoteContext(lineID: Int64, eventID: Int64? = nil, in reader: some DatabaseReader) throws -> QuoteContext {
        try reader.read { db in
            guard let anchor = try Row.fetchOne(db, sql: """
                SELECT transcript_id, seq FROM transcript_lines WHERE line_id = ?
                """, arguments: [lineID]) else { return QuoteContext(lines: []) }

            let tid: Int64 = anchor["transcript_id"]
            let seq: Int = anchor["seq"]
            let r = QuoteContext.radius
            // 这一屏是某一场里的前后 3 句 ⇒ 场内上下文。
            let sid = try Int64.fetchOne(db, sql: """
                SELECT session_id FROM transcripts WHERE id = ?
                """, arguments: [tid])
            var eventIDs: Set<Int64>?
            if let eventID {
                guard let sid else { throw ContinuousIngestion.Failure.invalid("事件的出处已不存在") }
                eventIDs = try eventLineIDs(eventID, transcriptIDs: activeTranscripts(db,sessionID:sid), in: db)
                guard eventIDs!.contains(lineID) else { throw ContinuousIngestion.Failure.invalid("原话已不在这件事的有效范围内") }
            }
            let label = try SpeakerNaming.labels(
                in: db, scope: sid.map { .session($0) } ?? .global)

            let rows = try Row.fetchAll(db, sql: """
                SELECT l.line_id, l.t_start_ms, l.text, l.is_gap, l.redacted,
                       \(SpeakerNaming.keyExpr(session: "t.session_id")) AS speaker
                  FROM transcript_lines l
                  JOIN transcripts      t ON t.id = l.transcript_id
                  LEFT JOIN line_speakers ls ON ls.line_id = l.line_id
                 WHERE l.transcript_id = ? AND l.seq BETWEEN ? AND ?
                 ORDER BY l.seq
                """, arguments: [tid, seq - r, seq + r])

            return QuoteContext(lines: rows.filter { eventIDs?.contains($0["line_id"]) ?? true }.map { row in
                let id: Int64 = row["line_id"]
                // 抹除过的行**不显示原文**。库里 redacted 的语义就是「这段不该再被看到」,
                // 界面照读等于把抹除撤销了(§墓碑通道)。
                let redacted = (row["redacted"] as Int? ?? 0) == 1
                return QuoteContext.Line(
                    id: id,
                    atMillis: row["t_start_ms"],
                    text: redacted ? "(这段已抹除)" : row["text"],
                    speaker: (row["speaker"] as String?).map { label[$0] ?? $0 },
                    isGap: (row["is_gap"] as Int? ?? 0) == 1,
                    isRedacted: redacted,
                    isTarget: id == lineID)
            })
        }
    }

    /// 整场逐字稿。行数可能上万,所以只取需要的列。
    static func transcript(sessionID: Int64, eventID: Int64? = nil, in reader: some DatabaseReader) throws
        -> [QuoteContext.Line] {
        try reader.read { db in
            let tids = try activeTranscripts(db, sessionID: sessionID)
            guard !tids.isEmpty else { return [] }
            let eventIDs = try eventID.map { try eventLineIDs($0, transcriptIDs: tids, in: db) }

            let label = try SpeakerNaming.labels(in: db, scope: .session(sessionID))
            return try Row.fetchAll(db, sql: """
                SELECT l.line_id, l.t_start_ms, l.text, l.is_gap, l.redacted,
                       \(SpeakerNaming.keyExpr(session: "t.session_id")) AS speaker
                  FROM transcript_lines l
                  JOIN transcripts      t ON t.id = l.transcript_id
                  LEFT JOIN line_speakers ls ON ls.line_id = l.line_id
                 WHERE l.transcript_id IN (\(placeholders(tids.count)))
                 ORDER BY l.transcript_id, l.seq
                """, arguments: StatementArguments(tids)).filter { eventIDs?.contains($0["line_id"]) ?? true }.map { row in
                let redacted = (row["redacted"] as Int? ?? 0) == 1
                return QuoteContext.Line(
                    id: row["line_id"],
                    atMillis: row["t_start_ms"],
                    text: redacted ? "(这段已抹除)" : row["text"],
                    speaker: (row["speaker"] as String?).map { label[$0] ?? $0 },
                    isGap: (row["is_gap"] as Int? ?? 0) == 1,
                    isRedacted: redacted,
                    isTarget: false)
            }
        }
    }
}
