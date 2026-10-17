import XCTest
import GRDB
@testable import GrowthApp

/// 出稿与失败的首页一句话(M1-12a / PRD §4.1.8,拍板 2026-08-12)。
///
/// 🔴 **这个文件守的是一条会被「优化」掉的设计判断**:这一句与 §4.2.2 提示条
/// 是两条,不许合并成一条按优先级取第一。合并之后「有 1 段没成」会被
/// 「3 天没打开了」顶掉,而 G5 要求失败恒可见 —— 而且合并后的界面**看起来很正常**,
/// 只是永远少说一句话。`testFailureIsNeverSuppressedByTheBanner` 就是那把尺子。
final class ProcessingDigestTests: XCTestCase {

    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
    }

    override func tearDownWithError() throws { dbQueue = nil }

    private func card(_ id: Int64, _ state: SessionDisplayState) -> SessionCard {
        SessionCard(id: id, startTime: "14:00", durationMinutes: 30,
                    state: state, attachments: .none)
    }

    private func someSummary() -> SessionSummary {
        SessionSummary(title: "", oneLiner: "对方对交付时间有顾虑", keyPoints: [])
    }

    // MARK: - 什么都没有时不说话

    /// 一场都没有 ⇒ **没有这一句**,而不是「今天整理出 0 场」。
    /// 那句话会在一个还什么都没录的早晨挂在首页上,像是出了什么事。
    func testNoSessionsYieldsNoDigest() {
        XCTAssertNil(ProcessingDigest.make(from: []))
    }

    /// 全都还在路上 ⇒ 也没有这一句。**还没有结果的事不许下结论** ——
    /// 归进任何一边都是在替它判死或判活。
    func testInFlightSessionsCountTowardsNeitherHalf() {
        let digest = ProcessingDigest.make(from: [
            card(1, .recording(elapsedMinutes: 12)),
            card(2, .processing),
            card(3, .uploading(percent: 40)),
            card(4, .queued(ahead: 1)),
            card(5, .waitingForNetwork),
        ])
        XCTAssertNil(digest)
    }

    // MARK: - 两半各自可缺

    /// 只出稿 ⇒ 只说出稿那半,**不加「有 0 段没成」**。
    func testOnlyReadySaysOnlyTheReadyHalf() throws {
        let digest = try XCTUnwrap(ProcessingDigest.make(from: [
            card(1, .done(someSummary())),
            card(2, .attributionPending(someSummary())),   // 说话人还在整理,但纪要看得到
            card(3, .processing),
        ]))
        XCTAssertEqual(digest.readyCount, 2)
        XCTAssertEqual(digest.brokenCount, 0)
        XCTAssertEqual(digest.sentence, "今天整理出 2 场")
    }

    /// 只失败 ⇒ **不说「今天整理出 0 场」**。说了会让人以为今天本来该有稿。
    func testOnlyBrokenDoesNotClaimZeroOutput() throws {
        let digest = try XCTUnwrap(ProcessingDigest.make(from: [
            card(7, .failed(attempt: 2, willRetry: true)),
        ]))
        XCTAssertEqual(digest.sentence, "有 1 段没成")
        XCTAssertEqual(digest.brokenSessionIDs, [7])
    }

    /// 两半都有 ⇒ 拍板给的那句话的形状。
    func testBothHalvesMatchTheRuledSentence() throws {
        let digest = try XCTUnwrap(ProcessingDigest.make(from: [
            card(1, .done(someSummary())),
            card(2, .done(someSummary())),
            card(3, .done(someSummary())),
            card(4, .failed(attempt: 1, willRetry: true)),
        ]))
        XCTAssertEqual(digest.sentence, "今天整理出 3 场,有 1 段没成")
    }

    // MARK: - 「只保留了文字记录」算没成

    /// `.degraded` 归进**没成**那半。
    ///
    /// PRD §4.1.7 说它是**灰色终态、需手动重试** —— 也就是它不会自己好。
    /// 归进「成了」的话,用户永远不知道该去管它,而首页会说「今天全整理出来了」。
    func testTranscriptOnlyCountsAsBrokenBecauseItWillNotFixItself() throws {
        let digest = try XCTUnwrap(ProcessingDigest.make(from: [
            card(1, .done(someSummary())),
            card(2, .degraded),
            card(3, .partialFailure(missing: "承诺")),
        ]))
        XCTAssertEqual(digest.readyCount, 1)
        XCTAssertEqual(digest.brokenSessionIDs, [2, 3])
        XCTAssertEqual(digest.sentence, "今天整理出 1 场,有 2 段没成")
    }

    // MARK: - 🔴 失败不被内容提示顶掉(G5)

    /// **这一条是整个文件的理由。**
    ///
    /// 同时满足「有 1 段没成」与「3 天没打开了」时,两句话**都要在**。
    /// 把它们合成一个按优先级取第一条的字段,失败那句就会被顶掉 ——
    /// 而 G5 要求失败恒可见。合并后的首页看起来毫无问题,只是永远少说一句。
    func testFailureIsNeverSuppressedByTheBanner() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, '2026-08-17T14:00:00+08:00', '2026-08-17', 'recording', 'closed')
                """)
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (1, 1, 1, 1, 'step-asr-v1', 'partial', '2026-08-17T14:30:00+08:00')
                """)
            try db.execute(sql: """
                INSERT INTO transcript_lines (transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
                VALUES (1, 0, 0, 1800000, '这一场只剩文字记录', 0)
                """)
        }

        let feed = try HomeProjection.homeFeed(
            day: "2026-08-17",
            summaries: [:],
            banner: .awayForDays(days: 5, sessionCount: 3),   // 内容提示同时成立
            in: dbQueue)

        let digest = try XCTUnwrap(feed.digest, "失败被内容提示顶掉了 —— G5 要求它恒可见")
        XCTAssertEqual(digest.brokenCount, 1)
        XCTAssertEqual(feed.banner, .awayForDays(days: 5, sessionCount: 3), "提示条也不该被挤掉")
    }

    // MARK: - 折进「零碎」的那些也要数

    /// 数的是**今天全部场次**,不是没被折叠的那些。
    ///
    /// 只数 `todayCards` 会漏掉正好被折进「零碎」的那一段失败 ——
    /// 而首页上「今天全好了」和「有一段没成」长得完全不一样。
    func testFoldedFragmentsAreStillCounted() throws {
        try dbQueue.write { db in
            for id in Int64(1)...2 {
                try db.execute(sql: """
                    INSERT INTO sessions (id, started_at, day, source, status)
                    VALUES (?, ?, '2026-08-17', 'recording', 'closed')
                    """, arguments: [id, "2026-08-17T1\(id):00:00+08:00"])
                try db.execute(sql: """
                    INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                    VALUES (?, ?, 1, 1, 'step-asr-v1', ?, '2026-08-17T15:00:00+08:00')
                    """, arguments: [id, id, id == 1 ? "frozen" : "partial"])
                try db.execute(sql: """
                    INSERT INTO transcript_lines (transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
                    VALUES (?, 0, 0, 600000, '一句话', 0)
                    """, arguments: [id])
            }
        }

        // 1 号有纪要但零要点 ⇒ 会被折进「零碎」;2 号 partial ⇒ 降级(没成)。
        let feed = try HomeProjection.homeFeed(
            day: "2026-08-17",
            summaries: [1: SessionSummary(title: "", oneLiner: "一句话", keyPoints: [])],
            in: dbQueue)

        XCTAssertNotNil(feed.fragments, "夹具没造出折叠场景,这条测试就没在测它想测的东西")
        let digest = try XCTUnwrap(feed.digest)
        XCTAssertEqual(digest.readyCount, 1, "被折进零碎的那一场也出了稿")
        XCTAssertEqual(digest.brokenSessionIDs, [2])
    }
}
