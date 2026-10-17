import Foundation
import GRDB









typealias LineID = Int64
typealias PersonID = Int64
typealias JudgmentID = Int64


enum AttributionSource: String, CaseIterable {
    case systemOrganized = "系统整理"
    case crossValidated  = "系统交叉验证"
    case voiceprint      = "声纹识别"
    case platformLabel   = "平台标注"
    case userConfirmed   = "用户确认"


    var rank: Int {
        switch self {
        case .systemOrganized: return 0
        case .crossValidated:  return 1
        case .voiceprint:      return 2
        case .platformLabel:   return 3
        case .userConfirmed:   return 4
        }
    }
}

enum Actor: String {
    case user
    case systemCascade = "system-cascade"











    case system
}


enum RecomputeTarget: String, CaseIterable {
    case summaryStances = "纪要·表态"
    case summaryCommits = "纪要·承诺"






    case matterProgress = "事·进展"






    case personDiscoveries = "发现·关于人"







    case cards = "卡片"

    case observations = "观察"

    case personBrief = "人·简报"





    case selfStances = "我·立场与原则"
}


enum RecomputeOutcome: Equatable {
    case recomputed(rows: Int)

    case pendingSchema(table: String)
}

struct AssignResult: Equatable {

    let judgmentID: JudgmentID?

    let changedLines: [LineID]

    let blockedByUserConfirmation: [LineID]


    let blockedByMixedLine: [LineID]
    let recomputed: [RecomputeTarget: RecomputeOutcome]

    var isNoOp: Bool { judgmentID == nil }
}





enum RecomputeRegistry {









    typealias Fn = (Database, [LineID], JudgmentID) throws -> RecomputeOutcome

    private static var fns: [RecomputeTarget: Fn] = [:]

    static func register(_ target: RecomputeTarget, _ fn: @escaping Fn) {
        fns[target] = fn
    }

    static var registered: Set<RecomputeTarget> { Set(fns.keys) }

    static func run(_ db: Database, lines: [LineID],
                    triggeredBy: JudgmentID) throws -> [RecomputeTarget: RecomputeOutcome] {
        var out: [RecomputeTarget: RecomputeOutcome] = [:]

        for target in RecomputeTarget.allCases {
            guard let fn = fns[target] else { continue }
            out[target] = try fn(db, lines, triggeredBy)
        }
        return out
    }









    static func registerM0Defaults() {
        register(.summaryStances) { db, lines, _ in
            guard try db.tableExists("summary_stances") else {
                return .pendingSchema(table: "summary_stances")
            }
            return .recomputed(rows: try ExtractionStore.recomputePending(
                db, table: "summary_stances", lines: lines))
        }
        register(.summaryCommits) { db, lines, _ in
            guard try db.tableExists("summary_commitments") else {
                return .pendingSchema(table: "summary_commitments")
            }
            return .recomputed(rows: try ExtractionStore.recomputePending(
                db, table: "summary_commitments", lines: lines))
        }
























        register(.matterProgress) { db, lines, _ in
            guard try db.tableExists("matter_timeline") else {
                return .pendingSchema(table: "matter_timeline")
            }
            let cols = Set(try db.columns(in: "matter_timeline").map(\.name))
            let attribution = cols.intersection(["person_id", "speaker", "cluster_tag"])
            guard attribution.isEmpty else {
                throw NSError(domain: "RecomputeRegistry", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "matter_timeline 多了归属列 \(attribution.sorted()) —— "
                      + "「这张表不存归属所以不用重算」那条结论的前提没了,"
                      + "必须重新判:要么真的写重算,要么说清为什么还是不用。"])
            }
            _ = lines
            return .recomputed(rows: 0)
        }














        register(.personDiscoveries) { db, lines, _ in
            guard try db.tableExists("discovery_evidence") else {
                return .pendingSchema(table: "discovery_evidence")
            }
            guard !lines.isEmpty else { return .recomputed(rows: 0) }
            let marks = lines.map { _ in "?" }.joined(separator: ",")
            try db.execute(sql: """
                UPDATE discoveries SET withdrawn_at = ?
                 WHERE withdrawn_at IS NULL
                   AND kind IN (SELECT kind FROM discovery_kinds WHERE subject = '人')
                   AND id IN (SELECT discovery_id FROM discovery_evidence
                               WHERE line_id IN (\(marks)))
                """, arguments: StatementArguments([ISO8601DateFormatter().string(from: Date())]
                                                   + lines.map { $0 as DatabaseValueConvertible }))
            return .recomputed(rows: db.changesCount)
        }












