import Foundation
import GRDB



















enum VoiceprintRemote {



    struct JobLine: Codable {
        let line_id: Int64
        let block_seq: Int
        let start_ms: Int
        let end_ms: Int










        let cluster_tag: String?
    }

    struct Job: Codable {
        let schema: Int
        let model: String
        let session: Int64
        let ext: String
        let lines: [JobLine]
        var force: Bool?













        var exclude_persons: [Int64]?
    }





    static let lineSelectSQL = """
        WITH ln AS (
          SELECT l.line_id AS line_id, l.block_seq AS blk,
                 l.t_start_ms AS s, l.t_end_ms AS e,
                 ls.source AS src, ls.person_id AS pid,


















                 CASE WHEN ls.cluster_tag LIKE t.session_id || '-%'
                      THEN substr(ls.cluster_tag, length(t.session_id) + 2)
                      ELSE ls.cluster_tag END AS tag
            FROM transcript_lines l
            JOIN transcripts t ON t.id = l.transcript_id
            JOIN sessions   ss ON ss.id = t.session_id
                              AND ss.active_transcript_id = t.id
            LEFT JOIN line_speakers ls ON ls.line_id = l.line_id
           WHERE ss.id = ? AND l.is_gap = 0 AND l.redacted = 0
        ),









        mixed AS (
          SELECT tag FROM ln
           WHERE src = '\(AttributionSource.userConfirmed.rawValue)' AND pid IS NOT NULL AND tag IS NOT NULL
           GROUP BY tag HAVING COUNT(DISTINCT pid) > 1
        )
        SELECT line_id, blk, s, e, tag
          FROM ln







         WHERE COALESCE(src, '') <> '\(AttributionSource.userConfirmed.rawValue)'
            OR tag IS NULL
            OR tag NOT IN (SELECT tag FROM mixed)
         ORDER BY line_id
        """



    static func jobPayload(sessionID: Int64, force: Bool = false,
                           in db: DatabaseQueue) throws -> Data? {
        let offsets = BlockTiming.offsets(sessionID: sessionID, in: db)
        let rows = try db.read { d in
            try Row.fetchAll(d, sql: lineSelectSQL, arguments: [sessionID])
        }










        var uploaded: Set<Int> = []
        var kept: [Int: [KeptInterval]] = [:]
        for job in try UploadJobStore.all(sessionID: sessionID, in: db) {
            uploaded.insert(job.blockSeq)
            if let iv = SpeechTrim.decode(job.keptJSON) { kept[job.blockSeq] = iv }
        }

        let lines: [JobLine] = rows.compactMap { row in
            guard let blk = row["blk"] as Int?,
                  let within = BlockTiming.withinBlock(startMs: row["s"], endMs: row["e"],
                                                       blockSeq: blk, offsets: offsets)
            else { return nil }        // 定位不到音频的行判不了,跳过(与端侧链同口径)

            guard uploaded.contains(blk) else { return nil }

            guard let iv = kept[blk] else {
                return JobLine(line_id: row["line_id"], block_seq: blk,
                               start_ms: within.start, end_ms: within.end,
                               cluster_tag: row["tag"])
            }
            guard let w = TranscriptFreeze.wavRange(blockStart: within.start,
                                                    blockEnd: within.end,
                                                    keptIntervals: iv)
            else { return nil }        // 定位不到 / 跨裁剪缝,判据在 `wavRange`
            return JobLine(line_id: row["line_id"], block_seq: blk,
                           start_ms: w.start, end_ms: w.end, cluster_tag: row["tag"])
        }
        guard !lines.isEmpty else { return nil }

        let mine = try db.read { d in
            try Int64.fetchAll(d, sql: """
                SELECT person_id FROM voiceprint_clusters WHERE session_id = ?
                """, arguments: [sessionID])
        }
        var job = Job(schema: 1, model: VoiceprintModel.current, session: sessionID,


                      ext: "wav", lines: lines)
        if !mine.isEmpty { job.exclude_persons = mine }
        if force { job.force = true }
        return try JSONEncoder().encode(job)
    }





