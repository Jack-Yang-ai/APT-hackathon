import XCTest
import GRDB
@testable import GrowthApp

/// 卡片产出器(`M3-B2`)。
///
/// 🔴 **验收里那条「造脏数据打自己」在这**:同一立场重复表达三次,断言**只出 0 张卡**。
/// 「重复不出卡」是 §4.6.2.2 整节的立意,而它失效时的表现是
/// **用户被同一件事问三遍** —— 界面完全正常,只是烦人。
final class CardProducerTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-25T18:30:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try TestPeople.seed(in: dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, ?, '2026-08-25', ?, ?)
                """, arguments: [self.now, SessionBridge.Source.recording,
                                 SessionBridge.Status.closed])
            try db.execute(sql: """
                INSERT INTO matters (id, title, state, created_at, updated_at)
                VALUES (1, '产品定位', '活跃', ?, ?), (2, '排期', '已结案', ?, ?),
                       (3, '招人节奏', '活跃', ?, ?)
                """, arguments: [self.now, self.now, self.now, self.now, self.now, self.now])
        }
    }

    override func tearDownWithError() throws { dbQueue = nil }

    // MARK: - 造样例

    private func deps(exclusivity: Bool?) -> CardProducer.Dependencies {
        .init(exclusivityScreen: { _ in exclusivity },
              matterState: { db, id in
                  try String.fetchOne(db, sql: "SELECT state FROM matters WHERE id = ?",
                                      arguments: [id])
              })
    }

    private func fact(matter: String = "1",
                      direction: CardTrigger.Direction? = .oppose) -> CardTrigger.StanceFact {
        .init(topicKey: "产品定位", direction: direction, matterID: matter, premiseKey: nil)
    }

    private func record(direction: CardTrigger.Direction = .oppose,
                        matters: Set<String> = ["1"],
                        premise: String? = nil) -> CardTrigger.StanceRecord {
        .init(direction: direction, premiseKey: premise, matterIDs: matters,
              userJudged: false, judgmentOverturned: false)
    }

    @discardableResult
    private func produce(_ f: CardTrigger.StanceFact, _ rs: [CardTrigger.StanceRecord],
                         exclusivity: Bool? = false) throws -> CardProducer.Outcome {
        try dbQueue.write { db in
            try CardProducer.produce(stance: f, sameTopic: rs, objectKind: "事", sessionID: 1,
                                     body: "你说了一个判断,记下来?", quote: "我不太认同",
                                     lineID: nil, now: self.now,
                                     deps: self.deps(exclusivity: exclusivity), into: db)
        }
    }

    private func cardCount() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards") ?? 0 }
    }

    private func drops() throws -> [String: Int] {
        try dbQueue.read { db in
            var out: [String: Int] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT reason, COUNT(*) n FROM card_drops GROUP BY reason") {
                out[r["reason"]] = r["n"]
            }
            return out
        }
    }

    // MARK: - 🔴 造脏数据打自己(验收原文)

    /// **同一立场重复表达三次 ⇒ 只出 0 张卡。**
    ///
    /// 第一次是「第一次表达」会出立场卡,所以这条测的是**已经记过之后**再说三遍。
    /// 失效时的表现是用户被同一件事问三遍 —— 界面完全正常,只是烦人。
    func testSayingTheSameStanceThreeTimesProducesZeroCards() throws {
        var appended = 0
        for _ in 0..<3 {
            appended += try produce(fact(), [record()]).appended
        }
        XCTAssertEqual(try cardCount(), 0, "重复表达出了卡 —— §4.6.2.2 整节的立意就没了")
        XCTAssertEqual(appended, 3, "三次都该是「静默追加证据」")
    }

    /// 对照:**第一次**表达要出立场卡 —— 否则上面那条可能只是「什么都不出」。
    func testTheFirstTimeAStanceIsExpressedDoesProduceACard() throws {
        let o = try produce(fact(), [])
        XCTAssertEqual(o.emitted.count, 1)
        XCTAssertEqual(try cardCount(), 1)
    }

    // MARK: - 🔴 排他性粗筛:算不出来 ⇒ 不出卡 + 记账

    /// PRD §4.4.6 把「只属于他」标成 **prompt 约束 + 抽样盲测**,不是机械可判 ——
    /// 产出器里算不出来。⇒ **fail-closed**,并且记的理由是「**还没接上**」,
    /// 不是「没过」:前者是缺口,后者是结论,混了就没人知道该去接什么。
    func testAnUnwiredExclusivityScreenBlocksThePrincipleCardAndSaysSo() throws {
        // 跨到第 2 件事 ⇒ 判定会给原则浮现卡
        let o = try produce(fact(matter: "3"), [record(matters: ["1"])], exclusivity: nil)
        XCTAssertTrue(o.emitted.isEmpty, "粗筛还没接就出了原则浮现卡")
        XCTAssertEqual(try drops()[CardTrigger.DropReason.exclusivityUnknown.rawValue], 1,
                       "没记账 —— 那这个缺口就再也没人看得见了")
    }

    /// 🔴 **不许图省事传 `true`**:粗筛过了才出。这条钉的是「传进去的确实被用到」。
    func testThePrincipleCardOnlyAppearsWhenTheScreenActuallyPassed() throws {
        // ⚠️ 跨事要用**活跃**的那件(3)。第一版用了已结案的 2 ⇒ 被
        // 「事已结案不再出卡」那条挡下,红的是夹具不是实现。
        let passed = try produce(fact(matter: "3"), [record(matters: ["1"])], exclusivity: true)
        XCTAssertEqual(passed.emitted.count, 1)
        let kind = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT kind FROM cards WHERE id = ?",
                                arguments: [passed.emitted[0]])
        }
        XCTAssertEqual(kind, CardTrigger.Kind.principleEmerging.rawValue)
    }

    // MARK: - 🔴 M3-0f 挡着的卡型:判定照出,落库挡住

    func testThePremiseOverturnedCardIsJudgedButNotStored() throws {
        let f = CardTrigger.StanceFact(topicKey: "产品定位", direction: .oppose,
                                       matterID: "1", premiseKey: "预算不会批")
        let o = try produce(f, [record(premise: "预算会批")])
        XCTAssertEqual(o.blocked, 1, "前提推翻卡没被挡 —— M3-0f 还没出数")
        XCTAssertEqual(try cardCount(), 0)
        // 判定本身仍然给出了那个卡型(0b 的 8 条测试钉着),这里只验落库那一侧
        XCTAssertTrue(CardTrigger.blockedPendingPremiseRecall.contains(.premiseOverturned))
    }

    // MARK: - §4.6.4 异常

    /// 指向**已结案**的事,不再出卡。
    func testAClosedMatterStopsProducingCards() throws {
        let o = try produce(fact(matter: "2"), [])
        XCTAssertTrue(o.emitted.isEmpty)
        XCTAssertEqual(try drops()["事已已结案,不再出卡"], 1)
    }

    /// 事结案时,它名下**没处理过**的卡自动撤回;**已处理的不动**。
    ///
    /// 🔴 撤掉已处理的等于把用户的判断也一起抹了 —— PRD 说的是「自动撤回,
    /// 不进推送队列」,不是「删掉历史」。
    func testClosingAMatterWithdrawsOnlyTheUnansweredCards() throws {
        let a = try produce(fact(), []).emitted[0]
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO cards (kind, object_kind, object_id, session_id, body, created_at)
                VALUES (?, '事', '1', 1, '另一张', ?)
                """, arguments: [CardTrigger.Kind.nomination.rawValue, self.now])
            let b = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO judgments (decided_at, actor, action, target_kind, target_id)
                VALUES (?, 'user', 'card_accept', 'card', ?)
                """, arguments: [self.now, "\(b)"])
        }
        let n = try dbQueue.write { db in
            try CardProducer.withdrawCards(forClosedMatter: "1", now: self.now, in: db)
        }
        XCTAssertEqual(n, 1, "撤回的张数不对 —— 已处理的那张不该被撤")
        let withdrawn = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT withdrawn_at FROM cards WHERE id = ?",
                                arguments: [a])
        }
        XCTAssertNotNil(withdrawn)
    }

    // MARK: - 两种 drop 都要记账

    /// §3.2:「归一老是失败所以一张卡都没出」与「今天真的没什么可问」
    /// 长得一模一样 —— 不记的话,抽取质量下滑的表现就是界面上安安静静地没有卡片。
    func testBothDropReasonsAreWrittenToTheLedger() throws {
        try produce(fact(direction: nil), [])                       // 归一失败
        try produce(fact(), [.init(direction: .oppose, premiseKey: nil, matterIDs: ["1"],
                                   userJudged: true, judgmentOverturned: false)])  // 已判断过
        let d = try drops()
        XCTAssertEqual(d[CardTrigger.DropReason.normalizationFailed.rawValue], 1)
        XCTAssertEqual(d[CardTrigger.DropReason.alreadyJudged.rawValue], 1)
        XCTAssertEqual(try cardCount(), 0)
    }
}