        register(.cards) { db, lines, triggeredBy in
            guard try db.tableExists("cards") else { return .pendingSchema(table: "cards") }
            guard !lines.isEmpty else { return .recomputed(rows: 0) }
            let marks = lines.map { _ in "?" }.joined(separator: ",")
            let args = StatementArguments(lines.map { $0 as DatabaseValueConvertible? })
            let victims = try Int64.fetchAll(db, sql: """
                SELECT id FROM cards
                 WHERE withdrawn_at IS NULL AND line_id IN (\(marks))
                """, arguments: args)
            guard !victims.isEmpty else { return .recomputed(rows: 0) }

            let now = ISO8601DateFormatter().string(from: Date())
            for card in victims {
                try db.execute(sql: "UPDATE cards SET withdrawn_at = ? WHERE id = ?",
                               arguments: [now, card])



                guard let live = try Int64.fetchOne(db, sql: """
                    SELECT judgment_id FROM judgment_current
                     WHERE target_kind = 'card' AND target_id = ?
                    """, arguments: ["\(card)"]) else { continue }
                try db.execute(sql: """
                    INSERT INTO judgments
                      (decided_at, actor, caused_by, undoes, action, target_kind, target_id, payload)
                    VALUES (?, 'system-cascade', ?, ?, 'undo', 'card', ?, ?)
                    """, arguments: [now, triggeredBy, live, "\(card)",
                                     #"{"reason":"依据的原话被说话人纠正"}"#])
            }
            return .recomputed(rows: victims.count)
        }






        register(.observations) { db, lines, _ in
            guard try db.tableExists("observation_evidence") else {
                return .pendingSchema(table: "observation_evidence")
            }
            guard !lines.isEmpty else { return .recomputed(rows: 0) }
            let marks = lines.map { _ in "?" }.joined(separator: ",")
            try db.execute(sql: """
                UPDATE person_observations SET withdrawn_at = ?
                 WHERE withdrawn_at IS NULL
                   AND id IN (SELECT observation_id FROM observation_evidence
                               WHERE line_id IN (\(marks)))
                """, arguments: StatementArguments([ISO8601DateFormatter().string(from: Date())]
                                                   + lines.map { $0 as DatabaseValueConvertible? }))
            return .recomputed(rows: db.changesCount)
        }











        register(.personBrief) { db, lines, _ in
            guard try db.tableExists("person_brief") else {
                return .pendingSchema(table: "person_brief")
            }
            guard !lines.isEmpty else { return .recomputed(rows: 0) }
            try db.execute(sql: "DELETE FROM person_brief")
            return .recomputed(rows: db.changesCount)
        }













        register(.selfStances) { db, lines, _ in
            guard try db.tableExists("self_stance_evidence") else {
                return .pendingSchema(table: "self_stance_evidence")
            }
            guard !lines.isEmpty else { return .recomputed(rows: 0) }
            let marks = lines.map { _ in "?" }.joined(separator: ",")
            let args = StatementArguments(lines.map { $0 as DatabaseValueConvertible? })



            try db.execute(sql: """
                DELETE FROM self_stance_evidence
                 WHERE line_id IN (\(marks))
                   AND line_id NOT IN (SELECT line_id FROM line_speakers
                                        WHERE person_id = \(MatterSituation.mePersonID))
                """, arguments: args)






            try db.execute(sql: """
                UPDATE self_stances SET premise = NULL, premise_line_id = NULL
                 WHERE premise_line_id IN (\(marks))
                   AND premise_line_id NOT IN (SELECT line_id FROM line_speakers
                                                WHERE person_id = \(MatterSituation.mePersonID))
                """, arguments: args)


            let now = ISO8601DateFormatter().string(from: Date())
            try db.execute(sql: """
                UPDATE self_stances SET withdrawn_at = ?
                 WHERE withdrawn_at IS NULL
                   AND id NOT IN (SELECT stance_id FROM self_stance_evidence)
                """, arguments: [now])
            let withdrawn = db.changesCount




            try db.execute(sql: """
                UPDATE self_principles SET demoted_at = ?
                 WHERE demoted_at IS NULL AND source_kind = '系统提炼'
                   AND (SELECT COUNT(DISTINCT matter_id) FROM self_stance_evidence
                         WHERE stance_id = self_principles.stance_id) < 2
                """, arguments: [now])
            return .recomputed(rows: withdrawn + db.changesCount)
        }
    }


    static func resetToM0Defaults() {
        fns = [:]
        registerM0Defaults()
    }
}

enum AssignSpeaker {

    enum Failure: Error, CustomStringConvertible {
        case noLines
        case confidenceRequired
        case causedByRequired
        case unknownLines([LineID])

        var description: String {
            switch self {
            case .noLines:
                return "assignSpeaker 至少要给一行"
            case .confidenceRequired:
                return "非「用户确认」的来源必须给 confidence(§3.2.2 签名)"
            case .causedByRequired:
                return "actor=system-cascade 必须给 causedBy —— 否则审计链断了(D5/G2)"
            case .unknownLines(let ids):
                return "这些 line_id 在 transcript_lines 里不存在,归属会悬空:\(ids)"
            }
        }
    }





















