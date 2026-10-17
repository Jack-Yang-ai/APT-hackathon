import Foundation
import GRDB

enum AskDraftStore {
    struct Draft {
        let text: String
        let scope: AskScope?
    }
    static func read(_ key: String, in db: Database) throws -> Draft? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM ask_drafts WHERE key=?", arguments: [key]) else { return nil }
        let session: Int64? = row["context_session_id"]
        return Draft(text: row["text"], scope: session.map { AskScope(sessionID: $0, eventID: row["context_event_id"]) })
    }
    static func save(_ text: String, revision: Int, scope: AskScope?, key: String, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO ask_drafts(key,text,revision,context_session_id,context_event_id) VALUES(?,?,?,?,?)
            ON CONFLICT(key) DO UPDATE SET text=excluded.text,revision=excluded.revision,context_session_id=excluded.context_session_id,context_event_id=excluded.context_event_id
            """, arguments: [key, text, revision, scope?.sessionID, scope?.eventID])
    }
    static func move(from oldKey: String, to newKey: String, in db: Database) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO ask_drafts(key,text,revision,context_session_id,context_event_id)
            SELECT ?,text,revision,context_session_id,context_event_id FROM ask_drafts WHERE key=?
            """, arguments: [newKey, oldKey])
        try db.execute(sql: "DELETE FROM ask_drafts WHERE key=?", arguments: [oldKey])
    }
}
