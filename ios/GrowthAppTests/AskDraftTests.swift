import XCTest
import GRDB
@testable import GrowthApp

@MainActor
final class AskDraftTests: XCTestCase {
    private var db: DatabaseQueue!
    private let stamp = "2026-10-14T10:00:00+08:00"
    override func setUpWithError() throws {
        db = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(db)
        try db.write { try $0.execute(sql: "INSERT INTO sessions(id,started_at,day,source,status) VALUES(1,?,'2026-10-14','watch','closed')", arguments: [stamp]) }
    }

    func testMainDraftAndBackgroundSurviveNewModelAndAgentReopen() async throws {
        let model = AskViewModel(db: db)
        await model.load()
        _ = await model.openMain(attaching: AskScope(sessionID: 1), prefill: "主聊天未发送")
        _ = await model.openMain(preservingBackground: true)
        XCTAssertEqual(model.draft, "主聊天未发送")
        XCTAssertEqual(model.scope, AskScope(sessionID: 1))
        let reopened = AskViewModel(db: db)
        await reopened.load()
        XCTAssertEqual(reopened.draft, "主聊天未发送")
        XCTAssertEqual(reopened.scope, AskScope(sessionID: 1))
        await reopened.clearBackground()
        let cleared = AskViewModel(db: db)
        await cleared.load()
        XCTAssertNil(cleared.scope)
        XCTAssertEqual(cleared.draft, "主聊天未发送")
    }

    func testContextualPrefillPreservesSavedMainDraftAcrossTopicAndRestart() async throws {
        let model = AskViewModel(db: db)
        await model.load()
        model.draft = "  原来没写完的问题\n"
        let now = stamp
        let topic = try await db.write { try AskStore.open(now: now, title: "其它话题", in: $0) }
        await model.openConversation(topic)
        model.draft = "话题自己的草稿"
        let prefill = "这件事下一步怎么做？"
        let opened = await model.openMain(attaching: AskScope(sessionID: 1), prefill: prefill)
        XCTAssertTrue(opened)
        let expected = "  原来没写完的问题\n\n\n" + prefill
        XCTAssertEqual(model.draft, expected)
        _ = await model.openMain(attaching: AskScope(sessionID: 1), prefill: prefill)
        XCTAssertEqual(model.draft, expected, "重复进入同一追问不能重复追加")
        let restored = AskViewModel(db: db)
        await restored.load()
        XCTAssertEqual(restored.draft, expected)
        XCTAssertEqual(restored.scope, AskScope(sessionID: 1))
        await restored.openConversation(topic)
        XCTAssertEqual(restored.draft, "话题自己的草稿")
        let turns = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ask_turns") }
        XCTAssertEqual(turns, 0)
    }

    func testMainNamedTopicAndUnsentTopicKeepSeparateDrafts() async throws {
        let topic = try await db.write { try AskStore.open(now: self.stamp, title: "项目", in: $0) }
        let model = AskViewModel(db: db)
        await model.load()
        model.draft = "主聊天草稿"
        _ = await model.openMain(attaching: AskScope(sessionID: 1), preservingBackground: false)
        await model.openConversation(topic)
        XCTAssertEqual(model.draft, "")
        XCTAssertNil(model.scope)
        model.draft = "项目草稿"
        await model.startNewConversation(title: "新话题")
        XCTAssertEqual(model.draft, "")
        model.draft = "空话题草稿"
        _ = await model.openMain(preservingBackground: true)
        XCTAssertEqual(model.draft, "主聊天草稿")
        XCTAssertEqual(model.scope, AskScope(sessionID: 1))
        await model.openConversation(topic)
        XCTAssertEqual(model.draft, "项目草稿")
        XCTAssertNil(model.scope)
        await model.startNewConversation(title: "新话题")
        XCTAssertEqual(model.draft, "空话题草稿")
        let conversationCount = try await model.conversations().count
        XCTAssertEqual(conversationCount, 2, "未发送的新话题不得创建正式聊天行")
    }

    func testDraftWriteFailureKeepsInputAndReportsError() async throws {
        let model = AskViewModel(db: db)
        await model.load()
        try await db.write { try $0.execute(sql: "CREATE TRIGGER reject_draft BEFORE INSERT ON ask_drafts BEGIN SELECT RAISE(ABORT,'draft failpoint'); END") }
        model.draft = "留在界面上的输入"
        XCTAssertEqual(model.draft, "留在界面上的输入")
        XCTAssertNotNil(model.draftFailure)
        try await db.write { try $0.execute(sql: "DROP TRIGGER reject_draft") }
        model.draft += "继续编辑"
        XCTAssertNil(model.draftFailure)
        let saved = try await db.read { try AskDraftStore.read("main", in: $0) }
        XCTAssertEqual(saved?.text, model.draft)
    }

