import Foundation
import GRDB























enum SpeakerNaming {
























    static func keyExpr(session: String) -> String {





        """
        CASE WHEN ls.person_id   IS NOT NULL THEN 'p:' || ls.person_id
             WHEN ls.cluster_tag IS NOT NULL THEN 'c:' || \(session) || ':' || ls.cluster_tag
             ELSE NULL END
        """
    }


    static var meKey: String { "p:\(mePersonID)" }



















    static let mePersonID: Int64 = -1








    static let meDisplayName = "我"
















    static func meIsIdentified(in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT 1 FROM line_speakers WHERE person_id = ? LIMIT 1
            """, arguments: [mePersonID]) ?? false
    }






















    enum Scope: Equatable {

        case global

        case session(Int64)
    }

    static func labels(in db: Database, scope: Scope = .global) throws -> [String: String] {
        let keys = try String.fetchAll(db, sql: """
            SELECT \(keyExpr(session: "t.session_id")) AS who
              FROM line_speakers ls
              JOIN transcript_lines l ON l.line_id = ls.line_id
              JOIN transcripts      t ON t.id = l.transcript_id
              JOIN sessions         s ON s.id = t.session_id
             WHERE who IS NOT NULL
             GROUP BY who
             ORDER BY MIN(l.line_id)
            """)




        let meIdentified = try meIsIdentified(in: db)
        let meKey = Self.meKey


        let names = try PersonStore.names(in: db)





        let anon = try anonymousLabels(in: db)






        var sessionsOf: [String: Set<Int64>] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT \(keyExpr(session: "t.session_id")) AS who, t.session_id AS sid
              FROM line_speakers ls
              JOIN transcript_lines l ON l.line_id = ls.line_id
              JOIN transcripts      t ON t.id = l.transcript_id
             WHERE who IS NOT NULL AND ls.person_id IS NOT NULL
             GROUP BY who, sid
            """) {
            sessionsOf[row["who"], default: []].insert(row["sid"])
        }







        var stampOf: [Int64: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, started_at FROM sessions") {
            let at: String = row["started_at"]

            stampOf[row["id"]] = at.count >= 16
                ? String(at.dropFirst(5).prefix(5)) + " " + String(at.dropFirst(11).prefix(5))
                : at
        }

        var out: [String: String] = [:]
        var n = 0                              // `p:` 键的全库序
        var perSession: [Int64: Int] = [:]     // `c:` 键的场内序
        var taken: [Int64: Set<Int>] = [:]     // 每场被 `p:` 键占掉的号
        var pending: [String] = []             // 待编场内号的 `c:` 键
        for key in keys {
            if meIdentified && key == meKey {
                out[key] = "我"
            } else if let name = personID(of: key).flatMap({ names[$0] }),



                      !(key == meKey && !meIdentified) {
                out[key] = name
            } else if let label = personID(of: key).flatMap({ anon[$0] }) {
                out[key] = label
            } else if personID(of: key) != nil {



                n += 1
                out[key] = "说话人 \(n)"
                for sid in sessionsOf[key] ?? [] { taken[sid, default: []].insert(n) }
            } else {
                pending.append(key)
            }
        }













        for key in pending {
            guard let sid = sessionID(of: key) else { continue }














            var k: Int
            if let n = upstreamIndex(of: key) {
                k = n + 1
            } else {


                k = (perSession[sid] ?? 0) + 1
            }
            while taken[sid]?.contains(k) == true { k += 1 }
            perSession[sid] = max(perSession[sid] ?? 0, k)


            if scope == .session(sid) || stampOf[sid] == nil {
                out[key] = "说话人 \(k)"
            } else {
                out[key] = "\(stampOf[sid]!) 的说话人 \(k)"
            }
        }
        return out
    }



    static func upstreamIndex(of key: String) -> Int? {
        guard key.hasPrefix("c:"), let colon = key.dropFirst(2).firstIndex(of: ":") else { return nil }
        let tag = String(key.dropFirst(2)[key.dropFirst(2).index(after: colon)...])
        guard tag.hasPrefix("speaker_") else { return nil }
        return Int(tag.dropFirst("speaker_".count))
    }



    static func sessionID(of key: String) -> Int64? {
        guard key.hasPrefix("c:") else { return nil }
        let rest = key.dropFirst(2)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        return Int64(rest[rest.startIndex..<colon])
    }



    static func anonymousLabels(in db: Database) throws -> [Int64: String] {
        let ids = try Int64.fetchAll(db, sql: """
            SELECT id FROM persons WHERE name IS NULL AND source = '声纹聚类' ORDER BY id
            """)
        var out: [Int64: String] = [:]
        for (i, id) in ids.enumerated() {
            out[id] = i < 26
                ? "声音" + String(UnicodeScalar(UInt8(65 + i)))
                : "声音\(i + 1)"
        }
        return out
    }



    static func personID(of key: String) -> Int64? {
        guard key.hasPrefix("p:") else { return nil }
        return Int64(key.dropFirst(2))
    }







    static func inSession(_ db: Database, transcriptIDs: [Int64]) throws -> [String] {
        guard !transcriptIDs.isEmpty else { return [] }
        let all = try labels(in: db)
        let marks = Array(repeating: "?", count: transcriptIDs.count).joined(separator: ",")
        let keys = try String.fetchAll(db, sql: """
            SELECT \(keyExpr(session: "t.session_id")) AS who
              FROM line_speakers ls
              JOIN transcript_lines l ON l.line_id = ls.line_id
              JOIN transcripts      t ON t.id = l.transcript_id
             WHERE l.transcript_id IN (\(marks)) AND who IS NOT NULL
             GROUP BY who
             ORDER BY MIN(l.transcript_id), MIN(l.seq)
            """, arguments: StatementArguments(transcriptIDs))
        return keys.map { all[$0] ?? $0 }
    }
}
