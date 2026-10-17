import XCTest
import GRDB
@testable import GrowthApp

final class AudioExportRecoveryTests: XCTestCase {
    private let now = "2026-10-15T09:00:00Z"

    func testEmptyTrimExportsOriginalSamplesAndWholeTimeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        var bytes = WavExport.header(samples: 16000)
        for i in 0..<16000 {
            var sample = Int16(i % 100).littleEndian
            withUnsafeBytes(of: &sample) { bytes.append(contentsOf: $0) }
        }
        try bytes.write(to: source)
        let empty = SpeechTrim.Plan(intervals: [], ratio: 0, fellBack: false)
        let plan = BackgroundUploadCenter.exportPlan(empty)
        XCTAssertNil(plan, "整块送检必须同步使用整块时间还原，不能落 []")
        let output = try await WavExport.convert(source, to: root.appendingPathComponent("out.wav"), keeping: plan?.intervals)
        XCTAssertEqual(try Data(contentsOf: output).count, bytes.count)
        XCTAssertEqual(try Data(contentsOf: source), bytes, "原音频不能被裁改")
    }

    func testNonemptyApprovedTrimRemainsUnchanged() {
        let plan = SpeechTrim.Plan(intervals: [KeptInterval(startMs: 1000, endMs: 2000)], ratio: 0.2, fellBack: false)
        XCTAssertEqual(BackgroundUploadCenter.exportPlan(plan), plan)
        XCTAssertNil(BackgroundUploadCenter.exportPlan(nil))
    }

    func testTransientExportErrorsNeverBecomePermanentGaps() {
        XCTAssertFalse(BackgroundUploadCenter.isPermanentExportFailure(CancellationError(), untrimmed: true))
        XCTAssertFalse(BackgroundUploadCenter.isPermanentExportFailure(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), untrimmed: true))
        XCTAssertFalse(BackgroundUploadCenter.isPermanentExportFailure(AudioImport.Failure.unreadable("temporarily unavailable"), untrimmed: true))
        let empty = WavExport.Failure.emptyAudio(URL(fileURLWithPath: "/unused"))
        XCTAssertFalse(BackgroundUploadCenter.isPermanentExportFailure(empty, untrimmed: false))
        XCTAssertTrue(BackgroundUploadCenter.isPermanentExportFailure(empty, untrimmed: true))
        XCTAssertTrue(BackgroundUploadCenter.isPermanentExportFailure(AudioImport.Failure.noAudioTrack, untrimmed: true))
    }

    func testPermanentClassificationUsesExistingStateAndSentinelTogether() {
        let permanent = UploadJobStore.Job(sessionID: 1, blockSeq: 0, key: "x", state: "failed", httpStatus: -1, lastError: "bad", updatedAt: now, keptJSON: nil)
        XCTAssertTrue(permanent.isPermanentFailure)
        let temporary = UploadJobStore.Job(sessionID: 1, blockSeq: 0, key: "x", state: "failed", httpStatus: 500, lastError: "network", updatedAt: now, keptJSON: nil)
        XCTAssertFalse(temporary.isPermanentFailure)
        let done = UploadJobStore.Job(sessionID: 1, blockSeq: 0, key: "x", state: "done", httpStatus: -1, lastError: nil, updatedAt: now, keptJSON: nil)
        XCTAssertFalse(done.isPermanentFailure)
    }

    func testV55RecoveryArchivesOnlyEligibleBlocksAndPreservesPaidASR() throws {
        let db = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(db, upTo: "v55_recording_memory_outbox")
        try db.write { d in
            for id in 1...9 {
                try d.execute(sql: "INSERT INTO sessions(id,started_at,day,source,status,removed_at) VALUES(?,?,'2026-10-14',?,'closed',?)",
                    arguments: [id, "2026-10-14T0\(id):00:00Z", id == 4 ? "import" : "watch", id == 5 ? now : nil])
                try d.execute(sql: "INSERT INTO upload_jobs(session_id,block_seq,r2_key,state,http_status,last_error,created_at,updated_at,kept_json) VALUES(?,0,?,'failed',-1,?,?,?,?)",
                    arguments: [id, "audio/\(id)", id == 9 ? "音频转 wav 失败:这个文件读不出来:AVFoundationErrorDomain Code=-11847 Operation Interrupted" : (id == 6 ? "音频转 wav 失败:其他错误" : "音频转 wav 失败:block-0000.m4a 解出来一个采样点都没有"), now, now, "[]"])
                for kind in ["upload_audio", "transcribe"] {
                    try d.execute(sql: "INSERT INTO tasks(kind,session_id,state,attempts,priority,created_at) VALUES(?,?,'done',2,0,?)", arguments: [kind, id, now])
                }
            }
            for (session, block) in [(1, 1), (2, 0)] {
                try d.execute(sql: "INSERT INTO asr_jobs(session_id,block_seq,remote_id,state,result_json,created_at,updated_at) VALUES(?,?,'paid','done','{" + "\"result\":[]" + "}',?,?)", arguments: [session, block, now, now])
            }
            for session in [3, 7, 8] {
                try d.execute(sql: "INSERT INTO transcripts(id,session_id,version,part,asr_model,status,created_at) VALUES(?,?,?,1,'test','partial',?)", arguments: [session, session, session == 8 ? 2 : 1, now])
            }
            for session in [7, 8] {
                try d.execute(sql: "INSERT INTO stream_sessions(session_id,created_at) VALUES(?,?)", arguments: [session, now])
            }
            try d.execute(sql: "INSERT INTO stream_blocks(session_id,block_seq,transcript_id,offset_ms,duration_ms) VALUES(7,0,7,0,1000)")
        }
        try AppDatabase.makeMigrator().migrate(db)
        try db.read { d in
            XCTAssertEqual(try Int.fetchAll(d, sql: "SELECT session_id FROM upload_empty_export_recovery ORDER BY session_id"), [1, 9])
            XCTAssertEqual(try String.fetchOne(d, sql: "SELECT kept_json FROM upload_empty_export_recovery"), "[]")
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM asr_jobs WHERE state='done' AND remote_id='paid'"), 2)
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM upload_jobs"), 7)
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM tasks WHERE state='queued' AND session_id=1 AND attempts=2"), 2)
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM tasks WHERE state='done' AND session_id NOT IN (1,9)"), 14)
        }
        // 重开不会再次删除新的失败或洗掉重试账。
        _ = try UploadJobStore.claim(sessionID: 1, blockSeq: 0, key: "audio/1", now: now, in: db)
        try UploadJobStore.failPermanently(sessionID: 1, blockSeq: 0, error: "still empty", now: now, in: db)
        try AppDatabase.makeMigrator().migrate(db)
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM upload_jobs WHERE session_id=1") }, 1)
    }
}
