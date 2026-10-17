import XCTest
import GRDB
@testable import GrowthApp

/// 卡片写侧(`M3-B2`)。**每一条都是照着「漏了会怎样」写的**,不是照着接口列的。
///
/// 🔴 写侧最贵的失败形态是**静默成功**:库里记了一笔、界面收起来了,
/// 而那条判断此后再也没被任何视图读到。所以下面既验「写没写进去」,
/// 也验「读侧读不读得回来」—— 只验前者的话,写侧改个 action 拼写就全绿着漂走了。
final class CardStoreTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private var store: CardStore!
    private let now = "2026-08-26T15:30:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        store = CardStore(writer: dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, ?, '2026-08-26', ?, ?)
                """, arguments: [self.now, SessionBridge.Source.recording,
                                 SessionBridge.Status.closed])
            try db.execute(sql: """
                INSERT INTO matters (id, title, state, created_at, updated_at)
                VALUES (1, '产品定位', '活跃', ?, ?)
                """, arguments: [self.now, self.now])
        }
    }

    override func tearDownWithError() throws { dbQueue = nil; store = nil }

    // MARK: - 造样例

    @discardableResult
    private func card(_ kind: CardTrigger.Kind = .stance, withdrawn: Bool = false) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO cards (kind, object_kind, object_id, session_id, body, quote,
                                   created_at, withdrawn_at)
                VALUES (?, '事', '1', 1, '你表了个态,记下来?', '我不太认同', ?, ?)
                """, arguments: [kind.rawValue, self.now, withdrawn ? self.now : nil])
            return db.lastInsertedRowID
        }
    }

    private func state(_ id: Int64) throws -> CardQueueProjection.State {
        try dbQueue.read { db in
            try XCTUnwrap(CardQueueProjection.fetch(db).first { $0.id == id }).state
        }
    }

    private func judgmentCount(on id: Int64) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM judgments WHERE target_kind = 'card' AND target_id = ?
                """, arguments: [String(id)]) ?? 0
        }
    }

    // MARK: - 四个出口都要能被读侧读回来

    func testEveryExitRoundTripsThroughTheProjection() throws {
        // 🔴 **这条钉的是写侧与读侧用同一份 action 名。**
        // 写侧自己敲一遍字符串、拼错一个字母的表现是:判断写进去了,
        // 而读侧把它当成「没判断过」⇒ 这张卡照常再推一次。
        for (exit, expected) in [("accept", CardQueueProjection.State.accepted),
                                 ("decline", .declined),
                                 ("hold", .held),
                                 ("wrongQuestion", .wrongQuestion)] {
            let id = try card()
            switch exit {
            case "accept":   try store.accept(card: id, now: now)
            case "decline":  try store.decline(card: id, now: now)
            case "hold":     try store.hold(card: id, now: now)
            default:         try store.wrongQuestion(card: id, now: now)
            }
            XCTAssertEqual(try state(id), expected, "\(exit) 落库了但读侧读不回来")
        }
    }

    // MARK: - 幂等(判 11)

    func testSameStateTwiceWritesOnlyOnce() throws {
        let id = try card()
        try store.hold(card: id, now: now)
        try store.hold(card: id, now: now)
        // 不挡的话审计链里会多出一次用户从没做过的决定,而界面完全正常
        // (`judgment_current` 只取最新那条)。
        XCTAssertEqual(try judgmentCount(on: id), 1)
        XCTAssertEqual(try state(id), .held)
    }

    func testChangingYourMindStillWrites() throws {
        // 幂等闸只挡「与当前态一致」,改主意必须写得进去。
        let id = try card()
        try store.hold(card: id, now: now)
        try store.accept(card: id, now: now)
        XCTAssertEqual(try judgmentCount(on: id), 2)
        XCTAssertEqual(try state(id), .accepted)
    }

    // MARK: - 判断不许落在看不见的对象上

    func testJudgingAGhostCardThrowsAndWritesNothing() throws {
        XCTAssertThrowsError(try store.accept(card: 9_999, now: now)) {
            guard case CardStore.Failure.noSuchCard = $0 else {
                return XCTFail("应该是 noSuchCard,实际 \($0)")
            }
        }
        XCTAssertEqual(try judgmentCount(on: 9_999), 0)
    }

    func testWithdrawnCardRefusesJudgment() throws {
        // §4.6.4:事结案 ⇒ 名下的卡自动撤回。此后再落判断 = 判断落在
        // 一个用户已经看不到的对象上,而它会一直躺在审计链里。
        let id = try card(withdrawn: true)
        XCTAssertThrowsError(try store.accept(card: id, now: now)) {
            guard case CardStore.Failure.withdrawn = $0 else {
                return XCTFail("应该是 withdrawn,实际 \($0)")
            }
        }
        XCTAssertEqual(try judgmentCount(on: id), 0)
    }

    // MARK: - 就地可改

    func testEditBodyLeavesTheQuoteUntouchedAndConfirms() throws {
        let id = try card()
        try store.editBody(card: id, to: "你更倾向先做减法", now: now)
        let row = try dbQueue.read { db in
            try XCTUnwrap(Row.fetchOne(db, sql: "SELECT body, quote FROM cards WHERE id = ?",
                                       arguments: [id]))
        }
        XCTAssertEqual(row["body"] as String?, "你更倾向先做减法")
        // 🔴 原话是冻结层引来的,一个字都不许动。
        XCTAssertEqual(row["quote"] as String?, "我不太认同")
        XCTAssertEqual(try state(id), .accepted, "「改完即确认」(PRD §4.6.2)")
    }

    func testEditingAnAlreadyAcceptedCardStillRecordsTheNewText() throws {
        // 🔴 改正文**不吃幂等闸**:态没变,但他确认的那句话变了。
        // 吃了的话,判断库里那条 `card_accept` 还指着旧正文,
        // 而审计链要答的正是「他确认的是哪句话」。
        let id = try card()
        try store.accept(card: id, now: now)
        try store.editBody(card: id, to: "改了一版", now: now)
        XCTAssertEqual(try judgmentCount(on: id), 2)
    }

    // MARK: - 合并卡的批量出口

    func testHoldAllIsAllOrNothing() throws {
        let a = try card(), b = try card()
        // 中间夹一个不存在的 id:整批必须一条都不落。
        XCTAssertThrowsError(try store.holdAll(cards: [a, 9_999, b], now: now))
        XCTAssertEqual(try judgmentCount(on: a), 0, "事务没回滚 ⇒ 前面几条留在了库里")
        XCTAssertEqual(try judgmentCount(on: b), 0)

        try store.holdAll(cards: [a, b], now: now)
        XCTAssertEqual(try state(a), .held)
        XCTAssertEqual(try state(b), .held)
    }

    // MARK: - 就地可改要留下「改动前」(M2-审26 对抗审查·必须修 1)

    func testEditBodyRecordsBeforeAndAfterInThePayload() throws {
        // PRD §5.3:「就地改了系统的措辞 → 记录改动前后的差异,作为该类抽取的负例」。
        // 原地覆盖而 payload 为 NULL 的话,「前」永久丢失且**不可回填**,全程零报错;
        // 而「他确认的是哪句话」这个审计问题也答不出来 —— 两条无 payload 的
        // card_accept 指向同一张被覆盖的卡,彼此不可区分。
        let id = try card()
        try store.editBody(card: id, to: "你更倾向先做减法", now: now)
        let payload = try dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT j.payload FROM judgment_current jc
                  JOIN judgments j ON j.id = jc.judgment_id
                 WHERE jc.target_kind = 'card' AND jc.target_id = ?
                """, arguments: [String(id)])
        }
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(XCTUnwrap(payload).utf8)) as? [String: String])
        XCTAssertEqual(obj["edited_from"], "你表了个态,记下来?")
        XCTAssertEqual(obj["edited_to"], "你更倾向先做减法")
    }

    func testEditBodyRejectsEmptyText() throws {
        // 「改完即确认」+ 空正文 = 一张确认过的空卡。空不是一种改法。
        let id = try card()
        XCTAssertThrowsError(try store.editBody(card: id, to: "  \n", now: now))
        XCTAssertEqual(try judgmentCount(on: id), 0)
        let body = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT body FROM cards WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(body, "你表了个态,记下来?", "正文不许被清掉")
    }

    // MARK: - holdAll 撞上已撤回的卡(M2-审26 对抗审查·建议改 2)

    func testHoldAllSkipsWithdrawnCardsButKeepsTheRest() throws {
        // 合并卡已渲染在屏上,期间事结案级联撤回了其中一张 —— 用户点「都先放着」。
        // 撤回是**正常的业务结局**(CardStore 自己的注释就这么写):整批不该因它失败,
        // 那张跳过(它已不在任何队列里,held 与否没有意义),其余照落。
        // 野 id 仍然整批回滚 —— 那是调用方 bug,不是业务结局。
        let a = try card(), w = try card(withdrawn: true), b = try card()
        try store.holdAll(cards: [a, w, b], now: now)
        XCTAssertEqual(try state(a), .held)
        XCTAssertEqual(try state(b), .held)
        XCTAssertEqual(try judgmentCount(on: w), 0, "撤回的卡不该收到判断")
    }

    // MARK: - quote 是冻结层的复制品,要物理防线(M2-审26 对抗审查·建议改 3)

    func testQuoteIsPhysicallyFrozen() throws {
        // 「一个字都不许动」写在注释里不算守住(复核清单 §五)。
        // 冻结层本体 transcript_lines 有 no_update 触发器,这份复制品也要有 ——
        // 否则未来任何 UPDATE cards SET quote=? 都零报错,卡上的「逐字原话」不再逐字。
        let id = try card()
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "UPDATE cards SET quote = '改掉了' WHERE id = ?", arguments: [id])
        })
        // body / pushed_at / withdrawn_at 的正常更新不受牵连(误伤面为零)。
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE cards SET body = 'x', pushed_at = ? WHERE id = ?",
                           arguments: [now, id])
        }
    }

    // MARK: - 追问

    func testAskBackStillThrows() throws {
        // 对话层(PRD §4.7)不在 M3。写一条判断然后返回 = 假装对话存在。
        let id = try card()
        XCTAssertThrowsError(try store.askBack(card: id, now: now))
        XCTAssertEqual(try judgmentCount(on: id), 0)
    }

    // MARK: - §5.3 学习闭环:三次「问得不对」停用该卡型

    func testThreeWrongQuestionsDisableTheKind() throws {
        for _ in 0..<CardProducer.wrongQuestionDisableAt {
            try store.wrongQuestion(card: try card(.stance), now: now)
        }
        let disabled = try dbQueue.read { try CardProducer.disabledKinds(in: $0) }
        XCTAssertTrue(disabled.contains(CardTrigger.Kind.stance.rawValue))
        // 只按掉这一型,别的型不受牵连。
        XCTAssertFalse(disabled.contains(CardTrigger.Kind.closing.rawValue))
    }

    func testUndoingAWrongQuestionBringsTheKindBack() throws {
        // 🔴 这条钉的是「数 `judgment_current`,不数 `judgments`」。
        // 数 append-only 的原始表,撤销之后计数不会减回去 ——
        // 而停用是不可见的:表现只是「这类卡再也没出现过」。
        var last: Int64 = 0
        for _ in 0..<CardProducer.wrongQuestionDisableAt {
            let id = try card(.stance)
            try store.wrongQuestion(card: id, now: now)
            last = id
        }
        XCTAssertTrue(try dbQueue.read { try CardProducer.disabledKinds(in: $0) }
                        .contains(CardTrigger.Kind.stance.rawValue))
        try dbQueue.write { db in
            let jid = try Int64.fetchOne(db, sql: """
                SELECT id FROM judgments WHERE target_kind = 'card' AND target_id = ?
                """, arguments: [String(last)])
            try db.execute(sql: """
                INSERT INTO judgments (decided_at, actor, caused_by, undoes, action,
                                       target_kind, target_id)
                VALUES (?, 'user', NULL, ?, 'undo', 'card', ?)
                """, arguments: [self.now, jid, String(last)])
        }
        XCTAssertFalse(try dbQueue.read { try CardProducer.disabledKinds(in: $0) }
                        .contains(CardTrigger.Kind.stance.rawValue),
                       "撤销了一次,计数应该减回 2 —— 数原始表就会一直是 3")
    }
}
