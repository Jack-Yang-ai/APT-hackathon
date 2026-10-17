import Foundation
import GRDB

/// 当前问答附带的记录背景。nil 表示按问题检索全部记录。
struct AskScope: Equatable {
    let sessionID: Int64
    var eventID: Int64? = nil

    func label(in db: Database) throws -> String {
        guard let head = try Row.fetchOne(db, sql: "SELECT started_at, removed_at FROM sessions WHERE id = ?", arguments: [sessionID]),
              head["removed_at"] as String? == nil else {
            throw ContinuousIngestion.Failure.invalid("这份记录已经移出记忆")
        }
        if let eventID {
            let tids = try SessionDetailProjection.activeTranscripts(db, sessionID:sessionID)
            guard let event = try SessionDetailProjection.detailEvents(db,transcriptIDs:tids,startedAt:head["started_at"],label:[:]).first(where: { $0.id == eventID }) else {
                throw ContinuousIngestion.Failure.invalid("这件事已重新整理，请从最新详情继续问")
            }
            return String(event.title.prefix(100))
        }
        return "\(HomeProjection.clockTime(fromISO: head["started_at"])) 的记录"
    }

    static func latestReceived(in db: Database) throws -> AskScope? {
        let id = try Int64.fetchOne(db, sql: """
            SELECT id FROM sessions WHERE source = ? AND status = ? AND removed_at IS NULL
             ORDER BY julianday(started_at) DESC, id DESC LIMIT 1
            """, arguments: [SessionSource.watch, SessionBridge.Status.open])
        return id.map { AskScope(sessionID: $0) }
    }

    static func latestWithWords(in db: Database) throws -> AskScope? {
        let id = try Int64.fetchOne(db, sql: """
            SELECT s.id FROM sessions s WHERE s.removed_at IS NULL AND EXISTS(
              SELECT 1 FROM transcripts t JOIN transcript_lines l ON l.transcript_id = t.id
               WHERE t.session_id = s.id AND t.version = (SELECT MAX(version) FROM transcripts WHERE session_id = s.id)
                 AND l.is_gap = 0 AND l.redacted = 0)
             ORDER BY julianday(s.started_at) DESC, s.id DESC LIMIT 1
            """)
        return id.map { AskScope(sessionID: $0) }
    }

    /// 最近原话总会参与当前范围，不把“刚才定了什么”交给关键词碰运气。
    func materials(for question: String, in db: Database) throws -> [AskRetrieval.Material] {
        _ = try label(in: db)
        let allowed = try eventID.map { try SessionDetailProjection.eventLineIDs($0,transcriptIDs:SessionDetailProjection.activeTranscripts(db,sessionID:sessionID),in:db) }
        if allowed?.isEmpty == true { return [] }
        let eventFilter = allowed.map { "AND l.line_id IN (\(Array(repeating:"?",count:$0.count).joined(separator:",")))" } ?? ""
        var args: [DatabaseValueConvertible?] = [sessionID]
        if let allowed { args += allowed.map { $0 as DatabaseValueConvertible? } }
        let rows = try Row.fetchAll(db, sql: """
            SELECT l.line_id, l.text, l.t_start_ms, s.started_at FROM transcript_lines l
              JOIN transcripts t ON t.id = l.transcript_id JOIN sessions s ON s.id = t.session_id
             WHERE t.session_id = ? AND t.version = (SELECT MAX(version) FROM transcripts WHERE session_id = s.id)
               AND l.redacted = 0 AND l.is_gap = 0 AND s.removed_at IS NULL \(eventFilter)
             ORDER BY t.part DESC, l.seq DESC LIMIT 28
            """, arguments: StatementArguments(args))
        let recent = rows.reversed().map { row in
            AskRetrieval.Material(hit: TranscriptSearch.Hit(lineID: row["line_id"], sessionID: sessionID,
                sessionStartedAt: row["started_at"], atMillis: row["t_start_ms"], text: row["text"], snippet: row["text"]), matchedTerms: 0)
        }
        let found = try AskRetrieval.materials(for: question, in: db).filter { $0.hit.sessionID == sessionID }
        var seen = Set<Int64>()
        return (recent + found.filter { allowed?.contains($0.hit.lineID) ?? true })
            .filter { seen.insert($0.hit.lineID).inserted }
    }
}
