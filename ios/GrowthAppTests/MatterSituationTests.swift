import XCTest
import GRDB
@testable import GrowthApp

/// 局面面板(M2-B4)。验收三条:**数字与脉络一致**、**<200ms**、
/// **grep 零直写 matters/judgments**。
final class MatterSituationTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let nowDate = ISO8601DateFormatter.growth.date(from: "2026-08-18T20:00:00+08:00")!
    private var matterID: Int64 = 0

    private func at(_ daysAgo: Int) -> String {
        ISO8601DateFormatter.growth.string(
            from: nowDate.addingTimeInterval(-Double(daysAgo) * 86_400))
    }

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        matterID = try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO matters (title, state, created_at, updated_at)
                VALUES ('产品该定位成什么', '活跃', ?, ?)
                """, arguments: [at(60), at(3)])
            return db.lastInsertedRowID
        }
    }
    override func tearDownWithError() throws { dbQueue = nil }

    private func panel() throws -> MatterSituation.Panel {
        try dbQueue.read { try MatterSituation.panel(matterID: matterID, now: nowDate, in: $0) }
    }

    /// 造一条脉络,可选挂一行原话。
    private func progress(daysAgo: Int, lineID: Int64? = nil) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO matter_timeline (matter_id, at, summary, line_id)
                VALUES (?, ?, '有了新说法', ?)
                """, arguments: [matterID, at(daysAgo), lineID])
        }
    }

    // MARK: - 数字与脉络一致(出口判据)

    func testStalledDaysMatchTheLatestProgress() throws {
        try progress(daysAgo: 18)
        try progress(daysAgo: 40)
        XCTAssertEqual(try panel().stalledDays, 18, "停滞天数该跟着**最近**那条脉络,不是最早那条")
    }

    /// 🔴 从没推进过 ⇒ nil,**不是 0** ——「0 天没推进」的意思是「今天刚推进」。
    /// 而这一屏是给用户判断「该跟进哪件」的,那个错法正好把答案弄反。
    func testNeverProgressedIsNotZeroDays() throws {
        let p = try panel()
        XCTAssertNil(p.stalledDays)
        XCTAssertEqual(p.unavailable["停滞时长"], "这件事还没有任何进展",
                       "算不出来要说清为什么 —— 界面隐藏是 G6,而原因不该跟着丢掉")
    }

    func testOpenQuestionsCountOnlyTheUnclosedOnes() throws {
        try dbQueue.write { db in
            for (q, closed) in [("还悬着", nil), ("已经定了", at(1))] as [(String, String?)] {
                try db.execute(sql: """
                    INSERT INTO matter_open_questions (matter_id, question, opened_at, closed_at)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [matterID, q, at(5), closed])
            }
        }
        XCTAssertEqual(try panel().openQuestions, 1)
    }

    /// 热度按自然周比,两周都没动静时整行不显示(G6)。
    func testHeatComparesTwoWeeksAndHidesWhenQuiet() throws {
        XCTAssertNil(try panel().heat)
        XCTAssertNotNil(try panel().unavailable["讨论热度"])
        try progress(daysAgo: 1)
        try progress(daysAgo: 3)
        try progress(daysAgo: 9)
        let h = try XCTUnwrap(try panel().heat)
        XCTAssertEqual([h.thisWeek, h.lastWeek], [2, 1])
    }

    // MARK: - 🔴 算不出来的,如实说,不编

    /// 承诺**兑现比**给不了 —— `summary_commitments` 没有兑现状态列。
    ///
    /// 编一个(比如「有后续提及就算兑现」)会得到一个看着合理、实际没有依据的数,
    /// 而用户会拿它做判断。这条测试钉的就是「不许编」。
    func testTheFulfilmentRatioIsReportedAsUnavailableRatherThanInvented() throws {
        // 挂一行真实存在的原话 —— 材料集非空,承诺那一项才走得到
        try TestPeople.seed(in: dbQueue)
        try seedMaterial(stancesByPerson: [1: 1])
        let p = try panel()
        XCTAssertNotNil(p.unavailable["承诺兑现比"], "兑现比被编出来了 —— 上游根本没有这个字段")
        // ⚠️ 2026-09-01 换了措辞,结论没变(必须说清为什么算不出来)。原文是
        // 「summary_commitments 没有兑现状态列…(PRD §4.5.3 要的那一半)」—— 表名 + 章节号。
        // `unavailable` 是按空态两分法给界面备的**原因文案**(G6),
        // 今天 `MatterDetailView` 不渲染它,不代表明天不渲染。
        XCTAssertTrue(p.unavailable["承诺兑现比"]!.contains("兑现"), "没说清为什么算不出来")
        XCTAssertFalse(p.unavailable["承诺兑现比"]!.contains("summary_commitments"),
                       "把表名写进了给界面用的原因文案")
    }

    /// 材料集为空时,依赖材料的几项**逐个说明原因**,而不是一起静默消失。
    func testEmptyMaterialExplainsEachMissingItem() throws {
        let p = try panel()
        for key in ["用户缺席", "推动者", "承诺状态"] {
            XCTAssertNotNil(p.unavailable[key], "\(key) 算不出来却没说原因")
        }
        XCTAssertNil(p.driver)
        XCTAssertNil(p.commitments)
    }

    /// 口径:**平手不给推动者**。硬选一个等于替用户断言了一件他没说过的事。
    func testATieYieldsNoDriverRatherThanAnArbitraryPick() throws {
        try TestPeople.seed(in: dbQueue)
        try seedMaterial(stancesByPerson: [1: 1, 2: 1])
        let p = try panel()
        XCTAssertNil(p.driver, "并列第一却硬选了一个")
        XCTAssertEqual(p.unavailable["推动者"], "并列第一,不硬选")
    }

    func testAClearLeaderIsReported() throws {
        try TestPeople.seed(in: dbQueue)
        try seedMaterial(stancesByPerson: [1: 3, 2: 1])
        XCTAssertEqual(try panel().driver?.personID, 1)
        XCTAssertEqual(try panel().driver?.weight, 3)
    }

    /// 🔴 没起过名字的人也能当推动者 —— `persons.name` 可空,而全时录音里
    /// 「声纹认出来了但还没命名」是常态。按非空读会**直接崩**(这条测试打出来的)。
    func testAnUnnamedPersonCanStillBeTheDriver() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO persons (id, name, source, created_at, updated_at)
                VALUES (1, NULL, '用户创建', ?, ?)
                """, arguments: [at(5), at(5)])
        }
        try seedMaterial(stancesByPerson: [1: 2])
        let d = try XCTUnwrap(try panel().driver)
        XCTAssertEqual(d.personID, 1)
        XCTAssertNil(d.name, "没名字就是没名字 —— 不该在数据层编一个「说话人 N」出来")
    }

    /// 造材料:给若干人各造 n 条表态,并把那些行挂进脉络。
    private func seedMaterial(stancesByPerson: [Int64: Int]) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, ?, '2026-08-16', 'recording', 'closed')
                """, arguments: [at(2)])
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (1, 1, 1, 1, 'x', 'frozen', ?)
                """, arguments: [at(2)])
        }
        var line: Int64 = 100
        for (person, n) in stancesByPerson.sorted(by: { $0.key < $1.key }) {
            for _ in 0..<n {
                let id = line; line += 1
                try dbQueue.write { db in
                    try db.execute(sql: """
                        INSERT INTO transcript_lines
                          (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
                        VALUES (?, 1, ?, 0, 1000, '说了句话', 0)
                        """, arguments: [id, id])
                    try db.execute(sql: """
                        INSERT INTO line_speakers (line_id, person_id, source, confidence, updated_at)
                        VALUES (?, ?, '用户确认', 1.0, ?)
                        """, arguments: [id, person, at(2)])
                    try db.execute(sql: """
                        INSERT INTO summary_stances (transcript_id, line_id, seq, stance, quote)
                        VALUES (1, ?, ?, '表了个态', '说了句话')
                        """, arguments: [id, id])
                }
                try progress(daysAgo: 2, lineID: id)
            }
        }
    }

    // MARK: - 验收:200ms

    /// PRD §4.5.3:打开任一活跃事,局面 200ms 内呈现。
    func testThePanelComesBackWellUnderTwoHundredMilliseconds() throws {
        try TestPeople.seed(in: dbQueue)
        try seedMaterial(stancesByPerson: [1: 40, 2: 40])
        let t0 = Date()
        _ = try panel()
        let ms = Date().timeIntervalSince(t0) * 1000
        XCTAssertLessThan(ms, 200, "局面算了 \(Int(ms))ms —— PRD §4.5.3 要求 200ms 内")
    }

    // MARK: - 🔴 验收:B4 零写库

    /// 规格原文:**「一律经 M2-B2 的唯一写路径,B4 自身零写库」**,
    /// 并且验收要「grep B4 代码零直写 matters/judgments」。
    ///
    /// ⚠️ 这条**扫源码,不比数据**(铁律 4)。跑一次没写库只能证明「今天这条路没写」,
    /// 挡不住将来有人在里面加一句 INSERT。
    func testTheSituationLayerContainsNoWrites() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("GrowthApp/Presentation/MatterSituation.swift"),
            encoding: .utf8)
        XCTAssertFalse(src.isEmpty, "读不到源码 —— 这条断言在空转")
        // 去掉注释再扫:注释里出现「不许 INSERT」不该把自己判红
        let code = src.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let r = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<r.lowerBound])
            }.joined(separator: "\n")
        for verb in ["INSERT", "UPDATE ", "DELETE"] {
            XCTAssertFalse(code.contains(verb),
                           "局面层里出现了 \(verb) —— 它必须是纯派生,写路径归 MatterStateMachine")
        }
        // 照妖镜:去注释没有把代码也吃掉
        XCTAssertTrue(code.contains("SELECT"), "去注释处理把代码也删了 —— 上面的扫描是空转")
    }
}
