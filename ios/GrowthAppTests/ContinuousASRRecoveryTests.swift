import XCTest
import GRDB
@testable import GrowthApp

/// 生产装配与接入接线；不请求云端，不读取用户库。
final class ContinuousASRRecoveryTests: XCTestCase {
    private var db: DatabaseQueue!
    private var dir: URL!
    private let day = "2099-10-13"
    private let t0 = ISO8601DateFormatter().date(from: "2099-10-13T01:00:00Z")!
    private var stamp: String { ISO8601DateFormatter.growth.string(from: t0) }
    private let empty = #"{"duration":4.48,"result":[{}]}"#
    private let spoken = #"{"result":[{"utterances":[{"start_time":1000,"end_time":3000,"text":"项目讨论继续","speaker":{"id":"speaker_0"}}]}]}"#

    override func setUpWithError() throws {
        db = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(db)
        try db.write {
            try $0.execute(sql: "INSERT INTO sessions(id,started_at,day,source,status) VALUES(1,?,?,'watch','recording')",
                           arguments: [stamp, day])
        }
        let target = RecordingPaths.audioDir(day: day, source: SessionSource.watch)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw ContinuousIngestion.Failure.invalid("测试录音目录已有内容，不覆盖")
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        dir = target
        let ledger = target.appendingPathComponent("ledger.jsonl")
        try BlockLedger.append(LedgerEntry(at: t0, mark: .sessionStarted, source: SessionSource.watch), to: ledger)
        for seq in 0..<3 {
            let start = t0.addingTimeInterval(Double(seq * 270))
            let name = String(format: "block-%04d.m4a", seq)
            try BlockLedger.append(LedgerEntry(block: BlockRecord(seq: seq, startedAt: start,
                endedAt: start.addingTimeInterval(270), hardCut: false, fileName: name)), to: ledger)
            try Data("preserved-audio-\(seq)".utf8).write(to: target.appendingPathComponent(name))
        }
    }
    override func tearDownWithError() throws {
        if let dir { try FileManager.default.removeItem(at: dir) }
        db = nil; dir = nil
    }
    private func done(_ seq: Int, raw: String) throws {
        _ = try ASRJobStore.claim(sessionID: 1, blockSeq: seq, remoteID: "remote-\(seq)", now: stamp, in: db)
        try ASRJobStore.finish(sessionID: 1, blockSeq: seq, resultJSON: raw, now: stamp, in: db)
    }
    private func job(_ seq: Int) throws -> ASRJobStore.Job? {
        try db.read { try ASRJobStore.fetch($0, sessionID: 1, blockSeq: seq) }
    }
    private func ingest() throws -> ContinuousIngestion.Appended? {
        let call = try XCTUnwrap(ProcessingPump.dependencies(in: db, trigger: .foreground).ingestCompletedBlocks)
        return try call(1, ASRJobStore.all(sessionID: 1, in: db))
    }

