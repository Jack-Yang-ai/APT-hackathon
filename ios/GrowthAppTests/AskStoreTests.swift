import XCTest
import GRDB
@testable import GrowthApp

/// 自由提问的对话记录(§4.7.3 / migration v16)。
///
/// 重点不在「存得进读得出」,在四条**出了错也不会有人发现**的事:
/// 失败之后问题还在不在 · 标题会不会随对话漂 · 删除单位是不是「轮」·
/// 进程被杀后「提问中」收不收得干净。
final class AskStoreTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-17T17:00:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
    }
    override func tearDownWithError() throws { dbQueue = nil }

    private func openAndAsk(_ q: String) throws -> (conv: Int64, turn: Int64) {
        try dbQueue.write { db in
            let c = try AskStore.open(now: now, in: db)
            let t = try AskStore.askBegin(conversation: c, question: q, now: now, in: db)
            return (c, t)
        }
    }

    // MARK: - G5:失败要保留用户已输入的问题

    /// 🔴 **这一条是 `askBegin` 必须在发请求之前调用的全部理由。**
    ///
    /// G5 要求「失败显示原因与重试,**保留用户已输入的问题**」。
    /// 若实现改成「成功才写库」,这条测试立刻红 —— 而在真机上,
    /// 它表现为「网络一断,刚敲的一大段问题没了」,用户不会再敲第二遍。
    func testAFailedTurnKeepsTheQuestionAndSaysWhy() throws {
        let (conv, turn) = try openAndAsk("他上次到底同意了没有")
        try dbQueue.write { db in
            try AskStore.fail(turn, reason: "云代理没配", now: now, in: db)
        }
        let turns = try dbQueue.read { try AskStore.turns(of: conv, in: $0) }
        XCTAssertEqual(turns.count, 1, "失败把整行删掉了 —— 用户敲的问题没了")
        XCTAssertEqual(turns[0].question, "他上次到底同意了没有")
        XCTAssertEqual(turns[0].status, .failed)
        XCTAssertEqual(turns[0].error, "云代理没配",
                       "只说失败不说原因,用户没法在『网络断了』和『没配』之间分辨")
    }

    // MARK: - 标题

    /// 标题只在第一轮定,**后面不覆盖**。
    /// 用最后一问当标题的话,历史列表会随对话推进不断变样,用户找不回来。
    func testTitleIsFrozenAtTheFirstQuestion() throws {
        let (conv, _) = try openAndAsk("首页结构那次是谁拍的板")
        try dbQueue.write { db in
            _ = try AskStore.askBegin(conversation: conv, question: "那后来改了吗",
                                      now: now, in: db)
        }
        let list = try dbQueue.read { try AskStore.conversations(in: $0) }
        XCTAssertEqual(list.first?.title, "首页结构那次是谁拍的板")
    }

    /// 刚开、还没问的对话**没有标题**,不是「新对话」。
    /// 编一个假标题会让它在历史里和真有内容的混在一起。
    func testAnEmptyConversationHasNoTitleRatherThanAFakeOne() throws {
        try dbQueue.write { db in _ = try AskStore.open(now: now, in: db) }
        XCTAssertNil(try dbQueue.read { try AskStore.conversations(in: $0) }.first?.title)
    }

    // MARK: - 出处

    /// `cited_line_ids` 要原样回来 —— 它既是 G3 的出处链接,也是成本审计。
    func testCitationsRoundTrip() throws {
        let (conv, turn) = try openAndAsk("他反对过吗")
        try dbQueue.write { db in
            try AskStore.answer(turn, text: "反对过。", citedLineIDs: [11, 47, 300],
                                now: now, in: db)
        }
        let t = try dbQueue.read { try AskStore.turns(of: conv, in: $0) }[0]
        XCTAssertEqual(t.citedLineIDs, [11, 47, 300])
        XCTAssertEqual(t.status, .answered)
    }

    /// **空出处是合法的**,它的意思是「一条材料都没检索到」——
    /// 而那时回答应当是「这个我没有记录」(P5),不是编一个。
    /// 所以这里不能因为空就抛,否则上层会被迫伪造一条出处。
    func testNoCitationsIsALegitimateAnswer() throws {
        let (conv, turn) = try openAndAsk("我三年前说过什么")
        try dbQueue.write { db in
            try AskStore.answer(turn, text: "这个我没有记录。", citedLineIDs: [],
                                now: now, in: db)
        }
        XCTAssertEqual(try dbQueue.read { try AskStore.turns(of: conv, in: $0) }[0].citedLineIDs, [])
    }

    // MARK: - 删除单位是「轮」

    func testDeletingOneTurnLeavesTheRestOfTheConversation() throws {
        let (conv, first) = try openAndAsk("第一问")
        try dbQueue.write { db in
            _ = try AskStore.askBegin(conversation: conv, question: "第二问", now: now, in: db)
            try AskStore.deleteTurn(first, in: db)
        }
        let turns = try dbQueue.read { try AskStore.turns(of: conv, in: $0) }
        XCTAssertEqual(turns.map(\.question), ["第二问"])
    }

    /// 删一个不存在的轮要**抛**,不能静默成功 ——
    /// 「删掉了」而其实什么都没删,是本仓反复出现的那种失败。
    func testDeletingAGhostTurnThrows() throws {
        XCTAssertThrowsError(try dbQueue.write { db in try AskStore.deleteTurn(999, in: db) })
    }

    // MARK: - 进程被杀

    /// App 被杀时停在「提问中」的轮子,重启后必须被收掉 ——
    /// 否则界面永远转圈,而请求的回调再也不会来。
    /// 与 `TaskQueue.reclaimInterrupted` 同一个道理。
    func testInterruptedTurnsAreReclaimedOnLaunch() throws {
        let (conv, _) = try openAndAsk("一个永远等不到答案的问题")
        let n = try dbQueue.write { db in try AskStore.reclaimInterrupted(now: now, in: db) }
        XCTAssertEqual(n, 1)
        let t = try dbQueue.read { try AskStore.turns(of: conv, in: $0) }[0]
        XCTAssertEqual(t.status, .failed)
        XCTAssertEqual(t.question, "一个永远等不到答案的问题", "收尾时把问题弄丢了")
        XCTAssertNotNil(t.error, "收掉了但没说为什么")
    }

    /// 已经答完的轮子**不许**被收尾动到。
    func testReclaimDoesNotTouchAnsweredTurns() throws {
        let (_, turn) = try openAndAsk("已经答过的")
        try dbQueue.write { db in
            try AskStore.answer(turn, text: "答案", citedLineIDs: [1], now: now, in: db)
            XCTAssertEqual(try AskStore.reclaimInterrupted(now: now, in: db), 0)
        }
    }

    func testEmptyQuestionIsRejected() throws {
        XCTAssertThrowsError(try dbQueue.write { db in
            let c = try AskStore.open(now: now, in: db)
            _ = try AskStore.askBegin(conversation: c, question: "  \n ", now: now, in: db)
        })
    }
}
