import Foundation
import GRDB


















enum SpeakerReviews {

    enum State: String {
        case pending  = "待复查"
        case kept     = "是本人"
        case rejected = "不是本人"
    }
    enum Mode: String { case line, cluster }




    static func enqueue(lineID: Int64, person: Int64, score: Double,
                        clusterKey: String, mode: Mode = .line, now: String, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO speaker_reviews
              (line_id, person_id, score, cluster_key, mode, state, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(line_id) DO UPDATE SET
              person_id = excluded.person_id, score = excluded.score, cluster_key = excluded.cluster_key,
              mode = excluded.mode, updated_at = excluded.updated_at
            WHERE speaker_reviews.state = excluded.state
            """, arguments: [lineID, person, score, clusterKey, mode.rawValue, State.pending.rawValue, now, now])
    }



    static func answer(lineID: Int64, _ state: State, now: String,
                       in writer: some DatabaseWriter) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE speaker_reviews SET state = ?, updated_at = ? WHERE line_id = ?
                """, arguments: [state.rawValue, now, lineID])
        }
    }

    static func pendingCount(in reader: some DatabaseReader) throws -> Int {
        try reader.read { try pendingCount(in: $0) }
    }

    static func pendingCount(in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM speaker_reviews WHERE state = ?
            """, arguments: [State.pending.rawValue]) ?? 0
    }


    struct SelfCandidate: Identifiable, Equatable {
        var id: Int64 { lineID }
        let lineID: Int64
        let sessionID: Int64
        let clusterKey: String
        let text: String
        let isClusterConfirmation: Bool
    }

    static func selfCandidates(sessionID: Int64? = nil,
                               in reader: some DatabaseReader) throws -> [SelfCandidate] {
        try reader.read { try selfCandidates(sessionID: sessionID, in: $0) }
    }

    private static func selfCandidates(sessionID: Int64?, in db: Database) throws -> [SelfCandidate] {
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.line_id, r.cluster_key, r.mode, l.text, t.session_id, ls.person_id
                  FROM speaker_reviews r
                  JOIN transcript_lines l ON l.line_id = r.line_id
                  JOIN transcripts t ON t.id = l.transcript_id
                  LEFT JOIN line_speakers ls ON ls.line_id = l.line_id
                 WHERE r.state = ? AND r.person_id = ? AND l.is_gap = 0 AND l.redacted = 0
                   AND (ls.source IS NULL OR ls.source <> ?)
                   AND (? IS NULL OR t.session_id = ?)
                   AND t.version = (SELECT MAX(version) FROM transcripts WHERE session_id = t.session_id)
                 ORDER BY r.created_at, r.line_id
                """, arguments: [State.pending.rawValue, SpeakerNaming.mePersonID,
                                  AttributionSource.userConfirmed.rawValue, sessionID, sessionID])
            return rows.map { r in
                SelfCandidate(lineID: r["line_id"], sessionID: r["session_id"],
                              clusterKey: r["cluster_key"], text: r["text"],
                              isClusterConfirmation: (r["mode"] as String) == Mode.cluster.rawValue)
            }
    }

    enum SelfFailure: Error { case candidateChanged }


    @discardableResult
    static func answerSelf(_ candidate: SelfCandidate, isMe: Bool, now: String,
                           in writer: some DatabaseWriter) throws -> [Int64] {
        try writer.write { db in
        guard try selfCandidates(sessionID: candidate.sessionID, in: db).contains(candidate)
        else { throw SelfFailure.candidateChanged }
        let lines: [Int64]
        if candidate.isClusterConfirmation {
            lines = try Int64.fetchAll(db, sql: """
                    SELECT l.line_id FROM transcript_lines l
                      JOIN transcripts t ON t.id = l.transcript_id
                      JOIN line_speakers ls ON ls.line_id = l.line_id
                     WHERE t.session_id = ? AND l.is_gap = 0 AND l.redacted = 0
                       AND t.version = (SELECT MAX(version) FROM transcripts WHERE session_id = t.session_id)
                       AND ls.source <> ?
                       AND (ls.cluster_tag = ? OR CAST(t.session_id AS TEXT) || '-' || ls.cluster_tag = ?)
                    """, arguments: [candidate.sessionID, AttributionSource.userConfirmed.rawValue,
                                      candidate.clusterKey, candidate.clusterKey])
        } else { lines = [candidate.lineID] }
        guard !lines.isEmpty else { throw SelfFailure.candidateChanged }
        _ = try AssignSpeaker.assignSpeaker(
            lines: lines, person: isMe ? SpeakerNaming.mePersonID : nil, clusterTag: nil,
            source: .userConfirmed, confidence: nil, actor: .user, now: now, in: db)
            if candidate.isClusterConfirmation {
                try db.execute(sql: """
                    UPDATE speaker_reviews SET state = ?, updated_at = ?
                     WHERE cluster_key = ? AND person_id = ? AND state = ?
                    """, arguments: [isMe ? State.kept.rawValue : State.rejected.rawValue,
                                      now, candidate.clusterKey, SpeakerNaming.mePersonID, State.pending.rawValue])
            } else {
                try db.execute(sql: "UPDATE speaker_reviews SET state = ?, updated_at = ? WHERE line_id = ?",
                               arguments: [isMe ? State.kept.rawValue : State.rejected.rawValue, now, candidate.lineID])
            }
        return lines
        }
    }
}
