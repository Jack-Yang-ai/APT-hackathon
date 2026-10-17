import XCTest
import GRDB
@testable import GrowthApp

/// 夺回上游分人(`M2-认9`)。
///
/// 🔴 **这组守的是「错位」这一种失败。** 把 utterance 按顺序贴回转写行,
/// 一旦数量对不上而照贴不误,表现是**每个人的话都挪了一格** ——
/// 屏幕上一切正常、行数一条不少、没有任何东西会红,而每一句都记在错的人名下。
/// 所以「对不上就整场跳过」这条比「修好了」更重要。
final class UpstreamDiarizationRepairTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-31T16:00:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
    }
    override func tearDownWithError() throws { dbQueue = nil }

    // MARK: - 夹具

    private func resultJSON(_ speakers: [String?]) -> String {
        let utts = speakers.map { s -> String in
            let spk = s.map { "\"speaker\":{\"id\":\"\($0)\"}," } ?? ""
            return "{\(spk)\"text\":\"x\",\"start_time\":0,\"end_time\":1}"
        }
        return "{\"duration\":1,\"result\":[{\"text\":\"x\",\"utterances\":[\(utts.joined(separator: ","))]}]}"
    }

    /// 一场:n 行实句 + 一份 ASR 结果。`attributed` 给每行当前的 (person, tag, source)。
    private func makeSession(_ sessionID: Int64, speakers: [String?],
                             attributed: [(Int64?, String?, String)]) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status, active_transcript_id)
                VALUES (?, '2026-08-28T14:00:00+08:00', '2026-08-28', 'recording', 'closed', ?)
                """, arguments: [sessionID, sessionID])
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (?, ?, 1, 1, 'step-asr', 'frozen', ?)
                """, arguments: [sessionID, sessionID, now])
            for (i, a) in attributed.enumerated() {
                let lineID = sessionID * 1000 + Int64(i)
                try db.execute(sql: """
                    INSERT INTO transcript_lines
                      (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, block_seq)
                    VALUES (?, ?, ?, ?, ?, '一句话', 0, 0)
                    """, arguments: [lineID, sessionID, i, i * 1000, i * 1000 + 900])
                try db.execute(sql: """
                    INSERT INTO line_speakers
                      (line_id, person_id, cluster_tag, confidence, source, updated_at)
                    VALUES (?, ?, ?, 0.5, ?, ?)
                    """, arguments: [lineID, a.0, a.1, a.2, now])
            }
            try db.execute(sql: """
                INSERT INTO asr_jobs (session_id, block_seq, remote_id, state, result_json,
                                      created_at, updated_at)
                VALUES (?, 0, 'r', 'done', ?, ?, ?)
                """, arguments: [sessionID, resultJSON(speakers), now, now])
        }
    }

    private func tags(_ sessionID: Int64) throws -> [String?] {
        try dbQueue.read { db in
            try String?.fetchAll(db, sql: """
                SELECT ls.cluster_tag FROM transcript_lines l
                  JOIN line_speakers ls ON ls.line_id = l.line_id
                  JOIN transcripts t ON t.id = l.transcript_id
                 WHERE t.session_id = ? ORDER BY l.seq
                """, arguments: [sessionID])
        }
    }

    // MARK: - 夺回

    /// 被声纹碎簇盖掉的行,标签要回到 ASR 那一份,人要清空。
    func testVoiceprintFragmentsAreReplacedByUpstreamTags() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO persons (id, name, source, created_at, updated_at)
                VALUES (34, NULL, '声纹聚类', ?, ?)
                """, arguments: [now, now])
        }
        try makeSession(1, speakers: ["speaker_0", "speaker_1", "speaker_0"],
                        attributed: [(34, "1-c0", "声纹识别"),
                                     (nil, "1-c1", "声纹识别"),
                                     (34, "1-c2", "声纹识别")])

        let r = try dbQueue.write { try AppDatabase.applyUpstreamDiarizationRepair(now: now, in: $0) }

        XCTAssertEqual(r.repaired[1]?.count, 3)
        XCTAssertEqual(try tags(1), ["speaker_0", "speaker_1", "speaker_0"],
                       "标签没回到 ASR 那一份 —— 新的出题会把这一场判成「没有分人」")
        let people = try dbQueue.read { db in
            try Int64?.fetchAll(db, sql: """
                SELECT ls.person_id FROM line_speakers ls
                  JOIN transcript_lines l ON l.line_id = ls.line_id
                  JOIN transcripts t ON t.id = l.transcript_id WHERE t.session_id = 1
                """)
        }
        XCTAssertEqual(people, [nil, nil, nil],
                       "碎簇人格还挂在行上 —— 那 40 个人格就删不掉(外键)")
    }

    /// 🔴 **行数对不上就整场跳过。** 照贴的话每个人的话都挪一格,而没有东西会红。
    func testMismatchedCountsSkipTheWholeSessionInsteadOfShifting() throws {
        try makeSession(2, speakers: ["speaker_0", "speaker_1"],          // 2 条 utterance
                        attributed: [(nil, "2-c0", "声纹识别"),           // 3 行
                                     (nil, "2-c1", "声纹识别"),
                                     (nil, "2-c2", "声纹识别")])

        let r = try dbQueue.write { try AppDatabase.applyUpstreamDiarizationRepair(now: now, in: $0) }

        XCTAssertNil(r.repaired[2], "数量对不上还照贴了 —— 每一句都会记在错的人名下")
        XCTAssertEqual(r.skipped[2], "行数 3 ≠ utterance 数 2")
        XCTAssertEqual(try tags(2), ["2-c0", "2-c1", "2-c2"], "跳过的场次一个字都不该动")
    }

    /// 用户确认过的行不许被夺回 —— 那是他亲手做的判断。
    func testUserConfirmedLinesAreNeverTouched() throws {
        try makeSession(3, speakers: ["speaker_0", "speaker_1"],
                        attributed: [(SpeakerNaming.mePersonID, "3-c0", "用户确认"),
                                     (nil, "3-c1", "声纹识别")])

        _ = try dbQueue.write { try AppDatabase.applyUpstreamDiarizationRepair(now: now, in: $0) }

        XCTAssertEqual(try tags(3), ["3-c0", "speaker_1"],
                       "用户确认过的那一行被改了 —— 这一步不许碰用户的判断")
    }

    /// 上游本来就没给分人(SSE 形态)⇒ 跳过,**并且说得出为什么**。
    func testSessionsWithNoUpstreamSpeakersAreSkippedWithAReason() throws {
        try makeSession(4, speakers: [nil, nil],
                        attributed: [(nil, "4-c0", "声纹识别"), (nil, "4-c1", "声纹识别")])

        let r = try dbQueue.write { try AppDatabase.applyUpstreamDiarizationRepair(now: now, in: $0) }

        XCTAssertNil(r.repaired[4])
        XCTAssertEqual(r.skipped[4], "上游本来就没给分人(SSE 形态)")
    }

    /// 同一场里混着 SSE 的块:没标签的那几行原样留着,不给它们编一个。
    func testUtterancesWithoutSpeakerLeaveTheirLineAlone() throws {
        try makeSession(5, speakers: ["speaker_0", nil],
                        attributed: [(nil, "5-c0", "声纹识别"), (nil, "5-c1", "声纹识别")])

        _ = try dbQueue.write { try AppDatabase.applyUpstreamDiarizationRepair(now: now, in: $0) }

        XCTAssertEqual(try tags(5), ["speaker_0", "5-c1"],
                       "给没有 speaker 的 utterance 编了个标签 —— 「不知道」不是一个身份")
    }

    /// 修过就要在账本上留痕,否则这次改动无迹可寻。
    func testEveryRepairedSessionLeavesAJudgment() throws {
        try makeSession(6, speakers: ["speaker_0"], attributed: [(nil, "6-c0", "声纹识别")])
        _ = try dbQueue.write { try AppDatabase.applyUpstreamDiarizationRepair(now: now, in: $0) }
        let n = try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM judgments WHERE payload LIKE '%M2-认9%'
                """) ?? 0
        }
        XCTAssertEqual(n, 1, "改了归属却没留判断记录 —— 下一个人查不到这些行为什么变了")
    }
}
