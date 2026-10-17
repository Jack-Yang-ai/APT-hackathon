import XCTest
import GRDB
@testable import GrowthApp

/// 「这一场为什么还没有纪要」(M1-14b)。
///
/// 🔴 **验收原文:三种不同原因的失败,界面上给出三种不同的说明。**
/// 所以这组测试的重点不是「有没有话说」,而是**那三句话彼此不同**,
/// 而且每一句都指向一个用户真的做得到的动作。
final class SessionStallTextTests: XCTestCase {

    /// 三种原因 → 三种说明。**互不相同**,而且都带得走原因原文。
    func testThreeReasonsGiveThreeDifferentExplanations() {
        let texts = [
            SessionStallText.explain(("dead", "云代理还没配")),
            SessionStallText.explain(("dead", "这一场一块音频都没有")),
            SessionStallText.explain(("retrying", "轮询 r-7:断网了")),
        ]
        XCTAssertEqual(Set(texts).count, 3, "三种原因说出了同一句话:\(texts)")
        XCTAssertTrue(texts[0].contains("云代理还没配"))
        XCTAssertTrue(texts[1].contains("一块音频都没有"))
        XCTAssertTrue(texts[2].contains("断网了"))
    }

    /// 「不会自己好」的那档要说清楚它不会自己好,并给出出口 ——
    /// 不说的话用户会一直等(和 M1-12d 卡面上那句「重试中」是同一个病)。
    func testADeadSessionSaysItWillNotRecoverAndPointsToTheWayOut() {
        let t = SessionStallText.explain(("dead", "这一场一块音频都没有"))
        XCTAssertTrue(t.contains("不会自己好"), t)
        XCTAssertTrue(t.contains("再试一次"), "没有告诉用户能做什么:\(t)")
    }

    /// 还在路上的那档**不许**说成终态 —— 说了用户会去动一件正在正常进行的事。
    func testARetryingSessionIsNotDescribedAsATerminalFailure() {
        let t = SessionStallText.explain(("retrying", "断网了"))
        XCTAssertFalse(t.contains("不会自己好"), t)
        XCTAssertTrue(t.contains("还在处理"), t)
    }

    /// 没记原因**要说出来**,不许拿一句体面话盖过去 ——
    /// 「失败了但不知道为什么」是个缺陷,而体面话会让它永远不被发现(§3.2)。
    func testAMissingReasonIsReportedAsADefectNotSmoothedOver() {
        let t = SessionStallText.explain(("dead", nil))
        XCTAssertTrue(t.contains("缺陷"), t)
    }

    /// 压根没有任务行(比如导入的历史场次)不是失败 —— 别说得像出了事。
    func testNoTaskRowIsNotAFailure() {
        let t = SessionStallText.explain(nil)
        XCTAssertFalse(t.contains("没能"), t)
        XCTAssertFalse(t.contains("缺陷"), t)
    }

    // MARK: - 取的是哪一行

    /// 一场可能有上传/转写/抽取三个任务。用户问的是「它现在卡在哪」,
    /// 所以取**最新那一行**;历史失败在 `processing_events` 里。
    func testLastWordTakesTheNewestTaskOfTheSession() throws {
        let db = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(db)
        try db.write { d in
            try d.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, '2026-08-17T10:00:00+08:00', '2026-08-17', 'recording', 'closed')
                """)
            try d.execute(sql: """
                INSERT INTO tasks (kind, session_id, state, priority, created_at, attempts, last_error)
                VALUES ('upload_audio', 1, 'done', 0, 'x', 0, '早先那次的原因'),
                       ('transcribe',   1, 'dead', 0, 'x', 3, '这一场一块音频都没有')
                """)
        }
        let w = try XCTUnwrap(TaskQueue.lastWord(sessionID: 1, in: db))
        XCTAssertEqual(w.state, "dead")
        XCTAssertEqual(w.reason, "这一场一块音频都没有")
    }
}
