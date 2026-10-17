import Foundation
import GRDB




























enum ConfirmCascade {



    private static func normalisedTag(_ column: String, session: String) -> String {
        """
        CASE WHEN \(column) LIKE \(session) || '-%'
             THEN substr(\(column), length(\(session)) + 2)
             ELSE \(column) END
        """
    }








    static func siblings(of lines: [LineID], in db: Database) throws -> [LineID] {
        guard !lines.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: lines.count).joined(separator: ",")
        let tag = normalisedTag("ls.cluster_tag", session: "t.session_id")
        return try LineID.fetchAll(db, sql: """
            WITH src AS (
              SELECT DISTINCT t.session_id AS sid, \(tag) AS tag
                FROM line_speakers   ls
                JOIN transcript_lines l ON l.line_id = ls.line_id
                JOIN transcripts      t ON t.id = l.transcript_id
               WHERE ls.line_id IN (\(marks)) AND ls.cluster_tag IS NOT NULL
            )
            SELECT ls.line_id
              FROM line_speakers   ls
              JOIN transcript_lines l ON l.line_id = ls.line_id
              JOIN transcripts      t ON t.id = l.transcript_id
              JOIN src ON src.sid = t.session_id AND src.tag = \(tag)
              LEFT JOIN persons p ON p.id = ls.person_id
             WHERE l.is_gap = 0 AND l.redacted = 0
               AND ls.line_id NOT IN (\(marks))
               AND (ls.person_id IS NULL
                    OR p.source = '\(PersonStore.Source.clustered.rawValue)')
             ORDER BY ls.line_id
            """, arguments: StatementArguments(lines + lines))
    }












    static func retroactivePlan(in db: Database) throws -> [(person: PersonID, line: LineID)] {
        let tag = normalisedTag("ls.cluster_tag", session: "t.session_id")
        return try Row.fetchAll(db, sql: """
            WITH n AS (
              SELECT ls.line_id AS line_id, t.session_id AS sid,
                     ls.person_id AS person_id, ls.source AS src, \(tag) AS tag
                FROM line_speakers   ls
                JOIN transcript_lines l ON l.line_id = ls.line_id
                JOIN transcripts      t ON t.id = l.transcript_id
               WHERE l.is_gap = 0 AND l.redacted = 0 AND ls.cluster_tag IS NOT NULL
            ),
            owner AS (
              SELECT n.sid AS sid, n.tag AS tag, MIN(n.person_id) AS pid
                FROM n JOIN persons p ON p.id = n.person_id
               WHERE n.src = '\(AttributionSource.userConfirmed.rawValue)'
                 AND p.source <> '\(PersonStore.Source.clustered.rawValue)'
               GROUP BY n.sid, n.tag
              HAVING COUNT(DISTINCT n.person_id) = 1
            )
            SELECT o.pid AS pid, n.line_id AS line_id
              FROM n JOIN owner o ON o.sid = n.sid AND o.tag = n.tag
              LEFT JOIN persons p ON p.id = n.person_id
             WHERE n.person_id IS NULL
                OR p.source = '\(PersonStore.Source.clustered.rawValue)'
             ORDER BY o.pid, n.line_id
            """).map { (person: $0["pid"] as PersonID, line: $0["line_id"] as LineID) }
    }





    @discardableResult
    static func confirm(lines: [LineID], person: PersonID, now: String,
                        in db: DatabaseQueue) throws -> (AssignResult, [LineID]) {
        let r = try AssignSpeaker.assignSpeaker(
            lines: lines, person: person, clusterTag: nil,
            source: .userConfirmed, confidence: nil, actor: .user, now: now, in: db)
        guard let caused = r.judgmentID else { return (r, []) }
        let rest = try db.read { try siblings(of: lines, in: $0) }
        guard !rest.isEmpty else { return (r, []) }
        let c = try AssignSpeaker.assignSpeaker(
            lines: rest, person: person, clusterTag: nil,
            source: .crossValidated,


            confidence: 0, actor: .systemCascade, causedBy: caused, now: now, in: db)
        return (r, c.changedLines)
    }
}