    func testQuestionWriteFailureCannotClearDraft() async throws {
        let model = AskViewModel(db: db)
        await model.load()
        model.draft = "问题必须保留"
        try await db.write { try $0.execute(sql: "CREATE TRIGGER reject_question BEFORE INSERT ON ask_turns BEGIN SELECT RAISE(ABORT,'ask failpoint'); END") }
        await model.send()
        XCTAssertEqual(model.draft, "问题必须保留")
        XCTAssertTrue(model.readFailure != nil || model.draftFailure != nil)
        let reopened = AskViewModel(db: db)
        await reopened.load()
        XCTAssertEqual(reopened.draft, "问题必须保留")
        let turnCount = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ask_turns") }
        XCTAssertEqual(turnCount, 0)
    }

    func testFailureClearingDraftRollsBackQuestionAtomically() async throws {
        let model = AskViewModel(db: db)
        await model.load()
        model.draft = "清理失败也保留"
        try await db.write { try $0.execute(sql: "CREATE TRIGGER reject_clear BEFORE UPDATE ON ask_drafts WHEN NEW.text='' BEGIN SELECT RAISE(ABORT,'clear failpoint'); END") }
        await model.send()
        XCTAssertEqual(model.draft, "清理失败也保留")
        let text = try await db.read { try AskDraftStore.read("main", in: $0)?.text }
        XCTAssertEqual(text, "清理失败也保留")
        let turnCount = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ask_turns") }
        XCTAssertEqual(turnCount, 0)
    }

    func testDeletedDraftBackgroundBlocksSendButCanBeRemoved() async throws {
        let model = AskViewModel(db: db)
        await model.load()
        _ = await model.openMain(attaching: AskScope(sessionID: 1), prefill: "这份背景")
        _ = try MemoryRemoval.removeSession(1, audioFiles: [], now: stamp, in: db)
        let restored = AskViewModel(db: db)
        await restored.load()
        XCTAssertFalse(restored.canSend)
        XCTAssertNotNil(restored.readFailure)
        await restored.clearBackground()
        XCTAssertTrue(restored.canSend)
        XCTAssertEqual(restored.draft, "这份背景")
    }

    func testFailedDraftReadCannotSwitchMainIntoNewTopic() async throws {
        let model = AskViewModel(db: db)
        await model.load()
        let original = model.currentConversationID
        model.draft = "主聊天必须留下"
        try await db.write { try $0.execute(sql: "ALTER TABLE ask_drafts RENAME TO hidden_drafts") }
        await model.startNewConversation(title: "不能切的")
        XCTAssertEqual(model.currentConversationID, original)
        XCTAssertTrue(model.isMain)
        XCTAssertEqual(model.draft, "主聊天必须留下")
        XCTAssertFalse(model.canSend)
        XCTAssertTrue(model.readFailure != nil || model.draftFailure != nil)
        try await db.write { try $0.execute(sql: "ALTER TABLE hidden_drafts RENAME TO ask_drafts") }
        await model.load()
        XCTAssertTrue(model.canSend)
    }

    func testFailedDraftReadKeepsTopicWhenOpeningMain() async throws {
        let now = stamp
        let topic = try await db.write { try AskStore.open(now: now, title: "项目", in: $0) }
        let model = AskViewModel(db: db)
        await model.load()
        await model.openConversation(topic)
        model.draft = "话题必须留下"
        try await db.write { try $0.execute(sql: "ALTER TABLE ask_drafts RENAME TO hidden_drafts") }
        let opened = await model.openMain(preservingBackground: true)
        XCTAssertFalse(opened)
        XCTAssertEqual(model.currentConversationID, topic)
        XCTAssertFalse(model.isMain)
        XCTAssertEqual(model.draft, "话题必须留下")
        XCTAssertFalse(model.canSend)
    }

    func testNewTopicDraftMovesAtomicallyWithLatestInput() async throws {
        try await db.write { d in
            try AskDraftStore.save("后输入的草稿", revision: 2, scope: nil, key: "new:项目", in: d)
            try d.execute(sql: "UPDATE ask_drafts SET text='' WHERE key='new:项目' AND revision=1")
            try AskDraftStore.move(from: "new:项目", to: "topic:42", in: d)
            XCTAssertNil(try AskDraftStore.read("new:项目", in: d))
            XCTAssertEqual(try AskDraftStore.read("topic:42", in: d)?.text, "后输入的草稿")
        }
        try await db.write { d in
            try AskDraftStore.save("保全原草稿", revision: 1, scope: nil, key: "new:失败", in: d)
            try d.execute(sql: "CREATE TRIGGER reject_move BEFORE INSERT ON ask_drafts WHEN NEW.key='topic:43' BEGIN SELECT RAISE(ABORT,'move failpoint'); END")
        }
        do {
            try await db.write { try AskDraftStore.move(from: "new:失败", to: "topic:43", in: $0) }
            XCTFail("应回滚")
        } catch { }
        let kept = try await db.read { try AskDraftStore.read("new:失败", in: $0)?.text }
        XCTAssertEqual(kept, "保全原草稿")
    }

