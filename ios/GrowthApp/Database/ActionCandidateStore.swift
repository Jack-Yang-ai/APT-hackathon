import Foundation
import GRDB
import CryptoKit

/// AI 候选与用户个人行动分开；重识别只更新候选，纪要和用户记录不动。
enum ActionCandidateStore {
    static func sessionLines(_ sessionID: Int64, in db: Database) throws -> [ExtractValidate.Line] {
        try ExtractionRunner.activeTranscripts(db, sessionID: sessionID).flatMap { try ExtractionRunner.lines(db, transcriptID: $0) }
    }

    static func sessionRevision(_ sessionID: Int64, in db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(r.id),0) FROM transcript_line_revisions r JOIN transcript_lines l ON l.line_id=r.line_id JOIN transcripts t ON t.id=l.transcript_id WHERE t.session_id=? AND t.version=(SELECT MAX(version) FROM transcripts WHERE session_id=?)", arguments: [sessionID,sessionID]) ?? 0
    }
    static func snapshot(_ lines: [ExtractValidate.Line]) throws -> String {
        let body = lines.map { [String($0.lineID), $0.text, $0.isGap ? "1" : "0", $0.clusterTag ?? "", $0.personID.map { String($0) } ?? "", $0.startSeconds.map { String($0) } ?? "", $0.endSeconds.map { String($0) } ?? ""] }
        return SHA256.hash(data: try JSONEncoder().encode(body)).map { String(format: "%02x", $0) }.joined()
    }

    static func isCurrent(_ transcriptID: Int64, in db: Database) throws -> Bool {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM action_assessments WHERE transcript_id=?", arguments: [transcriptID]),
              row["protocol"] as String == ActionExtraction.protocolVersion else { return false }
        let scope: String = row["scope"]
        guard let sessionID = try Int64.fetchOne(db, sql: "SELECT session_id FROM transcripts WHERE id=?", arguments: [transcriptID]) else { throw ExtractionStore.Failure.staleSource }
        let revision = scope == "session" ? try sessionRevision(sessionID, in: db) : try Int64.fetchOne(db, sql: """
            SELECT COALESCE(MAX(r.id),0) FROM transcript_line_revisions r JOIN transcript_lines l ON l.line_id=r.line_id WHERE l.transcript_id=?
            """, arguments: [transcriptID]) ?? 0
        let hash = try snapshot(scope == "session" ? sessionLines(sessionID, in: db) : ExtractionRunner.lines(db, transcriptID: transcriptID))
        let closed = try String.fetchOne(db, sql: "SELECT status FROM sessions WHERE id=?", arguments: [sessionID]) == "closed"
        if closed && scope != "session" { return false }
        return row["source_revision"] as Int64 == revision && row["snapshot"] as String == hash
    }

    @discardableResult
    static func store(_ payload: [String: Any], transcriptID: Int64, now: String,
                      expectedLines: [ExtractValidate.Line], expectedRevision: Int64? = nil, in writer: some DatabaseWriter) throws -> Int {
        try writer.write { try write(payload, transcriptID: transcriptID, now: now, expectedLines: expectedLines, expectedRevision: expectedRevision, in: $0) }
    }

    @discardableResult
    static func write(_ payload: [String: Any], transcriptID: Int64, now: String,
                      expectedLines: [ExtractValidate.Line]? = nil, expectedRevision: Int64? = nil,
                      sessionScope: Bool = false, in db: Database) throws -> Int {
        guard payload["action_protocol"] != nil || payload["personal_actions"] != nil else { return 0 }
        guard let sessionID = try Int64.fetchOne(db, sql: "SELECT session_id FROM transcripts WHERE id=?", arguments: [transcriptID]) else { throw ExtractionStore.Failure.staleSource }
        let singlePart = try ExtractionRunner.activeTranscripts(db, sessionID: sessionID).count == 1
        let sessionScope = sessionScope || singlePart
        let lines = try sessionScope ? sessionLines(sessionID, in: db) : ExtractionRunner.lines(db, transcriptID: transcriptID)
        let active = try Bool.fetchOne(db, sql: """
            SELECT s.removed_at IS NULL AND t.version=(SELECT MAX(version) FROM transcripts WHERE session_id=t.session_id)
              FROM transcripts t JOIN sessions s ON s.id=t.session_id WHERE t.id=?
            """, arguments: [transcriptID]) ?? false
        guard active, try expectedLines.map({ try snapshot($0) == snapshot(lines) }) ?? true else { throw ExtractionStore.Failure.staleSource }
        let clean = try ActionExtraction.validate(payload, lines: lines)
        guard let items = clean["personal_actions"] as? [[String: Any]] else { throw ExtractValidate.Failure.schema("未完成个人行动识别") }
        let revision = sessionScope ? try sessionRevision(sessionID, in: db) : try Int64.fetchOne(db, sql: """
            SELECT COALESCE(MAX(r.id),0) FROM transcript_line_revisions r JOIN transcript_lines l ON l.line_id=r.line_id WHERE l.transcript_id=?
            """, arguments: [transcriptID]) ?? 0
        if let expectedRevision, expectedRevision != revision { throw ExtractionStore.Failure.staleSource }
        try db.execute(sql: "DELETE FROM action_candidates WHERE transcript_id=?", arguments: [transcriptID])
        try db.execute(sql: """
            INSERT INTO action_assessments(transcript_id,protocol,snapshot,source_revision,created_at,scope) VALUES(?,?,?,?,?,?)
            ON CONFLICT(transcript_id) DO UPDATE SET protocol=excluded.protocol,snapshot=excluded.snapshot,source_revision=excluded.source_revision,created_at=excluded.created_at,scope=excluded.scope
            """, arguments: [transcriptID, ActionExtraction.protocolVersion, try snapshot(lines), revision, now, sessionScope ? "session" : "transcript"])
        var sequences: [Int64: Int] = [:]
        for item in items {
            let id = ActionExtraction.integer(item["line_id"])!
            let seq = sequences[id, default: 0]; sequences[id] = seq + 1
            let evidence = String(decoding: try JSONSerialization.data(withJSONObject: item["evidence"]!, options: [.sortedKeys]), as: UTF8.self)
            try db.execute(sql: """
                INSERT INTO action_candidates(transcript_id,line_id,seq,kind,title,quote,evidence,condition_text,deadline_text,collaborators_text) VALUES(?,?,?,?,?,?,?,?,?,?)
                """, arguments: [transcriptID, id, seq, item["kind"] as? String, item["title"] as? String, item["quote"] as? String,
                                   evidence, item["condition_text"] as? String, item["deadline_text"] as? String, item["collaborators_text"] as? String])
        }
        return items.count
    }

    static func isSessionCurrent(_ sessionID: Int64, in db: Database) throws -> Bool {
        let tids = try ExtractionRunner.activeTranscripts(db, sessionID: sessionID)
        guard !tids.isEmpty else { return false }
        for id in tids where try !isCurrent(id, in: db) { return false }
        return true
    }

    @discardableResult
    static func storeSession(_ payload: [String: Any], sessionID: Int64, now: String,
                             expectedLines: [ExtractValidate.Line], expectedRevision: Int64,
                             in writer: some DatabaseWriter) throws -> Int {
        try writer.write { db in
            guard try snapshot(sessionLines(sessionID, in: db)) == snapshot(expectedLines),
                  try sessionRevision(sessionID, in: db) == expectedRevision else { throw ExtractionStore.Failure.staleSource }
            let clean = try ActionExtraction.validate(payload, lines: expectedLines)
            guard let items = clean["personal_actions"] as? [[String: Any]] else { throw ExtractValidate.Failure.schema("整场尚未完成个人行动识别") }
            for tid in try ExtractionRunner.activeTranscripts(db, sessionID: sessionID) {
                let ids = Set(try ExtractionRunner.lines(db, transcriptID: tid).map(\.lineID))
                let part: [String: Any] = ["action_protocol": ActionExtraction.protocolVersion, "personal_actions": items.filter { ActionExtraction.integer($0["line_id"]).map(ids.contains) ?? false }]
                _ = try write(part, transcriptID: tid, now: now, expectedLines: expectedLines, expectedRevision: expectedRevision, sessionScope: true, in: db)
            }
            return items.count
        }
    }

    struct LegacySession: Identifiable { let id: Int64; let title: String; let busy: Bool }

    static func unassessedSessions(in db: Database) throws -> [LegacySession] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.id,t.session_id,s.started_at,
                   (SELECT state FROM tasks WHERE session_id=s.id AND kind=? ORDER BY task_id DESC LIMIT 1) AS task_state
              FROM transcripts t JOIN sessions s ON s.id=t.session_id
             WHERE s.removed_at IS NULL AND s.status='closed' AND t.version=(SELECT MAX(version) FROM transcripts WHERE session_id=s.id)
               AND EXISTS(SELECT 1 FROM summaries WHERE transcript_id=t.id)
               AND EXISTS(SELECT 1 FROM transcript_lines WHERE transcript_id=t.id AND is_gap=0 AND redacted=0)
             ORDER BY s.started_at DESC,t.part
            """, arguments: [ProcessingOrchestrator.Kind.extract])
        var seen = Set<Int64>(); var result: [LegacySession] = []
        for r in rows where try !isCurrent(r["id"], in: db) {
            let id: Int64 = r["session_id"]
            if seen.insert(id).inserted {
                let state: String? = r["task_state"]
                result.append(LegacySession(id: id, title: "录音 · \(r["started_at"] as String)", busy: ["queued","running","retrying","waiting_network"].contains(state ?? "")))
            }
        }
        return result
    }

    static func requestReassessment(_ sessionID: Int64, now: String, in writer: some DatabaseWriter) throws {
        try writer.write { db in
            guard try unassessedSessions(in: db).contains(where: { $0.id == sessionID }) else {
                throw ContinuousIngestion.Failure.invalid("这场录音尚无可重新识别的原话，或已经识别完成")
            }
            let state = try String.fetchOne(db, sql: "SELECT state FROM tasks WHERE session_id=? AND kind=?", arguments: [sessionID,ProcessingOrchestrator.Kind.extract])
            if ["queued","running","retrying","waiting_network"].contains(state ?? "") { return }
            let token = UUID().uuidString
            if state == nil {
                try db.execute(sql: "INSERT INTO tasks(session_id,kind,state,priority,attempts,created_at,action_request_token) VALUES(?,?,?,1,0,?,?)", arguments: [sessionID,ProcessingOrchestrator.Kind.extract,"queued",now,token])
            } else {
                try db.execute(sql: "UPDATE tasks SET state=?,attempts=0,next_retry_at=NULL,last_error=NULL,created_at=?,action_request_token=? WHERE session_id=? AND kind=?", arguments: ["queued",now,token,sessionID,ProcessingOrchestrator.Kind.extract])
            }
        }
    }
}