    static func requeue(sessionID: Int64, force: Bool, in db: DatabaseQueue) async throws {
        guard let c = ProxySettings.config else { throw ProxyClient.Failure.notConfigured }
        guard let payload = try jobPayload(sessionID: sessionID, force: force, in: db) else {
            return   // 没有可判的行,排了也是空转
        }
        try await ProxyClient.enqueueVoiceprint(payload: payload, config: c)
        let now = ISO8601DateFormatter.growth.string(from: Date())
        try await db.write { d in


            try d.execute(sql: """
                UPDATE tasks SET state = 'queued', attempts = 0,
                       next_retry_at = NULL, last_error = NULL
                 WHERE session_id = ? AND kind = 'voiceprint'
                """, arguments: [sessionID])
            try d.execute(sql: """
                INSERT INTO tasks (kind, session_id, state, priority, created_at, attempts)
                SELECT 'voiceprint', ?, 'queued', 0, ?, 0
                 WHERE NOT EXISTS (SELECT 1 FROM tasks
                                    WHERE session_id = ? AND kind = 'voiceprint')
                """, arguments: [sessionID, now, sessionID])
        }
    }



    struct ClusterVerdict: Codable {
        let kind: String
        var person_id: Int64?



        var candidate_person_id: Int64?
        var votes: Int?
        var of: Int?
        var why: String?
    }


    struct ReviewCandidate: Codable {
        let line_id: Int64
        let score: Double
    }

    struct Cluster: Codable {
        let cluster_key: String
        let verdict: ClusterVerdict
        let centroid: [Float]
        let lines: [Int64]


        var review: [ReviewCandidate]?
    }

    struct Result: Codable {
        let schema: Int
        let model: String
        let session: Int64
        let gated_out: Int
        let clusters: [Cluster]
        var identity_mode: String? = nil
    }

    enum Failure: Error, CustomStringConvertible {
        case modelMismatch(got: String)
        case identityModeMismatch
        var description: String {
            switch self {
            case .modelMismatch(let got):
                return "判决用的模型空间 \(got) ≠ 本机 \(VoiceprintModel.current) —— "
                     + "不同空间的判决看起来完全正常,合并进来就是把错的人写满一场。整批拒收。"
            case .identityModeMismatch:
                return "这份是旧版认人结果，已重新排给 Mac 按「只认我」处理"
            }
        }
    }

    struct MergeOutcome: Equatable {
        var matched = 0            // 认出(含既有匿名人格)
        var anonymousNew = 0       // 新建的匿名人格
        var anonymousReused = 0    // 重放时复用的
        var tagged = 0             // 只挂簇标签的(单段簇等,留给手动确认)
        var gatedOut = 0
    }


    @discardableResult
    static func mergeSelf(_ data: Data, sessionID: Int64, now: String,
                          in db: DatabaseQueue) throws -> MergeOutcome {
        let r = try JSONDecoder().decode(Result.self, from: data)
        guard r.schema == 1, r.session == sessionID, r.identity_mode == "self_only",
              r.clusters.allSatisfy({ c in
                  c.cluster_key.hasPrefix("\(sessionID)-") &&
                  ((c.verdict.kind == "person" && c.verdict.person_id == SpeakerNaming.mePersonID) ||
                   (c.verdict.kind == "rejected" && c.verdict.person_id == nil)) &&
                  (c.verdict.candidate_person_id == nil || c.verdict.candidate_person_id == SpeakerNaming.mePersonID) &&
                  (c.review ?? []).allSatisfy { c.lines.contains($0.line_id) && $0.score.isFinite }
              }) else { throw Failure.identityModeMismatch }
        guard r.model == VoiceprintModel.current else { throw Failure.modelMismatch(got: r.model) }
        let allIDs = r.clusters.flatMap(\.lines)
        guard Set(allIDs).count == allIDs.count,
              Set(r.clusters.map(\.cluster_key)).count == r.clusters.count,
              r.gated_out >= 0 else { throw Failure.identityModeMismatch }
        return try db.write { d in
            let available = Set(try Int64.fetchAll(d, sql: """
                SELECT l.line_id FROM transcript_lines l JOIN transcripts t ON t.id = l.transcript_id
                 WHERE t.session_id = ? AND l.is_gap = 0 AND l.redacted = 0
                   AND t.version = (SELECT MAX(version) FROM transcripts WHERE session_id = t.session_id)
                """, arguments: [sessionID]))
            guard Set(allIDs).isSubset(of: available) else { throw Failure.identityModeMismatch }

            try d.execute(sql: """
                DELETE FROM speaker_reviews WHERE state = ? AND line_id IN
                  (SELECT l.line_id FROM transcript_lines l JOIN transcripts t ON t.id = l.transcript_id
                    WHERE t.session_id = ?)
                """, arguments: [SpeakerReviews.State.pending.rawValue, sessionID])
            try d.execute(sql: "UPDATE sessions SET voiceprint_gated_out = ? WHERE id = ?",
                          arguments: [r.gated_out, sessionID])
            var out = MergeOutcome(gatedOut: r.gated_out)
            for c in r.clusters where !c.lines.isEmpty {
                if c.verdict.person_id != nil || c.verdict.candidate_person_id != nil {
                    for candidate in c.review ?? [] {
                        let confirmed = try Bool.fetchOne(d, sql: "SELECT source = ? FROM line_speakers WHERE line_id = ?",
                                                         arguments: [AttributionSource.userConfirmed.rawValue, candidate.line_id]) ?? false
                        if !confirmed {
                            try SpeakerReviews.enqueue(lineID: candidate.line_id, person: SpeakerNaming.mePersonID,
                                score: candidate.score, clusterKey: c.cluster_key,
                                mode: c.verdict.kind == "rejected" ? .cluster : .line, now: now, in: d)
                        }
                    }
                }
                let isMe = c.verdict.kind == "person"
                let confidence = c.verdict.of.flatMap { n -> Double? in
                    guard n > 0, let votes = c.verdict.votes else { return nil }
                    return Double(votes) / Double(n)
                } ?? 0
                _ = try AssignSpeaker.assignSpeaker(lines: c.lines,
                    person: isMe ? SpeakerNaming.mePersonID : nil, clusterTag: c.cluster_key,
                    source: .voiceprint, confidence: confidence, actor: .system, now: now, in: d)
                if isMe { out.matched += 1 } else { out.tagged += 1 }
            }
            return out
        }
    }