    @discardableResult
    static func assignSpeaker(lines: [LineID],
                              person: PersonID?,
                              clusterTag: String?,
                              source: AttributionSource,
                              confidence: Double?,
                              actor: Actor,
                              causedBy: JudgmentID? = nil,
                              now: String,
                              in writer: some DatabaseWriter) throws -> AssignResult {
        try writer.write { db in
            try assignSpeaker(lines: lines, person: person, clusterTag: clusterTag,
                              source: source, confidence: confidence, actor: actor,
                              causedBy: causedBy, now: now, in: db)
        }
    }


    static func assignSpeaker(lines: [LineID],
                              person: PersonID?,
                              clusterTag: String?,
                              source: AttributionSource,
                              confidence: Double?,
                              actor: Actor,
                              causedBy: JudgmentID? = nil,
                              now: String,
                              in db: Database) throws -> AssignResult {

        guard !lines.isEmpty else { throw Failure.noLines }
        if source != .userConfirmed, confidence == nil { throw Failure.confidenceRequired }
        if actor == .systemCascade, causedBy == nil { throw Failure.causedByRequired }

        let wanted = Array(Set(lines)).sorted()


        let existing = try LineID.fetchSet(db, sql: """
            SELECT line_id FROM transcript_lines WHERE line_id IN (\(placeholders(wanted.count)))
            """, arguments: StatementArguments(wanted))
        let missing = wanted.filter { !existing.contains($0) }
        guard missing.isEmpty else { throw Failure.unknownLines(missing) }


        var current: [LineID: (person: PersonID?, source: String, clusterTag: String?)] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT line_id, person_id, source, cluster_tag FROM line_speakers
             WHERE line_id IN (\(placeholders(wanted.count)))
            """, arguments: StatementArguments(wanted)) {
            current[row["line_id"]] = (row["person_id"], row["source"], row["cluster_tag"])
        }





        let mixed = person == nil || source == .userConfirmed
            ? [] : try MixedLineStore.mixedIDs(among: wanted, in: db)

        var blocked: [LineID] = []
        var blockedMixed: [LineID] = []
        var changed: [LineID] = []
        for line in wanted {
            let cur = current[line]
            if mixed.contains(line) {
                blockedMixed.append(line)
                continue
            }
            if cur?.source == AttributionSource.userConfirmed.rawValue,
               source != .userConfirmed {
                blocked.append(line)
                continue
            }





            if cur?.person == person, cur?.source == source.rawValue,
               clusterTag == nil || cur?.clusterTag == clusterTag { continue }
            changed.append(line)
        }

        guard !changed.isEmpty else {
            return AssignResult(judgmentID: nil, changedLines: [],
                                blockedByUserConfirmation: blocked,
                                blockedByMixedLine: blockedMixed, recomputed: [:])
        }

        for line in changed {
            try db.execute(sql: """
                INSERT INTO line_speakers (line_id, person_id, cluster_tag, role, confidence, source, updated_at)
                VALUES (?, ?, ?, NULL, ?, ?, ?)
                ON CONFLICT(line_id) DO UPDATE SET
                    person_id   = excluded.person_id,
                    cluster_tag = COALESCE(excluded.cluster_tag, line_speakers.cluster_tag),
                    confidence  = excluded.confidence,
                    source      = excluded.source,
                    updated_at  = excluded.updated_at
                """, arguments: [line, person, clusterTag, confidence, source.rawValue, now])
        }



        let targetID = jsonArray(changed)
        try db.execute(sql: """
            INSERT INTO judgments
              (decided_at, actor, caused_by, undoes, action, target_kind, target_id, payload, basis_line_ids)
            VALUES (?, ?, ?, NULL, ?, 'line', ?, ?, ?)
            """, arguments: [now, actor.rawValue, causedBy,
                             person == nil ? "unassign_speaker" : "assign_speaker",
                             targetID,
                             try jsonPayload(person: person, clusterTag: clusterTag,
                                             source: source, confidence: confidence),
                             targetID])
        let judgmentID = db.lastInsertedRowID


        let recomputed = try RecomputeRegistry.run(db, lines: changed, triggeredBy: judgmentID)

        return AssignResult(judgmentID: judgmentID, changedLines: changed,
                            blockedByUserConfirmation: blocked,
                            blockedByMixedLine: blockedMixed, recomputed: recomputed)
    }

    private static func placeholders(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ",")
    }

    private static func jsonArray(_ ids: [LineID]) -> String {
        "[" + ids.map(String.init).joined(separator: ",") + "]"
    }










    private static func jsonPayload(person: PersonID?, clusterTag: String?,
                                    source: AttributionSource,
                                    confidence: Double?) throws -> String {
        var obj: [String: Any] = ["source": source.rawValue]
        obj["person_id"]   = person.map { $0 as Any }     ?? NSNull()
        obj["confidence"]  = confidence.map { $0 as Any } ?? NSNull()
        obj["cluster_tag"] = clusterTag.map { $0 as Any } ?? NSNull()
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
