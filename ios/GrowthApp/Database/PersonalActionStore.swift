import Foundation
import GRDB
import CryptoKit

enum ActionStatus: String, CaseIterable, Identifiable {
    case next, confirm, followup, doing, done, cancelled
    var id: String { rawValue }
    var title: String {
        switch self {
        case .next: return "下一步"
        case .confirm: return "待确认"
        case .followup: return "待跟进"
        case .doing: return "进行中"
        case .done: return "已完成"
        case .cancelled: return "已取消"
        }
    }
    var isClosed: Bool { self == .done || self == .cancelled }
}

struct ActionCandidate: Identifiable, Equatable {
    var id: String { sourceKey ?? "\(kind):\(lineID):\(seq)" }
    let kind: String
    let lineID: Int64
    let seq: Int
    let sessionID: Int64
    let version: Int
    let title: String
    let detail: String
    let quote: String
    let sourceTime: String
    let personID: Int64?
    let attribution: String?
    let pending: Bool
    let quoteIsCurrent: Bool
    let fingerprint: String
    var sourceKey: String? = nil
    var admissionKind: String? = nil
    var conditions: String = ""
    var deadlineText: String = ""
    var contextQuotes: [String] = []
    var atMillis: Int = 0
    var isMine: Bool { personID == SpeakerNaming.mePersonID }
    var evidence: String {
        if isMine { return "本人 · \(attribution ?? "归属待核")" }
        if personID != nil { return "已归属他人，需重新核验" }
        return "说话人待确认，尚不能认作你的承诺"
    }
}

struct PersonalAction: Identifiable, Equatable {
    let id: Int64
    var title: String
    var status: ActionStatus
    var resumeStatus: ActionStatus
    var deadline: String?
    var conditions: String
    var nextStep: String
    var collaborators: String
    let sourceKey: String?
    let sourceVersion: Int?
    let sourceFingerprint: String?
    var source: ActionCandidate?
    var sourceWarning: String?
    var removedAt: String? = nil
    var extractedDeadline: String = ""
    var shownStatus: ActionStatus { !status.isClosed && sourceWarning != nil ? .confirm : status }
}

/// 手机唯一写方。抽取只提供候选，用户保存后才建立行动；不自动覆盖用户字段。
enum PersonalActionStore {
    static let changed = Notification.Name("APTPersonalActionsChanged")

    static func candidates(in db: Database) throws -> [ActionCandidate] {
        let adopted = try String.fetchSet(db, sql: "SELECT source_key FROM personal_actions WHERE source_key IS NOT NULL")
        let ignored = try String.fetchSet(db, sql: "SELECT source_key FROM action_dismissals")
        let removedLines = try removedSourceLines(in: db)
        let legacyLines = try Int64.fetchSet(db, sql: "SELECT source_line_id FROM personal_actions WHERE source_line_id IS NOT NULL AND source_key NOT LIKE 'action:%'")
        return try sources(in: db).filter { $0.admissionKind != nil && $0.quoteIsCurrent && ($0.personID == nil || $0.isMine) && !adopted.contains($0.id) && !ignored.contains($0.id) && !legacyLines.contains($0.lineID) && !removedLines.contains($0.lineID) }
    }

