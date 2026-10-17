import XCTest
import GRDB
@testable import GrowthApp

/// 发现三表的 DDL 断言(`M3-0c` 迁移 v26)。
///
/// 🔴 **这一组守的是「写错了不会有任何东西报错」的那几处**:
/// 闭集漂了、「没出现」类少了可复算口径、认错人之后人线发现还挂着 ——
/// 三种都是编译过、测试绿、界面正常,而内容是错的。
final class DiscoverySchemaTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-25T16:00:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try TestPeople.seed(in: dbQueue)
        RecomputeRegistry.resetToM0Defaults()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, '2026-08-25T14:00:00+08:00', '2026-08-25', 'recording', 'closed')
                """)
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (1, 1, 1, 1, 'step-asr-v1', 'frozen', '2026-08-25T15:00:00+08:00')
                """)
            try db.execute(sql: """
                INSERT INTO transcript_lines (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
                VALUES (10, 1, 0, 0, 1000, '交付时间还是太紧了', 0),
                       (11, 1, 1, 1000, 2000, '这个前提没人确认过', 6)
                """)
            try db.execute(sql: """
                INSERT INTO generation_batches (batch_id, producer, prompt_version, model_id, created_at)
                VALUES ('b1', '发现', 'discovery/v1', 'deepseek-v4-flash', '2026-08-25T15:30:00+08:00')
                """)
        }
    }

    override func tearDownWithError() throws { dbQueue = nil }

    // MARK: - 造样例

    @discardableResult
    private func makeDiscovery(_ kind: DiscoveryKind, object: String,
                               statBasis: String? = nil,
                               evidenceLines: [Int] = [10]) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO discoveries (kind, object_id, summary, stat_basis, batch_id,
                                         created_at, last_touched_at)
                VALUES (?, ?, '摘要一行', ?, 'b1', ?, ?)
                """, arguments: [kind.rawValue, object, statBasis, now, now])
            let id = db.lastInsertedRowID
            for (i, line) in evidenceLines.enumerated() {
                try db.execute(sql: """
                    INSERT INTO discovery_evidence (discovery_id, line_id, form, seq)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [id, line, kind.evidenceForm == .absence ? "anchor" : "quote", i])
            }
            return id
        }
    }

    private func withdrawnAt(_ id: Int64) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT withdrawn_at FROM discoveries WHERE id = ?",
                                arguments: [id])
        }
    }

    // MARK: - 闭集:DDL 的那份就是 Swift 那份

    /// 播种表与 `DiscoveryKind.allCases` **逐行**一致。
    ///
    /// 这条不是重复 `test_discovery_kinds.py`(那道比的是 PRD 与 Swift)——
    /// 这道比的是 **Swift 与库**:迁移里少播一行、或播的 `subject` 写错,
    /// 那道 Python 闸一个字都不会红。
    func testSeededClosedSetMatchesSwiftRowByRow() throws {
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT kind, subject, evidence_form FROM discovery_kinds")
        }
        XCTAssertEqual(rows.count, DiscoveryKind.allCases.count,
                       "播种表 \(rows.count) 行,Swift \(DiscoveryKind.allCases.count) 型 —— 少播的那一型一条也写不进去")
        for k in DiscoveryKind.allCases {
            let r = rows.first { $0["kind"] == k.rawValue }
            XCTAssertNotNil(r, "「\(k.rawValue)」没播进库")
            XCTAssertEqual(r?["subject"], k.subject.rawValue, "「\(k.rawValue)」的对象列漂了")
            XCTAssertEqual(r?["evidence_form"], k.evidenceForm.rawValue, "「\(k.rawValue)」的依据形态漂了")
        }
    }

    /// 闭集外的类型**连写都写不进去**(外键,不是约定)。
    func testAKindOutsideTheClosedSetIsRefusedByTheDatabase() throws {
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO discoveries (kind, object_id, summary, batch_id, created_at, last_touched_at)
                VALUES ('离职倾向', 'p7', '越界的一条', 'b1', ?, ?)
                """, arguments: [now, now])
        }, "闭集外的类型写进去了 —— PRD 那句「清单之外不做」就没有落点了")
    }

    // MARK: - 「没出现」类必须带可复算统计口径

    /// 🔴 三种组合各测一次:少了、多了、对了。
    ///
    /// 只测「对的能进去」是假绿的标准形状 —— 触发器写反了它照样绿。
    func testAbsenceKindWithoutARecomputableBasisIsRefused() throws {
        // ① 「没出现」类不带口径 ⇒ 拒
        XCTAssertThrowsError(try makeDiscovery(.suspendedCommitment, object: "p7"),
                             "「承诺悬置」没有可复算口径也进去了 —— 那是无依据推论(R-A 禁止项)")
        // ② 有原话类**带**了口径 ⇒ 也拒(它不该有)
        XCTAssertThrowsError(try makeDiscovery(.attitudeChange, object: "p7", statBasis: "近 6 周未再提及"),
                             "有原话类带着统计口径也进去了 —— 界面标注的依据形态会与内容对不上")
        // ③ 正确的两种组合都能进
        XCTAssertNoThrow(try makeDiscovery(.suspendedCommitment, object: "p7",
                                           statBasis: "近 6 周内该承诺再未被任一说话人提及"))
        XCTAssertNoThrow(try makeDiscovery(.attitudeChange, object: "p7"))
    }

    // MARK: - 批次:默认「未判卷」

    /// 🔴 `verdict` 没有别的默认可选。停止线 3 一次都没验过(`M3-0g`,用户拍板带风险先做)——
    /// 给它一个「达标」的默认值等于替没跑过的判卷撒谎。
    func testABatchIsUnadjudicatedUntilSomebodySaysOtherwise() throws {
        let v = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT verdict FROM generation_batches WHERE batch_id = 'b1'")
        }
        XCTAssertEqual(v, "未判卷")
    }

    // MARK: - 🔴 §3.2.3 第 7 项:认错人之后,人线发现整条撤回

    /// 归属一变,**人线**发现整条撤回;**事线**发现纹丝不动。
    ///
    /// 🔴 这是这一组里最贵的一条。漏了它的表现是:用户把「说话人3」纠正成别人之后,
    /// 那条「他连续 4 次提到交付时间」**还挂在原来那个人的档案上** ——
    /// 数字还是 4,原话还能点开,只是主语错了。没有任何东西会报错。
    func testCorrectingASpeakerWithdrawsPersonDiscoveriesButNotMatterOnes() throws {
        let personSide = try makeDiscovery(.repeatedConcern, object: "p7", evidenceLines: [10])
        let matterSide = try makeDiscovery(.argumentShift, object: "m1", evidenceLines: [10])

        _ = try AssignSpeaker.assignSpeaker(lines: [10], person: 7, clusterTag: nil,
                                            source: .userConfirmed, confidence: nil,
                                            actor: .user, now: now, in: dbQueue)

        XCTAssertNotNil(try withdrawnAt(personSide), "人线发现没被撤回 —— 主语可能已经错了")
        XCTAssertNil(try withdrawnAt(matterSide),
                     "事线发现被连坐撤回了 —— 它一个字都不提「谁说的」,归属变了它不变")
    }

    /// 只撤**引了这条行**的那些。不相干的发现不许被扫到。
    func testAnUnrelatedPersonDiscoveryIsLeftAlone() throws {
        let touched = try makeDiscovery(.repeatedConcern, object: "p7", evidenceLines: [10])
        let untouched = try makeDiscovery(.repeatedConcern, object: "p8", evidenceLines: [11])

        _ = try AssignSpeaker.assignSpeaker(lines: [10], person: 7, clusterTag: nil,
                                            source: .userConfirmed, confidence: nil,
                                            actor: .user, now: now, in: dbQueue)

        XCTAssertNotNil(try withdrawnAt(touched))
        XCTAssertNil(try withdrawnAt(untouched), "没引这条行的发现也被撤了 —— 每纠正一个人就清一片")
    }

    /// 幂等:再纠正一次,已撤回的时间戳不许被覆盖。
    ///
    /// 覆盖了的后果是「这条是什么时候失效的」永远指向最后一次纠正,审计链就断了。
    func testWithdrawingTwiceKeepsTheFirstTimestamp() throws {
        let d = try makeDiscovery(.repeatedConcern, object: "p7", evidenceLines: [10])
        _ = try AssignSpeaker.assignSpeaker(lines: [10], person: 7, clusterTag: nil,
                                            source: .userConfirmed, confidence: nil,
                                            actor: .user, now: now, in: dbQueue)
        let first = try withdrawnAt(d)
        XCTAssertNotNil(first)

        _ = try AssignSpeaker.assignSpeaker(lines: [10], person: 8, clusterTag: nil,
                                            source: .userConfirmed, confidence: nil,
                                            actor: .user, now: now, in: dbQueue)
        XCTAssertEqual(try withdrawnAt(d), first, "第二次纠正把撤回时间覆盖了 —— 审计链断在这里")
    }
}
