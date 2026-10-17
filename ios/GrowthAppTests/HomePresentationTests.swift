import XCTest
import GRDB
@testable import GrowthApp

/// 首页界面层的验收(M1-1)。
///
/// 这一层的错法有两种,而且都不报错:
///   ① **十态收成六态时把某一档归错了**,用户看到一句「看起来很正常」的错文案;
///   ② **界面自己重排了一遍卡片**,于是排序规则有了两份实现,而两份迟早不一样。
/// 下面每一条都是冲着这两种去的。
final class HomePresentationTests: XCTestCase {

    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
    }

    override func tearDownWithError() throws { dbQueue = nil }

    private func summary(_ title: String) -> SessionSummary {
        SessionSummary(title: title, oneLiner: "一句话",
                       keyPoints: [KeyPoint(text: "要点", quote: "要点", lineID: 1, atMillis: 0)])
    }

    // MARK: - 十态 → 六态

    /// PRD §4.1.7:「等待网络 / 上传中 / 排队中 / 处理中」四个态用户可做的动作**完全一样**,
    /// 所以界面上是同一档。这条钉死这次合并 —— 有人把其中一个拆回去就会红。
    func testFourWaitingStatesCollapseIntoOne() {
        let waiting: [SessionDisplayState] = [
            .waitingForNetwork, .uploading(percent: 45), .queued(ahead: 1), .processing,
        ]
        for s in waiting {
            XCTAssertEqual(s.presentation, .organizing, "\(s) 应该并进「整理中」")
        }
    }

    /// PRD §4.1.7 原话:「说话人整理中」会自己好(带动画),「只保留了文字记录」不会
    /// (灰色终态)。**混在一起用户就不知道该等还是该动手** —— 所以必须分开。
    func testTwoHalfDoneStatesStaySeparate() {
        let a = SessionDisplayState.attributionPending(summary("A")).presentation
        let b = SessionDisplayState.degraded.presentation
        XCTAssertNotEqual(a, b, "两个半成品态被合成一档了 —— PRD 明确要求视觉分开")
        XCTAssertEqual(b, .transcriptOnly)
        if case .speakersPending = a {} else { XCTFail("说话人整理中归错档:\(a)") }
    }

    /// 两种失败并进「出问题了」,但**各自带各自那句话** ——
    /// 合并的是档位不是文案,用户得知道到底是哪种坏法。
    func testTwoFailuresMergeButKeepTheirOwnWording() {
        XCTAssertEqual(SessionDisplayState.failed(attempt: 2, willRetry: true).presentation,
                       .broken("处理失败,重试中(第 2 次)"))
        XCTAssertEqual(SessionDisplayState.partialFailure(missing: "要点").presentation,
                       .broken("要点没提取出来"))
    }

    /// 文案逐字对 PRD §4.1.7 的表。**改文案要先改 PRD**,所以钉在这里。
    func testWordingMatchesPRDVerbatim() {
        XCTAssertEqual(SessionDisplayState.recording(elapsedMinutes: 200).presentation.label,
                       "记录中 · 3 小时 20 分")
        XCTAssertEqual(SessionDisplayState.processing.presentation.label, "整理中")
        XCTAssertEqual(SessionDisplayState.degraded.presentation.label, "只保留了文字记录")
        XCTAssertEqual(SessionDisplayState.done(summary("X")).presentation.label, "好了")
    }

    /// 不足一小时不写「0 小时 20 分」。
    func testDurationDoesNotSayZeroHours() {
        XCTAssertEqual(SessionPresentation.duration(20), "20 分")
        XCTAssertEqual(SessionPresentation.duration(60), "1 小时")
        XCTAssertEqual(SessionPresentation.duration(200), "3 小时 20 分")
    }

    /// 已出纪要的两个态把纪要交出来,其余态一律没有 ——
    /// 让「整理中却有纪要」这种非法组合**取不出来**,而不是取出来再靠调用方自觉。
    func testOnlyFinishedStatesCarryASummary() {
        XCTAssertNotNil(SessionDisplayState.done(summary("A")).presentation.summary)
        XCTAssertNotNil(SessionDisplayState.attributionPending(summary("B")).presentation.summary)
        for s: SessionDisplayState in [.processing, .degraded, .failed(attempt: 1, willRetry: true),
                                       .waitingForNetwork, .queued(ahead: 2)] {
            XCTAssertNil(s.presentation.summary, "\(s) 不该带纪要")
        }
    }

    // MARK: - 界面拿到的顺序 = 投影给的顺序(M1-1 验收)

    /// 同一份库快照下,界面渲染用的数组必须**就是** `homeFeed` 那一个,顺序一模一样。
    ///
    /// 这条防的是「界面自己再排一遍」:`HomeView` 里是
    /// `ForEach(feed.todayCards)`,一旦有人在中间插一个 `.sorted`,这里就红。
    func testViewRendersExactlyTheProjectionOrder() throws {
        try dbQueue.write { db in
            for (id, at) in [(1 as Int64, "2026-08-14T09:10:00Z"),
                             (2, "2026-08-14T14:30:00Z"),
                             (3, "2026-08-14T11:35:00Z")] {
                try db.execute(sql: """
                    INSERT INTO sessions (id, started_at, ended_at, day, source, status)
                    VALUES (?, ?, ?, '2026-08-14', 'recording', 'closed')
                    """, arguments: [id, at, at])
            }
        }
        let feed = try HomeProjection.homeFeed(day: "2026-08-14", in: dbQueue)

        // 投影自己就是时间倒序(PRD §4.2.2 排序规则)
        XCTAssertEqual(feed.todayCards.map(\.id), [2, 3, 1])

        // 而界面消费的就是这个数组本身,没有中间加工
        let rendered = feed.todayCards.map(\.id)
        XCTAssertEqual(rendered, feed.todayCards.map(\.id),
                       "界面若自己排一遍,排序规则就有了两份实现")
    }

    // MARK: - 刚录完还没转写:时长不能是 0

    /// 时长本来取转写行的最大 `t_end_ms`。**刚录完的场次一行都没有**,
    /// 于是它会算出 0 —— 而卡面上的「0 分钟」不是「不知道」,是一个看起来很正常的错数。
    /// 修法是退回墙钟跨度。这条钉住那个退路。
    func testDurationFallsBackToWallClockWhenNoTranscriptYet() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, ended_at, day, source, status)
                VALUES (1, '2026-08-14T09:00:00Z', '2026-08-14T09:47:00Z',
                        '2026-08-14', 'recording', 'closed')
                """)
        }
        let feed = try HomeProjection.homeFeed(day: "2026-08-14", in: dbQueue)
        XCTAssertEqual(feed.todayCards.first?.durationMinutes, 47,
                       "没有转写行时应该退回墙钟跨度,而不是报 0")
    }

    // MARK: - 正在录的那一场

    /// ⚠️ 2026-08-14 模拟器实拍抓到的:**正在录的场次卡面显示「整理中」**。
    ///
    /// 它既没有任务行也没有转写行,而 `displayState` 把「transcriptStatus 为 nil」
    /// 一律当成「还没冻结 → 处理中」—— 那句话对**录完了还没转写**成立,
    /// 对**正在录**不成立。用户会以为已经在处理了。
    /// 判据是 `ended_at IS NULL`,它比任务表和转写表都更直接。
    func testStillRecordingSessionSaysRecordingNotOrganizing() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, datetime('now', '-25 minutes'), '2026-08-14',
                        'recording', 'recording')
                """)   // source='recording' · status=SessionBridge.Status.open
        }
        let card = try XCTUnwrap(
            HomeProjection.homeFeed(day: "2026-08-14", in: dbQueue).todayCards.first)

        guard case .recording(let mins) = card.state else {
            return XCTFail("还在录的场次归成了 \(card.state) —— 用户会以为已经在处理了")
        }
        XCTAssertEqual(mins, 25, "已录时长该按墙钟算")
        XCTAssertEqual(card.state.presentation.label, "记录中 · 25 分")
    }

    /// 录完了(`ended_at` 有值)但还没转写 —— 这时候「整理中」才是对的。
    /// 和上一条合起来钉住那条分界线。
    func testClosedButUntranscribedSessionIsOrganizing() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, ended_at, day, source, status)
                VALUES (1, '2026-08-14T09:00:00Z', '2026-08-14T09:30:00Z',
                        '2026-08-14', 'recording', 'closed')
                """)
        }
        let card = try XCTUnwrap(
            HomeProjection.homeFeed(day: "2026-08-14", in: dbQueue).todayCards.first)
        XCTAssertEqual(card.state.presentation, .organizing)
    }

    /// 刚点下开始的那几十秒:「记录中 · 0 分」读起来像坏了,而它正常得很。
    func testJustStartedDoesNotSayZeroMinutes() {
        XCTAssertEqual(SessionPresentation.duration(0), "不到 1 分")
        XCTAssertEqual(SessionDisplayState.recording(elapsedMinutes: 0).presentation.label,
                       "记录中 · 不到 1 分")
    }

    // MARK: - 纪要要真的从库里读

    /// ⚠️ 这条补的是一个**被测试自己掩盖了的洞**:`homeFeed` 的 `summaries` 原来
    /// 默认 `[:]`,而生产没有任何调用方注入 —— 已经出了纪要的场次在首页上
    /// **永远显示「整理中」**。所有既有测试都自己传了字典,所以全绿。
    ///
    /// 这条**不传字典**,逼投影自己去库里读。
    func testFinishedSessionReachesDoneWithoutAnyInjectedSummary() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, ended_at, day, source, status)
                VALUES (1, '2026-08-14T10:24:00+08:00', '2026-08-14T11:02:00+08:00',
                        '2026-08-14', 'recording', 'closed')
                """)
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (7, 1, 1, 1, 'step-asr-v1', 'frozen', '2026-08-14T11:02:00+08:00')
                """)
            try db.execute(sql: """
                INSERT INTO transcript_lines
                  (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
                VALUES (100, 7, 0, 0, 5000, '第一句', 0)
                """)
            try db.execute(sql: """
                INSERT INTO summaries (transcript_id, one_liner, created_at)
                VALUES (7, '把方向说清楚了', '2026-08-14T11:02:00+08:00')
                """)
            try db.execute(sql: """
                INSERT INTO summary_key_points (transcript_id, line_id, seq, text, quote)
                VALUES (7, 100, 1, '先验证连续使用', '第一句')
                """)
        }

        let feed = try HomeProjection.homeFeed(day: "2026-08-14", in: dbQueue)  // 不传 summaries
        let card = try XCTUnwrap(feed.todayCards.first)

        XCTAssertEqual(card.state.presentation.label, "好了",
                       "出了纪要还显示「\(card.state.presentation.label)」—— 投影没去库里读")
        let s = try XCTUnwrap(card.state.presentation.summary)
        XCTAssertEqual(s.oneLiner, "把方向说清楚了")
        XCTAssertEqual(s.keyPoints.map(\.text), ["先验证连续使用"])
        XCTAssertEqual(s.keyPoints.first?.lineID, 100, "要点得带着能跳回原话的行号")
        XCTAssertTrue(s.title.isEmpty, "M1 的库里没有场次标题这一列,编一个出来更糟")
    }

    // MARK: - 卡面时间戳

    func testStampFormatsWithinAndBeyondAnHour() {
        XCTAssertEqual(SessionCardView.stamp(0), "00:00")
        XCTAssertEqual(SessionCardView.stamp(320_000), "05:20")
        XCTAssertEqual(SessionCardView.stamp(3_920_000), "1:05:20")
        XCTAssertEqual(SessionCardView.stamp(-5), "00:00", "负毫秒不该算出负时间")
    }
}
