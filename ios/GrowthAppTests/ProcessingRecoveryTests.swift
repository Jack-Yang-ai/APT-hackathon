import XCTest
import GRDB
@testable import GrowthApp

final class ProcessingRecoveryTests: XCTestCase {
    private var db: DatabaseQueue!
    private let stamp = "2026-10-15T10:00:00+08:00"

    override func setUpWithError() throws {
        db = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(db)
        try db.write { d in
            for id in 1...7 {
                let day = "2026-10-0\(id)"
                try d.execute(sql: "INSERT INTO sessions(id,started_at,day,source,status) VALUES(?,?,?,'watch','closed')",
                              arguments: [id, day + "T10:00:00+08:00", day])
            }
        }
    }

    func testHistoricalFailuresAndBackoffAreDiscoverableWithoutSemanticEvents() throws {
        try db.write { d in
            for (id, state, priority, next) in [(1,"dead",0,Optional<String>.none),
                                               (2,"degraded",0,nil), (3,"retrying",0,Optional(stamp)),
                                               (4,"done",0,nil), (5,"queued",0,nil),
                                               (6,"retrying",1,Optional(stamp)), (7,"retrying",0,nil)] {
                try d.execute(sql: "INSERT INTO tasks(kind,session_id,state,priority,next_retry_at,last_error,created_at) VALUES('transcribe',?,?,?,?,?,?)",
                              arguments: [id,state,priority,next,"失败原因 \(id)",stamp])
            }
        }
        let rows = try ProcessingOrchestrator.retryableSessions(in: db)
        XCTAssertEqual(rows.map(\.id), [3,2,1], "不受今天、事件产物或最近处理条数限制")
        XCTAssertEqual(rows.first?.issue, "失败原因 3")
        let revival = try ProcessingOrchestrator.retrySession(1, now: stamp, in: db)
        XCTAssertEqual(revival.tasks, 1)
        XCTAssertEqual(try ProcessingOrchestrator.retryableSessions(in: db).map(\.id), [3,2])
    }

    func testRemovedSessionCannotBeRetriedFromAnAlreadyOpenScreen() throws {
        try db.write { d in
            try d.execute(sql: "INSERT INTO tasks(kind,session_id,state,priority,created_at) VALUES('extract',1,'dead',0,?)", arguments: [stamp])
        }
        XCTAssertEqual(try ProcessingOrchestrator.retryableSessions(in: db).map(\.id), [1])
        try db.write { try $0.execute(sql: "UPDATE sessions SET removed_at=? WHERE id=1", arguments: [stamp]) }
        XCTAssertTrue(try ProcessingOrchestrator.retryableSessions(in: db).isEmpty)
        XCTAssertThrowsError(try ProcessingOrchestrator.retrySession(1, now: stamp, in: db))
        XCTAssertEqual(try db.read { try String.fetchOne($0, sql: "SELECT state FROM tasks WHERE session_id=1") }, "dead")
    }

    func testFailedStreamingPieceCanBeRetriedWhileItsTaskIsQueued() throws {
        try db.write { d in
            try d.execute(sql: "UPDATE sessions SET status='open' WHERE id=1")
            try d.execute(sql: "INSERT INTO stream_sessions(session_id,created_at) VALUES(1,?)", arguments: [stamp])
            try d.execute(sql: "INSERT INTO tasks(kind,session_id,state,priority,created_at) VALUES('transcribe',1,'queued',0,?)", arguments: [stamp])
            try d.execute(sql: "INSERT INTO asr_jobs(session_id,block_seq,remote_id,state,created_at,updated_at) VALUES(1,0,'failed-task','failed',?,?)", arguments: [stamp,stamp])
        }
        XCTAssertEqual(try ProcessingOrchestrator.retryableSessions(in: db).map(\.id), [1])
        let revival = try ProcessingOrchestrator.retrySession(1, now: stamp, in: db)
        XCTAssertEqual(revival.resubmittedBlocks, 1)
        XCTAssertTrue(try ProcessingOrchestrator.retryableSessions(in: db).isEmpty)
        XCTAssertEqual(try db.read { try String.fetchOne($0, sql: "SELECT status FROM sessions WHERE id=1") }, "open")
    }

    func testReadingFailureIsThrownInsteadOfClaimingNoFailedRecordings() throws {
        try db.write { try $0.execute(sql: "ALTER TABLE tasks RENAME TO unavailable_tasks") }
        XCTAssertThrowsError(try ProcessingOrchestrator.retryableSessions(in: db))
    }

