import XCTest
import GRDB
@testable import GrowthApp

/// 会话之间的切换(M2-B6)。
///
/// M1 的问问只有一段对话:`load()` 永远续最近那一个。这一组守的是**切换**本身,
/// 而切换有一个会静默出错的地方 —— 见 `testStartingANewOneSurvivesAReload`。
@MainActor
final class AskConversationSwitchTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let t0 = "2026-08-17T09:00:00+08:00"
    private let t1 = "2026-08-18T09:00:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
    }
    override func tearDownWithError() throws { dbQueue = nil }

    @discardableResult
    private func seed(_ question: String, at now: String) throws -> Int64 {
        try dbQueue.write { db in
            let c = try AskStore.open(now: now, in: db)
            _ = try AskStore.askBegin(conversation: c, question: question, now: now, in: db)
            return c
        }
    }

    // MARK: - 续上最近那段(M1 已有的行为,别改坏)

    func testLoadOpensUniqueMainAndKeepsExistingChatsAsTopics() async throws {
        try seed("第一段问的", at: t0)
        let newer = try seed("第二段问的", at: t1)

        let model = AskViewModel(db: dbQueue)
        await model.load()

        XCTAssertNotEqual(model.currentConversationID, newer)
        XCTAssertTrue(model.isMain)
        XCTAssertEqual(model.conversationTitle, "主聊天")
        XCTAssertTrue(model.turns.isEmpty)
        await model.load()
        let list = try await model.conversations()
        XCTAssertEqual(list.filter(\.isMain).count, 1)
        XCTAssertEqual(list.filter { !$0.isMain }.count, 2, "旧消息必须在话题里可打开")
    }

    // MARK: - 打开历史里的某一段

    func testOpeningAnOlderConversationShowsItsOwnTurns() async throws {
        let older = try seed("第一段问的", at: t0)
        try seed("第二段问的", at: t1)

        let model = AskViewModel(db: dbQueue)
        await model.load()
        await model.openConversation(older)

        XCTAssertEqual(model.currentConversationID, older)
        XCTAssertEqual(model.turns.map(\.question), ["第一段问的"],
                       "打开旧对话之后显示的还是别段的内容")
    }

    // MARK: - 🔴 这一条是这组测试存在的理由

    /// **「开新的一段」之后再 `load()` 一次,不许被续回旧的那段。**
    ///
    /// `load()` 的续接判据是 `conversationID == nil`。如果「开新的一段」只是把 id
    /// 清成 nil,那么下一次 load(切走再切回来、界面重建、`.task` 重跑)就会
    /// **把用户刚开的新对话又续回最近那一段** —— 而他敲的第一句会落进一段几天前的
    /// 对话里,界面上什么异常都看不出来。
    ///
    /// 这就是为什么 `AskViewModel` 里要有 `deliberatelyBlank`:
    /// 「还没挑过」与「用户主动开了新的」不能用同一个值表示。
    func testStartingANewOneSurvivesAReload() async throws {
        try seed("旧的那段", at: t0)

        let model = AskViewModel(db: dbQueue)
        await model.load()
        await model.startNewConversation()
        XCTAssertNil(model.currentConversationID)
        XCTAssertTrue(model.turns.isEmpty)

        // 界面重建 —— `.task` 会再跑一次 load()
        await model.load()

        XCTAssertNil(model.currentConversationID,
                     "开了新的一段,重新 load 之后又被续回旧对话了 —— "
                     + "用户敲的第一句会落进一段几天前的对话里,而界面上看不出来")
        XCTAssertTrue(model.turns.isEmpty, "新的一段里冒出了旧对话的轮次")
    }

    /// 开新的一段**不建库行** —— 建了的话,用户开了又走开就在历史里留下一段
    /// 没有标题、点进去空白的对话(标题是第一轮问题定的)。
    func testStartingANewOneDoesNotCreateARow() async throws {
        try seed("旧的那段", at: t0)
        let model = AskViewModel(db: dbQueue)
        await model.load()
        let before = try await dbQueue.read { try AskStore.conversations(in: $0).count }
        await model.startNewConversation()

        let after = try await dbQueue.read { try AskStore.conversations(in: $0).count }
        XCTAssertEqual(after, before,
                       "「开新的一段」提前建了行 —— 历史里会多出一段没有标题的空对话")
    }

    // MARK: - 读失败不许伪装成「还没问过」

    func testAListingFailureThrowsInsteadOfLookingEmpty() async throws {
        // 把表拆掉造读失败。空列表与读不出来在屏幕上一模一样,
        // 而前者是一句结论 —— 这条断言守的是「别下那个结论」。
        try await dbQueue.write { db in try db.execute(sql: "DROP TABLE ask_conversations") }
        let model = AskViewModel(db: dbQueue)
        do {
            _ = try await model.conversations()
            XCTFail("读不出来却没抛 —— 界面会画成「还没问过什么」")
        } catch {
            // 期望:抛出来,由界面显示原因
        }
    }
}
