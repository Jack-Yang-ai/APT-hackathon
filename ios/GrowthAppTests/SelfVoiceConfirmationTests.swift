import XCTest
import GRDB
@testable import GrowthApp

final class SelfVoiceConfirmationTests: XCTestCase {
    private var db: DatabaseQueue!
    private let now = "2026-10-12T12:00:00+08:00"

    override func setUpWithError() throws {
        db = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(db)
        RecomputeRegistry.resetToM0Defaults()
        try db.write { d in
            for sid in [7, 8] {
                try d.execute(sql: "INSERT INTO sessions (id, started_at, day, source, status) VALUES (?, ?, '2026-10-12', 'recording', 'closed')", arguments: [sid, "2026-10-12T\(sid + 10):00:00+08:00"])
                try d.execute(sql: """
                    INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at, frozen_at)
                    VALUES (?, ?, 1, 1, 'x', 'frozen', ?, ?)
                    """, arguments: [sid * 10, sid, now, now])
                for i in 0..<3 {
                    let id = sid * 100 + i
                    try d.execute(sql: """
                        INSERT INTO transcript_lines (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, is_gap)
                        VALUES (?, ?, ?, ?, ?, '我的测试原话', 0, 0)
                        """, arguments: [id, sid * 10, i, i * 5000, i * 5000 + 4000])
                    try d.execute(sql: """
                        INSERT INTO line_speakers (line_id, person_id, cluster_tag, source, confidence, updated_at)
                        VALUES (?, NULL, 'speaker_0', '系统整理', 0, ?)
                        """, arguments: [id, now])
                }
            }
        }
    }

    private func result(kind: String = "rejected", mode: String = "self_only", person: Int64? = nil,
                        lines: [Int64] = [700, 701, 702]) throws -> Data {
        var verdict: [String: Any] = ["kind": kind, "candidate_person_id": -1, "votes": 1, "of": 3]
        if let person { verdict["person_id"] = person }
        return try JSONSerialization.data(withJSONObject: [
            "schema": 1, "model": VoiceprintModel.current, "session": 7, "identity_mode": mode,
            "gated_out": 0, "clusters": [["cluster_key": "7-speaker_0", "verdict": verdict,
                                          "centroid": [0.6, 0.8], "lines": lines,
                                          "review": [["line_id": 700, "score": 5.1], ["line_id": 701, "score": 5.0]]]]])
    }

    func testGrayYesConfirmsWholeClusterButDoesNotEnrollUnheardAudio() throws {
        try VoiceprintRemote.mergeSelf(result(), sessionID: 7, now: now, in: db)
        let c = try XCTUnwrap(SpeakerReviews.selfCandidates(sessionID: 7, in: db).first)
        XCTAssertTrue(c.isClusterConfirmation)
        XCTAssertEqual(Set(try SpeakerReviews.answerSelf(c, isMe: true, now: now, in: db)), [700, 701, 702])
        try db.read { d in
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM line_speakers WHERE person_id = -1 AND source = '用户确认'"), 3)
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM voiceprints"), 0)
            XCTAssertNil(try Int64.fetchOne(d, sql: "SELECT person_id FROM line_speakers WHERE line_id = 800"))
        }
        XCTAssertTrue(try SpeakerReviews.selfCandidates(in: db).isEmpty)
    }

    func testGrayNoSurvivesHighScoreReplayAndStopsAskingWholeCluster() throws {
        try VoiceprintRemote.mergeSelf(result(), sessionID: 7, now: now, in: db)
        let c = try XCTUnwrap(SpeakerReviews.selfCandidates(in: db).first)
        try SpeakerReviews.answerSelf(c, isMe: false, now: now, in: db)
        try VoiceprintRemote.mergeSelf(result(kind: "person", person: -1), sessionID: 7, now: now, in: db)
        try db.read { d in
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM line_speakers WHERE line_id BETWEEN 700 AND 702 AND person_id IS NULL AND source = '用户确认'"), 3)
        }
        XCTAssertTrue(try SpeakerReviews.selfCandidates(in: db).isEmpty)
    }