    func testLegacyPartialCannotPayAgainWithoutAContentPreservingRecovery() throws {
        try db.write { d in
            try d.execute(sql: "INSERT INTO tasks(kind,session_id,state,priority,created_at) VALUES('transcribe',1,'degraded',0,?)", arguments: [stamp])
            try d.execute(sql: "INSERT INTO transcripts(id,session_id,version,part,asr_model,status,created_at) VALUES(1,1,1,1,'legacy','partial',?)", arguments: [stamp])
            try d.execute(sql: "INSERT INTO transcript_lines(line_id,transcript_id,seq,t_start_ms,t_end_ms,text,char_offset) VALUES(10,1,0,0,1000,'已经核对过的原话',0)")
            try d.execute(sql: "INSERT INTO asr_jobs(session_id,block_seq,remote_id,state,created_at,updated_at) VALUES(1,1,'failed-task','failed',?,?)", arguments: [stamp,stamp])
        }
        let row = try XCTUnwrap(ProcessingOrchestrator.retryableSessions(in: db).first)
        XCTAssertNotNil(row.blockedReason)
        // freeze 复用 v1/part1；不能因另有较新的 frozen 就放行旧 partial。
        try db.write { try $0.execute(sql: "INSERT INTO transcripts(id,session_id,version,part,asr_model,status,created_at) VALUES(2,1,2,1,'later','frozen',?)", arguments: [stamp]) }
        XCTAssertNotNil(try ProcessingOrchestrator.retryableSessions(in: db).first?.blockedReason)
        XCTAssertThrowsError(try ProcessingOrchestrator.retrySession(row.id, now: stamp, in: db))
        try db.read { d in
            XCTAssertEqual(try String.fetchOne(d, sql: "SELECT state FROM tasks WHERE session_id=1"), "degraded")
            XCTAssertEqual(try String.fetchOne(d, sql: "SELECT state FROM asr_jobs WHERE session_id=1"), "failed")
            XCTAssertEqual(try String.fetchOne(d, sql: "SELECT text FROM transcript_lines WHERE line_id=10"), "已经核对过的原话")
        }
    }

    func testRevisedStreamingVersionCannotResubmitIntoTheFirstVersionPipeline() throws {
        try db.write { d in
            try d.execute(sql: "INSERT INTO stream_sessions(session_id,created_at) VALUES(1,?)", arguments: [stamp])
            try d.execute(sql: "INSERT INTO tasks(kind,session_id,state,priority,created_at) VALUES('transcribe',1,'degraded',0,?)", arguments: [stamp])
            try d.execute(sql: "INSERT INTO transcripts(id,session_id,version,part,asr_model,status,created_at) VALUES(1,1,2,1,'revised','frozen',?)", arguments: [stamp])
            try d.execute(sql: "INSERT INTO asr_jobs(session_id,block_seq,remote_id,state,created_at,updated_at) VALUES(1,1,'failed-task','failed',?,?)", arguments: [stamp,stamp])
        }
        XCTAssertNotNil(try ProcessingOrchestrator.retryableSessions(in: db).first?.blockedReason)
        XCTAssertThrowsError(try ProcessingOrchestrator.retrySession(1, now: stamp, in: db))
        XCTAssertEqual(try db.read { try String.fetchOne($0, sql: "SELECT state FROM asr_jobs WHERE session_id=1") }, "failed")
    }

    func testRevisedVersionsCanRetryOnlyDownstreamFailures() throws {
        for (index, kind) in [ProcessingOrchestrator.Kind.extract, ProcessingOrchestrator.Kind.progress, ProcessingOrchestrator.Kind.voiceprint,
                              ProcessingOrchestrator.Kind.extract, ProcessingOrchestrator.Kind.progress, ProcessingOrchestrator.Kind.voiceprint].enumerated() {
            let id = index + 1
            try db.write { d in
                if id <= 3 { try d.execute(sql: "INSERT INTO stream_sessions(session_id,created_at) VALUES(?,?)", arguments: [id,stamp]) }
                try d.execute(sql: "INSERT INTO transcripts(session_id,version,part,asr_model,status,created_at) VALUES(?,2,1,'revised',?,?)", arguments: [id,id <= 3 ? "frozen" : "partial",stamp])
                try d.execute(sql: "INSERT INTO tasks(kind,session_id,state,priority,created_at) VALUES('transcribe',?,'done',0,?)", arguments: [id,stamp])
                try d.execute(sql: "INSERT INTO tasks(kind,session_id,state,priority,created_at) VALUES(?,?,?,0,?)", arguments: [kind,id,id <= 3 ? "dead" : "degraded",stamp])
            }
            XCTAssertNil(try ProcessingOrchestrator.retryableSessions(in: db).first(where: { $0.id == Int64(id) })?.blockedReason)
            let revival = try ProcessingOrchestrator.retrySession(Int64(id), now: stamp, in: db)
            XCTAssertEqual(revival.tasks, 1); XCTAssertEqual(revival.resubmittedBlocks, 0)
            try db.read { d in
                XCTAssertEqual(try String.fetchOne(d, sql: "SELECT state FROM tasks WHERE session_id=? AND kind=?", arguments: [id,kind]), "queued")
                XCTAssertEqual(try String.fetchOne(d, sql: "SELECT state FROM tasks WHERE session_id=? AND kind='transcribe'", arguments: [id]), "done")
                XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT version FROM transcripts WHERE session_id=?", arguments: [id]), 2)
            }
        }
    }