    @discardableResult
    static func merge(_ data: Data, sessionID: Int64, now: String,
                      in db: DatabaseQueue) throws -> MergeOutcome {
        let r = try JSONDecoder().decode(Result.self, from: data)
        guard r.model == VoiceprintModel.current else {
            throw Failure.modelMismatch(got: r.model)
        }
        var out = MergeOutcome(gatedOut: r.gated_out)



        try db.write { d in
            try d.execute(sql: "UPDATE sessions SET voiceprint_gated_out = ? WHERE id = ?",
                          arguments: [r.gated_out, sessionID])
        }

        for c in r.clusters where !c.lines.isEmpty {




            if let who = c.verdict.person_id ?? c.verdict.candidate_person_id,
               let review = c.review, !review.isEmpty {
                try db.write { d in
                    for cand in review {
                        try SpeakerReviews.enqueue(lineID: cand.line_id, person: who,
                                                   score: cand.score,
                                                   clusterKey: c.cluster_key,
                                                   mode: r.identity_mode == "self_only" && c.verdict.kind == "rejected" ? .cluster : .line,
                                                   now: now, in: d)
                    }
                }
            }
            switch c.verdict.kind {
            case "person":
                guard let pid = c.verdict.person_id else { continue }
                let conf = c.verdict.of.flatMap { of -> Double? in
                    guard of > 0, let v = c.verdict.votes else { return nil }
                    return Double(v) / Double(of)
                } ?? 0
                _ = try AssignSpeaker.assignSpeaker(
                    lines: c.lines, person: pid, clusterTag: c.cluster_key,
                    source: .voiceprint, confidence: conf, actor: .system,
                    now: now, in: db)
                out.matched += 1

            case "anonymous_candidate" where c.lines.count >= 2:


                let pid = try db.write { d -> Int64 in
                    if let existing = try Int64.fetchOne(d, sql: """
                        SELECT person_id FROM voiceprint_clusters WHERE cluster_key = ?
                        """, arguments: [c.cluster_key]) {
                        out.anonymousReused += 1
                        return existing
                    }


                    try d.execute(sql: """
                        INSERT INTO persons (name, source, created_at, updated_at)
                        VALUES (NULL, ?, ?, ?)
                        """, arguments: [PersonStore.Source.clustered.rawValue, now, now])
                    let pid = d.lastInsertedRowID



                    try d.execute(sql: """
                        INSERT INTO voiceprint_clusters
                          (cluster_key, session_id, person_id, created_at,
                           candidate_person_id, candidate_votes, candidate_of)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [c.cluster_key, sessionID, pid, now,
                                         c.verdict.candidate_person_id,
                                         c.verdict.votes, c.verdict.of])
























                    out.anonymousNew += 1
                    return pid
                }
                _ = try AssignSpeaker.assignSpeaker(
                    lines: c.lines, person: pid, clusterTag: c.cluster_key,


                    source: .voiceprint, confidence: 0, actor: .system,
                    now: now, in: db)

            default:

                _ = try AssignSpeaker.assignSpeaker(
                    lines: c.lines, person: nil, clusterTag: c.cluster_key,
                    source: .voiceprint, confidence: 0, actor: .system,
                    now: now, in: db)
                out.tagged += 1
            }
        }
        return out
    }
}
