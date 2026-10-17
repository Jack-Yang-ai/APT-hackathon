import XCTest
import GRDB
@testable import GrowthApp

/// 转写作业的落盘状态(M1-4)。
///
/// 这一层挡的是**重放花两遍钱**。M1-4 的准入条件是「整条链路能从落盘状态恢复」,
/// 而恢复意味着同一段编排会被跑很多遍(App 被杀、后台唤醒、用户重开)。
/// 提交转写没有落盘去重的话,每一次重放都是再花一次钱,
/// 而且会拿到第二个 task_id —— 之后哪个算数没人说得清。
final class ASRJobStoreTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-14T12:00:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, '2026-08-14T10:00:00+08:00', '2026-08-14', 'recording', 'closed')
                """)
        }
    }

    override func tearDownWithError() throws { dbQueue = nil }

    // MARK: - 重放不许再花一次钱

    /// 🔴 **这条是这张表存在的全部理由。**
    /// 同一块提交两次,第二次必须是 no-op,而且拿回**第一次**那个 remote id。
    func testClaimingTwiceDoesNotSubmitAgain() throws {
        let first = try ASRJobStore.claim(sessionID: 1, blockSeq: 0,
                                          remoteID: "task-aaa", now: now, in: dbQueue)
        XCTAssertTrue(first.inserted)

        let second = try ASRJobStore.claim(sessionID: 1, blockSeq: 0,
                                           remoteID: "task-bbb", now: now, in: dbQueue)
        XCTAssertFalse(second.inserted, "重放又提交了一次 —— 这一次是白花的钱")
        XCTAssertEqual(second.job.remoteID, "task-aaa",
                       "拿回的该是第一次那个 id;两个 id 并存时没人说得清哪个算数")

        try dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asr_jobs"), 1)
        }
    }

    /// 不同块各自独立 —— 去重是按「块」不是按「场」。
    func testDifferentBlocksAreIndependent() throws {
        XCTAssertTrue(try ASRJobStore.claim(sessionID: 1, blockSeq: 0,
                                            remoteID: "a", now: now, in: dbQueue).inserted)
        XCTAssertTrue(try ASRJobStore.claim(sessionID: 1, blockSeq: 1,
                                            remoteID: "b", now: now, in: dbQueue).inserted)
        XCTAssertEqual(try ASRJobStore.pending(sessionID: 1, in: dbQueue).count, 2)
    }

    /// ⚠️ **失败之后重放也不许重新提交。**
    ///
    /// 实测约 15% 的场次会落到兜底腿,**而且重试救不了**(是内容特性不是偶发)。
    /// 失败记录留着,重放就是 no-op;要重来必须是显式动作,
    /// 不能靠「记录没了所以又跑了一遍」——那正是悄悄烧钱的形态。
    func testFailedJobIsNotResubmittedOnReplay() throws {
        _ = try ASRJobStore.claim(sessionID: 1, blockSeq: 0,
                                  remoteID: "task-aaa", now: now, in: dbQueue)
        try ASRJobStore.fail(sessionID: 1, blockSeq: 0, error: "audio_download",
                             now: now, in: dbQueue)

        let replay = try ASRJobStore.claim(sessionID: 1, blockSeq: 0,
                                           remoteID: "task-ccc", now: now, in: dbQueue)
        XCTAssertFalse(replay.inserted, "失败的块被重放时又提交了一次")
        XCTAssertEqual(replay.job.state, .failed)
        XCTAssertEqual(replay.job.lastError, "audio_download",
                       "失败原因被抹了 —— 事后查不出它为什么没成")
    }

    // MARK: - 结果

    /// 存的是**原始报文**。解析器改了要能拿回原文重跑,而重新提交是要花钱的。
    func testFinishKeepsTheRawPayload() throws {
        _ = try ASRJobStore.claim(sessionID: 1, blockSeq: 0,
                                  remoteID: "task-aaa", now: now, in: dbQueue)
        let raw = #"{"status":"SUCCESS","utterances":[{"text":"你好","start":0}]}"#
        try ASRJobStore.finish(sessionID: 1, blockSeq: 0, resultJSON: raw,
                               now: now, in: dbQueue)

        let done = try ASRJobStore.finished(sessionID: 1, in: dbQueue)
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done[0].resultJSON, raw, "原始报文没原样存下来")
        XCTAssertEqual(done[0].state, .done)
        XCTAssertTrue(try ASRJobStore.pending(sessionID: 1, in: dbQueue).isEmpty)
    }

    /// 完成之后重放仍是 no-op —— 不会把一块已经转好的再提交一遍。
    func testFinishedJobIsNotResubmitted() throws {
        _ = try ASRJobStore.claim(sessionID: 1, blockSeq: 0,
                                  remoteID: "task-aaa", now: now, in: dbQueue)
        try ASRJobStore.finish(sessionID: 1, blockSeq: 0, resultJSON: "{}",
                               now: now, in: dbQueue)
        let replay = try ASRJobStore.claim(sessionID: 1, blockSeq: 0,
                                           remoteID: "task-zzz", now: now, in: dbQueue)
        XCTAssertFalse(replay.inserted)
        XCTAssertEqual(replay.job.state, .done)
    }

    /// 已完成的按**块序**出,不按写入顺序 —— 拼接靠这个序,乱了整场时间轴就错。
    func testFinishedComesBackInBlockOrder() throws {
        for seq in [2, 0, 1] {
            _ = try ASRJobStore.claim(sessionID: 1, blockSeq: seq,
                                      remoteID: "t\(seq)", now: now, in: dbQueue)
            try ASRJobStore.finish(sessionID: 1, blockSeq: seq, resultJSON: "{}",
                                   now: now, in: dbQueue)
        }
        XCTAssertEqual(try ASRJobStore.finished(sessionID: 1, in: dbQueue).map(\.blockSeq),
                       [0, 1, 2])
    }

    /// 表的闭集约束是活的 —— 写一个不在闭集里的状态该被 DB 挡下,
    /// 而不是靠调用方自觉。
    func testStateIsAClosedSetAtTheDatabaseLevel() throws {
        _ = try ASRJobStore.claim(sessionID: 1, blockSeq: 0,
                                  remoteID: "a", now: now, in: dbQueue)
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "UPDATE asr_jobs SET state = 'whatever' WHERE block_seq = 0")
        }, "state 的 CHECK 没生效 —— 状态机可以被写进任意字符串")
    }
}
