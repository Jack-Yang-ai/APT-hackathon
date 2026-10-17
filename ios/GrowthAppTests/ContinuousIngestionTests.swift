import XCTest
import GRDB
@testable import GrowthApp

final class ContinuousIngestionTests: XCTestCase {
    private var db: DatabaseQueue!
    private let stamp = "2026-10-13T10:00:00+08:00"
    private var freezes = 0
    override func setUpWithError() throws {
        db = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(db)
        try db.write { d in
            try d.execute(sql: "INSERT INTO sessions(id, started_at, day, source, status) VALUES(1, ?, '2026-10-13', 'watch', 'recording')", arguments: [stamp])
        }
    }

    private func block(_ seq: Int) -> PendingBlock {
        PendingBlock(blockSeq: seq, fileURL: URL(fileURLWithPath: "/tmp/not-read-\(seq).m4a"),
                     seconds: 300, offsetMs: (seq - 7) * 300_000, durationMs: 300_000)
    }
    private func done(_ seq: Int) throws {
        _ = try ASRJobStore.claim(sessionID: 1, blockSeq: seq, remoteID: "r\(seq)", now: stamp, in: db)
        try ASRJobStore.finish(sessionID: 1, blockSeq: seq, resultJSON: "{}", now: stamp, in: db)
    }
    @discardableResult
    private func append(_ seqs: [Int]) throws -> ContinuousIngestion.Appended? {
        try ContinuousIngestion.append(sessionID: 1, blocks: seqs.map(block),
            jobs: ASRJobStore.all(sessionID: 1, in: db), skipped: [], now: stamp,
            freezeBlock: { b, part, record in
                self.freezes += 1
                return try TranscriptFreeze.freeze(sessionID: 1, asrModel: "fake", part: part,
                    blocks: [BlockTranscript(blockSeq: b.blockSeq, offsetMs: b.offsetMs,
                        keptIntervals: [KeptInterval(startMs: 0, endMs: b.durationMs)],
                        lines: [ASRLine(startMs: 1000, endMs: 3000, text: "片\(b.blockSeq)项目原话")])],
                    now: self.stamp, onFrozen: record, in: self.db)
            }, in: db)
    }

    func testOpenWatchAppendsWithoutSealingAndReplayNeverRefreezes() throws {
        try done(7)
        XCTAssertEqual(try append([7])?.blockSeqs, [7])
        try done(8)
        XCTAssertEqual(try append([7, 8])?.blockSeqs, [8])
        XCTAssertEqual(try append([7, 8])?.blockSeqs, [])
        XCTAssertEqual(freezes, 2)
        try db.read { d in
            XCTAssertEqual(try String.fetchOne(d, sql: "SELECT status FROM sessions WHERE id = 1"), "recording")
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM transcripts"), 2)
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM tasks WHERE kind = 'extract'"), 1)
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM tasks WHERE kind IN ('voiceprint','progress')"), 0)
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT MAX(t_start_ms) FROM transcript_lines"), 301000)
        }
    }

    func testLaterDoneWaitsForEarlierThenBothAdvance() throws {
        _ = try ASRJobStore.claim(sessionID: 1, blockSeq: 7, remoteID: "r7", now: stamp, in: db)
        try done(8)
        XCTAssertEqual(try append([7, 8])?.blockSeqs, [])
        try ASRJobStore.finish(sessionID: 1, blockSeq: 7, resultJSON: "{}", now: stamp, in: db)
        XCTAssertEqual(try append([7, 8])?.blockSeqs, [7, 8])
    }

    func testFailedPrefixRemainsRetryableAndLaterDoneIsNotLost() throws {
        try done(7)
        try ASRJobStore.fail(sessionID: 1, blockSeq: 7, error: "报文空", now: stamp, in: db)
        try done(8)
        XCTAssertEqual(try append([7, 8])?.blockSeqs, [])
        XCTAssertEqual(freezes, 0, "失败不能提前冻成不可修补的 gap")
        try db.write { try $0.execute(sql: "INSERT INTO tasks(kind,session_id,state,priority,created_at) VALUES('transcribe',1,'queued',0,?)", arguments: [stamp]) }
        let retry = try ProcessingOrchestrator.retrySession(1, now: stamp, in: db)
        XCTAssertEqual(retry.resubmittedBlocks, 1)
        XCTAssertNil(try db.read { try ASRJobStore.fetch($0, sessionID: 1, blockSeq: 7) })
        XCTAssertEqual(try db.read { try ASRJobStore.fetch($0, sessionID: 1, blockSeq: 8)?.state }, .done)
        try done(7)
        XCTAssertEqual(try append([7, 8])?.blockSeqs, [7, 8])
        XCTAssertEqual(freezes, 2)
    }