    func testSpokenEmptySpokenAdvancesAndReplayPreservesSources() throws {
        try done(0, raw: spoken); try done(1, raw: empty); try done(2, raw: spoken)
        XCTAssertEqual(try ingest()?.blockSeqs, [0, 1, 2])
        XCTAssertEqual(try ingest()?.blockSeqs, [])
        let gap = try db.read { try XCTUnwrap(Row.fetchOne($0, sql: "SELECT l.*,t.status FROM transcript_lines l JOIN transcripts t ON t.id=l.transcript_id WHERE l.block_seq=1")) }
        XCTAssertEqual(gap["is_gap"] as Int, 1)
        XCTAssertEqual(gap["text"] as String, "〔此段未识别到文字，录音已保留〕")
        XCTAssertEqual(gap["status"] as String, "partial")
        XCTAssertEqual(gap["t_start_ms"] as Int, 270_000)
        XCTAssertEqual(gap["t_end_ms"] as Int, 540_000)
        try db.read {
            XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM stream_blocks"), 3)
            XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM transcripts"), 3)
            XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tasks WHERE kind='extract' AND state='queued'"), 1)
            XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT MIN(t_start_ms) FROM transcript_lines WHERE block_seq=2"), 541_000)
            XCTAssertEqual(try String.fetchOne($0, sql: "SELECT status FROM sessions WHERE id=1"), "recording")
            XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT SUM(resubmits) FROM asr_jobs"), 0)
        }
        XCTAssertEqual(try job(1)?.state, .done)
        XCTAssertEqual(try job(1)?.resultJSON, empty)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("block-0001.m4a")), Data("preserved-audio-1".utf8))
    }

    func testPermanentUploadGapDoesNotHideLaterPaidTranscription() throws {
        try done(0, raw: spoken); try done(2, raw: spoken)
        _ = try UploadJobStore.claim(sessionID: 1, blockSeq: 1, key: "bad-source", now: stamp, in: db)
        try UploadJobStore.failPermanently(sessionID: 1, blockSeq: 1, error: "confirmed missing source", now: stamp, in: db)
        XCTAssertEqual(try ingest()?.blockSeqs, [0, 1, 2])
        XCTAssertEqual(try ingest()?.blockSeqs, [])
        try db.read {
            XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM transcript_lines l JOIN transcripts t ON t.id=l.transcript_id WHERE l.block_seq=1 AND l.is_gap=1 AND t.status='partial'"), 1)
            XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM transcript_lines WHERE block_seq=2 AND is_gap=0"), 1)
            XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM asr_jobs"), 2)
        }
        XCTAssertEqual(try job(2)?.remoteID, "remote-2")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("block-0001.m4a")), Data("preserved-audio-1".utf8))
    }

    func testTemporaryUploadFailureRemainsRetryableWithoutFreezingGap() throws {
        try done(0, raw: spoken); try done(2, raw: spoken)
        _ = try UploadJobStore.claim(sessionID: 1, blockSeq: 1, key: "retryable-source", now: stamp, in: db)
        try UploadJobStore.fail(sessionID: 1, blockSeq: 1, status: 500, error: "temporary", now: stamp, in: db)
        XCTAssertEqual(try ingest()?.blockSeqs, [0])
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM transcript_lines WHERE block_seq=1") }, 0)
        XCTAssertEqual(try job(2)?.state, .done)
        XCTAssertEqual(try job(2)?.resultJSON, spoken)
    }

    func testAllEmptyUsesLocalExtractionWithoutInventingMatters() async throws {
        for seq in 0..<3 { try done(seq, raw: empty) }
        XCTAssertEqual(try ingest()?.blockSeqs, [0, 1, 2])
        var deps = ProcessingPump.dependencies(in: db, trigger: .foreground)
        deps.extract = { _ in throw ContinuousIngestion.Failure.invalid("空片不应请求模型") }
        deps.enqueueExtractLines = { _, _, _ in throw ContinuousIngestion.Failure.invalid("空片不应云端排队") }
        _ = try await ProcessingOrchestrator.tick(now: t0, deps: deps, in: db)
        try await db.read {
            XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM summaries"), 3)
            XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM summary_events"), 0)
            XCTAssertEqual(try String.fetchOne($0, sql: "SELECT state FROM tasks WHERE kind='extract'"), "done")
            XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM transcripts WHERE status='partial'"), 3)
        }
    }

    func testMalformedPayloadStillBlocksAndKeepsFollowingResult() throws {
        try done(0, raw: "not-json"); try done(1, raw: spoken)
        XCTAssertThrowsError(try ingest())
        XCTAssertEqual(try job(0)?.state, .failed)
        XCTAssertEqual(try job(1)?.state, .done)
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM stream_blocks") }, 0)
        XCTAssertEqual(try ASRJobStore.recoverEmptyRecognitions(now: stamp, in: db), 0)
    }

    func testTextWithInvalidTimesIsNotTreatedAsEmpty() throws {
        let badTime = #"{"result":[{"utterances":[{"start_time":3000,"end_time":1000,"text":"有字但时间倒挂"}]}]}"#
        try done(0, raw: badTime); try done(1, raw: spoken)
        XCTAssertThrowsError(try ingest())
        XCTAssertEqual(try job(0)?.state, .failed)
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM stream_blocks") }, 0)
    }

    func testRecoveryReusesOnlyKnownMisclassifiedCacheAndWakesDeadTask() throws {
        try done(0, raw: empty); try done(1, raw: empty); try done(2, raw: "bad-json")
        for (seq, why) in [(0, ASRJobStore.legacyEmptyResultError), (1, "audio_download"), (2, ASRJobStore.legacyEmptyResultError)] {
            try ASRJobStore.fail(sessionID: 1, blockSeq: seq, error: why, now: stamp, in: db)
        }
        let task = try TaskQueue.enqueue(kind: "transcribe", sessionID: 1, now: stamp, in: db)
        try db.write { try $0.execute(sql: "UPDATE tasks SET state='dead',attempts=2,next_retry_at='2099-12-31' WHERE task_id=?", arguments: [task]) }
        XCTAssertEqual(try ASRJobStore.recoverEmptyRecognitions(now: stamp, in: db), 1)
        XCTAssertEqual(try ASRJobStore.recoverEmptyRecognitions(now: stamp, in: db), 0)
        XCTAssertEqual(try job(0)?.state, .done)
        XCTAssertEqual(try job(0)?.remoteID, "remote-0")
        XCTAssertEqual(try job(0)?.resultJSON, empty)
        XCTAssertEqual(try job(1)?.state, .failed)
        XCTAssertEqual(try job(2)?.state, .failed)
        XCTAssertEqual(try ingest()?.blockSeqs, [0])
        try db.read {
            XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT attempts FROM tasks WHERE task_id=?", arguments: [task]), 2)
            XCTAssertEqual(try String.fetchOne($0, sql: "SELECT state FROM tasks WHERE task_id=?", arguments: [task]), "queued")
            XCTAssertNil(try String.fetchOne($0, sql: "SELECT next_retry_at FROM tasks WHERE task_id=?", arguments: [task]))
            XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT SUM(resubmits) FROM asr_jobs"), 0)
        }
    }

    func testRemovedAndLegacyClosedSessionsAreNotRecovered() throws {
        try done(0, raw: empty)
        try ASRJobStore.fail(sessionID: 1, blockSeq: 0, error: ASRJobStore.legacyEmptyResultError, now: stamp, in: db)
        try db.write { try $0.execute(sql: "UPDATE sessions SET removed_at=? WHERE id=1", arguments: [stamp]) }
        XCTAssertEqual(try ASRJobStore.recoverEmptyRecognitions(now: stamp, in: db), 0)
        try db.write { try $0.execute(sql: "UPDATE sessions SET removed_at=NULL,status='closed' WHERE id=1") }
        XCTAssertEqual(try ASRJobStore.recoverEmptyRecognitions(now: stamp, in: db), 0)
        try db.write { try $0.execute(sql: "INSERT INTO stream_sessions(session_id,created_at) VALUES(1,?)", arguments: [stamp]) }
        XCTAssertEqual(try ASRJobStore.recoverEmptyRecognitions(now: stamp, in: db), 1)
        XCTAssertEqual(try ingest()?.blockSeqs, [0])
    }

    func testUnknownShapesAndMixedResultsCannotBecomeEmpty() {
        for raw in ["{}", "not-json", #"{"result":[{"error":"failed"}]}"#,
                    #"{"result":[{}, {"utterances":[{"text":"真正的文字"}]}]}"#,
                    #"{"result":[{"text":"真实内容","utterances":[]}]}"#,
                    #"{"utterances":[],"result":[{"segments":[{"text":"另一层的文字"}]}]}"#,
                    #"{"result":[{"utterances":[],"segments":[{"text":"另一个字段的文字"}]}]}"#,
                    #"{"utterances":[],"result":[{"utterances":[{"unexpected":"new-shape"}]}]}"#,
                    #"{"utterances":[{"unexpected":"new-shape"}]}"#] {
            XCTAssertFalse(ASRResponseParser.isEmptyRecognition(rawJSON: raw))
        }
        for raw in [empty, #"{"result":[{"utterances":[]}]}"#,
                    #"{"data":{"utterances":[{"text":"  \n  "}]}}"#] {
            XCTAssertTrue(ASRResponseParser.isEmptyRecognition(rawJSON: raw))
        }
    }

    func testRefrozenStreamIsNotRecoveredOrWoken() throws {
        try done(0, raw: empty)
        try ASRJobStore.fail(sessionID: 1, blockSeq: 0, error: ASRJobStore.legacyEmptyResultError, now: stamp, in: db)
        try db.write {
            try $0.execute(sql: "INSERT INTO stream_sessions(session_id,created_at) VALUES(1,?)", arguments: [stamp])
            try $0.execute(sql: "UPDATE sessions SET status='closed' WHERE id=1")
        }
        _ = try TranscriptFreeze.freeze(sessionID: 1, asrModel: "test", version: 2,
            blocks: [], missing: [MissingBlock(blockSeq: 0, offsetMs: 0, durationMs: 270_000)], now: stamp, in: db)
        let task = try TaskQueue.enqueue(kind: "transcribe", sessionID: 1, now: stamp, in: db)
        try db.write { try $0.execute(sql: "UPDATE tasks SET state='dead' WHERE task_id=?", arguments: [task]) }
        XCTAssertEqual(try ASRJobStore.recoverEmptyRecognitions(now: stamp, in: db), 0)
        XCTAssertEqual(try job(0)?.state, .failed)
        XCTAssertEqual(try db.read { try String.fetchOne($0, sql: "SELECT state FROM tasks WHERE task_id=?", arguments: [task]) }, "dead")
    }

    func testClosedDegradedStreamRecoveryRunsThroughNormalQueue() async throws {
        try done(0, raw: empty); try done(1, raw: spoken); try done(2, raw: spoken)
        try ASRJobStore.fail(sessionID: 1, blockSeq: 0, error: ASRJobStore.legacyEmptyResultError, now: stamp, in: db)
        let task = try TaskQueue.enqueue(kind: "transcribe", sessionID: 1, now: stamp, in: db)
        try await db.write {
            try $0.execute(sql: "INSERT INTO stream_sessions(session_id,created_at) VALUES(1,?)", arguments: [self.stamp])
            try $0.execute(sql: "UPDATE sessions SET status='closed' WHERE id=1")
            try $0.execute(sql: "UPDATE tasks SET state='degraded' WHERE task_id=?", arguments: [task])
        }
        XCTAssertEqual(try ASRJobStore.recoverEmptyRecognitions(now: stamp, in: db), 1)
        XCTAssertEqual(try TaskQueue.nextRunnable(now: stamp, in: db), task)
        var deps = ProcessingPump.dependencies(in: db, trigger: .foreground)
        deps.proxy = .init(baseURL: URL(string: "https://example.invalid")!, token: "test")
        deps.submit = { _, _ in throw ContinuousIngestion.Failure.invalid("缓存恢复不能重提") }
        deps.query = { _ in throw ContinuousIngestion.Failure.invalid("缓存恢复不需要轮询") }
        let result = try await ProcessingOrchestrator.tick(now: t0, deps: deps, in: db)
        guard case .frozen(sessionID: 1, lines: 3, status: "partial") = result else {
            return XCTFail("恢复未通过正常队列接入：\(result)")
        }
        try await db.read {
            XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM stream_blocks"), 3)
            XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tasks WHERE kind='extract' AND state='queued'"), 1)
            XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT SUM(resubmits) FROM asr_jobs"), 0)
        }
    }
}
