import XCTest
import GRDB
@testable import GrowthApp

/// 进展归属 V1 的调用与判定(M2-B3)。**注入假调用,不联网不花钱。**
///
/// 这里钉的都是「错了会脏数据或多花钱」的:模型指到没进模型的事、
/// 引文不是原话却静默入库、还判不了的东西被算进判卷的分母。
final class ProgressAttributionRunnerTests: XCTestCase {
    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-20T10:00:00+08:00"
    private var sessionID: Int64 = 0
    private var lineID: Int64 = 0
    private var matterID: Int64 = 0

    /// 一场里有一句原话、一件词面命中的活跃事(带一个未关悬点)。
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
                INSERT INTO matter_open_questions (matter_id, question, opened_at)
                VALUES (?, '用哪种压缩方式', ?)
                """, arguments: [matterID, now])
            try db.execute(sql: """
                INSERT INTO sessions (started_at, day, source, status)
                VALUES (?, '2026-08-20', 'mic', 'done')
                """, arguments: [now])
            sessionID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO transcripts (session_id, version, part, asr_model, status, created_at, frozen_at)
                VALUES (?, 1, 1, 'x', 'frozen', ?, ?)
                """, arguments: [sessionID, now, now])
            let tid = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO transcript_lines
                  (transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, is_gap)
                VALUES (?, 0, 0, 1000, '压缩方式先按二月那版走', 0, 0)
                """, arguments: [tid])
            lineID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO summary_stances (transcript_id, line_id, seq, stance, quote, pending)
                VALUES (?, ?, 0, '压缩方式先按二月那版', '压缩方式先按二月那版走', 0)
                """, arguments: [tid, lineID])
        }
    }
    override func tearDownWithError() throws { dbQueue = nil }

    /// 给这一行定归属 —— 三项校验的第③项要它。
    ///
    /// 🔴 **走 `assignSpeaker`,不直接 INSERT `line_speakers`(铁律 3)。**
    /// 测试也不该绕这个唯一入口:绕过去写出来的行**可能是入口本身拒绝的形状**
    /// (第一版就是那么写的,当场撞 `source` 的 CHECK 约束),
    /// 于是被测代码在一份生产里根本不会出现的数据上跑绿。
    private func attribute(person: Int64 = 1, tag: String? = nil) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO persons (id, name, source, created_at, updated_at)
                VALUES (?, '我', '本人', ?, ?)
                """, arguments: [person, now, now])
        }
        _ = try AssignSpeaker.assignSpeaker(
            lines: [lineID], person: person, clusterTag: tag,
            source: .systemOrganized, confidence: 0.9,
            actor: .system, now: now, in: dbQueue)
    }

    private func reply(questionID: Int64?, quote: String) -> String {
        let q = questionID.map(String.init) ?? "null"
        return """
        {"items":[{"matter_id":\(matterID),"question_id":\(q),"line_id":\(lineID),
        "quote":"\(quote)","kind":"悬点关闭","summary":"定了"}]}
        """
    }

    private func run(_ raw: String) async throws -> ProgressAttributionRunner.Outcome {
        try await ProgressAttributionRunner.run(sessionID: sessionID,
                                                call: { _ in raw }, in: dbQueue)
    }

    // MARK: - 三档

    /// 指认了悬点 + 三项校验全过 ⇒ **高档(静默入库)**。
    func testHitQuestionAndVerbatimGoesHigh() async throws {
        let qid = try await dbQueue.read { try Int64.fetchOne($0, sql: "SELECT id FROM matter_open_questions")! }
        try attribute()
        let out = try await run(reply(questionID: qid, quote: "压缩方式先按二月那版"))
        XCTAssertEqual(out.judged.count, 1)
        XCTAssertEqual(out.judged[0].disposition,
                       .tiered(.init(tier: .high, reason: .hitQuestionAndValidated)))
        XCTAssertEqual(out.validationFailures, 0)
    }

    /// 指不出悬点 ⇒ **中档,出确认卡**,不许静默入库。
    func testNoQuestionGoesToConfirmationCard() async throws {
        try attribute()
        let out = try await run(reply(questionID: nil, quote: "压缩方式先按二月那版"))
        XCTAssertEqual(out.judged[0].disposition,
                       .tiered(.init(tier: .medium, reason: .validatedButNoQuestion)))
    }

    /// 🔴 **引文不是原话 ⇒ 低档,而且必须计数并说得出理由。**
    ///
    /// §3.2:校验失败要计数并告警,不能悄悄丢弃条目。
    /// 只给一个数而不留理由的话,排查时无从下手。
    func testNonVerbatimQuoteIsCountedWithAReason() async throws {
        try attribute()
        let out = try await run(reply(questionID: 1, quote: "压缩方式按三月那版"))
        XCTAssertEqual(out.validationFailures, 1, "引文对不上原文却没计数 —— 静默丢弃了")
        XCTAssertTrue(out.failureReasons.joined().contains("quote"), """
            计了数但说不出为什么:\(out.failureReasons)
            """)
        XCTAssertEqual(out.judged[0].disposition,
                       .tiered(.init(tier: .low, reason: .failedValidation)))
    }

    /// 🔴 **归属未定 ⇒ 挂起,既不入库也不打扰用户 —— 而且不算进任何一档。**
    ///
    /// 归属到位之后它自己就判得了了,现在弹确认卡等于问一个马上会自己有答案的问题。
    /// ⚠️ 更要紧的是**判卷失真**:`M2-L4` 判的是静默档判准率,
    /// 一条「还没判」的东西被算进任何一档,那个数就不是它自称的意思了。
    func testUnattributedLineIsHeldNotTiered() async throws {
        // 故意不调用 attribute()
        let out = try await run(reply(questionID: 1, quote: "压缩方式先按二月那版"))
        XCTAssertEqual(out.heldCount, 1)
        if case .held = out.judged[0].disposition {} else {
            XCTFail("归属未定却被判进了 \(out.judged[0].disposition) —— 判卷的分母会因此失真")
        }
        XCTAssertEqual(out.validationFailures, 0, "挂起不是失败,不该计进失败数")
    }

    // MARK: - 别让模型糊弄过去

    /// 🔴 **模型指到没进模型的那件事 ⇒ 丢弃并计数。**
    ///
    /// 它可能指一件被预筛掉的、甚至一件根本不存在的事 —— 那条进展没有任何依据。
    /// 不挡的话,一条凭空的进展会挂到一件今天压根没参与比对的事上。
    func testProgressPointingAtAnUncomparedMatterIsRejected() async throws {
        try attribute()
        let bogus = """
        {"items":[{"matter_id":99999,"question_id":1,"line_id":\(lineID),
        "quote":"压缩方式先按二月那版","kind":"悬点关闭","summary":"x"}]}
        """
        let out = try await run(bogus)
        XCTAssertEqual(out.judged.count, 0, "指到没进模型的事,却还是产出了一条进展")
        XCTAssertEqual(out.validationFailures, 1)
        XCTAssertTrue(out.failureReasons.joined().contains("99999"))
    }

    /// 没有事可比时**不调用模型** —— 每一次调用都是真金白银。
    func testNoMatterToCompareMeansNoModelCall() async throws {
        try await dbQueue.write { db in
            // 先删悬点再删事 —— 外键挡着,这也说明「事」不是可以随手清掉的东西。
            try db.execute(sql: "DELETE FROM matter_open_questions")
            try db.execute(sql: "DELETE FROM matters")
        }
        var called = false
        let out = try await ProgressAttributionRunner.run(
            sessionID: sessionID, call: { _ in called = true; return "{}" }, in: dbQueue)
        XCTAssertFalse(called, "一件可比的事都没有,却还是发了一次付费调用")
        XCTAssertEqual(out.judged.count, 0)
    }

    /// 模型回了不合契约的东西 ⇒ **抛**,不许当成「这一场没有进展」。
    ///
    /// §3.2:失败必须可见。当成空结果的话,一次上游故障会被记成一个事实结论。
    func testGarbageOutputThrowsInsteadOfLookingEmpty() async throws {
        try attribute()
        do {
            _ = try await run("对不起我不能帮你做这个")
            XCTFail("模型回了垃圾却没抛 —— 会被当成「这一场没有进展」")
        } catch ProgressAttributionRunner.Failure.badJSON {}
    }

    /// prompt 里必须带上可校验字段的要求 —— 这是「难糊弄」的全部来源。
    func testPromptDemandsIdentificationNotRelevance() throws {
        let plan = try dbQueue.read { try ProgressAttributionInput.build(sessionID: sessionID, in: $0) }
        let p = ProgressAttributionRunner.buildPrompt(plan)
        XCTAssertTrue(p.contains("line_id") && p.contains("quote") && p.contains("question_id"),
                      "prompt 没要求指认字段,可校验字段越多越难糊弄这条就落空了")
        XCTAssertTrue(p.contains("逐字"), "没要求逐字引用,三项校验的第②项等于没有依据")
    }
}
