import Foundation
import GRDB












struct RegistrySnapshot: Codable, Equatable {










    static let schemaVersion = "growth.voiceprints/3"

    let schema: String
    let takenAt: String
    let entries: [VoiceprintEntry]


    let revoked: [String]


    let persons: [Person]

    init(takenAt: String, entries: [VoiceprintEntry], revoked: [String],
         persons: [Person]) {
        self.schema = Self.schemaVersion
        self.takenAt = takenAt
        self.entries = entries
        self.revoked = revoked.sorted()
        self.persons = persons.sorted { $0.id < $1.id }
    }
}


protocol SnapshotStore {

    func put(_ data: Data, key: String) throws
    func get(key: String) throws -> Data

    func listKeys() throws -> [String]
}


struct LocalSnapshotStore: SnapshotStore {
    let root: URL

    func put(_ data: Data, key: String) throws {
        let url = root.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func get(key: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(key))
    }

    func listKeys() throws -> [String] {
        let dir = root.appendingPathComponent(RegistrySnapshotIO.prefix)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        return names.filter { $0.hasSuffix(".json") }
            .map { RegistrySnapshotIO.prefix + $0 }.sorted()
    }
}

enum RegistrySnapshotIO {


    static let prefix = "snapshots/voiceprints/"

    static func key(takenAt: String) -> String {

        prefix + takenAt.replacingOccurrences(of: ":", with: "-") + ".json"
    }

    enum Failure: Error, CustomStringConvertible {
        case noSnapshot
        case wrongSchema(String)

        var description: String {
            switch self {
            case .noSnapshot:
                return "快照桶里一份都没有 —— 此刻**不能**当成「底库本来就是空的」"
            case .wrongSchema(let s):
                return "快照 schema 是 \(s),不是 \(RegistrySnapshot.schemaVersion) —— 不猜着读"
            }
        }
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e
    }




    private struct SchemaEnvelope: Decodable { let schema: String }




    @discardableResult
    static func push(takenAt: String, to store: SnapshotStore,
                     from reader: some DatabaseReader) throws -> String {
        let snapshot = try reader.read { db in
            let entries = try VoiceprintRegistry.allEntriesForBackup(in: db)

            let referenced = Set(entries.map(\.personID))
            return RegistrySnapshot(
                takenAt: takenAt, entries: entries,
                revoked: Array(try VoiceprintRegistry.revokedIDs(in: db)),
                persons: try PersonStore.all(in: db).filter { referenced.contains($0.id) })
        }
        let key = key(takenAt: takenAt)
        try store.put(try encoder.encode(snapshot), key: key)
        return key
    }



    struct RestoreResult: Equatable {
        let inserted: Int

        let blockedByTombstone: Int

        let alreadyPresent: Int
    }










    @discardableResult
    static func restoreLatest(from store: SnapshotStore, now: String,
                              into writer: some DatabaseWriter) throws -> RestoreResult {
        guard let key = try store.listKeys().last else { throw Failure.noSnapshot }
        let data = try store.get(key: key)





        let envelope = try JSONDecoder().decode(SchemaEnvelope.self, from: data)
        guard envelope.schema == RegistrySnapshot.schemaVersion else {
            throw Failure.wrongSchema(envelope.schema)
        }
        let snapshot = try JSONDecoder().decode(RegistrySnapshot.self, from: data)

        return try writer.write { db in







            for p in snapshot.persons {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO persons (id, name, source, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [p.id, p.name, p.source, p.createdAt, p.updatedAt])
            }


            for id in snapshot.revoked {
                try db.execute(sql: """
                    INSERT INTO enroll_ledger (instruction_id, state, updated_at) VALUES (?, 'revoked', ?)
                    ON CONFLICT(instruction_id) DO UPDATE SET state = 'revoked', updated_at = ?
                    """, arguments: [id, now, now])
            }

            let revoked = try VoiceprintRegistry.revokedIDs(in: db)
            let present = Set(try String.fetchAll(
                db, sql: "SELECT instruction_id FROM voiceprints"))

            var inserted = 0, blocked = 0, already = 0
            for e in snapshot.entries {
                if revoked.contains(e.instructionID) { blocked += 1; continue }
                if present.contains(e.instructionID) { already += 1; continue }




                try db.execute(sql: """
                    INSERT INTO voiceprints
                      (person_id, embedding, dim, model, source, created_at, instruction_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [e.personID, e.embedding, e.dim, e.model,
                                     e.source, e.createdAt, e.instructionID])
                try db.execute(sql: """
                    INSERT INTO enroll_ledger (instruction_id, state, updated_at) VALUES (?, 'processed', ?)
                    ON CONFLICT(instruction_id) DO NOTHING
                    """, arguments: [e.instructionID, now])
                inserted += 1
            }
            return RestoreResult(inserted: inserted, blockedByTombstone: blocked,
                                 alreadyPresent: already)
        }
    }
}
