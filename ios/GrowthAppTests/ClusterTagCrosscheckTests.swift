import XCTest
import GRDB
@testable import GrowthApp

/// 「说话人一致」校验在**生产链路上**真的对撞得上(M0-20 验收②)。
///
/// 🔴 **这条测试补的是「只验了一半」。**
/// M0-20 此前只验了①「簇标签写进去了」,没验②「对撞得上」——
/// 而这个缺陷此前的形状**正是「写进去了但对撞不上」**:
/// `ExtractValidate` 那道检查要求 `Line.clusterTag` 非空,
/// 而在簇标签落库之前生产链路上每一行都是 nil ⇒ 那道检查**一次都没触发过**,
/// M0-6 里那条「挂起·簇标签与 speaker_hint 不一致」是拿手写假 JSON 验的。
///
/// 所以这里**不手写 `ExtractValidate.Line`**,而是让数据走完
/// `assignSpeaker` → `ExtractionRunner.lines` 这条真路径再喂给校验。
/// 手写 Line 的话,这条测试会在「生产链路把 clusterTag 丢了」时**照样绿**。
final class ClusterTagCrosscheckTests: XCTestCase {

    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try TestPeople.seed(in: dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status, active_transcript_id)
                VALUES (1, '2026-08-18T10:00:00+08:00', '2026-08-18', 'recording', 'closed', 1)
                """)
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (1, 1, 1, 1, 'stepaudio-2.5-asr', 'frozen', 'x')
                """)
            try db.execute(sql: """
                INSERT INTO transcript_lines
                  (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
                VALUES (100, 1, 0, 0, 5000, '我周三之前把方案发给你,这个没问题', 0),
                       (101, 1, 1, 5000, 9000, '那我这边等你的方案,收到我就开始排期', 0)
                """)
        }
        // 🔴 **走唯一入口写簇标签**,与 `ProcessingPump.writeClusterTags` 同一条路 ——
        // 直接 INSERT `line_speakers` 的话,这条测试就绕过了铁律 3 守着的那段。
        _ = try AssignSpeaker.assignSpeaker(
            lines: [100], person: nil, clusterTag: "speaker_0",
            source: .systemOrganized, confidence: 0.90, actor: .system,
            now: "2026-08-18T10:05:00+08:00", in: dbQueue)
        _ = try AssignSpeaker.assignSpeaker(
            lines: [101], person: nil, clusterTag: "speaker_1",
            source: .systemOrganized, confidence: 0.90, actor: .system,
            now: "2026-08-18T10:05:00+08:00", in: dbQueue)
    }

    /// 给这两行定下归属。**默认不调** —— 只写簇标签时 `person_id` 是空的,
    /// 而「归属未定」本身就会让条目挂起(那是校验③的前半);
    /// 要单独验「簇标签对不对得上」,得先把前半那条让开。
    ///
    /// ⚠️ `clusterTag: nil` 是刻意的:入口用 COALESCE 保住原来的簇标签,
    /// 而簇标签正是这项校验的证据,不该被这一步顶掉。
    private func settleAttribution() throws {
        for (line, person) in [(Int64(100), Int64(7)), (Int64(101), Int64(8))] {
            _ = try AssignSpeaker.assignSpeaker(
                lines: [line], person: person, clusterTag: nil,
                source: .userConfirmed, confidence: nil, actor: .user,
                now: "2026-08-18T10:10:00+08:00", in: dbQueue)
        }
    }

    override func tearDownWithError() throws { dbQueue = nil }

    private func lines() throws -> [ExtractValidate.Line] {
        try dbQueue.read { try ExtractionRunner.lines($0, transcriptID: 1) }
    }

    /// 一份形状合法的抽取产出,`speaker_hint` 由调用方指定。
    private func payload(hint: String) -> [String: Any] {
        [
            "one_liner": "定了方案的交付时间",
            "key_points": [],
            "commitments": [[
                "what": "把方案发给对方", "to_whom_text": "对方",
                "quote": "我周三之前把方案发给你", "line_id": 100,
                "speaker_hint": hint,
            ]],
            "stances": [], "pendings": [], "topic_keys": [],
        ]
    }

    // MARK: - 前提:簇标签真的走到了校验那一侧

    /// 这条先立住,否则下面两条都是空转 —— 如果生产查询丢了 `cluster_tag`,
    /// 「不一致」永远判不出来,而那时**两条断言都会绿**(都走不到那个分支)。
    func testTheProductionQueryCarriesTheClusterTag() throws {
        let ls = try lines()
        XCTAssertEqual(ls.count, 2)
        XCTAssertEqual(ls.first { $0.lineID == 100 }?.clusterTag, "speaker_0",
                       "生产链路把 cluster_tag 丢了 —— 「说话人一致」这项校验会永远不触发")
        XCTAssertEqual(ls.first { $0.lineID == 101 }?.clusterTag, "speaker_1")
    }

    // MARK: - 验收②:对撞得上

    /// 🔴 **故意把 `speaker_hint` 改成别的簇 → 必须判成挂起。**
    ///
    /// 它补的是「模型挂错行」:模型看到的是 speaker_1 说的那句,
    /// 却把承诺记到了 speaker_0 的行上。不挡的话,一条承诺会落到错的人名下,
    /// 而那正是本仓最贵的失误(漏掉承诺是纪要最贵的失误,记错人比漏掉更糟)。
    func testAMismatchedSpeakerHintIsHeldForReview() throws {
        try settleAttribution()
        let (clean, stats) = try ExtractValidate.validate(payload(hint: "speaker_1"),
                                                          lines: try lines())
        XCTAssertEqual(stats.pending, 1, "簇标签对不上却没被判挂起")
        XCTAssertEqual(stats.discarded, 0, "挂起不是丢弃 —— 归属到位后它要能自己出现")
        XCTAssertEqual(stats.pendingReasons["簇标签与 speaker_hint 不一致"], 1)

        // 挂起的条目**保留在产出里**并带 pending 标记(§4.2)
        let commitments = try XCTUnwrap(clean["commitments"] as? [[String: Any]])
        XCTAssertEqual(commitments.count, 1)
        XCTAssertEqual(commitments[0]["pending"] as? Bool, true)
        // `speaker_hint` 只用于校验、**永不落库**
        XCTAssertNil(commitments[0]["speaker_hint"], "speaker_hint 漏进了产出")
    }

    /// 归属还没定时**本来就挂起**(校验③的前半)——
    /// 上面几条要先把归属定下来,才验得到「簇标签对不对得上」那后半。
    /// 两半共用一个「挂起」的出口,不分开测的话,一个恒真的实现也能全绿。
    func testAnUnattributedLineIsAlreadyPendingBeforeAnyHintCheck() throws {
        let (_, stats) = try ExtractValidate.validate(payload(hint: "speaker_0"),
                                                      lines: try lines())
        XCTAssertEqual(stats.pending, 1)
        XCTAssertNil(stats.pendingReasons["簇标签与 speaker_hint 不一致"],
                     "挂起的原因记成了「簇标签对不上」,而真实原因是归属未定")
    }

    /// 对得上的时候不许误伤 —— 没有这一条,上面那条可以靠「永远挂起」蒙混过关。
    func testAMatchingSpeakerHintPassesThrough() throws {
        try settleAttribution()
        let (_, stats) = try ExtractValidate.validate(payload(hint: "speaker_0"),
                                                      lines: try lines())
        XCTAssertEqual(stats.pending, 0, "簇标签对得上却被判挂起了")
        XCTAssertEqual(stats.passed, 1)
    }

    /// 模型没给 `speaker_hint` 时**不判挂起** —— 没给不等于给错。
    /// 判挂起的话,一份完全正常的产出会整份卡在复核里。
    func testAMissingSpeakerHintIsNotTreatedAsAMismatch() throws {
        try settleAttribution()
        var p = payload(hint: "speaker_0")
        var c = (p["commitments"] as! [[String: Any]])[0]
        c["speaker_hint"] = nil
        p["commitments"] = [c]
        let (_, stats) = try ExtractValidate.validate(p, lines: try lines())
        XCTAssertEqual(stats.pending, 0)
        XCTAssertEqual(stats.passed, 1)
    }
}
