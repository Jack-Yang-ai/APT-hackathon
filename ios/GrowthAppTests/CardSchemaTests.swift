import XCTest
import GRDB
@testable import GrowthApp

/// 卡片表与 §3.2.3 第 9 项的级联撤销(`M3-0c` 迁移 v27)。
///
/// 🔴 **这一组的重心在级联那一半。** 清单第 9 项两句话:
/// 「依据失效的卡片自动撤回;**已处理的,其判断记录同步撤销**」——
/// 只做第一句的表现是:卡片从界面消失,而它承载的那次「是这样」还生效着,
/// 「我确认过什么」与「界面上还剩什么」从此分家,而没有任何东西会报错。
final class CardSchemaTests: XCTestCase {

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
                VALUES (10, 1, 0, 0, 1000, '这个方案我不太认同', 0),
                       (11, 1, 1, 1000, 2000, '还是按老办法吧', 9)
                """)
        }
    }

    override func tearDownWithError() throws { dbQueue = nil }

    // MARK: - 造样例

    @discardableResult
    private func makeCard(_ kind: CardTrigger.Kind = .stance, line: Int? = 10) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO cards (kind, object_kind, object_id, session_id, body, quote, line_id, created_at)
                VALUES (?, '事', 'm1', 1, '你说了一个判断,记下来?', '我不太认同', ?, ?)
                """, arguments: [kind.rawValue, line, now])
            return db.lastInsertedRowID
        }
    }

    /// 用户处理了这张卡 —— 写一条真的判断记录。
    @discardableResult
    private func userAnswers(_ card: Int64, _ action: String = "card_accept") throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO judgments (decided_at, actor, action, target_kind, target_id)
                VALUES (?, 'user', ?, 'card', ?)
                """, arguments: [now, action, "\(card)"])
            return db.lastInsertedRowID
        }
    }

    private func liveJudgment(_ card: Int64) throws -> Int64? {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT judgment_id FROM judgment_current
                 WHERE target_kind = 'card' AND target_id = ?
                """, arguments: ["\(card)"])
        }
    }

    private func withdrawnAt(_ card: Int64) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT withdrawn_at FROM cards WHERE id = ?", arguments: [card])
        }
    }

    @discardableResult
    private func correct(_ line: Int, to person: Int64) throws -> AssignResult {
        try AssignSpeaker.assignSpeaker(lines: [LineID(line)], person: person, clusterTag: nil,
                                        source: .userConfirmed, confidence: nil,
                                        actor: .user, now: now, in: dbQueue)
    }

    // MARK: - 闭集与优先级:库里那份就是 Swift 那份

    /// `card_kinds` 逐行等于 `CardTrigger.Kind`,**连优先级一起**。
    ///
    /// 优先级就是队列排序的「重要度」(技术方案 §4.6.2)——
    /// 播错一个数的表现是「某一型永远排不上,而队列每天照样出 B 张」。
    func testSeededCardKindsMatchSwiftRowByRow() throws {
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT kind, priority FROM card_kinds")
        }
        XCTAssertEqual(rows.count, CardTrigger.Kind.allCases.count)
        for k in CardTrigger.Kind.allCases {
            XCTAssertEqual(rows.first { $0["kind"] == k.rawValue }?["priority"], k.priority,
                           "「\(k.rawValue)」的优先级漂了 —— 队列会排错而照样出 B 张")
        }
    }

    /// 闭集外的卡型连写都写不进去。
    func testAKindOutsideTheClosedSetIsRefusedByTheDatabase() throws {
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO cards (kind, object_kind, object_id, body, created_at)
                VALUES ('离职预警卡', '人', 'p7', '越界的一张', ?)
                """, arguments: [self.now])
        })
    }

    // MARK: - §3.2.3 第 9 项前半:自动撤回

    func testCorrectingASpeakerWithdrawsTheCardThatQuotedThatLine() throws {
        let hit = try makeCard(line: 10)
        let miss = try makeCard(line: 11)
        try correct(10, to: 7)
        XCTAssertNotNil(try withdrawnAt(hit))
        XCTAssertNil(try withdrawnAt(miss), "没引这条行的卡也被撤了")
    }

    /// 幂等:第二次纠正不覆盖第一次的撤回时间,也不再写一条 undo。
    func testWithdrawingTwiceNeitherOverwritesNorDoubleUndoes() throws {
        let card = try makeCard()
        try userAnswers(card)
        try correct(10, to: 7)
        let first = try withdrawnAt(card)
        let undoCount = { try self.dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM judgments WHERE action = 'undo' AND target_id = ?
                """, arguments: ["\(card)"]) ?? 0
        } }
        XCTAssertEqual(try undoCount(), 1)

        try correct(10, to: 8)
        XCTAssertEqual(try withdrawnAt(card), first, "撤回时间被第二次纠正覆盖了 —— 审计链断在这里")
        // 🔴 第二次不许再写一条 undo:`judgments(undoes)` 上有唯一索引,
        //    真写了会当场抛 —— 而那是一次**写失败**,整条 assignSpeaker 事务回滚,
        //    表现是「用户纠正不了说话人」,离真因隔着好几跳。
        XCTAssertEqual(try undoCount(), 1, "同一张卡被撤销了两次")
    }

    // MARK: - 🔴 §3.2.3 第 9 项后半:已处理的,判断记录同步撤销

    /// 用户答过的卡被撤回时,那次判断必须**当场失效**。
    ///
    /// 判据不是「库里多了一行」,是 **`judgment_current` 里那条没了** ——
    /// 前者只证明写进去了,后者才证明它真的不生效了。
    func testAnAnsweredCardHasItsJudgmentUndoneWhenWithdrawn() throws {
        let card = try makeCard()
        let answer = try userAnswers(card)
        XCTAssertEqual(try liveJudgment(card), answer, "前提没成立:用户那次判断本来就没生效")

        let result = try correct(10, to: 7)

        XCTAssertNil(try liveJudgment(card),
                     "卡片撤回了,而用户那次判断还生效着 —— 「我确认过什么」与界面分家了")

        // 级联那条要**回链到触发它的那次用户动作**(D5/G2),不是回链到别的什么。
        let row = try dbQueue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT actor, caused_by, undoes FROM judgments
                 WHERE action = 'undo' AND target_kind = 'card' AND target_id = ?
                """, arguments: ["\(card)"])
        }
        XCTAssertEqual(row?["actor"], "system-cascade")
        XCTAssertEqual(row?["undoes"], answer, "撤的不是用户那一条")
        XCTAssertEqual(row?["caused_by"], result.judgmentID,
                       "🔴 回链指错了 —— 审计链会指到一条不相干的判断上,而没有东西会报错")
    }

    /// 没人答过的卡只撤回,**不凭空写一条 undo**。
    ///
    /// 写了的后果是判断库里多出一条「撤销了一个不存在的判断」的记录,
    /// 而判断库是 append-only,清不掉。
    func testAnUntouchedCardIsWithdrawnWithoutFabricatingAnUndo() throws {
        let card = try makeCard()
        try correct(10, to: 7)
        XCTAssertNotNil(try withdrawnAt(card))
        let undos = try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM judgments WHERE action = 'undo' AND target_kind = 'card'
                """) ?? 0
        }
        XCTAssertEqual(undos, 0, "没人答过的卡也写了一条撤销 —— 判断库 append-only,这条清不掉")
    }
}
