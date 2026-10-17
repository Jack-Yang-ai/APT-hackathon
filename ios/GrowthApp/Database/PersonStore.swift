import Foundation
import GRDB




















struct Person: Equatable, Codable {
    let id: Int64
    let name: String?
    let source: String
    let createdAt: String
    let updatedAt: String
}

enum PersonStore {



    enum Source: String {

        case me         = "本人"

        case seed       = "声纹种子"

        case user       = "用户创建"

        case backfilled = "迁移回填"


        case clustered  = "声纹聚类"
    }

    enum Failure: Error, CustomStringConvertible {
        case emptyName
        case noSuchPerson(id: Int64)

        var description: String {
            switch self {
            case .emptyName:
                return "人得有名字 —— 空名字在界面上会显示成一片空白,"
                     + "而「没名字」与「叫空字符串」是两件事,后者查不出来"
            case .noSuchPerson(let id):
                return "没有 id 为 \(id) 的人"
            }
        }
    }









    @discardableResult
    static func create(name: String, source: Source, now: String,
                       in db: Database) throws -> Int64 {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyName }
        try db.execute(sql: """
            INSERT INTO persons (name, source, created_at, updated_at) VALUES (?, ?, ?, ?)
            """, arguments: [trimmed, source.rawValue, now, now])
        return db.lastInsertedRowID
    }

    @discardableResult
    static func create(name: String, source: Source, now: String,
                       in writer: some DatabaseWriter) throws -> Int64 {
        try writer.write { try create(name: name, source: source, now: now, in: $0) }
    }


    static func rename(_ id: Int64, to name: String, now: String, in db: Database) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyName }
        try db.execute(sql: "UPDATE persons SET name = ?, updated_at = ? WHERE id = ?",
                       arguments: [trimmed, now, id])


        guard db.changesCount > 0 else { throw Failure.noSuchPerson(id: id) }
    }

    static func rename(_ id: Int64, to name: String, now: String,
                       in writer: some DatabaseWriter) throws {
        try writer.write { try rename(id, to: name, now: now, in: $0) }
    }



    static func all(in db: Database) throws -> [Person] {
        try Row.fetchAll(db, sql: """
            SELECT id, name, source, created_at, updated_at FROM persons ORDER BY id
            """).map {
            Person(id: $0["id"], name: $0["name"], source: $0["source"],
                   createdAt: $0["created_at"], updatedAt: $0["updated_at"])
        }
    }

    static func all(in reader: some DatabaseReader) throws -> [Person] {
        try reader.read { try all(in: $0) }
    }





    static func names(in db: Database) throws -> [Int64: String] {
        var out: [Int64: String] = [:]
        for row in try Row.fetchAll(
            db, sql: "SELECT id, name FROM persons WHERE name IS NOT NULL") {
            out[row["id"]] = row["name"]
        }
        return out
    }

    static func find(_ id: Int64, in db: Database) throws -> Person? {
        try all(in: db).first { $0.id == id }
    }
}