    static func actions(in db: Database, includeRemoved: Bool = false) throws -> [PersonalAction] {
        let current = Dictionary(try sources(in: db).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return try Row.fetchAll(db, sql: "SELECT * FROM personal_actions \(includeRemoved ? "" : "WHERE removed_at IS NULL") ORDER BY updated_at DESC, id DESC").map { row in
            let key: String? = row["source_key"]
            let source = key.flatMap { current[$0] }
            let fingerprint: String? = row["source_fingerprint"]
            let warning: String?
            if key == nil { warning = nil }
            else if source == nil { warning = "当前识别结果或出处已变化，请核对原话和行动状态。" }
            else if source?.fingerprint != fingerprint { warning = "原话、提取结果或说话人归属已变化，请重新核验。" }
            else if source?.isMine != true { warning = "说话人尚未确认是你，这条仍需确认归属。" }
            else if source?.admissionKind == nil && row["admission_reviewed"] as Bool == false { warning = "旧提取尚未按个人待办核验，请重新识别或核对这件行动。" }
            else if source?.pending == true && row["source_reviewed"] as Bool == false { warning = "提取结果仍待核验，请先查看出处。" }
            else { warning = nil }
            return PersonalAction(id: row["id"], title: row["title"],
                status: ActionStatus(rawValue: row["status"])!, resumeStatus: ActionStatus(rawValue: row["resume_status"])!,
                deadline: row["deadline"], conditions: row["conditions"], nextStep: row["next_step"],
                collaborators: row["collaborators"], sourceKey: key, sourceVersion: row["source_version"],
                sourceFingerprint: fingerprint, source: source, sourceWarning: warning, removedAt: row["removed_at"], extractedDeadline: row["deadline_text"])
        }
    }

    @discardableResult
    static func create(title: String, status: ActionStatus = .next, deadline: String?, conditions: String, nextStep: String,
                       collaborators: String, deadlineText: String = "", now: String, in db: Database) throws -> Int64 {
        let title = try validTitle(title)
        try db.execute(sql: """
            INSERT INTO personal_actions(title,status,resume_status,deadline,conditions,next_step,collaborators,deadline_text,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """, arguments: [title, status.rawValue, (status.isClosed ? ActionStatus.next : status).rawValue,
                              deadline, conditions, nextStep, collaborators, deadlineText, now, now])
        return db.lastInsertedRowID
    }

    @discardableResult
    static func adopt(_ candidate: ActionCandidate, now: String, in db: Database) throws -> Int64 {
        // 重复点击也不能重开用户已完成／取消的记录。
        if let id = try Int64.fetchOne(db, sql: "SELECT id FROM personal_actions WHERE source_key = ?", arguments: [candidate.id]) { return id }
        guard try !removedSourceLines(in: db).contains(candidate.lineID) else {
            throw ContinuousIngestion.Failure.invalid("这条候选已忽略，请先在已移除中恢复")
        }
        guard let current = try sources(in: db).first(where: { $0.id == candidate.id }),
              current.fingerprint == candidate.fingerprint,
              current.admissionKind != nil, current.quoteIsCurrent,
              current.personID == nil || current.isMine else {
            throw ContinuousIngestion.Failure.invalid("来源已变化，请重新读取后确认")
        }
        let status: ActionStatus = !current.isMine || current.pending || current.admissionKind == "request" ? .confirm : current.admissionKind == "follow_up" ? .followup : .next
        try db.execute(sql: """
            INSERT INTO personal_actions(title,status,resume_status,collaborators,source_key,source_kind,
              source_line_id,source_seq,source_version,source_fingerprint,source_reviewed,created_at,updated_at,conditions,deadline_text)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, arguments: [try validTitle(current.title), status.rawValue, status.rawValue, current.detail,
                              current.id, current.kind, current.lineID, current.seq, current.version, current.fingerprint,
                              current.isMine && !current.pending, now, now, current.conditions, current.deadlineText])
        return db.lastInsertedRowID
    }

    static func update(_ action: PersonalAction, now: String, in db: Database) throws {
        // 保存时只改用户字段，不把界面持有的旧来源快照写回去。
        guard let current = try actions(in: db).first(where: { $0.id == action.id }) else {
            throw ContinuousIngestion.Failure.invalid("行动已不存在")
        }
        if !action.status.isClosed, action.status != .confirm, current.sourceWarning != nil {
            throw ContinuousIngestion.Failure.invalid("请先核验行动来源；当前只能保留待确认或关闭行动")
        }
        let resume = action.status.isClosed ? (current.status.isClosed ? current.resumeStatus : current.shownStatus) : action.status
        try db.execute(sql: """
            UPDATE personal_actions SET title=?,status=?,resume_status=?,deadline=?,conditions=?,next_step=?,collaborators=?,updated_at=?,deadline_text=? WHERE id=?
            """, arguments: [try validTitle(action.title), action.status.rawValue, resume.rawValue,
                              action.deadline, action.conditions, action.nextStep, action.collaborators, now, action.extractedDeadline, action.id])
    }

    /// 来源已确认为本人后，用户主动核验最新依据；保留全部编辑与完成状态。
    static func revalidate(_ id: Int64, now: String, in db: Database) throws {
        guard let action = try actions(in: db).first(where: { $0.id == id }),
              let source = action.source, source.isMine, source.quoteIsCurrent else {
            throw ContinuousIngestion.Failure.invalid("先在录音详情中确认本人并核对原话")
        }
        try db.execute(sql: "UPDATE personal_actions SET source_version=?,source_fingerprint=?,source_reviewed=1,admission_reviewed=1,updated_at=? WHERE id=?",
                       arguments: [source.version, source.fingerprint, now, id])
    }

    static func setStatus(_ id: Int64, status: ActionStatus?, now: String, in db: Database) throws {
        guard var action = try actions(in: db).first(where: { $0.id == id }) else {
            throw ContinuousIngestion.Failure.invalid("行动已不存在")
        }
        let wanted = status ?? action.resumeStatus
        action.status = !wanted.isClosed && action.sourceWarning != nil ? .confirm : wanted
        try update(action, now: now, in: db)
    }

    static func remove(_ id: Int64, now: String, in db: Database) throws {
        try db.execute(sql: "UPDATE personal_actions SET removed_at=COALESCE(removed_at,?),updated_at=? WHERE id=?", arguments: [now,now,id])
    }

    static func restore(_ id: Int64, now: String, in db: Database) throws {
        try db.execute(sql: "UPDATE personal_actions SET removed_at=NULL,updated_at=? WHERE id=?", arguments: [now,id])
    }

    static func dismissCandidate(_ candidate: ActionCandidate, now: String, in db: Database) throws {
        guard try Int64.fetchOne(db,sql:"SELECT id FROM personal_actions WHERE source_key=?",arguments:[candidate.id]) == nil,
              let current = try sources(in: db).first(where: { $0.id == candidate.id }),
              current.fingerprint == candidate.fingerprint, current.admissionKind != nil,
              current.quoteIsCurrent, current.personID == nil || current.isMine else {
            throw ContinuousIngestion.Failure.invalid("候选或来源已变化，请重新读取后操作")
        }
        try db.execute(sql:"INSERT INTO action_dismissals(source_key,source_line_id,removed_at) VALUES(?,?,?) ON CONFLICT(source_key) DO UPDATE SET removed_at=excluded.removed_at",arguments:[current.id,current.lineID,now])
    }

    struct Dismissal: Identifiable {
        let id: String
        let source: ActionCandidate?
        var title: String { source?.quoteIsCurrent == true ? source!.title : "出处已变化的候选" }
    }

    static func dismissals(in db: Database) throws -> [Dismissal] {
        let current = Dictionary(try sources(in: db).map { ($0.id,$0) },uniquingKeysWith:{ first,_ in first })
        return try String.fetchAll(db,sql:"SELECT source_key FROM action_dismissals ORDER BY removed_at DESC").map { Dismissal(id:$0,source:current[$0]) }
    }

    static func restoreCandidate(_ key: String, in db: Database) throws {
        try db.execute(sql:"DELETE FROM action_dismissals WHERE source_key=?",arguments:[key])
    }

    /// 用户拒绝的是这句原话提出来的事项，模型改写标题不能覆盖该判断。
    /// 同句有多个动作时先保守抑制，用户恢复后再重新确认。
    private static func removedSourceLines(in db: Database) throws -> Set<Int64> {
        try Int64.fetchSet(db, sql: """
            SELECT source_line_id FROM action_dismissals
            UNION SELECT source_line_id FROM personal_actions WHERE removed_at IS NOT NULL AND source_line_id IS NOT NULL
            """)
    }

    private static func validTitle(_ text: String) throws -> String {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ContinuousIngestion.Failure.invalid("请填写行动标题") }
        return title
    }

    /// “你要做的”复用个人行动准入；已完成／取消不再列成未办事项。
    static func recognized(in db: Database) throws -> [ActionCandidate] {
        let closed = try String.fetchSet(db, sql: "SELECT source_key FROM personal_actions WHERE source_key IS NOT NULL AND (removed_at IS NOT NULL OR status IN (?,?))", arguments: [ActionStatus.done.rawValue, ActionStatus.cancelled.rawValue])
        let closedLegacyLines = try Int64.fetchSet(db, sql: "SELECT source_line_id FROM personal_actions WHERE source_line_id IS NOT NULL AND source_key NOT LIKE 'action:%' AND (removed_at IS NOT NULL OR status IN (?,?))", arguments: [ActionStatus.done.rawValue, ActionStatus.cancelled.rawValue])
        let ignored = try String.fetchSet(db, sql: "SELECT source_key FROM action_dismissals")
        let removedLines = try removedSourceLines(in: db)
        return try sources(in: db).filter { $0.admissionKind != nil && $0.quoteIsCurrent && !closed.contains($0.id) && !ignored.contains($0.id) && !closedLegacyLines.contains($0.lineID) && !removedLines.contains($0.lineID) }
    }

    private static func admittedSources(in db: Database) throws -> [ActionCandidate] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT c.*,a.snapshot,a.source_revision,a.scope,t.session_id,t.version,s.started_at,l.text,l.t_start_ms,ls.person_id,ls.source AS attribution
              FROM action_candidates c JOIN action_assessments a ON a.transcript_id=c.transcript_id
              JOIN transcripts t ON t.id=c.transcript_id JOIN sessions s ON s.id=t.session_id
              JOIN transcript_lines l ON l.line_id=c.line_id LEFT JOIN line_speakers ls ON ls.line_id=l.line_id
             WHERE a.protocol=? AND s.removed_at IS NULL AND l.redacted=0 AND l.is_gap=0
               AND t.version=(SELECT MAX(version) FROM transcripts WHERE session_id=s.id)
             ORDER BY s.started_at DESC,t.part,c.line_id,c.seq
            """, arguments: [ActionExtraction.protocolVersion])
        var current: [Int64: Bool] = [:]
        var result: [ActionCandidate] = []
        for r in rows {
            let tid: Int64 = r["transcript_id"]
            if current[tid] == nil { current[tid] = try ActionCandidateStore.isCurrent(tid, in: db) }
            let evidenceText: String = r["evidence"]
            let evidence = (try? JSONSerialization.jsonObject(with: Data(evidenceText.utf8))) as? [[String: Any]] ?? []
            var context: [String] = []; var signatures: [String] = []
            var valid = current[tid] == true && !evidence.isEmpty
            for e in evidence {
                guard let id = ActionExtraction.integer(e["line_id"]), let quote = e["quote"] as? String,
                      let line = try Row.fetchOne(db, sql: "SELECT l.text,l.redacted,l.is_gap,ls.person_id,ls.source,ls.cluster_tag FROM transcript_lines l JOIN transcripts t ON t.id=l.transcript_id LEFT JOIN line_speakers ls ON ls.line_id=l.line_id WHERE l.line_id=? AND t.session_id=? AND t.version=?", arguments: [id,r["session_id"] as Int64,r["version"] as Int]) else { valid = false; continue }
                let text: String = line["text"]
                valid = valid && (line["redacted"] as Int == 0) && (line["is_gap"] as Int == 0) && TextNormalize.isVerbatim(quote: quote, source: text)
                context.append(text)
                signatures.append("\(id)|\(text)|\((line["person_id"] as Int64?).map(String.init) ?? "")|\(line["source"] as String? ?? "")")
            }
            let kind: String = r["kind"], lineID: Int64 = r["line_id"], seq: Int = r["seq"]
            let personID: Int64? = r["person_id"], attribution: String? = r["attribution"]
            let title: String = r["title"], detail: String = r["collaborators_text"]
            let fields = [String(r["version"] as Int),r["snapshot"] as String,String(r["source_revision"] as Int64),r["scope"] as String,title,kind,detail,r["condition_text"] as String,r["deadline_text"] as String,evidenceText,String(valid)] + signatures
            let fingerprint = SHA256.hash(data: try JSONEncoder().encode(fields)).map { String(format: "%02x", $0) }.joined()
            let hit = TranscriptSearch.Hit(lineID: lineID, sessionID: r["session_id"], sessionStartedAt: r["started_at"], atMillis: r["t_start_ms"], text: "", snippet: "")
            result.append(ActionCandidate(kind: kind == "accepted" ? "commitment" : "pending", lineID: lineID, seq: seq,
                sessionID: r["session_id"], version: r["version"], title: title, detail: detail, quote: r["text"], sourceTime: sourceTime(hit),
                personID: personID, attribution: attribution, pending: !valid || personID == nil, quoteIsCurrent: valid, fingerprint: fingerprint,
                sourceKey: "action:\(lineID):\(SHA256.hash(data: Data(TextNormalize.normalize(title).utf8)).map { String(format: "%02x", $0) }.joined())", admissionKind: kind, conditions: r["condition_text"], deadlineText: r["deadline_text"], contextQuotes: context, atMillis: r["t_start_ms"]))
        }
        return result
    }

    private static func sources(in db: Database) throws -> [ActionCandidate] {
        var result = try admittedSources(in: db)
        for (table, kind, body, detail) in [("summary_commitments", "commitment", "what", "to_whom_text"),
                                           ("summary_pendings", "pending", "issue", "parties_text")] {
            let rows = try Row.fetchAll(db, sql: """
                SELECT x.line_id,x.seq,x.\(body) AS title,x.\(detail) AS detail,x.quote,x.pending,x.pending_reason,
                       l.text,l.t_start_ms,t.session_id,t.version,s.started_at,ls.person_id,ls.source AS attribution,
                       COALESCE((SELECT MAX(id) FROM transcript_line_revisions WHERE line_id=l.line_id),0) AS revision,
                       EXISTS(SELECT 1 FROM transcript_line_revisions r WHERE r.line_id=l.line_id AND
                         r.id>COALESCE((SELECT source_revision FROM summaries WHERE transcript_id=t.id),0)) AS revised
                  FROM \(table) x JOIN transcripts t ON t.id=x.transcript_id
                  JOIN sessions s ON s.id=t.session_id JOIN transcript_lines l ON l.line_id=x.line_id
                  LEFT JOIN line_speakers ls ON ls.line_id=l.line_id
                 WHERE s.removed_at IS NULL AND l.redacted=0 AND l.is_gap=0
                   AND t.version=(SELECT MAX(version) FROM transcripts WHERE session_id=s.id)
                 ORDER BY s.started_at DESC,t.part,x.seq
                """)
            for row in rows {
                let title: String = row["title"]
                if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                let personID: Int64? = row["person_id"]
                let attribution: String? = row["attribution"]
                let quote: String = row["quote"], text: String = row["text"]
                let quoteCurrent = !(row["revised"] as Bool) && TextNormalize.isVerbatim(quote: quote, source: text)
                // 悬点历史 pending 不随 assignSpeaker 重算，仍保留待确认；本人逐字
                // 出处已有效时可由用户显式 revalidate，旧引文失配则不能采用。
                let pending = !quoteCurrent || (row["pending"] as Int) != 0
                let fields = [title, row["detail"] as String? ?? "", row["quote"] as String, row["text"] as String,
                              String(row["version"] as Int), personID.map(String.init) ?? "", attribution ?? "",
                              String(row["revision"] as Int64), String(row["pending"] as Int), String(row["revised"] as Bool)]
                let bytes = try JSONEncoder().encode(fields)
                let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                let hit = TranscriptSearch.Hit(lineID: row["line_id"], sessionID: row["session_id"],
                    sessionStartedAt: row["started_at"], atMillis: row["t_start_ms"], text: "", snippet: "")
                result.append(ActionCandidate(kind: kind, lineID: row["line_id"], seq: row["seq"], sessionID: row["session_id"],
                    version: row["version"], title: title, detail: row["detail"] ?? "", quote: text,
                    sourceTime: sourceTime(hit),
                    personID: personID, attribution: attribution, pending: pending, quoteIsCurrent: quoteCurrent, fingerprint: fingerprint))
            }
        }
        return result
    }

    private static func sourceTime(_ hit: TranscriptSearch.Hit) -> String {
        guard let start = ISO8601DateFormatter.growth.date(from: hit.sessionStartedAt) else { return hit.sessionStartedAt }
        return start.addingTimeInterval(Double(hit.atMillis) / 1000).formatted(date: .abbreviated, time: .shortened)
    }
}
