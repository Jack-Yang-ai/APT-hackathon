import XCTest
import GRDB
@testable import GrowthApp

@MainActor
final class AskTopicAndSourceTests: XCTestCase {
    private var db: DatabaseQueue!
    private let now = "2026-10-13T10:00:00+08:00"

    override func setUpWithError() throws {
        db = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(db)
        try db.write { d in
            try d.execute(sql: "INSERT INTO sessions(id,started_at,day,source,status) VALUES(1,?,'2026-10-13','recording','closed'),(2,'2026-10-13T11:00:00+08:00','2026-10-13','recording','closed')", arguments: [now])
            try d.execute(sql: "INSERT INTO transcripts(id,session_id,version,part,asr_model,status,created_at) VALUES(1,1,1,1,'fake','frozen',?),(2,2,1,1,'fake','frozen',?)", arguments: [now, now])
            try d.execute(sql: "INSERT INTO transcript_lines(line_id,transcript_id,seq,t_start_ms,t_end_ms,text,is_gap,char_offset) VALUES(10,1,0,0,1000,'项目A原话',0,0),(20,2,0,0,1000,'项目B原话',0,0)")
        }
    }

    func testMainIsUniqueProtectedAndManualTopicNameSurvivesFirstSend() throws {
        try db.write { d in
            let main = try AskStore.main(now: now, in: d)
            XCTAssertEqual(try AskStore.main(now: now, in: d), main)
            XCTAssertThrowsError(try AskStore.rename(main, title: "改主聊天", in: d))
            XCTAssertThrowsError(try AskStore.archive(main, archived: true, in: d))
            let topic = try AskStore.open(now: now, title: "项目规划", in: d)
            try AskStore.archive(topic, archived: true, in: d)
            _ = try AskStore.askBegin(conversation: topic, question: "第一问不要覆盖手动名", now: now, in: d)
            XCTAssertEqual(try AskStore.conversation(topic, in: d)?.title, "项目规划")
            XCTAssertEqual(try AskStore.conversation(topic, in: d)?.archived, false)
            XCTAssertThrowsError(try AskStore.rename(topic, title: "主聊天", in: d))
            XCTAssertThrowsError(try AskStore.rename(topic, title: String(repeating: "字", count: 13), in: d))
        }
    }

    func testPageBackgroundUsesMainWithoutCreatingTopicAndSurvivesReload() async throws {
        let model = AskViewModel(db: db)
        await model.load()
        let main = model.currentConversationID
        await model.startNewConversation(title: "空话题")
        let before = try await model.conversations()
        XCTAssertEqual(before.count, 1, "未发送的空话题不能落行")
        let opened = await model.openMain(attaching: AskScope(sessionID: 1), prefill: "项目A定了什么？")
        XCTAssertTrue(opened)
        XCTAssertEqual(model.currentConversationID, main)
        XCTAssertEqual(model.scope, AskScope(sessionID: 1))
        XCTAssertEqual(model.draft, "项目A定了什么？")
        await model.load()
        XCTAssertEqual(model.scope, AskScope(sessionID: 1))
        await model.clearBackground()
        XCTAssertNil(model.scope)
        XCTAssertNil(model.contextLabel)
        let after = try await model.conversations()
        XCTAssertEqual(after.count, 1)
    }

    func testDeletionClearsUncitedDependenciesAndRejectsLateAnswer() throws {
        let (conversation, answered, asking) = try db.write { d -> (Int64, Int64, Int64) in
            let c = try AskStore.main(now: now, in: d)
            let material = try AskScope(sessionID: 1).materials(for: "原话", in: d)
            let first = try AskStore.askBegin(conversation: c, question: "项目A", now: now, in: d)
            try AskStore.recordSources(first, materials: material + material, history: [], in: d)
            try AskStore.answer(first, text: "依据没显式引用的原话", citedLineIDs: [], now: now, in: d)
            let second = try AskStore.askBegin(conversation: c, question: "接着呢", now: now, in: d)
            try AskStore.recordSources(second, materials: [], history: AskStore.turns(of: c, in: d), in: d)
            return (c, first, second)
        }
        _ = try MemoryRemoval.removeLines([10], audioFiles: [], in: db)
        try db.write { d in
            let turns = try AskStore.turns(of: conversation, in: d)
            XCTAssertEqual(turns.map(\.status), [.failed, .failed])
            XCTAssertNil(turns.first?.answer)
            XCTAssertThrowsError(try AskStore.answer(asking, text: "迟到的旧内容", citedLineIDs: [], now: now, in: d))
            XCTAssertNil(try AskStore.sourceText(turnID: answered, lineID: 10, in: d))
        }
    }

