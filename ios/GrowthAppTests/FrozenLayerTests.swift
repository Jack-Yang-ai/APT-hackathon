import XCTest
import GRDB
@testable import GrowthApp

/// 冻结层(A1)与全文检索排除规则的单元测试。
///
/// 这里刻意不只跑 happy path:每条「不该发生的事」都构造一次真的去撞,
/// 因为 DDL 级的约束一旦漏写,上层代码是察觉不到的——它只会安静地写成功。
final class FrozenLayerTests: XCTestCase {

    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()          // 内存库
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try TestPeople.seed(in: dbQueue)
        try seed()
    }

    override func tearDownWithError() throws {
        dbQueue = nil
    }

    /// 一场 + 一个转写版本 + 两行:一行正常、一行占位。
    private func seed() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, '2026-08-08T14:00:00+08:00', '2026-08-08', 'recording', 'closed')
                """)
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at, frozen_at)
                VALUES (1, 1, 1, 1, 'step-asr-v1', 'frozen', '2026-08-08T15:00:00+08:00', '2026-08-08T15:00:00+08:00')
                """)
            // seq 0:正常行。seq 1:缺块占位行(§3.1.6 的 is_gap=1)
            try db.execute(sql: """
                INSERT INTO transcript_lines (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, is_gap)
                VALUES (10, 1, 0, 0, 5000, '今天下午三点开会讨论预算', 0, 0),
                       (11, 1, 1, 5000, 35000, '〔此处缺失 30 秒〕', 12, 1)
                """)
        }
    }

    private func ftsHitCount(_ query: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM transcript_lines_fts WHERE transcript_lines_fts MATCH ?
                """, arguments: [query]) ?? -1
        }
    }

    // MARK: - 验收第一条:插入一行后 UPDATE 抛错

    func testUpdateFrozenLineIsRejected() throws {
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "UPDATE transcript_lines SET text = '改掉了' WHERE line_id = 10")
        }, "改冻结行的正文必须被 A1 触发器 ABORT")

        // 落对没落对:确认正文一个字节都没动,而不是「抛了错但也改了」
        let text = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT text FROM transcript_lines WHERE line_id = 10")
        }
        XCTAssertEqual(text, "今天下午三点开会讨论预算")
    }

    func testDeleteFrozenLineIsRejected() throws {
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM transcript_lines WHERE line_id = 10")
        }, "transcript_lines 永不 DELETE")

        let n = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_lines") ?? -1
        }
        XCTAssertEqual(n, 2)
    }

    // MARK: - 验收第二条:is_gap=1 的行搜不到

    /// 照妖镜:先证明索引真的能搜到东西。少了这条,「占位行搜不到」在一个
    /// 彻底坏掉的索引上也会是绿的。
    func testNormalLineIsSearchable() throws {
        XCTAssertEqual(try ftsHitCount("\"开会讨论\""), 1)
    }

    func testGapLineIsNotSearchable() throws {
        XCTAssertEqual(try ftsHitCount("\"此处缺失\""), 0, "占位行不该被搜出来")
    }

    // MARK: - redact 通道(§3.1.7):唯一放行的 UPDATE

    func testRedactChannelIsAllowedAndRemovesFromIndex() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE transcript_lines SET text = '〔已移出记忆〕', redacted = 1 WHERE line_id = 10
                """)
        }

        // 行还在、line_id 还在 —— 引用它的判断记录不悬空(E4)
        let stillThere = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_lines WHERE line_id = 10") ?? -1
        }
        XCTAssertEqual(stillThere, 1)

        // 但搜不到了
        XCTAssertEqual(try ftsHitCount("\"开会讨论\""), 0, "脱敏后不该还能被搜出来")
    }

    /// 借 redact 之名顺手改别的列,必须一起被拒——否则「唯一通道」就是个筛子。
    func testRedactCannotSmuggleOtherColumnChanges() throws {
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE transcript_lines SET text = '〔已移出记忆〕', redacted = 1, seq = 99 WHERE line_id = 10
                """)
        }, "redact 通道只许改 text 与 redacted,顺手改 seq 必须 ABORT")
    }

    /// redacted 只能 0→1。改回 0 等于「把移出记忆撤销」,不是这条通道该干的事。
    func testRedactCannotBeReverted() throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE transcript_lines SET text = '〔已移出记忆〕', redacted = 1 WHERE line_id = 10")
        }
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "UPDATE transcript_lines SET text = '恢复', redacted = 0 WHERE line_id = 10")
        }, "redacted 1→0 必须 ABORT")
    }

    // MARK: - 归属层可重算(§3.1.5):改归属不碰转写

    func testAttributionIsFreelyRewritable() throws {
        // 走唯一入口(B1)。这条测试原来直接 UPDATE line_speakers —— 那时入口还不存在;
        // 入口有了之后再留着直接写,「归属只有一条路可写」这句话就软了。
        RecomputeRegistry.resetToM0Defaults()
        // clusterTag: nil —— 这条测试打的是「改归属不碰转写」,链路里没有分人步骤,
        // 拿不到簇标签。它的写入由 AssignSpeakerTests 那几条专门钉。
        try AssignSpeaker.assignSpeaker(lines: [10], person: 7, clusterTag: nil,
                                        source: .voiceprint,
                                        confidence: 0.9, actor: .user,
                                        now: "2026-08-08T16:00:00+08:00", in: dbQueue)
        // 归属可以改无数次
        try AssignSpeaker.assignSpeaker(lines: [10], person: 9, clusterTag: nil,
                                        source: .userConfirmed,
                                        confidence: nil, actor: .user,
                                        now: "2026-08-08T16:05:00+08:00", in: dbQueue)

        let (person, text) = try dbQueue.read { db -> (Int?, String?) in
            let p = try Int.fetchOne(db, sql: "SELECT person_id FROM line_speakers WHERE line_id = 10")
            let t = try String.fetchOne(db, sql: "SELECT text FROM transcript_lines WHERE line_id = 10")
            return (p, t)
        }
        XCTAssertEqual(person, 9)
        XCTAssertEqual(text, "今天下午三点开会讨论预算", "改归属不该碰转写一个字节")
    }

    /// source 是闭集,写个没登记过的值必须被 CHECK 拦下。
    ///
    /// 这一条**刻意绕过入口直接写**:要打的是 DDL 上的 CHECK 约束,而入口只会发出
    /// 合法值,从入口打不到它。全仓仅此一处直接写 `line_speakers`。
    func testAttributionSourceIsClosedSet() throws {
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO line_speakers (line_id, person_id, source, updated_at)
                VALUES (11, 7, '瞎猜的', '2026-08-08T16:00:00+08:00')
                """)
        })
    }
}
