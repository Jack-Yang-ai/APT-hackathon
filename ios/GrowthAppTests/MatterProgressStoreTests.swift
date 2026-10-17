import XCTest
import GRDB
@testable import GrowthApp

/// 进展落库的唯一写入口(M2-B3,迁移 v23)。
///
/// 这里钉的都是「写错了也不报错」的:重放多落一条(用户被同一件事反复问)、
/// 「还判不了」的东西被写进静默档(判卷的分母失真)、审计链断掉
/// (「这条脉络为什么这么说」再也答不出来)。
final class MatterProgressStoreTests: XCTestCase {
    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-20T10:00:00+08:00"
    private var sessionID: Int64 = 0
    private var lineID: Int64 = 0
    private var matterID: Int64 = 0

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO matters (title, state, created_at, updated_at)
                VALUES ('压缩方式怎么定', '活跃', ?, ?)
                """, arguments: [now, now])
            matterID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO sessions (started_at, day, source, status)
                VALUES (?, '2026-08-20', 'mic', 'done')
                """, arguments: [now])
            sessionID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO transcripts (session_id, version, part, asr_model, status, created_at, frozen_at)
                VALUES (?, 1, 1, 'x', 'frozen', ?, ?)
                """, arguments: [sessionID, now, now])
            try db.execute(sql: """
                INSERT INTO transcript_lines
                  (transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, is_gap)
                VALUES (?, 0, 0, 1000, '压缩方式先按二月那版走', 0, 0)
                """, arguments: [db.lastInsertedRowID])
            lineID = db.lastInsertedRowID
        }
    }
    override func tearDownWithError() throws { dbQueue = nil }

    private func progress(question: Int64? = nil) -> ProgressAttributionRunner.Progress {
        .init(matterID: matterID, questionID: question, lineID: lineID,
              quote: "压缩方式先按二月那版", kind: "悬点关闭", summary: "定了")
    }

    private func judged(_ d: ProgressAttributionRunner.Disposition, question: Int64? = nil)
        -> [ProgressAttributionRunner.Judged] {
        [.init(progress: progress(question: question), disposition: d)]
    }

    @discardableResult
    private func land(_ j: [ProgressAttributionRunner.Judged]) throws -> MatterProgressStore.Landed {
        try dbQueue.write { try MatterProgressStore.land(j, sessionID: sessionID, in: $0, now: now) }
    }

    private func count(_ table: String) throws -> Int {
        try dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }

    // MARK: - 三档各落在哪

    func testHighGoesSilentlyToTheTimeline() throws {
        let r = try land(judged(.tiered(.init(tier: .high, reason: .hitQuestionAndValidated))))
        XCTAssertEqual(r.toTimeline, 1)
        XCTAssertEqual(try count("matter_timeline"), 1)
        XCTAssertEqual(try count("matter_progress_cards"), 0, "静默档不该同时弹卡去打扰用户")
    }

    func testMediumGoesToAConfirmationCard() throws {
        let r = try land(judged(.tiered(.init(tier: .medium, reason: .validatedButNoQuestion))))
        XCTAssertEqual(r.toCards, 1)
        XCTAssertEqual(try count("matter_progress_cards"), 1)
        XCTAssertEqual(try count("matter_timeline"), 0, "中档还没经用户判,不许先进脉络")
    }

    func testLowWritesNothing() throws {
        try land(judged(.tiered(.init(tier: .low, reason: .failedValidation))))
        XCTAssertEqual(try count("matter_timeline"), 0)
        XCTAssertEqual(try count("matter_progress_cards"), 0)
    }

    /// 🔴 **挂起一个字都不写。**
    ///
    /// 它是「还判不了」,不是一档。写进任何一张表都会让 `M2-L4` 判的那个
    /// **静默档判准率**失真 —— 那个数就不是它自称的意思了。
    func testHeldWritesNothingAtAll() throws {
        try land(judged(.held("归属未定")))
        XCTAssertEqual(try count("matter_timeline"), 0)
        XCTAssertEqual(try count("matter_progress_cards"), 0)
        XCTAssertEqual(try count("judgments"), 0, "还没判的东西不该在审计链里留判决")
    }

    // MARK: - 幂等(编排会被重放很多遍)

    /// 🔴 **重放不许多落一条。**
    ///
    /// 编排会被重放很多遍(`ProcessingOrchestrator` 里那句「这个函数会被重放
    /// 很多遍」同一条理由)。没有幂等闸的话,用户看到的是**同一件事被反复问**,
    /// 而没有任何东西会报错。
    func testReplayDoesNotDuplicate() throws {
        let j = judged(.tiered(.init(tier: .medium, reason: .validatedButNoQuestion)))
        try land(j)
        let second = try land(j)
        XCTAssertEqual(try count("matter_progress_cards"), 1, "重放多落了一张卡")
        XCTAssertEqual(second.toCards, 0)
        XCTAssertEqual(second.alreadyLanded, 1, """
            撞了幂等闸却报成「落了 0 条」——「这一场没有进展」与
            「上一拍已经落过了」处置完全不同,而两者都返回 0。
            """)
    }

    func testReplayDoesNotDuplicateTimelineEither() throws {
        let j = judged(.tiered(.init(tier: .high, reason: .hitQuestionAndValidated)))
        try land(j)
        try land(j)
        XCTAssertEqual(try count("matter_timeline"), 1, "重放在脉络里多落了一条")
    }

    /// 手写的脉络(没有来路)**不该被幂等闸挡住** —— 那道唯一索引是带条件的。
    func testHandWrittenTimelineIsNotBlockedByTheGuard() throws {
        try dbQueue.write { db in
            for i in 0..<2 {
                try db.execute(sql: """
                    INSERT INTO matter_timeline (matter_id, at, summary) VALUES (?, ?, ?)
                    """, arguments: [matterID, now, "手写第 \(i) 条"])
            }
        }
        XCTAssertEqual(try count("matter_timeline"), 2, """
            两条都没有 session_id/line_id,幂等闸不该管它们 —— 管了的话
            用户没法在同一件事上手写第二条脉络。
            """)
    }

    // MARK: - 「不用重算」那条结论的前提

    /// 🔴 **照妖镜:给 `matter_timeline` 加一列归属,重算目标必须当场抛。**
    ///
    /// 「这张表不存归属,所以归属改了不用重算」是一条**有前提的结论**。
    /// 前提是「它没有人的列」。把这条要求只写进注释是守不住的
    /// (复核清单 §五点名的形状,本仓在 `R2Layout.swift` 上栽过)——
    /// 所以前提写成了运行时检查,而这条测试证明那个检查真的会响。
    func testAddingAnAttributionColumnBreaksTheNoRecomputeClaim() throws {
        try dbQueue.write { db in
            try db.execute(sql: "ALTER TABLE matter_timeline ADD COLUMN person_id INTEGER")
        }
        XCTAssertThrowsError(try dbQueue.write { db in
            _ = try RecomputeRegistry.run(db, lines: [self.lineID], triggeredBy: 1)
        }, "加了归属列还静默返回 0 —— 那条结论的前提已经没了")
    }

    /// 反面:**没有归属列时它必须正常返回**,否则上一条证明不了任何东西
    /// (说明是别的原因让它抛的)。
    func testNoAttributionColumnMeansNothingToRecompute() throws {
        XCTAssertNoThrow(try dbQueue.write { db in
            _ = try RecomputeRegistry.run(db, lines: [self.lineID], triggeredBy: 1)
        })
    }

    // MARK: - 审计链

    /// 🔴 **静默入脉络必须留判决,而且带得出那一行原话。**
    ///
    /// 审计链存在的全部理由就是回答「这一行为什么这么说」。
    /// 静默档是唯一不经用户眼睛的路径 —— 链断在这儿,就再也答不出来了。
    func testSilentWriteLeavesAnAuditTrail() throws {
        try land(judged(.tiered(.init(tier: .high, reason: .hitQuestionAndValidated)), question: 7))
        let row = try dbQueue.read { try Row.fetchOne($0, sql: "SELECT * FROM judgments") }
        XCTAssertNotNil(row)
        XCTAssertEqual(row?["actor"] as String?, "system-cascade", """
            actor 记成了别的 —— 这条进展是被「这一场抽取出了什么」触发的,
            有「因为」,不是原始观测。
            """)
        XCTAssertEqual(row?["target_kind"] as String?, "matter")
        XCTAssertEqual(row?["basis_line_ids"] as String?, "[\(lineID)]", """
            判决没带上依据的那一行 —— 审计链断了,
            「这条脉络为什么这么说」再也答不出来。
            """)
    }
}
