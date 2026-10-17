import Foundation
import GRDB

/// 跨片前文只取当前版本、同一采集场、已经完成的前一件事。
/// event_id 是手机 summary_events.id；E1/E2 只在一次模型调用内有效。
enum StreamContinuity {
    static let recipe = "v3-semantic-continuity"

    static func previousEvent(_ transcriptID: Int64, in db: Database) throws -> Row? {
        try Row.fetchOne(db, sql: """
            SELECT e.*, t.part, (SELECT MAX(t_end_ms) FROM transcript_lines
                                 WHERE transcript_id = e.transcript_id AND line_id BETWEEN e.first_line_id AND e.last_line_id
                                   AND is_gap = 0 AND redacted = 0) AS end_ms
              FROM summary_events e JOIN transcripts t ON t.id = e.transcript_id
              JOIN transcripts cur ON cur.id = ?
             WHERE t.session_id = cur.session_id AND t.version = cur.version AND t.part < cur.part
               AND e.first_line_id IS NOT NULL AND e.last_line_id IS NOT NULL
               AND e.title != ? AND EXISTS(SELECT 1 FROM stream_blocks WHERE transcript_id = cur.id)
             ORDER BY t.part DESC, e.seq DESC LIMIT 1
            """, arguments: [transcriptID, MemoryRemoval.tombstoneText])
    }

    static func context(_ transcriptID: Int64, in db: Database) throws -> [String: Any] {
        guard let previous = try previousEvent(transcriptID, in: db) else { return [:] }
        let rootID = try root(of: previous["id"], in: db)
        let rootTitle = try String.fetchOne(db, sql: "SELECT title FROM summary_events WHERE id = ?", arguments: [rootID])
        let tail = try String.fetchAll(db, sql: """
            SELECT text FROM transcript_lines WHERE transcript_id = ? AND line_id BETWEEN ? AND ?
              AND is_gap = 0 AND redacted = 0 ORDER BY seq DESC LIMIT 12
            """, arguments: [previous["transcript_id"] as Int64, previous["first_line_id"] as Int64,
                             previous["last_line_id"] as Int64]).reversed().joined(separator: "\n")
        return ["event_id": previous["id"] as Int64,
                "title": String((rootTitle ?? previous["title"] as String).prefix(240)),
                "latest_title": String((previous["title"] as String).prefix(240)),
                "summary": String((previous["summary"] as String).prefix(2400)),
                "tail": String(tail.suffix(1600)),
                "t_end_sec": Double(previous["end_ms"] as Int? ?? 0) / 1000]
    }

    static func root(of eventID: Int64, in db: Database) throws -> Int64 {
        var id = eventID
        var visited = Set<Int64>()
        while visited.insert(id).inserted {
            guard let row = try Row.fetchOne(db, sql: "SELECT continuation_id FROM summary_events WHERE id = ?", arguments: [id]) else {
                throw ContinuousIngestion.Failure.invalid("前一件事已不存在")
            }
            guard let prior = row["continuation_id"] as Int64? else { return id }
            id = prior
        }
        throw ContinuousIngestion.Failure.invalid("事件延续身份形成了循环")
    }
}