    func testCrashAfterFreezeBeforeCursorRecoversWithoutSecondFreeze() throws {
        try done(7)
        try db.write { try $0.execute(sql: "INSERT INTO stream_sessions(session_id, created_at) VALUES(1, ?)", arguments: [stamp]) }
        _ = try TranscriptFreeze.freeze(sessionID: 1, asrModel: "fake", part: 1,
            blocks: [BlockTranscript(blockSeq: 7, offsetMs: 0, keptIntervals: [KeptInterval(startMs: 0, endMs: 3000)],
                                     lines: [ASRLine(startMs: 0, endMs: 1000, text: "崩溃前保存")])], now: stamp, in: db)
        XCTAssertEqual(try append([7])?.blockSeqs, [7])
        XCTAssertEqual(freezes, 0)
    }

    func testOrphanPartWithAnotherBlockIdentityCannotBeReused() throws {
        try done(7); try done(8)
        try db.write { try $0.execute(sql: "INSERT INTO stream_sessions(session_id, created_at) VALUES(1, ?)", arguments: [stamp]) }
        _ = try TranscriptFreeze.freeze(sessionID: 1, asrModel: "fake", part: 1,
            blocks: [BlockTranscript(blockSeq: 8, offsetMs: 0, keptIntervals: [KeptInterval(startMs: 0, endMs: 3000)],
                lines: [ASRLine(startMs: 0, endMs: 1000, text: "错块的旧产物")])], now: stamp, in: db)
        XCTAssertThrowsError(try append([7, 8]))
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM stream_blocks") }, 0)
    }

    func testRemovalBetweenEligibilityAndFreezeRollsBackNewRawText() throws {
        try done(7)
        XCTAssertThrowsError(try ContinuousIngestion.append(sessionID: 1, blocks: [block(7)],
            jobs: ASRJobStore.all(sessionID: 1, in: db), skipped: [], now: stamp,
            freezeBlock: { block, part, record in
                try self.db.write { d in try d.execute(sql: "UPDATE sessions SET removed_at = ? WHERE id = 1", arguments: [self.stamp]) }
                return try TranscriptFreeze.freeze(sessionID: 1, asrModel: "fake", part: part,
                    blocks: [BlockTranscript(blockSeq: block.blockSeq, offsetMs: 0, keptIntervals: [KeptInterval(startMs: 0, endMs: 1000)],
                        lines: [ASRLine(startMs: 0, endMs: 1000, text: "不能补回的原文")])], now: self.stamp, onFrozen: record, in: self.db)
            }, in: db))
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM transcript_lines") }, 0)
    }

    func testQueueFailureRollsBackFreezeAndCursorTogether() throws {
        try done(7)
        try db.write { try $0.execute(sql: "CREATE TRIGGER reject_extract BEFORE INSERT ON tasks BEGIN SELECT RAISE(ABORT, 'queue failpoint'); END") }
        XCTAssertThrowsError(try append([7]))
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM stream_blocks") }, 0)
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM transcripts") }, 0)
        try db.write { try $0.execute(sql: "DROP TRIGGER reject_extract") }
        XCTAssertEqual(try append([7])?.blockSeqs, [7])
        XCTAssertEqual(freezes, 2)
    }

    func testLegacyClosedSessionAndRemovedSessionCannotEnterStream() throws {
        try done(7)
        try db.write { try $0.execute(sql: "UPDATE sessions SET status = 'closed'") }
        XCTAssertNil(try append([7]))
        try db.write { try $0.execute(sql: "UPDATE sessions SET status = 'recording', removed_at = ?", arguments: [stamp]) }
        XCTAssertNil(try append([7]))
        XCTAssertEqual(freezes, 0)
    }