    func testHighScoreReviewOnlyChangesTheHeardLine() throws {
        try VoiceprintRemote.mergeSelf(result(kind: "person", person: -1), sessionID: 7, now: now, in: db)
        let c = try XCTUnwrap(SpeakerReviews.selfCandidates(in: db).first)
        XCTAssertFalse(c.isClusterConfirmation)
        XCTAssertEqual(try SpeakerReviews.answerSelf(c, isMe: false, now: now, in: db), [700])
        try db.read { d in
            XCTAssertNil(try Int64.fetchOne(d, sql: "SELECT person_id FROM line_speakers WHERE line_id = 700"))
            XCTAssertEqual(try Int64.fetchOne(d, sql: "SELECT person_id FROM line_speakers WHERE line_id = 701"), -1)
        }
        XCTAssertEqual(try SpeakerReviews.selfCandidates(in: db).map(\.lineID), [701])
    }

    func testLegacyOtherPersonAndCrossSessionResultsCannotWrite() throws {
        for payload in [try result(mode: "open_set"), try result(kind: "person", person: 99), try result(lines: [700, 701, 800])] {
            XCTAssertThrowsError(try VoiceprintRemote.mergeSelf(payload, sessionID: 7, now: now, in: db))
        }
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM speaker_reviews") }, 0)
    }

    func testStaleConfirmationCannotOverwriteAUserDecision() throws {
        try VoiceprintRemote.mergeSelf(result(), sessionID: 7, now: now, in: db)
        let c = try XCTUnwrap(SpeakerReviews.selfCandidates(in: db).first)
        try SpeakerReviews.answerSelf(c, isMe: false, now: now, in: db)
        XCTAssertThrowsError(try SpeakerReviews.answerSelf(c, isMe: true, now: now, in: db))
    }

    func testReviewWriteFailureRollsBackTheAttributionAndAllowsRetry() throws {
        try VoiceprintRemote.mergeSelf(result(), sessionID: 7, now: now, in: db)
        let c = try XCTUnwrap(SpeakerReviews.selfCandidates(in: db).first)
        try db.write { try $0.execute(sql: """
            CREATE TRIGGER fail_review_answer BEFORE UPDATE ON speaker_reviews
            BEGIN SELECT RAISE(ABORT, 'test answer failpoint'); END;
            """) }
        XCTAssertThrowsError(try SpeakerReviews.answerSelf(c, isMe: true, now: now, in: db))
        XCTAssertTrue(try SpeakerReviews.selfCandidates(in: db).contains(c))
        XCTAssertNil(try db.read { try Int64.fetchOne($0, sql: "SELECT person_id FROM line_speakers WHERE line_id = 700") })
        try db.write { try $0.execute(sql: "DROP TRIGGER fail_review_answer") }
        try SpeakerReviews.answerSelf(c, isMe: true, now: now, in: db)
    }

    func testLowScoreRejudgeWithdrawsOldLineReviewInsteadOfTurningItIntoAClusterQuestion() throws {
        try VoiceprintRemote.mergeSelf(result(kind: "person", person: -1), sessionID: 7, now: now, in: db)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: result()) as? [String: Any])
        var cluster = try XCTUnwrap((payload["clusters"] as? [[String: Any]])?.first)
        cluster["verdict"] = ["kind": "rejected"]
        cluster["review"] = []
        payload["clusters"] = [cluster]
        try VoiceprintRemote.mergeSelf(JSONSerialization.data(withJSONObject: payload), sessionID: 7, now: now, in: db)
        XCTAssertTrue(try SpeakerReviews.selfCandidates(in: db).isEmpty)
    }

    func testAConfirmationRevokedDuringEmbeddingCannotEnterTheRegistry() throws {
        _ = try AssignSpeaker.assignSpeaker(lines: [700], person: -1, clusterTag: nil,
            source: .userConfirmed, confidence: nil, actor: .user, now: now, in: db)
        let vector: [Float] = [1, 0, 0]
        let cmd = EnrollCommand(action: .enroll, personID: -1,
            embedding: vector.withUnsafeBufferPointer { Data(buffer: $0) }, dim: vector.count,
            model: VoiceprintModel.current, source: "confirmed/7", id: nil)
        _ = try AssignSpeaker.assignSpeaker(lines: [700], person: nil, clusterTag: nil,
            source: .userConfirmed, confidence: nil, actor: .user, now: now, in: db)
        XCTAssertNil(try VoiceprintRegistry.applyConfirmed(cmd, lineID: 700, now: now, in: db))
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM voiceprints") }, 0)
    }
}
