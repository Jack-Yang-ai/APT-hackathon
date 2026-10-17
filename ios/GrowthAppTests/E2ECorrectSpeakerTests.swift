import XCTest
import GRDB
@testable import GrowthApp

/// `e2e_correct_speaker`:重算注册表的三条断言(§3.5.2,判 A5 修法)。
///
/// ⚠️ **与 §3.5.3 脚本清单的出入**:那张表把它列成 `e2e_correct_speaker.py`,
/// 但要断言的对象——`RecomputeRegistry`——是 Swift 的(§3.5.2 自己给的示例代码
/// 就是 Swift),而断言 2、3 还必须**真调一次 `assignSpeaker`**。
/// Python 脚本只读 DB 文件、够不着这两样(判 8 的分工)。所以写在 Swift 里。
/// 结构层面能从 DB 查的部分,已经在 `eval/checks/` 那五个脚本里了。
final class E2ECorrectSpeakerTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-08T16:00:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try TestPeople.seed(in: dbQueue)
        RecomputeRegistry.resetToM0Defaults()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, '2026-08-08T14:00:00+08:00', '2026-08-08', 'recording', 'closed')
                """)
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (1, 1, 1, 1, 'step-asr-v1', 'frozen', '2026-08-08T15:00:00+08:00')
                """)
            try db.execute(sql: """
                INSERT INTO transcript_lines (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
                VALUES (10, 1, 0, 0, 1000, '周三之前把接口文档给老王', 0)
                """)
            // 两条挂起的下游内容,归属一到位就该被翻回来
            try db.execute(sql: """
                INSERT INTO summary_stances (transcript_id, line_id, seq, stance, quote, pending, pending_reason)
                VALUES (1, 10, 0, '对交付时间有保留', '周三之前', 1, '归属未定')
                """)
            try db.execute(sql: """
                INSERT INTO summary_commitments (transcript_id, line_id, seq, what, quote, pending, pending_reason)
                VALUES (1, 10, 0, '周三前交文档', '接口文档给老王', 1, '归属未定')
                """)
        }
    }

    override func tearDownWithError() throws { dbQueue = nil }

    private func schemaTables() throws -> Set<String> {
        try dbQueue.read { db in try RecomputeCoverage.attributionConsumingTables(db) }
    }

    @discardableResult
    private func correctSpeaker() throws -> AssignResult {
        // clusterTag: nil —— 模拟的是用户在界面上确认一个人名,那一刻手上只有人名,
        // 没有分人产物。nil 不会抹掉已有簇标签(见 assignSpeaker 签名注释)。
        try AssignSpeaker.assignSpeaker(lines: [10], person: 7, clusterTag: nil,
                                        source: .userConfirmed,
                                        confidence: nil, actor: .user, now: now, in: dbQueue)
    }

    // MARK: - 断言 1:注册表覆盖当前 schema 里已存在的下游表

    func testRegistryCoversEveryExistingDownstreamTable() throws {
        let gaps = RecomputeCoverage.gaps(schemaTables: try schemaTables(),
                                          registered: RecomputeRegistry.registered)
        XCTAssertEqual(gaps, [], "有下游表没被注册:\n" + gaps.joined(separator: "\n"))
    }

    /// 验收的另一半:**故意漏注册一项则红**。
    /// 少了这条,断言 1 在一个「什么都没注册」的世界里也可能是绿的。
    func testMissingOneRegistrationIsCaught() throws {
        let gaps = RecomputeCoverage.gaps(schemaTables: try schemaTables(),
                                          registered: [.summaryStances])   // 故意漏掉承诺
        XCTAssertFalse(gaps.isEmpty, "漏注册了承诺,覆盖检查却是绿的")
        XCTAssertTrue(gaps.contains { $0.contains("summary_commitments") }, "\(gaps)")
    }

    func testEmptyRegistryIsCaught() throws {
        let gaps = RecomputeCoverage.gaps(schemaTables: try schemaTables(), registered: [])
        // 2026-08-18 由 2 变 3:迁移 v19 建了 `matter_timeline`(清单第 5 项)。
        // 这条断言的意思不是「就该是 3」,是**清单里已经建出来的表一张都不许漏点名** ——
        // 所以数字跟着 schema 长,而长了没人改这里就会红。
        // 2026-08-25 由 3 变 7:v26 建了 `discovery_evidence`(第 7 项前半)、
        // v27 建了 `cards`(第 9 项)、v28 建了 `observation_evidence`(第 7 项后半)
        // 与 `person_brief`(第 6 项)。
        // 2026-08-25 再 +2:v29 建了 `self_stance_evidence` 与 `self_stances`(第 8 项两行)。
        XCTAssertEqual(gaps.count, 9, "清单里已建出来的下游表都该被点名:\(gaps)")
    }

    /// M2 建了「事的三视角」却忘了注册 —— 这条断言必须随里程碑自己长大。
    func testFutureMilestoneTableWithoutRegistrationIsCaught() throws {
        var future = try schemaTables()
        future.insert("thing_perspectives")
        let gaps = RecomputeCoverage.gaps(schemaTables: future,
                                          registered: RecomputeRegistry.registered)
        XCTAssertTrue(gaps.contains { $0.contains("thing_perspectives") },
                      "M2 的表出现了却没注册,应当被抓住:\(gaps)")
    }

    /// 🔴 列名叫 `xxx_line_id` 的表**也要被看见**。
    ///
    /// 判据原来是「列名 == `line_id`」,而 `summary_stances.premise_line_id`
    /// (立场的前提锚在哪一行)是个不折不扣的行引用 —— 扫描器看不见它。
    /// 今天没出事只因为那张表另有一列真叫 `line_id`。
    /// 一张**只有** `premise_line_id` 的表(`M3-0c` 要建的 `self_stances` 就是)
    /// 会整张从闸底下溜过去,既不注册也不豁免 —— 而那道闸的全部意义就是二选一。
    func testATableWhoseOnlyLineReferenceIsSuffixedIsStillSeen() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE probe_only_suffixed (id INTEGER PRIMARY KEY, premise_line_id INTEGER)
                """)
        }
        XCTAssertTrue(try schemaTables().contains("probe_only_suffixed"),
                      "只有 `premise_line_id` 的表没被看见 —— 它会整张从闸底下溜过去")
    }

    /// 新建一张带 line_id 的表,既没注册也没进豁免名单 —— 逼一个决定,不许两样都不做。
    func testBrandNewConsumingTableForcesADecision() throws {
        var future = try schemaTables()
        future.insert("some_new_table_with_line_id")
        let gaps = RecomputeCoverage.gaps(schemaTables: future,
                                          registered: RecomputeRegistry.registered)
        XCTAssertTrue(gaps.contains { $0.contains("some_new_table_with_line_id") }, "\(gaps)")
    }

    /// 注册了但表不存在 —— 死注册,跑起来只会一直报 pendingSchema。
    func testRegistrationWithoutTableIsCaught() throws {
        let gaps = RecomputeCoverage.gaps(schemaTables: ["summary_stances", "line_speakers"],
                                          registered: RecomputeRegistry.registered)
        XCTAssertTrue(gaps.contains { $0.contains("承诺") }, "\(gaps)")
    }

    // MARK: - 断言 2:一次纠正后,注册表里每个函数都被调过

    func testEveryRegisteredFunctionRunsOnOneCorrection() throws {
        let result = try correctSpeaker()
        XCTAssertEqual(Set(result.recomputed.keys), RecomputeRegistry.registered,
                       "有注册函数没被调到 —— 入口悄悄跳过了某一项")
        for (target, outcome) in result.recomputed {
            guard case .recomputed = outcome else {
                return XCTFail("\(target.rawValue) 没真跑,而是 \(outcome)")
            }
        }
    }

    /// 「被调过」不等于「干了活」。这条验它确实把挂起翻回来了。
    func testOneCorrectionActuallyUpdatesDownstream() throws {
        try correctSpeaker()
        let (stance, commit) = try dbQueue.read { db -> (Int?, Int?) in
            (try Int.fetchOne(db, sql: "SELECT pending FROM summary_stances WHERE line_id = 10"),
             try Int.fetchOne(db, sql: "SELECT pending FROM summary_commitments WHERE line_id = 10"))
        }
        XCTAssertEqual(stance, 0)
        XCTAssertEqual(commit, 0)
    }

    // MARK: - 断言 3:每个重算函数幂等

    func testEveryRecomputeFunctionIsIdempotent() throws {
        try correctSpeaker()
        let after1 = try snapshot()

        // 直接把注册表再跑一遍(不经入口 —— 入口会因为幂等而 no-op,那样测不到函数本身)
        try dbQueue.write { db in _ = try RecomputeRegistry.run(db, lines: [10], triggeredBy: 1) }
        let after2 = try snapshot()

        XCTAssertEqual(after1, after2, "重算函数不幂等,连跑两次库状态就变了")

        try dbQueue.write { db in _ = try RecomputeRegistry.run(db, lines: [10], triggeredBy: 1) }
        XCTAssertEqual(try snapshot(), after1, "第三次也该一样")
    }

    /// 下游表的全量快照,用来比「跑两次有没有变」。
    private func snapshot() throws -> [String] {
        try dbQueue.read { db in
            var rows: [String] = []
            for table in ["summary_stances", "summary_commitments"] {
                for row in try Row.fetchAll(db, sql: """
                    SELECT id, line_id, pending, pending_reason FROM \(table) ORDER BY id
                    """) {
                    rows.append("\(table):\(row)")
                }
            }
            return rows
        }
    }
}