    func testDeletedBackgroundBlocksSendAndCanBeCleared() async throws {
        let model = AskViewModel(db: db)
        await model.load()
        _ = try MemoryRemoval.removeSession(1, audioFiles: [], now: now, in: db)
        _ = await model.openMain(attaching: AskScope(sessionID: 1), prefill: "问一下")
        XCTAssertFalse(model.canSend)
        XCTAssertNotNil(model.readFailure)
        await model.clearBackground()
        XCTAssertTrue(model.canSend)
    }

    func testExtractionCannotReinsertContentDeletedDuringModelRequest() async throws {
        let queue = db!
        do {
            _ = try await ExtractionRunner.run(transcriptID: 1, now: now, call: { _ in
                _ = try MemoryRemoval.removeLines([10], audioFiles: [], in: queue)
                return #"{"one_liner":"旧原话派生的内容","key_points":[],"commitments":[],"stances":[],"pendings":[],"topic_keys":[]}"#
            }, in: queue)
            XCTFail("删除后的迟到抽取必须拒绝")
        } catch ExtractionStore.Failure.staleSource { }
        let count = try await queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM summaries") }
        XCTAssertEqual(count, 0)
    }

    func testADeletedPartFinishesLocallyInsteadOfBlockingLaterParts() async throws {
        let queue = db!
        _ = try MemoryRemoval.removeLines([10], audioFiles: [], in: queue)
        _ = try await ExtractionRunner.run(transcriptID: 1, now: now, call: { _ in XCTFail("全删分片不能再付费"); return "" }, in: queue)
        let oneLiner = try await queue.read { try String.fetchOne($0, sql: "SELECT one_liner FROM summaries WHERE transcript_id = 1") }
        XCTAssertEqual(oneLiner, MemoryRemoval.tombstoneText)
    }

    func testCitationDateAdvancesAcrossMidnight() {
        let hit = TranscriptSearch.Hit(lineID: 1, sessionID: 1, sessionStartedAt: "2026-10-13T23:55:00+08:00", atMillis: 600_000, text: "午夜之后", snippet: "午夜之后")
        let line = AskPrompt.materialLine(.init(hit: hit, matchedTerms: 0))
        XCTAssertEqual(line, "[#1] 2026-10-14 00:05 · 午夜之后")
    }

    func testRefrozenSourcesAreExcludedFromNewHistoryWithoutBlockingMain() throws {
        try db.write { d in
            let c = try AskStore.main(now: now, in: d)
            let old = try AskStore.askBegin(conversation: c, question: "旧的A", now: now, in: d)
            try AskStore.recordSources(old, materials: AskScope(sessionID: 1).materials(for: "A", in: d), history: [], in: d)
            try AskStore.answer(old, text: "旧的A答复", citedLineIDs: [10], now: now, in: d)
            try d.execute(sql: "INSERT INTO transcripts(id,session_id,version,part,asr_model,status,created_at) VALUES(3,1,2,1,'fake','frozen',?)", arguments: [now])
            try d.execute(sql: "INSERT INTO transcript_lines(line_id,transcript_id,seq,t_start_ms,t_end_ms,text,is_gap,char_offset) VALUES(30,3,0,0,1000,'更正后的项目A',0,0)")
            XCTAssertFalse(try AskStore.sourcesAreCurrent(old, in: d))
            let fresh = try AskStore.askBegin(conversation: c, question: "现在的A", now: now, in: d)
            let history = try AskStore.turns(of: c, in: d).filter { turn in
                guard turn.status == .answered else { return false }
                return try AskStore.sourcesAreCurrent(turn.id, in: d)
            }
            try AskStore.recordSources(fresh, materials: AskScope(sessionID: 1).materials(for: "A", in: d), history: history, in: d)
            try AskStore.answer(fresh, text: "新A答复", citedLineIDs: [30], now: now, in: d)
            XCTAssertEqual(try AskStore.turns(of: c, in: d).last?.status, .answered)
        }
    }
}
