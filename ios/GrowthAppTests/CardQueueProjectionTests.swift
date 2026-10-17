import XCTest
import GRDB
@testable import GrowthApp

/// 卡片五页的展示模型(`M3-0e`)。
///
/// 🔴 **这一组守的三处,漏了都只是「数字/顺序不对」,不会崩**:
/// 合并与取前 B 的次序、同分时的全序、以及那条**禁止项**(没有「全部确认」)。
final class CardQueueProjectionTests: XCTestCase {

    private let now = ISO8601DateFormatter.growth.date(from: "2026-08-25T12:00:00+08:00")!
    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        dbQueue = try CardFixtures.inMemoryQueue(now: now)
    }

    override func tearDownWithError() throws { dbQueue = nil }

    private func queue(budget: Int = 3) throws -> [CardQueueProjection.Merged] {
        try dbQueue.read { db in
            try CardQueueProjection.pushQueue(now: self.now, budget: budget, in: db)
        }
    }

    /// 夹具站得住:六张卡真的进了库。
    func testTheFixtureIsRealAndNotEmpty() throws {
        let n = try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards") ?? 0 }
        XCTAssertEqual(n, 6, "夹具没灌进去 —— 下面每一条都会在空库上「通过」")
    }

    /// 🔴 **合并在排序取前 B 之前。**
    ///
    /// 同一件事同一场次的三张合并成一张、算 1 张预算。
    /// 反过来先取前 B 再合并,`B` 就成了「合并前的张数」——
    /// 用户设了 3 张/天,实际只收到 1 组,而没有任何东西会报错。
    func testMergingHappensBeforeTakingTheBudget() throws {
        let q = try queue(budget: 3)
        let first = try XCTUnwrap(q.first)
        XCTAssertEqual(first.rows.count, 3, "同一对象同一场次的三张没合并")
        XCTAssertEqual(first.budgetCost, 1, "合并后要算 1 张预算(PRD §4.6.2.1)")
        // 三张合并成 1 组 + 另一件事 1 组 = 2 组(地基卡与收尾卡不进队列)
        XCTAssertEqual(q.count, 2, "队列里应当是 2 组:\(q.map(\.id))")
    }

    /// 地基卡默认不推送、收尾卡不占预算即时出 —— **资格问题,不是排序问题**。
    func testFoundationAndWrapUpCardsNeverEnterTheQueue() throws {
        let kinds = try queue(budget: 10).flatMap { $0.rows.map(\.kind) }
        XCTAssertFalse(kinds.contains(CardTrigger.Kind.identity.rawValue),
                       "地基卡进了推送队列 —— PRD §4.6.3 说它默认不推送")
        XCTAssertFalse(kinds.contains(CardTrigger.Kind.wrapUp.rawValue),
                       "收尾卡进了推送队列 —— 它不占预算、即时出")
    }

    /// 🔴 **合并卡的重要度取组内最大,不取平均。**
    ///
    /// 取平均会把一张含「进展确认卡」(序 1)的合并卡拉到「结案卡」后面,
    /// 而它恰恰是最该问的那一张。
    func testAMergedCardTakesTheHighestImportanceNotTheAverage() throws {
        let q = try queue(budget: 10)
        let hot = try XCTUnwrap(q.first { $0.objectID == "1" })
        let cold = try XCTUnwrap(q.first { $0.objectID == "2" })
        XCTAssertEqual(hot.importance, CardTrigger.Kind.progressConfirm.importance,
                       "合并卡没取组内最大 —— 含序 1 的那组被拉下去了")
        XCTAssertGreaterThan(hot.score, cold.score)
        XCTAssertEqual(q.map(\.objectID), ["1", "2"], "排序不对:\(q.map { ($0.objectID, $0.score) })")
    }

    /// 紧急度:关联「正在动的事」⇒ 2,其余 ⇒ 1。
    /// **口径读 `MatterBoardProjection`,不另写一份判据。**
    func testUrgencyFollowsTheMatterBoardDefinitionOfMoving() throws {
        let q = try queue(budget: 10)
        XCTAssertEqual(try XCTUnwrap(q.first { $0.objectID == "1" }).urgency, 2, "今天动过的事没算紧急")
        XCTAssertEqual(try XCTUnwrap(q.first { $0.objectID == "2" }).urgency, 1, "停了 40 天的算成紧急了")
    }

    /// 搁置 = **永不再推送**(PRD §4.6.2),但仍留在页面上。
    func testHeldCardsNeverComeBackToTheQueueButStayOnThePage() throws {
        let target = try XCTUnwrap(try queue(budget: 10).first?.rows.first)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO judgments (decided_at, actor, action, target_kind, target_id)
                VALUES (?, 'user', 'card_hold', 'card', ?)
                """, arguments: [ISO8601DateFormatter.growth.string(from: self.now), "\(target.id)"])
        }
        let ids = try queue(budget: 10).flatMap { $0.rows.map(\.id) }
        XCTAssertFalse(ids.contains(target.id), "搁置过的卡又被推了一次")

        // 但它还在页面上,而且状态是「已先放着」
        let onPage = try dbQueue.read { db in try CardQueueProjection.fetch(db) }
        XCTAssertEqual(onPage.first { $0.id == target.id }?.state, .held,
                       "搁置的卡从页面上消失了 —— PRD 说它永久留在产生它的页面")
    }

    /// 🔴 **同分必须有确定的先后。**
    ///
    /// 不定 tie-break 的后果不是「顺序随便」,是**每次取前 B 张取到的不是同一批** ——
    /// 用户看到的「今天这几张」会漂,而不会有任何东西报错。
    func testTheOrderIsTotalSoRepeatedCallsAgree() throws {
        let a = try queue(budget: 10).map(\.id)
        let b = try queue(budget: 10).map(\.id)
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set(a).count, a.count, "同一组出现了两次")
    }

    /// 场次卡下最多挂 2 张(PRD §4.6.2「呈现量」)。
    func testASessionCardShowsAtMostTwo() throws {
        let shown = try dbQueue.read { db in
            try CardQueueProjection.onSession(1, now: self.now, in: db)
        }
        XCTAssertLessThanOrEqual(shown.count, CardQueueProjection.onSessionLimit)
    }

    /// 🔴 **禁止项:合并卡没有「全部确认」。**
    ///
    /// PRD §4.6.2.1 明写不提供它 —— 批量确认会让用户无脑全选,判断质量直接崩掉。
    /// ⚠️ 禁止项最容易在半年后被「顺手补齐」:一个 `acceptAll` 看起来只是对称性上的缺失。
    /// 所以扫源码,不靠注释。
    func testThereIsNoBulkAccept() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? [])
            .map { (rel: $0.path.replacingOccurrences(of: root.path + "/", with: ""), url: $0) }
            .filter { $0.rel.hasPrefix("GrowthApp/") }
        XCTAssertGreaterThan(files.count, 10, "一个 .swift 都没扫到,这条断言是空转的")

        // ⚠️ 判据就是这三个名字的字面量,**不写正则**。
        // 第一版这里挂了一个 `Regex` 再加一串 `contains` 兜底 —— 照妖镜显示
        // 真正抓住它的是 `contains`,正则那半从头到尾没起作用。
        // **看着在查而实际不查的表达式比没有更糟**:它让这道闸显得比实际强。
        let banned = ["func acceptAll(", "func confirmAll(", "func approveAll("]
        let offenders = try files.filter { f in
            try String(contentsOf: f.url, encoding: .utf8)
                .split(separator: "\n")
                .contains { line in
                    // 注释里提到不算 —— 本文件的类型注释里就写着 `acceptAll`
                    let code = line.range(of: "//").map { String(line[line.startIndex..<$0.lowerBound]) }
                                ?? String(line)
                    return banned.contains { code.contains($0) }
                }
        }.map(\.rel)
        XCTAssertEqual(offenders, [],
                       "合并卡出现了批量确认 —— PRD §4.6.2.1 明写不提供它:"
                       + "批量确认会让用户无脑全选,判断质量直接崩掉。\(offenders)")
    }

    /// 写侧的桩必抛,绝不 no-op。
    func testEveryUnwiredWriteThrows() {
        let w = UnimplementedCardWriting()
        XCTAssertThrowsError(try w.accept(card: 1, now: ""))
        XCTAssertThrowsError(try w.decline(card: 1, now: ""))
        XCTAssertThrowsError(try w.hold(card: 1, now: ""))
        XCTAssertThrowsError(try w.wrongQuestion(card: 1, now: ""))
        XCTAssertThrowsError(try w.askBack(card: 1, now: ""))
        XCTAssertThrowsError(try w.editBody(card: 1, to: "x", now: ""))
        XCTAssertThrowsError(try w.holdAll(cards: [1], now: ""))
    }
}