    func testLegacyPartialCanReleaseOnlyDownstreamBackoffWithoutResettingAttempts() throws {
        try db.write { d in
            try d.execute(sql: "INSERT INTO transcripts(session_id,version,part,asr_model,status,created_at) VALUES(1,1,1,'legacy','partial',?)", arguments: [stamp])
            try d.execute(sql: "INSERT INTO tasks(kind,session_id,state,priority,created_at) VALUES('transcribe',1,'done',0,?)", arguments: [stamp])
            try d.execute(sql: "INSERT INTO tasks(kind,session_id,state,priority,attempts,next_retry_at,created_at) VALUES('progress',1,'retrying',0,3,?,?)", arguments: [stamp,stamp])
        }
        XCTAssertNil(try ProcessingOrchestrator.retryableSessions(in: db).first?.blockedReason)
        let revival = try ProcessingOrchestrator.retrySession(1, now: stamp, in: db)
        XCTAssertEqual(revival.released,1); XCTAssertEqual(revival.resubmittedBlocks,0)
        try db.read { d in
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT attempts FROM tasks WHERE kind='progress'"),3)
            XCTAssertNil(try String.fetchOne(d, sql: "SELECT next_retry_at FROM tasks WHERE kind='progress'"))
        }
    }

    func testVersionGuardStillBlocksResumingTranscribeWithoutFailedASRJobs() throws {
        for (index,state) in ["dead","degraded","retrying"].enumerated() {
            let id = index + 1
            try db.write { d in
                try d.execute(sql: "INSERT INTO stream_sessions(session_id,created_at) VALUES(?,?)", arguments: [id,stamp])
                try d.execute(sql: "INSERT INTO transcripts(session_id,version,part,asr_model,status,created_at) VALUES(?,2,1,'revised','frozen',?)", arguments: [id,stamp])
                try d.execute(sql: "INSERT INTO tasks(kind,session_id,state,priority,next_retry_at,created_at) VALUES('transcribe',?,?,0,?,?)", arguments: [id,state,stamp,stamp])
            }
            XCTAssertNotNil(try ProcessingOrchestrator.retryableSessions(in: db).first(where: { $0.id == Int64(id) })?.blockedReason)
            XCTAssertThrowsError(try ProcessingOrchestrator.retrySession(Int64(id), now: stamp, in: db))
            XCTAssertEqual(try db.read { try String.fetchOne($0, sql: "SELECT state FROM tasks WHERE session_id=?", arguments: [id]) },state)
        }
    }

    func testLateFailedASRJobBlocksDownstreamRetryBeforeAnyMutation() throws {
        try db.write { d in
            try d.execute(sql: "INSERT INTO stream_sessions(session_id,created_at) VALUES(1,?)", arguments: [stamp])
            try d.execute(sql: "INSERT INTO transcripts(session_id,version,part,asr_model,status,created_at) VALUES(1,2,1,'revised','frozen',?)", arguments: [stamp])
            try d.execute(sql: "INSERT INTO tasks(kind,session_id,state,priority,created_at) VALUES('transcribe',1,'done',0,?),('extract',1,'dead',0,?)", arguments: [stamp,stamp])
        }
        XCTAssertNil(try ProcessingOrchestrator.retryableSessions(in: db).first?.blockedReason)
        try db.write { try $0.execute(sql: "INSERT INTO asr_jobs(session_id,block_seq,remote_id,state,created_at,updated_at) VALUES(1,1,'late-failure','failed',?,?)", arguments: [stamp,stamp]) }
        XCTAssertNotNil(try ProcessingOrchestrator.retryableSessions(in: db).first?.blockedReason)
        XCTAssertThrowsError(try ProcessingOrchestrator.retrySession(1, now: stamp, in: db))
        XCTAssertEqual(try db.read { try String.fetchOne($0, sql: "SELECT state FROM tasks WHERE kind='extract'") },"dead")
        XCTAssertEqual(try db.read { try String.fetchOne($0, sql: "SELECT state FROM asr_jobs") },"failed")
    }
}
