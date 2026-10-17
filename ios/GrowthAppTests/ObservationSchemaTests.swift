import XCTest
import GRDB
@testable import GrowthApp

/// 观察层与人的简报(`M3-0c` 迁移 v28,§3.2.3 清单第 6、7 项)。
///
/// 🔴 **这一组最贵的一条是「旧主人的简报也要失效」**:
/// 归属从 A 改到 B,重算函数跑的时候 `line_speakers` 已经改完了,
/// **A 是谁在那一刻根本查不到** —— 只失效新主人的,A 的简报会一直挂着
/// 一句不再属于他的话,而没有任何东西会报错。
final class ObservationSchemaTests: XCTestCase {

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
                VALUES (10, 1, 0, 0, 1000, '先看成本再看方案', 0),
                       (11, 1, 1, 1000, 2000, '交付时间还是太紧', 8)
                """)
            try db.execute(sql: """
                INSERT INTO generation_batches (batch_id, producer, prompt_version, model_id, created_at)
                VALUES ('b1', '观察', 'observation/v1', 'deepseek-v4-flash', '2026-08-25T15:30:00+08:00')
                """)
        }
    }

    override func tearDownWithError() throws { dbQueue = nil }

    @discardableResult
    private func makeObservation(person: Int64, lines: [Int] = [10]) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO person_observations
                  (person_id, statement, occurrence_count, batch_id, created_at)
                VALUES (?, '在 5 件事上都是先问成本再看方案', 5, 'b1', ?)
                """, arguments: [person, self.now])
            let id = db.lastInsertedRowID
            for (i, line) in lines.enumerated() {
                try db.execute(sql: """
                    INSERT INTO observation_evidence (observation_id, line_id, seq) VALUES (?, ?, ?)
                    """, arguments: [id, line, i])
            }
            return id
        }
    }

    private func withdrawnAt(_ id: Int64) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT withdrawn_at FROM person_observations WHERE id = ?",
                                arguments: [id])
        }
    }

    private func seedBrief(_ person: Int64, line: Int) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO person_brief (person_id, last_met_session_id, last_topic,
                                          last_topic_line_id, updated_at)
                VALUES (?, 1, '成本与方案', ?, ?)
                """, arguments: [person, line, self.now])
        }
    }

    private func briefCount() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM person_brief") ?? -1 }
    }

    @discardableResult
    private func correct(_ line: Int, to person: Int64) throws -> AssignResult {
        try AssignSpeaker.assignSpeaker(lines: [LineID(line)], person: person, clusterTag: nil,
                                        source: .userConfirmed, confidence: nil,
                                        actor: .user, now: now, in: dbQueue)
    }

    // MARK: - 「我自己」不是魔数

    /// `person_id = -1` 是 `persons` 里一条**真行**,不是约定出来的哨兵值。
    ///
    /// 这条钉住的是:关于我的观察与关于别人的观察走**同一张表、同一个外键** ——
    /// 哪天有人把「我」的观察挪去别的地方,外键这一侧会先说话。
    func testTheSelfObservationUsesARealForeignKeyNotASentinel() throws {
        let me = try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT name, source FROM persons WHERE id = ?",
                             arguments: [MatterSituation.mePersonID])
        }
        XCTAssertEqual(me?["source"], "本人", "`persons` 里没有「我」那一行 —— -1 就真成魔数了")
        XCTAssertNoThrow(try makeObservation(person: MatterSituation.mePersonID))
        // 不存在的人写不进去
        XCTAssertThrowsError(try makeObservation(person: 99999))
    }

    // MARK: - 第 7 项后半:依据失效的整条撤回

    /// 认错人 ⇒ 引了那条行的观察整条撤回;**关于我的和关于别人的一视同仁**。
    func testCorrectingASpeakerWithdrawsObservationsAboutAnyone() throws {
        let aboutOther = try makeObservation(person: 7, lines: [10])
        let aboutMe = try makeObservation(person: MatterSituation.mePersonID, lines: [10])
        let untouched = try makeObservation(person: 7, lines: [11])

        try correct(10, to: 8)

        XCTAssertNotNil(try withdrawnAt(aboutOther))
        XCTAssertNotNil(try withdrawnAt(aboutMe),
                        "关于我的观察没被撤 —— 它一样是「这个人做过 X N 次」,认错人就整条失效")
        XCTAssertNil(try withdrawnAt(untouched), "没引这条行的观察也被撤了")
    }

    /// 幂等:第二次纠正不覆盖第一次的撤回时间。
    func testWithdrawingTwiceKeepsTheFirstTimestamp() throws {
        let o = try makeObservation(person: 7, lines: [10])
        try correct(10, to: 7)
        let first = try withdrawnAt(o)
        XCTAssertNotNil(first)
        try correct(10, to: 8)
        XCTAssertEqual(try withdrawnAt(o), first)
    }

    // MARK: - 🔴 第 6 项:简报是缓存,归属一变整表失效

    /// **旧主人的简报也必须失效。**
    ///
    /// 这是这一组的重心。行 10 原本挂在 7 上,改到 8 之后:
    /// · 8 的简报脏了(多了一句)—— 只失效新主人的话,这一条能过;
    /// · **7 的简报也脏了(少了一句)** —— 而重算跑的时候 `line_speakers` 已经改完,
    ///   7 是谁在那一刻查不到。只按新主人失效,7 的简报会一直挂着一句不再属于他的话。
    /// ⇒ 所以是**整表失效**,而这条测试就是钉住「整表」这两个字。
    func testCorrectingASpeakerInvalidatesTheOldOwnersBriefToo() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO line_speakers (line_id, person_id, source, updated_at)
                VALUES (10, 7, '用户确认', ?)
                """, arguments: [self.now])
        }
        try seedBrief(7, line: 10)      // 旧主人
        try seedBrief(8, line: 11)      // 新主人
        XCTAssertEqual(try briefCount(), 2)

        try correct(10, to: 8)

        XCTAssertEqual(try briefCount(), 0,
                       "旧主人的简报还留着 —— 它挂着一句不再属于他的话,而没有东西会报错")
    }

    /// 没有归属改动就不要动缓存 —— 每次打开都清一遍缓存,缓存就白存了。
    func testNoAttributionChangeLeavesTheBriefCacheAlone() throws {
        try seedBrief(7, line: 10)
        try dbQueue.write { db in _ = try RecomputeRegistry.run(db, lines: [], triggeredBy: 1) }
        XCTAssertEqual(try briefCount(), 1, "什么都没改也把缓存清了 —— 那这层缓存不如不做")
    }
}