    func testNewVersionDuringOpenStreamStopsInsteadOfMixingVersions() throws {
        try done(7); _ = try append([7])
        _ = try TranscriptFreeze.freeze(sessionID: 1, asrModel: "fake", version: 2,
            blocks: [BlockTranscript(blockSeq: 7, offsetMs: 0, keptIntervals: [KeptInterval(startMs: 0, endMs: 3000)],
                                     lines: [ASRLine(startMs: 0, endMs: 1000, text: "新版本")])], now: stamp, in: db)
        XCTAssertThrowsError(try append([7]))
    }

    func testKnownASRBlockMissingFromLedgerCannotBeSilentlyDropped() throws {
        try done(7); _ = try append([7])
        try done(8)
        XCTAssertThrowsError(try append([7]))
    }

    func testRenumberedBlockIDsDoNotDetermineSemanticOrder() throws {
        try done(9); try done(7)
        let blocks = [PendingBlock(blockSeq: 9, fileURL: URL(fileURLWithPath: "/tmp/9.m4a"), seconds: 300, offsetMs: 0, durationMs: 300_000),
                      PendingBlock(blockSeq: 7, fileURL: URL(fileURLWithPath: "/tmp/7.m4a"), seconds: 300, offsetMs: 300_000, durationMs: 300_000)]
        var order: [Int] = []
        _ = try ContinuousIngestion.append(sessionID: 1, blocks: blocks,
            jobs: ASRJobStore.all(sessionID: 1, in: db), skipped: [], now: stamp,
            freezeBlock: { block, part, record in
                order.append(block.blockSeq)
                return try TranscriptFreeze.freeze(sessionID: 1, asrModel: "fake", part: part,
                    blocks: [BlockTranscript(blockSeq: block.blockSeq, offsetMs: block.offsetMs,
                        keptIntervals: [KeptInterval(startMs: 0, endMs: 3000)],
                        lines: [ASRLine(startMs: 0, endMs: 1000, text: "编号\(block.blockSeq)")])], now: self.stamp, onFrozen: record, in: self.db)
            }, in: db)
        XCTAssertEqual(order, [9, 7])
        XCTAssertEqual(try db.read { try Int.fetchAll($0, sql: "SELECT b.block_seq FROM stream_blocks b JOIN transcripts t ON t.id=b.transcript_id ORDER BY t.part") }, [9, 7])
    }

    func testContinuationStaysInSameMatterAndRejectsForeignOrFutureIdentity() throws {
        try done(7); try done(8); _ = try append([7, 8])
        let tids = try db.read { try SessionDetailProjection.activeTranscripts($0, sessionID: 1) }
        func payload(_ tid: Int64, prior: Int64? = nil) throws -> [String: Any] {
            let line = try db.read { try Int.fetchOne($0, sql: "SELECT line_id FROM transcript_lines WHERE transcript_id = ?", arguments: [tid])! }
            var event: [String: Any] = ["title": "项目规划", "summary": "新进展", "line_from": line, "line_to": line]
            if let prior { event["continuation_id"] = prior }
            return ["one_liner": "项目继续", "events": [event]]
        }
        _ = try ExtractionStore.store(payload(tids[0]), transcriptID: tids[0], now: stamp, in: db)
        let first = try db.read { try Int64.fetchOne($0, sql: "SELECT id FROM summary_events")! }
        XCTAssertThrowsError(try ExtractionStore.store(payload(tids[1], prior: 999), transcriptID: tids[1], now: stamp, in: db))
        _ = try ExtractionStore.store(payload(tids[1], prior: first), transcriptID: tids[1], now: stamp, in: db)
        let second = try db.read { try Int64.fetchOne($0, sql: "SELECT MAX(id) FROM summary_events")! }
        XCTAssertEqual(try db.read { try StreamContinuity.root(of: second, in: $0) }, first)
        let ctx = try db.read { try StreamContinuity.context(tids[1], in: $0) }
        XCTAssertEqual(ctx["event_id"] as? Int64, first)
        XCTAssertEqual(ctx["t_end_sec"] as? Double, 3)
    }
}
