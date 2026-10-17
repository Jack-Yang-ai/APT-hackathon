import Foundation
import GRDB
























enum VoiceprintSeed {



    static let source = "seed/local-user-import"
    static let resource = "voiceprint_seed"

    struct Report: Equatable {
        let peopleCreated: Int
        let inserted: Int

        let alreadyThere: Int

        let blockedByTombstone: Int
    }

    enum Failure: Error, CustomStringConvertible {
        case resourceMissing
        case badPayload(String)
        case dimMismatch(name: String, dim: Int, bytes: Int)

        var description: String {
            switch self {
            case .resourceMissing:
                return "包里没有 \(resource).json —— 种子文件没进 target"
            case .badPayload(let s):
                return "种子文件读不出来:\(s)"
            case .dimMismatch(let n, let d, let b):
                return "\(n) 的向量维度对不上:dim=\(d) 应为 \(d * 4) 字节,实际 \(b)"
            }
        }
    }


    @discardableResult
    static func importIfNeeded(bundle: Bundle = .main, now: String,
                               into writer: some DatabaseWriter) throws -> Report {
        guard let url = bundle.url(forResource: resource, withExtension: "json") else {
            throw Failure.resourceMissing
        }
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let dict = root as? [String: Any],
              let people = dict["people"] as? [String: Any] else {
            throw Failure.badPayload("缺 people")
        }

        var created = 0, inserted = 0, already = 0, blocked = 0

        for (name, raw) in people.sorted(by: { $0.key < $1.key }) {
            guard let blob = raw as? [String: Any],
                  let dim = blob["dim"] as? Int,
                  let vectors = blob["embeddings"] as? [String] else {
                throw Failure.badPayload("\(name) 的形状不对")
            }


            let personID = try writer.write { db -> Int64 in















                if name == SpeakerNaming.meDisplayName {
                    return SpeakerNaming.mePersonID
                }
                if let existing = try seededPerson(named: name, in: db) { return existing }
                created += 1
                return try PersonStore.create(name: name, source: .seed, now: now, in: db)
            }

            for b64 in vectors {
                guard let data = Data(base64Encoded: b64) else {
                    throw Failure.badPayload("\(name) 有一条向量不是 base64")
                }
                guard data.count == dim * 4 else {
                    throw Failure.dimMismatch(name: name, dim: dim, bytes: data.count)
                }
                let cmd = EnrollCommand(
                    action: .enroll, personID: personID, embedding: data, dim: dim,
                    model: VoiceprintModel.current, source: source,

                    id: EnrollCommand.stableID(source: source, personName: name,
                                                    embedding: data))
                let decision = try VoiceprintRegistry.apply(cmd, now: now, in: writer)
                if decision.execute { inserted += 1 }
                else if decision.reason.contains("tombstone") { blocked += 1 }
                else { already += 1 }
            }
        }
        return Report(peopleCreated: created, inserted: inserted,
                      alreadyThere: already, blockedByTombstone: blocked)
    }


    static func seededPerson(named name: String, in db: Database) throws -> Int64? {
        try Int64.fetchOne(db, sql: """
            SELECT id FROM persons WHERE name = ? AND source = ? ORDER BY id LIMIT 1
            """, arguments: [name, PersonStore.Source.seed.rawValue])
    }
}
