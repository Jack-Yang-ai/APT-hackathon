import Foundation
import GRDB
















enum VoiceprintModel {













    static let current = "redimnet-s/vb2+vox2+cnc/ft_mix"



    static let unknownLegacy = "unknown-pre-v7"
















    static let recommendedTemplates = 5
}


struct VoiceprintEntry: Equatable, Codable {
    let personID: Int64

    let embedding: Data
    let dim: Int

    let model: String
    let source: String
    let createdAt: String

    let instructionID: String
}


struct EnrollCommand: Equatable {
    enum Action: String { case enroll, unenroll }
    let action: Action
    let personID: Int64
    let embedding: Data
    let dim: Int


    let model: String
    let source: String

    let id: String?

    var instructionID: String {
        if let id, !id.isEmpty { return id }
        return "\(personID)::\(VoiceprintRegistry.sha256Hex(embedding))"
    }















    static func stableID(source: String, personName: String, embedding: Data) -> String {
        "\(source)::\(personName)::\(VoiceprintRegistry.sha256Hex(embedding))"
    }
}


struct EnrollDecision: Equatable {
    let execute: Bool
    let reason: String
}

enum VoiceprintRegistry {

    enum Failure: Error, CustomStringConvertible {
        case emptyEmbedding
        case dimMismatch(dim: Int, bytes: Int)
        case emptyModel

        var description: String {
            switch self {
            case .emptyEmbedding:
                return "嵌入是空的 —— 空嵌入比出来的分数是假的,不能进底库"
            case .dimMismatch(let dim, let bytes):
                return "维度对不上:dim=\(dim) 应为 \(dim * 4) 字节,实际 \(bytes) —— "
                     + "维度写错的向量比出来的分数是假的,比缺字段更难查"
            case .emptyModel:
                return "没写产出这条向量的模型 —— CAM++ 与 ReDimNet-M 都是 192 维,"
                     + "不记模型的话跨模型比对算出来的分数看着正常、其实无意义,而且没人会发现"
            }
        }
    }




    static func decide(_ cmd: EnrollCommand, in db: Database) throws -> EnrollDecision {
        let key = cmd.instructionID
        let state = try String.fetchOne(
            db, sql: "SELECT state FROM enroll_ledger WHERE instruction_id = ?",
            arguments: [key])

        switch cmd.action {
        case .unenroll:
            return state == "revoked"
                ? EnrollDecision(execute: false, reason: "这条撤销已经执行过")
                : EnrollDecision(execute: true, reason: "撤销")
        case .enroll:


            if state == "revoked" {
                return EnrollDecision(execute: false,
                                      reason: "这条 enroll 已被撤销,重放不执行(tombstone)")
            }
            if state == "processed" {
                return EnrollDecision(execute: false, reason: "这条 enroll 已经执行过")
            }
            return EnrollDecision(execute: true, reason: "首次执行")
        }
    }





    @discardableResult
    static func apply(_ cmd: EnrollCommand, now: String,
                      in writer: some DatabaseWriter) throws -> EnrollDecision {
        try writer.write { try apply(cmd, now: now, in: $0) }
    }


    static func applyConfirmed(_ cmd: EnrollCommand, lineID: Int64, now: String,
                               in writer: some DatabaseWriter) throws -> EnrollDecision? {
        try writer.write { db in
            let stillConfirmed = try Bool.fetchOne(db, sql: """
                SELECT 1 FROM line_speakers ls JOIN transcript_lines l ON l.line_id = ls.line_id
                 WHERE ls.line_id = ? AND ls.person_id = ? AND ls.source = ?
                   AND l.is_gap = 0 AND l.redacted = 0
                """, arguments: [lineID, cmd.personID, AttributionSource.userConfirmed.rawValue]) ?? false
            guard stillConfirmed, cmd.action == .enroll else { return nil }
            return try apply(cmd, now: now, in: db)
        }
    }

    private static func apply(_ cmd: EnrollCommand, now: String,
                              in db: Database) throws -> EnrollDecision {

        guard !cmd.embedding.isEmpty else { throw Failure.emptyEmbedding }
        guard cmd.dim > 0, cmd.embedding.count == cmd.dim * 4 else {
            throw Failure.dimMismatch(dim: cmd.dim, bytes: cmd.embedding.count)
        }
        guard !cmd.model.isEmpty else { throw Failure.emptyModel }

        let decision = try decide(cmd, in: db)
        guard decision.execute else { return decision }

        switch cmd.action {
        case .enroll:
            try db.execute(sql: """
                INSERT INTO voiceprints
                  (person_id, embedding, dim, model, source, created_at, instruction_id)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [cmd.personID, cmd.embedding, cmd.dim, cmd.model,
                                 cmd.source, now, cmd.instructionID])
            try setLedger(cmd.instructionID, "processed", now, db)
        case .unenroll:
            try db.execute(sql: "DELETE FROM voiceprints WHERE instruction_id = ?",
                           arguments: [cmd.instructionID])


            try setLedger(cmd.instructionID, "revoked", now, db)
        }
        return decision
    }

    private static func setLedger(_ key: String, _ state: String,
                                  _ now: String, _ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO enroll_ledger (instruction_id, state, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(instruction_id) DO UPDATE SET state = excluded.state,
                                                     updated_at = excluded.updated_at
            """, arguments: [key, state, now])
    }





    static func entries(in reader: some DatabaseReader,
                        model: String) throws -> [VoiceprintEntry] {
        try reader.read { db in try entries(in: db, model: model) }
    }

    static func entries(in db: Database, model: String) throws -> [VoiceprintEntry] {
        try rows(db, sql: """
            SELECT person_id, embedding, dim, model, source, created_at, instruction_id
              FROM voiceprints WHERE model = ? ORDER BY id
            """, arguments: [model])
    }



    static func allEntriesForBackup(in db: Database) throws -> [VoiceprintEntry] {
        try rows(db, sql: """
            SELECT person_id, embedding, dim, model, source, created_at, instruction_id
              FROM voiceprints ORDER BY id
            """, arguments: [])
    }

    private static func rows(_ db: Database, sql: String,
                             arguments: StatementArguments) throws -> [VoiceprintEntry] {
        try Row.fetchAll(db, sql: sql, arguments: arguments).map {
            VoiceprintEntry(personID: $0["person_id"], embedding: $0["embedding"],
                            dim: $0["dim"], model: $0["model"], source: $0["source"],
                            createdAt: $0["created_at"], instructionID: $0["instruction_id"])
        }
    }






    static func templateCounts(in db: Database, model: String) throws -> [Int64: Int] {
        var out: [Int64: Int] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT person_id, COUNT(*) AS n FROM voiceprints
             WHERE model = ? GROUP BY person_id
            """, arguments: [model]) {
            out[row["person_id"]] = row["n"]
        }
        return out
    }

    static func templateCounts(in reader: some DatabaseReader,
                               model: String) throws -> [Int64: Int] {
        try reader.read { db in try templateCounts(in: db, model: model) }
    }


    static func revokedIDs(in db: Database) throws -> Set<String> {
        Set(try String.fetchAll(
            db, sql: "SELECT instruction_id FROM enroll_ledger WHERE state = 'revoked'"))
    }




    static func sha256Hex(_ data: Data) -> String {


        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