    func testUnsavedInputCannotBeOverwrittenByAgentOrTopicSwitch() async throws {
        let now = stamp
        let topic = try await db.write { try AskStore.open(now: now, title: "项目", in: $0) }
        let model = AskViewModel(db: db)
        await model.load()
        let main = model.currentConversationID
        model.draft = "旧的已存输入"
        try await db.write { try $0.execute(sql: "CREATE TRIGGER reject_draft BEFORE INSERT ON ask_drafts BEGIN SELECT RAISE(ABORT,'draft failpoint'); END") }
        model.draft = "新的未落盘输入"
        XCTAssertNotNil(model.draftFailure)
        let reopened = await model.openMain(preservingBackground: true)
        XCTAssertFalse(reopened)
        XCTAssertEqual(model.draft, "新的未落盘输入")
        await model.openConversation(topic)
        XCTAssertEqual(model.currentConversationID, main)
        XCTAssertEqual(model.draft, "新的未落盘输入")
        try await db.write { try $0.execute(sql: "DROP TRIGGER reject_draft") }
        await model.openConversation(topic)
        XCTAssertEqual(model.currentConversationID, topic)
        _ = await model.openMain(preservingBackground: true)
        XCTAssertEqual(model.draft, "新的未落盘输入")
    }

    func testSpeakerChangeInvalidatesAnswerAndRejectsLateAnswer() async throws {
        let now = stamp
        let queue = db!
        try await queue.write { d in
            try d.execute(sql: "INSERT INTO transcripts(id,session_id,version,part,asr_model,status,created_at) VALUES(1,1,1,1,'test','frozen',?)", arguments: [now])
            try d.execute(sql: "INSERT INTO transcript_lines(line_id,transcript_id,seq,t_start_ms,t_end_ms,text,char_offset) VALUES(10,1,0,0,1000,'我来处理',0)")
        }
        let ids = try await queue.write { d -> (Int64,Int64,Int64) in
            let main = try AskStore.main(now: now, in: d)
            let done = try AskStore.askBegin(conversation: main, question: "谁来处理", now: now, in: d)
            let sources = try AskScope(sessionID: 1).materials(for: "处理", in: d)
            try AskStore.recordSources(done, materials: sources, history: [], in: d)
            try AskStore.answer(done, text: "原话里的说话人来处理", citedLineIDs: [10], now: now, in: d)
            let late = try AskStore.askBegin(conversation: main, question: "下一步", now: now, in: d)
            try AskStore.recordSources(late, materials: sources, history: [], in: d)
            return (main,done,late)
        }
        RecomputeRegistry.registerM0Defaults()
        _ = try AssignSpeaker.assignSpeaker(lines: [10], person: SpeakerNaming.mePersonID, clusterTag: nil,
            source: .userConfirmed, confidence: nil, actor: .user, now: now, in: queue)
        try await queue.write { d in
            XCTAssertFalse(try AskStore.sourcesAreCurrent(ids.1, in: d))
            XCTAssertThrowsError(try AskStore.answer(ids.2, text: "旧归属的迟到回答", citedLineIDs: [10], now: now, in: d))
            XCTAssertTrue(try AskStore.history(of: ids.0, excluding: ids.2, allowInputSources: true, in: d).isEmpty)
        }
        let model = AskViewModel(db: queue)
        await model.load()
        XCTAssertTrue(model.outdatedAnswerIDs.contains(ids.1))
    }

    func testTargetDraftReadFailurePreservesInitialSelectionAndInput() async throws {
        let now = stamp
        let topic = try await db.write { try AskStore.open(now: now, title: "项目", in: $0) }
        let model = AskViewModel(db: db, prefill: "尚未落盘的输入")
        try await db.write { try $0.execute(sql: "ALTER TABLE ask_drafts RENAME TO hidden_drafts") }
        await model.openConversation(topic)
        XCTAssertNil(model.currentConversationID)
        XCTAssertTrue(model.isMain)
        XCTAssertEqual(model.draft, "尚未落盘的输入")
        XCTAssertNotNil(model.readFailure)
        XCTAssertFalse(model.canSend)
    }

    func testSourceRevisionInvalidatesAnswerEvenWhenOldTextRemainsPrefix() async throws {
        let now = stamp
        let queue = db!
        try await queue.write { d in
            try d.execute(sql: "INSERT INTO transcripts(id,session_id,version,part,asr_model,status,created_at) VALUES(1,1,1,1,'test','frozen',?)", arguments: [now])
            try d.execute(sql: "INSERT INTO transcript_lines(line_id,transcript_id,seq,t_start_ms,t_end_ms,text,char_offset) VALUES(10,1,0,0,1000,'我来处理',0)")
        }
        let id = try await queue.write { d -> Int64 in
            let main = try AskStore.main(now: now, in: d)
            let turn = try AskStore.askBegin(conversation: main, question: "谁来处理", now: now, in: d)
            try AskStore.recordSources(turn, materials: AskScope(sessionID: 1).materials(for: "处理", in: d), history: [], in: d)
            try AskStore.answer(turn, text: "待核的原话", citedLineIDs: [10], now: now, in: d)
            return turn
        }
        _ = try TranscriptRevision.revise(lineID: 10, to: "我来处理？不，我没答应", actor: "用户", now: now, in: queue)
        let current = try await queue.read { try AskStore.sourcesAreCurrent(id, in: $0) }
        XCTAssertFalse(current)
    }
}
