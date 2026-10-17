import XCTest
import GRDB
@testable import GrowthApp

/// 事列表的展示模型 + 夹具管道(M2-0e)。
final class MatterBoardProjectionTests: XCTestCase {

    /// 定死「今天」——夹具随跑的时间变的话,截图对不上、测试也会在某天自己红。
    private let now = ISO8601DateFormatter.growth.date(from: "2026-08-18T20:00:00+08:00")!

    private func board() throws -> MatterBoardProjection.Board {
        let q = try MatterFixtures.inMemoryBoard(now: now)
        return try q.read { try MatterBoardProjection.board(now: now, in: $0) }
    }

    // MARK: - 分档口径

    /// 「正在动 / 其他活跃 / 沉睡」三档,照 H5 §1.1。
    ///
    /// 这三档的判据图纸**没给**,是 M2-0e 定死的(验收原话:有自由度的口径
    /// 在契约里定死,不留给实现)。所以这条测试守的是那个定义本身。
    func testTheThreeBucketsFollowTheDeclaredWindow() throws {
        let b = try board()
        XCTAssertEqual(b.moving.map(\.title), ["产品到底该定位成什么", "要不要自己做 ASR"],
                       "\(MatterBoardProjection.movingWindowDays) 天内动过的才算「正在动」")
        XCTAssertEqual(b.otherActive.map(\.title), ["招人的节奏怎么定"])
        XCTAssertEqual(b.sleeping.map(\.title), ["办公室要不要换"])
    }

    /// 候选**不进列表**,只让软入口亮起来(§1.1:候选走独立的候选区页)。
    func testCandidatesStayOutOfTheListButLightUpTheEntry() throws {
        let b = try board()
        XCTAssertFalse((b.moving + b.otherActive + b.sleeping).contains { $0.title.contains("复盘") },
                       "候选混进了列表 —— 它该在候选区,不在这一屏")
        XCTAssertTrue(b.hasPendingCandidates, "有候选却没让软入口亮")
    }

    // MARK: - 🔴 局面数字全部派生

    /// 「正在动的 · 4 件」是**算出来的**,不是某一列。
    func testTheActiveCountIsDerivedNotStored() throws {
        let b = try board()
        XCTAssertEqual(b.activeCount, b.moving.count + b.otherActive.count)
        XCTAssertEqual(b.activeCount, 3)
    }

    /// 悬点数按 `closed_at IS NULL` 数,关掉的不算。
    func testClosedQuestionsStopCounting() throws {
        let q = try MatterFixtures.inMemoryBoard(now: now)
        let before = try q.read { try MatterBoardProjection.board(now: now, in: $0) }
        XCTAssertEqual(before.moving.first?.openQuestions, 2)

        try q.write { db in
            try db.execute(sql: """
                UPDATE matter_open_questions SET closed_at = ?
                 WHERE id = (SELECT MIN(id) FROM matter_open_questions)
                """, arguments: ["2026-08-18T21:00:00+08:00"])
        }
        let after = try q.read { try MatterBoardProjection.board(now: now, in: $0) }
        XCTAssertEqual(after.moving.first?.openQuestions, 1,
                       "关掉的悬点还在计数 —— 口径是 closed_at IS NULL 才算悬着")
    }

    /// 🔴 **「从没推进过」不许被算成「今天推进的」。**
    ///
    /// 拿 `created_at` 顶替最近进展是最顺手的写法,而它会让一件从没动过的事
    /// 在列表上显示成刚刚活跃 —— 用户据此判断「该跟进哪件」,那正好是反的。
    func testAMatterWithNoProgressHasNoStalledDaysRatherThanZero() throws {
        let q = try MatterFixtures.inMemoryBoard(now: now)
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO matters (title, state, created_at, updated_at)
                VALUES ('刚立起来还没动过', '活跃', ?, ?)
                """, arguments: ["2026-08-18T19:00:00+08:00", "2026-08-18T19:00:00+08:00"])
        }
        let b = try q.read { try MatterBoardProjection.board(now: now, in: $0) }
        let fresh = try XCTUnwrap((b.moving + b.otherActive).first { $0.title.contains("还没动过") })
        XCTAssertNil(fresh.lastActivityAt, "没有脉络却报了一个活动时间")
        XCTAssertNil(fresh.stalledDays, "「从没推进过」被算成了 0 天 —— 那是「今天刚推进」的意思")
        XCTAssertTrue(b.otherActive.contains { $0.title.contains("还没动过") },
                      "没动静的该落在「其他活跃」,不是「正在动」")
    }

    // MARK: - 🔴 夹具走真 DDL,不是手写 JSON

    /// 夹具库里跑的是**真迁移**,所以库表一改这里就会红 ——
    /// 而手写 JSON 夹具想写什么字段就有什么字段,直到联调那天才炸(M1-17 的成因)。
    func testFixturesRunTheRealMigrationSoSchemaDriftIsCaught() throws {
        let q = try MatterFixtures.inMemoryBoard(now: now)
        try q.read { db in
            XCTAssertTrue(try db.tableExists("matters"))
            XCTAssertTrue(try db.tableExists("matter_open_questions"))
            XCTAssertTrue(try db.tableExists("matter_timeline"))
        }
        // 真迁移意味着**触发器也在**:夹具库里非法流转同样写不进去。
        // (读块之外做 —— GRDB 的库方法不可重入,嵌进 `read` 里会直接 fatalError。)
        XCTAssertThrowsError(try q.write { db in
            try db.execute(sql: "UPDATE matters SET state = '候选' WHERE state = '活跃'")
        }, "夹具库没带上流转闸 —— 那它就不是「真 DDL」")
    }

    // MARK: - 🔴 写侧桩必抛,绝不 no-op

    /// 契约日的桩每一个动作都抛。
    ///
    /// no-op 的形态是:用户点「单独盯着它」,界面照常收起卡片、照常给个成功的反馈,
    /// 而**库里什么都没发生** —— 下次打开又冒出来,而他以为已经处理过了。
    func testEveryStubbedActionThrowsInsteadOfSilentlyDoingNothing() {
        let s = MatterWritingStub()
        XCTAssertThrowsError(try s.promote(nomination: 1, now: "x"))
        XCTAssertThrowsError(try s.dismiss(nomination: 1, now: "x"))
        XCTAssertThrowsError(try s.defer_(nomination: 1, now: "x"))
        XCTAssertThrowsError(try s.close(matter: 1, now: "x"))
        XCTAssertThrowsError(try s.sleep(matter: 1, now: "x"))
        XCTAssertThrowsError(try s.wake(matter: 1, now: "x"))
        XCTAssertThrowsError(try s.closeQuestion(1, now: "x")) { e in
            // 报错要说清「还没接上」和「等谁」,不是一句「失败」。
            //
            // ⚠️ 2026-09-01 换了断言的**落点**,结论一个字没变:任务号从
            // `description` 挪到了 `blockingTask`。原因是 `Notice.error("…\(error)")`
            // 会把 `description` 原样端到用户脸上,而「M2-B2」对用户是零信息
            // (`UICopyTests` 守这一条)。两条纪律都对,错的是它们共用一个字符串。
            XCTAssertEqual((e as? MatterActionFailure)?.blockingTask, "M2-B2",
                           "没说清在等哪个任务:\(e)")
            XCTAssertFalse("\(e)".contains("M2-B2"), "任务号漏进了用户看的那句话:\(e)")
        }
    }

    /// 活跃上限只有一个出处。
    func testTheActiveLimitHasASingleSource() {
        XCTAssertEqual(MatterCapacity.activeLimit, 10, "PRD §4.3.4 容量规则:10 件(初)")
    }
}
