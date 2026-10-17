import XCTest
import GRDB
@testable import GrowthApp

/// 发现抽屉与详情的展示模型(`M3-0e`)。
///
/// 🔴 **这一组守的是「派生值算错了不会有东西报错」的那几处**:
/// 首页那句「有 N 条新发现」显示一个谁都解释不了的数、
/// 未经判卷的发现被当成定论呈现 —— 两者都只是「数字不对」,不会崩。
final class DiscoveryDrawerProjectionTests: XCTestCase {

    /// 夹具的时间锚。定死,免得断言随跑的时间变。
    private let now = ISO8601DateFormatter.growth.date(from: "2026-08-25T12:00:00+08:00")!
    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        dbQueue = try DiscoveryFixtures.inMemoryDrawer(now: now)
    }

    override func tearDownWithError() throws { dbQueue = nil }

    private func drawer() throws -> DiscoveryDrawerProjection.Drawer {
        try dbQueue.read { db in try DiscoveryDrawerProjection.drawer(now: self.now, in: db) }
    }

    /// 夹具本身得站得住:真 DDL、五条发现、证据数与 §4.7.4 的门槛一致。
    ///
    /// 没这一条的话,下面每一条都可能是在一个空库上「通过」。
    func testTheFixtureIsRealAndNotEmpty() throws {
        let (all, evidence) = try dbQueue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discoveries") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discovery_evidence") ?? 0)
        }
        XCTAssertEqual(all, 5, "夹具没灌进去 —— 下面每一条都会在空库上「通过」")
        XCTAssertEqual(evidence, 8, "有原话类 3×2 + 「没出现」类 2×1 = 8")
    }

    /// 🔴 **7 天没被触及的降为「旧」,而且不计入「有 N 条新发现」。**
    ///
    /// PRD §4.5.4 明写降为「旧」之后不再计入那个数。把 older 也算进去的后果是
    /// 首页永远挂着一个不降的数字,用户点进去却找不到「新」的东西 ——
    /// 而那正是这个产品刻意不做红点的理由。
    func testStaleDiscoveriesDropOutOfTheFreshCount() throws {
        let d = try drawer()
        XCTAssertEqual(d.fresh.map(\.objectID), ["m1", "p7"], "0/1 天前触及的才算新")
        XCTAssertEqual(d.older.map(\.objectID), ["m2"], "9 天前触及的该在「更早」里")
        XCTAssertEqual(d.freshCount, 2, "「有 N 条新发现」把「旧」的也数进去了")
    }

    /// 沉底的与撤回的都不进抽屉 —— 但**理由不同**,不该被压成同一件事。
    /// 沉底的还在历史里可搜,撤回的是依据没了。
    func testSunkAndWithdrawnAreBothOutOfTheDrawer() throws {
        let d = try drawer()
        let shown = (d.fresh + d.older).map(\.objectID)
        XCTAssertFalse(shown.contains("p8"), "沉底的还挂在抽屉里")
        XCTAssertEqual(shown.filter { $0 == "p7" }.count, 1,
                       "撤回的那条(也挂在 p7 上)还在抽屉里 —— 它的依据已经不成立了")
    }

    /// 🔴 **未判卷的标必须一路带到界面上。**
    ///
    /// 这是 `M3-0g` 那次拍板(「带风险先做」)的兑现物 —— 停止线 3 一次都没验过。
    /// 标掉在半路上,界面就在把未经检验的判断当成定论呈现。
    func testEveryDiscoveryCarriesTheBatchVerdict() throws {
        let d = try drawer()
        XCTAssertTrue(d.fresh.allSatisfy { $0.verdict == "未判卷" }, "未判卷的标掉了")
        XCTAssertTrue(d.fresh.allSatisfy(\.needsCaveat))

        // 判过卷并**达标**之后,提醒才摘掉 —— 而且是**整批**摘,不是逐条
        func setVerdict(_ v: String) throws {
            try dbQueue.write { db in
                try db.execute(sql: "UPDATE generation_batches SET verdict = ? WHERE batch_id = 'b1'",
                               arguments: [v])
            }
        }
        try setVerdict("达标")
        XCTAssertTrue(try drawer().fresh.allSatisfy { !$0.needsCaveat })

        // 🔴 **「未达标」同样要加提醒。**
        // 判据写成 `== "未判卷"` 的话,一批**判过卷而且没通过**的发现会被当成定论呈现 ——
        // 那比未判卷更糟:它是已知不合格,不是未知。
        try setVerdict("未达标")
        XCTAssertTrue(try drawer().fresh.allSatisfy(\.needsCaveat),
                      "判过卷但没达标的批次被当成定论呈现了 —— 判据写成了「等于未判卷」")
        XCTAssertEqual(try drawer().fresh.first?.verdict, "未达标",
                       "三种取值要能分开 —— 界面上是三句不同的话,压成布尔就再也分不开")
    }

    /// 依据形态要能区分,且「没出现」类必须带可复算口径(§4.7.4)。
    func testTheTwoEvidenceFormsAreDistinguishableOnTheRow() throws {
        let d = try drawer()
        let quoted = d.fresh.first { $0.kind == DiscoveryKind.argumentShift.rawValue }
        let absent = d.older.first { $0.kind == DiscoveryKind.stalledReason.rawValue }
        XCTAssertEqual(quoted?.evidenceForm, DiscoveryKind.EvidenceForm.quotes.rawValue)
        XCTAssertNil(quoted?.statBasis, "有原话类带着统计口径 —— 界面标注会与内容对不上")
        XCTAssertEqual(absent?.evidenceForm, DiscoveryKind.EvidenceForm.absence.rawValue)
        XCTAssertNotNil(absent?.statBasis, "「没出现」类没有可复算口径 —— 那就是无依据推论")
        XCTAssertEqual(quoted?.evidenceCount, 2)
        XCTAssertEqual(absent?.evidenceCount, 1)
    }

    /// 「最近移除」读判断库,24 小时窗口。
    func testRecentlyRemovedReadsTheJudgmentLedgerAndExpires() throws {
        let target = try drawer().fresh[0].id
        let iso = ISO8601DateFormatter.growth
        func dismiss(_ id: Int64, hoursAgo: Int) throws {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO judgments (decided_at, actor, action, target_kind, target_id)
                    VALUES (?, 'user', 'discovery_dismiss', 'discovery', ?)
                    """, arguments: [iso.string(from: self.now.addingTimeInterval(-Double(hoursAgo) * 3600)),
                                     "\(id)"])
            }
        }
        try dismiss(target, hoursAgo: 2)
        var removed = try dbQueue.read { db in
            try DiscoveryDrawerProjection.recentlyRemoved(now: self.now, in: db)
        }
        XCTAssertEqual(removed.map(\.id), [target])

        // 25 小时前移除的另一条 —— 过了找回窗口,不该再出现
        let other = try drawer().fresh[1].id
        try dismiss(other, hoursAgo: 25)
        removed = try dbQueue.read { db in
            try DiscoveryDrawerProjection.recentlyRemoved(now: self.now, in: db)
        }
        XCTAssertEqual(removed.map(\.id), [target], "过了 24 小时还能找回")
    }

    /// 🔴 **写侧的桩必抛,绝不 no-op。**
    ///
    /// no-op 的形态是:用户左滑,发现从界面消失,而库里什么都没发生 ——
    /// 下次打开它又回来了,而用户以为自己已经处理过。
    func testEveryUnwiredWriteThrows() {
        let w = UnimplementedDiscoveryWriting()
        XCTAssertThrowsError(try w.dismiss(discovery: 1, now: ""))
        XCTAssertThrowsError(try w.restore(discovery: 1, now: ""))
        XCTAssertThrowsError(try w.markUseful(discovery: 1, now: ""))
        XCTAssertThrowsError(try w.markWrong(discovery: 1, why: nil, now: ""))
        XCTAssertThrowsError(try w.markRead(discovery: 1, now: ""))
    }
}
