import XCTest
import GRDB
@testable import GrowthApp

/// 进展归属 V1 的输入层(M2-B3):读、裁、预筛。
///
/// 这里钉的都是**「漏了也不报错」**的那种:一件事悄悄不参与比对、
/// 被砍掉的事没人记下来、已关的悬点还在往 prompt 里塞钱。
final class ProgressAttributionInputTests: XCTestCase {
    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-20T10:00:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
    }
    override func tearDownWithError() throws { dbQueue = nil }

    @discardableResult
    private func matter(_ title: String, state: String = "活跃") throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO matters (title, state, created_at, updated_at) VALUES (?, ?, ?, ?)
                """, arguments: [title, state, now, now])
            return db.lastInsertedRowID
        }
    }

    private func question(_ matterID: Int64, _ text: String, closed: Bool = false) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO matter_open_questions (matter_id, question, opened_at, closed_at)
                VALUES (?, ?, ?, ?)
                """, arguments: [matterID, text, now, closed ? now : nil])
        }
    }

    private func timeline(_ matterID: Int64, _ summary: String, at: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO matter_timeline (matter_id, at, summary) VALUES (?, ?, ?)
                """, arguments: [matterID, at, summary])
        }
    }

    /// 造一场带抽取产出的场次。返回 sessionID。
    @discardableResult
    private func session(stance: String, quote: String) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (started_at, day, source, status)
                VALUES (?, '2026-08-20', 'mic', 'done')
                """, arguments: [now])
            let sid = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO transcripts (session_id, version, part, asr_model, status, created_at, frozen_at)
                VALUES (?, 1, 1, 'x', 'frozen', ?, ?)
                """, arguments: [sid, now, now])
            let tid = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO transcript_lines
                  (transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, is_gap)
                VALUES (?, 0, 0, 1000, ?, 0, 0)
                """, arguments: [tid, quote])
            let lid = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO summary_stances (transcript_id, line_id, seq, stance, quote, pending)
                VALUES (?, ?, 0, ?, ?, 0)
                """, arguments: [tid, lid, stance, quote])
            return sid
        }
    }

    private func plan(_ sid: Int64) throws -> ProgressAttributionInput.Plan {
        try dbQueue.read { try ProgressAttributionInput.build(sessionID: sid, in: $0) }
    }

    /// 一行「有簇、没身份」的归属 —— 拒识就是这个形态。
    private func clusterOnlySpeaker(lineID: Int64, tag: String = "speaker_0") throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO line_speakers (line_id, person_id, cluster_tag, source, updated_at)
                VALUES (?, NULL, ?, '声纹识别', ?)
                """, arguments: [lineID, tag, now])
        }
    }

    // MARK: - M2-审8:只读当前生效的那一版转写

    /// 在同一场上再冻一版 v2(v1 按冻结原则**保留**)。返回 (v2 的 transcript_id, v2 的 line_id)。
    @discardableResult
    private func refreeze(_ sid: Int64, stance: String, quote: String) throws -> (Int64, Int64) {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transcripts (session_id, version, part, asr_model, status, created_at, frozen_at)
                VALUES (?, 2, 1, 'x', 'frozen', ?, ?)
                """, arguments: [sid, now, now])
            let tid = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO transcript_lines
                  (transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, is_gap)
                VALUES (?, 0, 0, 1000, ?, 0, 0)
                """, arguments: [tid, quote])
            let lid = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO summary_stances (transcript_id, line_id, seq, stance, quote, pending)
                VALUES (?, ?, 0, ?, ?, 0)
                """, arguments: [tid, lid, stance, quote])
            return (tid, lid)
        }
    }

    /// 🔴 **重整之后,进展只能看见新那一版。**
    ///
    /// 冻结原则要求 v1 保留,所以「这一场有几版」的答案永远是「不止一版」。
    /// 而两处查询原来都只按 `t.session_id = ?` 过滤 ⇒ 同一句话以两个不同的
    /// `line_id` 各进一次上下文,已经改正或作废的旧文字照样能进「事」的脉络。
    /// **两版都合法,不会有任何东西报错** —— 只有这条断言会。
    func testOnlyTheActiveTranscriptVersionReachesTheModel() throws {
        let sid = try session(stance: "旧版:先不做", quote: "旧版:先不做")
        let (_, v2Line) = try refreeze(sid, stance: "新版:改成先做试点", quote: "新版:改成先做试点")

        let ctx = try dbQueue.read { db in
            try ProgressAttributionInput.sessionContext(sessionID: sid, in: db)
        }
        XCTAssertEqual(ctx.items.count, 1,
                       "两版材料都进了模型:\(ctx.items.map(\.text))")
        XCTAssertEqual(ctx.items.first?.text, "新版:改成先做试点")
        XCTAssertEqual(ctx.items.first?.lineID, v2Line)
    }

    /// 校验行同样只认新版本的行号。
    ///
    /// 漏掉这一处比漏掉上一处更毒:校验行是「这个 `line_id` 存不存在」的判据 ——
    /// 带上 v1 就等于**承认旧版本的行号仍然有效**,于是模型指着一句已经被重整
    /// 改掉的话,三项校验照样放行。
    func testValidationLinesAlsoDropTheOldVersion() throws {
        let sid = try session(stance: "旧版:先不做", quote: "旧版:先不做")
        let v1Line = try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT line_id FROM transcript_lines LIMIT 1")!
        }
        let (_, v2Line) = try refreeze(sid, stance: "新版:改成先做试点", quote: "新版:改成先做试点")

        let lines = try dbQueue.read { db in
            try ProgressAttributionRunner.validationLines(sessionID: sid, in: db)
        }
        XCTAssertEqual(Set(lines.keys), [v2Line])
        XCTAssertNil(lines[v1Line], "旧版本的行号还能通过校验 —— 模型可以指着一句被改掉的话")
    }

    /// 还没冻结的场次:**返回空,不退化成「全都读」**。
    ///
    /// 退化的后果恰恰是这次要修的那个形态 —— 而它只在「一版都没有」这个
    /// 边界上冒出来,平时看不见。
    func testASessionWithNoFrozenTranscriptYieldsNothingRatherThanEverything() throws {
        let sid = try dbQueue.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO sessions (started_at, day, source, status)
                VALUES ('2026-08-20T09:00:00+08:00', '2026-08-20', 'mic', 'recording')
                """)
            return db.lastInsertedRowID
        }
        let ctx = try dbQueue.read { db in
            try ProgressAttributionInput.sessionContext(sessionID: sid, in: db)
        }
        XCTAssertTrue(ctx.items.isEmpty)
        XCTAssertTrue(ctx.speakers.isEmpty)
        XCTAssertTrue(try dbQueue.read { db in
            try ProgressAttributionRunner.validationLines(sessionID: sid, in: db)
        }.isEmpty)
    }

    // MARK: - 有簇没身份

    /// 🔴 **`person_id IS NULL` 是常态,不是脏数据。**
    ///
    /// 开集拒识、还没认、走兜底没身份 —— 三条路都会在 `line_speakers` 上留下
    /// 一行 `person_id = NULL`。而 `Int64.fetchSet` 解不了 NULL 会**抛**。
    ///
    /// 实测代价(2026-08-24 从真机库读出来):某场次 的进展归属从 08-21 起
    /// **崩到第 58 次**,`last_error` 每拍写着
    /// `could not decode Int64 from database value NULL - column: "person_id"`,
    /// 而 `progress` 不是花钱的 kind ⇒ 上限 290 次 ⇒ **要到第 6 天才 dead**。
    /// 期间它每拍都占一次 pump,而界面上只是「还在处理」。
    ///
    /// ⚠️ 这条测试打的是**两处**查询(`activeMatters` 的参与人、`sessionContext`
    /// 的说话人)。只修一处的话另一处照旧抛,而两处的报错长得一模一样。
    func testNullPersonIDIsNormalNotACrash() throws {
        let sid = try session(stance: "这个方案先不做", quote: "这个方案先不做")
        let lineID = try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT line_id FROM transcript_lines LIMIT 1")!
        }
        try clusterOnlySpeaker(lineID: lineID)

        // ① sessionContext:本场的说话人
        let ctx = try dbQueue.read {
            try ProgressAttributionInput.sessionContext(sessionID: sid, in: $0)
        }
        XCTAssertTrue(ctx.speakers.isEmpty, """
            这一行没有身份,不该有人被算进「本场说话人」。
            """)

        // ② activeMatters:脉络里的参与人
        let mid = try matter("压缩方式怎么定")
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO matter_timeline (matter_id, at, summary, line_id)
                VALUES (?, ?, '上次说先不做', ?)
                """, arguments: [mid, now, lineID])
        }
        let matters = try dbQueue.read { try ProgressAttributionInput.activeMatters(in: $0) }
        XCTAssertEqual(matters.first?.people.isEmpty, true, """
            脉络里这一行没有身份,不该有人被算进「参与人」。
            """)

        // ③ 整条 build 走通 —— 上面两处任一抛,这里就崩,而真机上崩的正是这一条。
        XCTAssertNoThrow(try plan(sid), """
            有簇没身份的场次让进展归属抛了 —— 而那是开集下的常态形态,
            后果是这一场每拍重试一次、连崩 6 天。
            """)
    }

    // MARK: - 谁参与比对

    /// **只有「活跃」参与。** 沉睡的不进(PRD §4.3.6:沉睡不参与,唤醒是另一条路)。
    func testOnlyActiveMattersParticipate() throws {
        try matter("压缩方式怎么定", state: "活跃")
        try matter("压缩方式怎么定的老版本", state: "沉睡")
        try matter("压缩方式的另一件", state: "已结案")
        let all = try dbQueue.read { try ProgressAttributionInput.activeMatters(in: $0) }
        XCTAssertEqual(all.count, 1, """
            沉睡/已结案的事进了比对 —— 每一件都是一次真金白银的调用,
            而它们按规格根本不该参与。
            """)
    }

    /// 🔴 **上限读 `MatterCapacity.activeLimit`,不许在比对这边再写一个 10。**
    ///
    /// 技术方案 §4.5.5:两处各写一份,调高容量时只改一处,后果是
    /// 「有几件事永远不参与比对」而**不会有任何东西报错**(铁律 4)。
    /// 这条测试就是那道对撞:改了常数它跟着走,写死 10 就红。
    func testCapIsTheSharedConstantNotALocalTen() throws {
        for i in 0..<(MatterCapacity.activeLimit + 3) { try matter("事 \(i)") }
        let all = try dbQueue.read { try ProgressAttributionInput.activeMatters(in: $0) }
        XCTAssertEqual(all.count, MatterCapacity.activeLimit, """
            取到 \(all.count) 件,而容量上限是 \(MatterCapacity.activeLimit)。
            如果这里写死了 10 而常数被改过,这一行就是那个洞。
            """)
    }

    // MARK: - 裁

    /// **已关的悬点不进** —— 它们已经不是未决点了,塞进去是花钱买噪音。
    func testClosedQuestionsAreNotSentToTheModel() throws {
        let m = try matter("压缩方式怎么定")
        try question(m, "用哪种压缩")
        try question(m, "上周那个已经定了", closed: true)
        let ctx = try dbQueue.read { try ProgressAttributionInput.activeMatters(in: $0) }[0]
        XCTAssertEqual(ctx.openQuestions.map(\.text), ["用哪种压缩"])
    }

    /// 脉络只带最近 `timelineWindow` 条,**而且要是最近的那几条**。
    ///
    /// 🔴 取错成「最早的几条」不会报错,只会让模型永远看不到事情的近况 ——
    /// 而「进展」判的正是近况。
    func testTimelineKeepsTheMostRecentWindow() throws {
        let m = try matter("压缩方式怎么定")
        let w = ProgressAttributionInput.timelineWindow
        for i in 0..<(w + 5) {
            try timeline(m, "第 \(i) 条", at: "2026-08-\(String(format: "%02d", i + 1))T10:00:00+08:00")
        }
        let ctx = try dbQueue.read { try ProgressAttributionInput.activeMatters(in: $0) }[0]
        XCTAssertEqual(ctx.recentTimeline.count, w)
        XCTAssertEqual(ctx.recentTimeline.first, "第 \(w + 4) 条", "取的不是最近那条")
    }

    // MARK: - 预筛与预算

    /// 预筛掉的事**带着分数**,不是只留个数。
    ///
    /// 🔴 阈值现在是未校准的默认值,而校准要跑准召曲线 —— 曲线要的正是
    /// 「每件事当时得了多少分」。只记「筛掉了 3 件」的话那份数据永远补不回来。
    func testSkippedMattersCarryTheirScores() throws {
        try matter("完全无关的一件事")
        let sid = try session(stance: "压缩方式先按二月那版", quote: "压缩方式先按二月那版")
        let p = try plan(sid)
        XCTAssertEqual(p.compare.count, 0, "毫不相关的事进了模型 —— 预筛没起作用")
        XCTAssertEqual(p.skipped.count, 1)
        XCTAssertNotNil(p.skipped.first.map { $0.lexical }, "筛掉了却没留分数,校准时补不回来")
    }

    /// 词面命中的事要进模型 —— 这条与上一条是一对,证明预筛不是「全筛掉」。
    func testLexicalHitGetsCompared() throws {
        try matter("压缩方式怎么定")
        let sid = try session(stance: "压缩方式先按二月那版", quote: "压缩方式先按二月那版")
        let p = try plan(sid)
        XCTAssertEqual(p.compare.count, 1, """
            词面明显重合却没进模型 —— 预筛把该比的也筛掉了。
            skipped 里的分数:\(p.skipped)
            """)
    }

    /// 🔴 **超预算被砍掉的事必须记下来。**
    ///
    /// 技术方案 §4.5.1 原话:不记的话「这一场没有产生进展」与
    /// 「这一场有 8 件事没被比对」长得一模一样。
    func testDroppedForBudgetIsRecordedNotSilent() throws {
        // 造一批词面都命中、而且脉络很长的事,把预算撑爆。
        // 每件事的脉络要足够长,10 件加起来才撑得爆 20,000 的估算上限。
        // ⚠️ 用 `inputTokenBudget` 算出来,不写死一个数 —— 上限改了这条要跟着走,
        // 否则它会悄悄变成一条「永远撑不爆、于是永远绿」的假测试。
        let perMatter = ProgressAttributionInput.inputTokenBudget / MatterCapacity.activeLimit + 500
        let unit = "压缩方式怎么定这件事的来龙去脉很长很长。"
        let long = String(repeating: unit, count: perMatter / unit.count + 1)
        for i in 0..<(MatterCapacity.activeLimit) {
            let m = try matter("压缩方式怎么定 \(i)")
            try timeline(m, long, at: now)
        }
        let sid = try session(stance: "压缩方式先按二月那版", quote: "压缩方式先按二月那版")
        let p = try plan(sid)
        XCTAssertFalse(p.droppedForBudget.isEmpty, """
            输入估算 \(p.estimatedInputTokens) tok(上限 \(ProgressAttributionInput.inputTokenBudget)),
            却一件都没砍 —— 要么预算闸没生效,要么砍了没记。
            """)
        XCTAssertEqual(p.compare.count, ProgressAttributionInput.degradedCompareCount,
                       "降级之后该只比最相关的几件")
    }
}
