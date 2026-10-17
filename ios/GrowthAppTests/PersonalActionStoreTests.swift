import XCTest
import GRDB
@testable import GrowthApp

final class PersonalActionStoreTests: XCTestCase {
    private var queue: DatabaseQueue!
    private let stamp = "2026-10-14T10:00:00+08:00"

    override func setUpWithError() throws {
        queue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(queue)
        try TestPeople.seed(in: queue)
    }

    private func seed(person: Int64? = SpeakerNaming.mePersonID, part: Int = 1, version: Int = 1,
                      line: Int64 = 10, seq: Int = 0, kind: String = "commitment") throws {
        try queue.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO sessions(id,started_at,day,source,status) VALUES(1,?,'2026-10-14','watch','closed')", arguments: [stamp])
            try db.execute(sql: "INSERT OR IGNORE INTO transcripts(id,session_id,version,part,asr_model,status,created_at) VALUES(?,1,?,?,'test','frozen',?)", arguments: [line, version, part, stamp])
            try db.execute(sql: "INSERT OR IGNORE INTO transcript_lines(line_id,transcript_id,seq,t_start_ms,t_end_ms,text,char_offset) VALUES(?,?,0,1000,3000,'我明天给你方案',0)", arguments: [line, line])
            try db.execute(sql: "INSERT OR REPLACE INTO line_speakers(line_id,person_id,source,updated_at) VALUES(?,?,'用户确认',?)", arguments: [line, person, stamp])
            let table = kind == "commitment" ? "summary_commitments" : "summary_pendings"
            let column = kind == "commitment" ? "what" : "issue"
            try db.execute(sql: "INSERT INTO \(table)(transcript_id,line_id,seq,\(column),quote,pending) VALUES(?,?,?,'给方案','我明天给你方案',?)", arguments: [line, line, seq, person == nil ? 1 : 0])
            try db.execute(sql: "UPDATE sessions SET active_transcript_id=? WHERE id=1", arguments: [line])
            let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE transcript_id=?", arguments: [line]) ?? 0
            let action: [String: Any] = ["kind": kind == "commitment" ? "accepted" : "request", "title": "给方案", "line_id": line,
                "quote": "我明天给你方案", "evidence": [["line_id": line, "quote": "我明天给你方案"]],
                "condition_text": "", "deadline_text": "明天", "collaborators_text": ""]
            _ = try ActionCandidateStore.write(["action_protocol": ActionExtraction.protocolVersion, "personal_actions": (0..<n).map { i in var a = action; a["title"] = i == 0 ? "给方案" : "约客户"; return a }],
                                               transcriptID: line, now: stamp, sessionScope: true, in: db)
            let snapshot = try ActionCandidateStore.snapshot(ActionCandidateStore.sessionLines(1, in: db))
            try db.execute(sql: "UPDATE action_assessments SET snapshot=? WHERE transcript_id IN (SELECT id FROM transcripts WHERE session_id=1)", arguments: [snapshot])
        }
    }

    func testOthersAreExcludedAndUnknownStaysCandidate() throws {
        try seed(person: 7)
        try seed(person: nil, part: 2, line: 20)
        try seed(part: 3, line: 30)
        let candidates = try queue.read { try PersonalActionStore.candidates(in: $0) }
        XCTAssertEqual(Set(candidates.map(\.lineID)), [20,30])
        XCTAssertFalse(candidates.first { $0.lineID == 20 }!.isMine)
        XCTAssertTrue(candidates.first { $0.lineID == 20 }!.evidence.contains("尚不能认作"))
        let pending = candidates.first { $0.lineID == 20 }!
        let id = try queue.write { try PersonalActionStore.adopt(pending, now: stamp, in: $0) }
        let saved = try queue.read { try PersonalActionStore.actions(in: $0).first { $0.id == id }! }
        XCTAssertEqual(saved.status, .confirm)
        XCTAssertNotNil(saved.sourceWarning)
    }

    func testAllPartsOfLatestVersionAppearAndOldVersionIsExcluded() throws {
        try seed(version: 1)
        try seed(part: 1, version: 2, line: 20)
        try seed(part: 2, version: 2, line: 30)
        let candidates = try queue.read { try PersonalActionStore.candidates(in: $0) }
        XCTAssertEqual(Set(candidates.map(\.lineID)), [20,30])
        XCTAssertEqual(Set(candidates.map(\.version)), [2])
    }

    func testTwoCommitmentsOnOneLineCanBeAdoptedSeparately() throws {
        try seed()
        try seed(seq: 1)
        let candidates = try queue.read { try PersonalActionStore.candidates(in: $0) }
        XCTAssertEqual(candidates.count, 2)
        try queue.write { db in for candidate in candidates { _ = try PersonalActionStore.adopt(candidate, now: stamp, in: db) } }
        XCTAssertEqual(try queue.read { try PersonalActionStore.actions(in: $0).count }, 2)
    }

    func testRepeatedAdoptionPreservesEditsAndCompletion() throws {
        try seed()
        let candidate = try queue.read { try PersonalActionStore.candidates(in: $0)[0] }
        let id = try queue.write { try PersonalActionStore.adopt(candidate, now: stamp, in: $0) }
        try queue.write { db in
            var action = try PersonalActionStore.actions(in: db)[0]
            action.title = "按用户改的标题"; action.nextStep = "先确认需求"
            action.conditions = "收到资料后"; action.deadline = stamp; action.status = .done
            try PersonalActionStore.update(action, now: stamp, in: db)
            XCTAssertEqual(try PersonalActionStore.adopt(candidate, now: stamp, in: db), id)
        }
        let saved = try queue.read { try PersonalActionStore.actions(in: $0)[0] }
        XCTAssertEqual(saved.title, "按用户改的标题")
        XCTAssertEqual(saved.status, .done)
        XCTAssertEqual(saved.nextStep, "先确认需求")
        XCTAssertEqual(saved.conditions, "收到资料后")
        XCTAssertEqual(saved.deadline, stamp)
        XCTAssertTrue(try queue.read { try PersonalActionStore.candidates(in: $0).isEmpty })
    }

    func testChangedAttributionCannotBeAdoptedFromStaleScreen() throws {
        try seed()
        let candidate = try queue.read { try PersonalActionStore.candidates(in: $0)[0] }
        try queue.write { try $0.execute(sql: "UPDATE line_speakers SET person_id=7 WHERE line_id=10") }
        XCTAssertThrowsError(try queue.write { try PersonalActionStore.adopt(candidate, now: stamp, in: $0) })
        XCTAssertTrue(try queue.read { try PersonalActionStore.actions(in: $0).isEmpty })
    }

    func testChangedSourceWarnsWithoutReopeningCompletedActionAndRestoreNeedsConfirmation() throws {
        try seed()
        let candidate = try queue.read { try PersonalActionStore.candidates(in: $0)[0] }
        let id = try queue.write { try PersonalActionStore.adopt(candidate, now: stamp, in: $0) }
        try queue.write { try PersonalActionStore.setStatus(id, status: .done, now: stamp, in: $0) }
        try queue.write { try $0.execute(sql: "UPDATE line_speakers SET person_id=7 WHERE line_id=10") }
        let before = try queue.read { try PersonalActionStore.actions(in: $0)[0] }
        XCTAssertEqual(before.status, .done)
        XCTAssertNotNil(before.sourceWarning)
        XCTAssertThrowsError(try queue.write { try PersonalActionStore.revalidate(id, now: stamp, in: $0) })
        try queue.write { try PersonalActionStore.setStatus(id, status: nil, now: stamp, in: $0) }
        XCTAssertEqual(try queue.read { try PersonalActionStore.actions(in: $0)[0].shownStatus }, .confirm)
    }

    func testRevisionAndDeletionInvalidateSourceWithoutDeletingUserAction() throws {
        try seed()
        let candidate = try queue.read { try PersonalActionStore.candidates(in: $0)[0] }
        _ = try queue.write { try PersonalActionStore.adopt(candidate, now: stamp, in: $0) }
        _ = try TranscriptRevision.revise(lineID: 10, to: "我后天给你方案", actor: "用户", now: stamp, in: queue)
        XCTAssertNotNil(try queue.read { try PersonalActionStore.actions(in: $0)[0].sourceWarning })
        _ = try MemoryRemoval.removeLines([10], audioFiles: [], in: queue)
        let action = try queue.read { try PersonalActionStore.actions(in: $0)[0] }
        XCTAssertNotNil(action.sourceWarning)
        XCTAssertNil(action.source)
        XCTAssertEqual(action.title, "给方案")
        XCTAssertTrue(try queue.read { try PersonalActionStore.candidates(in: $0).isEmpty })
    }

    func testManualActionSurvivesFileReopenAndMigrationKeepsOldSources() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("actions-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var old: DatabaseQueue? = try DatabaseQueue(path: path)
        try AppDatabase.makeMigrator().migrate(old!, upTo: "v50_input_memory_sources")
        try old!.write { try $0.execute(sql: "INSERT INTO sessions(started_at,day,source,status) VALUES(?,'2026-10-14','recording','closed')", arguments: [stamp]) }
        try AppDatabase.makeMigrator().migrate(old!)
        _ = try old!.write { try PersonalActionStore.create(title: "手动行动", deadline: stamp, conditions: "条件", nextStep: "下一步", collaborators: "协作人", now: stamp, in: $0) }
        old = nil
        let reopened = try AppDatabase.open(atPath: path)
        let actions = try reopened.read { try PersonalActionStore.actions(in: $0) }
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].collaborators, "协作人")
        XCTAssertNil(actions[0].sourceWarning)
        XCTAssertEqual(try reopened.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sessions") }, 1)
    }

    func testRemovalAndRestoreKeepEditsAndCompletionAcrossMigrationAndReopen() throws {
        let path=FileManager.default.temporaryDirectory.appendingPathComponent("removed-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath:path) }
        var old: DatabaseQueue? = try DatabaseQueue(path:path)
        try AppDatabase.makeMigrator().migrate(old!,upTo:"v53_personal_action_admission")
        let id=try old!.write { try PersonalActionStore.create(title:"用户改过的标题",status:.done,deadline:stamp,conditions:"收到资料后",nextStep:"核对需求",collaborators:"李同学",deadlineText:"周五前",now:stamp,in:$0) }
        try AppDatabase.makeMigrator().migrate(old!)
        try old!.write { try PersonalActionStore.remove(id,now:stamp,in:$0) }
        XCTAssertTrue(try old!.read { try PersonalActionStore.actions(in:$0).isEmpty })
        old=nil
        let reopened=try AppDatabase.open(atPath:path)
        let removed=try reopened.read { try XCTUnwrap(PersonalActionStore.actions(in:$0,includeRemoved:true).first) }
        XCTAssertNotNil(removed.removedAt)
        XCTAssertEqual(removed.status,.done)
        try reopened.write { try PersonalActionStore.restore(id,now:stamp,in:$0) }
        let restored=try reopened.read { try XCTUnwrap(PersonalActionStore.actions(in:$0).first) }
        XCTAssertNil(restored.removedAt)
        XCTAssertEqual(restored.title,"用户改过的标题")
        XCTAssertEqual(restored.status,.done)
        XCTAssertEqual(restored.deadline,stamp)
        XCTAssertEqual(restored.extractedDeadline,"周五前")
        XCTAssertEqual(restored.nextStep,"核对需求")
        XCTAssertEqual(restored.conditions,"收到资料后")
        XCTAssertEqual(restored.collaborators,"李同学")
    }

    func testIgnoredCandidateSurvivesReextractionUntilExplicitRestore() throws {
        try seed()
        let candidate=try queue.read { try PersonalActionStore.candidates(in:$0)[0] }
        try queue.write { try PersonalActionStore.dismissCandidate(candidate,now:stamp,in:$0) }
        XCTAssertTrue(try queue.read { try PersonalActionStore.candidates(in:$0).isEmpty })
        XCTAssertTrue(try queue.read { try PersonalActionStore.recognized(in:$0).isEmpty })
        XCTAssertThrowsError(try queue.write { try PersonalActionStore.adopt(candidate,now:stamp,in:$0) },"旧屏幕不能采纳已忽略候选")
        try seed(seq:1)
        XCTAssertFalse(try queue.read { try PersonalActionStore.candidates(in:$0).contains { $0.id==candidate.id } })
        XCTAssertFalse(try queue.read { try PersonalActionStore.recognized(in:$0).contains { $0.id==candidate.id } })
        XCTAssertEqual(try queue.read { try PersonalActionStore.dismissals(in:$0).map(\.id) },[candidate.id])
        try queue.write { try PersonalActionStore.restoreCandidate(candidate.id,in:$0) }
        XCTAssertTrue(try queue.read { try PersonalActionStore.candidates(in:$0).contains { $0.id==candidate.id } })
    }

    func testStaleEditorAndRepeatedAdoptionCannotRestoreRemovedAction() throws {
        try seed()
        let candidate=try queue.read { try PersonalActionStore.candidates(in:$0)[0] }
        let id=try queue.write { try PersonalActionStore.adopt(candidate,now:stamp,in:$0) }
        var stale=try queue.read { try PersonalActionStore.actions(in:$0)[0] }
        try queue.write { try PersonalActionStore.remove(id,now:stamp,in:$0) }
        stale.title="过期编辑"
        XCTAssertThrowsError(try queue.write { try PersonalActionStore.update(stale,now:stamp,in:$0) })
        XCTAssertEqual(try queue.write { try PersonalActionStore.adopt(candidate,now:stamp,in:$0) },id)
        XCTAssertTrue(try queue.read { try PersonalActionStore.actions(in:$0).isEmpty })
        XCTAssertTrue(try queue.read { try PersonalActionStore.recognized(in:$0).isEmpty })
        try queue.write { try PersonalActionStore.restore(id,now:stamp,in:$0) }
        XCTAssertEqual(try queue.read { try PersonalActionStore.actions(in:$0)[0].title },"给方案")
    }

    func testModelTitleParaphraseCannotReviveIgnoredOrRemovedSource() throws {
        try seed()
        let original=try queue.read { try PersonalActionStore.candidates(in:$0)[0] }
        try queue.write { try PersonalActionStore.dismissCandidate(original,now:stamp,in:$0) }
        try queue.write { try $0.execute(sql:"UPDATE action_candidates SET title='把方案发给对方'") }
        XCTAssertTrue(try queue.read { try PersonalActionStore.candidates(in:$0).isEmpty })
        XCTAssertTrue(try queue.read { try PersonalActionStore.recognized(in:$0).isEmpty })
        XCTAssertThrowsError(try queue.write { try PersonalActionStore.adopt(original,now:stamp,in:$0) })
        try queue.write { try PersonalActionStore.restoreCandidate(original.id,in:$0) }
        let changed=try queue.read { try PersonalActionStore.candidates(in:$0)[0] }
        XCTAssertNotEqual(changed.id,original.id)
        let id=try queue.write { try PersonalActionStore.adopt(changed,now:stamp,in:$0) }
        try queue.write { try $0.execute(sql:"UPDATE action_candidates SET title='发出评审方案'") }
        let changedAgain=try queue.read { try PersonalActionStore.candidates(in:$0)[0] }
        try queue.write { try PersonalActionStore.remove(id,now:stamp,in:$0) }
        XCTAssertTrue(try queue.read { try PersonalActionStore.candidates(in:$0).isEmpty })
        XCTAssertTrue(try queue.read { try PersonalActionStore.recognized(in:$0).isEmpty })
        XCTAssertThrowsError(try queue.write { try PersonalActionStore.adopt(changedAgain,now:stamp,in:$0) })
        XCTAssertTrue(try queue.read { try PersonalActionStore.actions(in:$0).isEmpty })
    }

    func testCandidateDismissalRejectsChangedOwnerAndDoesNotCopyDeletedQuotes() throws {
        try seed()
        let stale=try queue.read { try PersonalActionStore.candidates(in:$0)[0] }
        try queue.write { try $0.execute(sql:"UPDATE line_speakers SET person_id=7 WHERE line_id=10") }
        XCTAssertThrowsError(try queue.write { try PersonalActionStore.dismissCandidate(stale,now:stamp,in:$0) })
        try seed(seq:1)
        let current=try queue.read { try PersonalActionStore.candidates(in:$0)[0] }
        try queue.write { try PersonalActionStore.dismissCandidate(current,now:stamp,in:$0) }
        _ = try TranscriptRevision.revise(lineID:10,to:"我不用给你方案了",actor:"用户",now:stamp,in:queue)
        XCTAssertEqual(try queue.read { try PersonalActionStore.dismissals(in:$0).first?.title },"出处已变化的候选")
        _ = try MemoryRemoval.removeLines([10],audioFiles:[],in:queue)
        let ignored=try queue.read { try XCTUnwrap(PersonalActionStore.dismissals(in:$0).first) }
        XCTAssertNil(ignored.source)
        XCTAssertEqual(ignored.title,"出处已变化的候选")
        XCTAssertEqual(try queue.read { try Row.fetchAll($0,sql:"PRAGMA table_info(action_dismissals)").map { $0["name"] as String } },["source_key","source_line_id","removed_at"])
        try queue.write { try PersonalActionStore.restoreCandidate(current.id,in:$0) }
        XCTAssertTrue(try queue.read { try PersonalActionStore.candidates(in:$0).isEmpty })
    }

    func testFailedWriteRollsBackAndDoesNotPretendToSave() throws {
        try queue.write { try $0.execute(sql: "CREATE TRIGGER reject_action BEFORE INSERT ON personal_actions BEGIN SELECT RAISE(ABORT,'disk failpoint'); END") }
        XCTAssertThrowsError(try queue.write { try PersonalActionStore.create(title: "行动", status: .doing, deadline: nil, conditions: "", nextStep: "", collaborators: "", now: stamp, in: $0) })
        XCTAssertTrue(try queue.read { try PersonalActionStore.actions(in: $0).isEmpty })
    }

    func testAssignSpeakerImmediatelyInvalidatesActiveActionWithoutOverwritingUserFields() throws {
        RecomputeRegistry.registerM0Defaults()
        try seed()
        let candidate = try queue.read { try PersonalActionStore.candidates(in: $0)[0] }
        _ = try queue.write { try PersonalActionStore.adopt(candidate, now: stamp, in: $0) }
        _ = try AssignSpeaker.assignSpeaker(lines: [10], person: 7, clusterTag: nil,
            source: .userConfirmed, confidence: nil, actor: .user, now: stamp, in: queue)
        let changed = try queue.read { try PersonalActionStore.actions(in: $0)[0] }
        XCTAssertEqual(changed.status, .next)
        XCTAssertEqual(changed.shownStatus, .confirm)
        XCTAssertEqual(changed.title, "给方案")
        XCTAssertTrue(changed.source!.evidence.contains("他人"))
        XCTAssertNotNil(changed.sourceWarning)
    }

    func testRealPendingExtractionCanBeReviewedAfterConfirmingMe() throws {
        RecomputeRegistry.registerM0Defaults()
        try seed(person: nil)
        try queue.write { try $0.execute(sql: "DELETE FROM summary_commitments") }
        let payload: [String: Any] = ["one_liner": "待讨论的方案", "key_points": [], "commitments": [], "stances": [],
            "pendings": [["issue": "方案待讨论", "line_id": 10, "quote": "我明天给你方案"]], "topic_keys": []]
        let line = ExtractValidate.Line(lineID: 10, text: "我明天给你方案", isGap: false, personID: nil, clusterTag: nil)
        let clean = try ExtractValidate.validate(payload, lines: [line]).clean
        _ = try ExtractionStore.store(clean, transcriptID: 10, now: stamp, in: queue)
        let candidate = try queue.read { try PersonalActionStore.candidates(in: $0)[0] }
        let id = try queue.write { try PersonalActionStore.adopt(candidate, now: stamp, in: $0) }
        _ = try AssignSpeaker.assignSpeaker(lines: [10], person: SpeakerNaming.mePersonID, clusterTag: nil,
            source: .userConfirmed, confidence: nil, actor: .user, now: stamp, in: queue)
        XCTAssertNotNil(try queue.read { try PersonalActionStore.actions(in: $0)[0].sourceWarning })
        try queue.write { db in
            _ = try ActionCandidateStore.write(["action_protocol":ActionExtraction.protocolVersion,"personal_actions":[
                ["kind":"accepted","title":"给方案","line_id":10,"quote":"我明天给你方案",
                 "evidence":[["line_id":10,"quote":"我明天给你方案"]],"condition_text":"","deadline_text":"明天","collaborators_text":""]]],
                transcriptID:10,now:stamp,sessionScope:true,in:db)
        }
        try queue.write { try PersonalActionStore.revalidate(id, now: stamp, in: $0) }
        XCTAssertNil(try queue.read { try PersonalActionStore.actions(in: $0)[0].sourceWarning })
        try queue.write { try PersonalActionStore.setStatus(id, status: .doing, now: stamp, in: $0) }
        XCTAssertEqual(try queue.read { try PersonalActionStore.actions(in: $0)[0].status }, .doing)
    }

    func testPartialQuoteCannotHideNegationAddedAfterExtraction() throws {
        try seed()
        try queue.write { try $0.execute(sql: "UPDATE summary_commitments SET quote='明天给你方案' WHERE line_id=10") }
        let old = try queue.read { try PersonalActionStore.candidates(in: $0)[0] }
        let id = try queue.write { try PersonalActionStore.adopt(old, now: stamp, in: $0) }
        _ = try TranscriptRevision.revise(lineID: 10, to: "我不会明天给你方案", actor: "用户", now: stamp, in: queue)
        let changed = try queue.read { try PersonalActionStore.actions(in: $0)[0] }
        XCTAssertEqual(changed.source?.quote, "我不会明天给你方案")
        XCTAssertTrue(changed.source!.pending)
        XCTAssertFalse(changed.source!.quoteIsCurrent)
        XCTAssertThrowsError(try queue.write { try PersonalActionStore.revalidate(id, now: stamp, in: $0) })
    }

    func testExtractionAfterRevisionUsesSnapshotEvenWhenRequestTimeWasEarlier() throws {
        try seed()
        try queue.write { try $0.execute(sql: "DELETE FROM summary_commitments") }
        _ = try TranscriptRevision.revise(lineID: 10, to: "我后天给你方案", actor: "用户", now: "2026-10-14T10:01:00+08:00", in: queue)
        let payload: [String: Any] = ["one_liner": "方案的安排", "key_points": [], "stances": [], "pendings": [], "topic_keys": [],
            "commitments": [["what": "后天给方案", "line_id": 10, "quote": "我后天给你方案"]],
            "action_protocol": ActionExtraction.protocolVersion,
            "personal_actions": [["kind":"accepted","title":"后天给方案","line_id":10,"quote":"我后天给你方案",
                "evidence":[["line_id":10,"quote":"我后天给你方案"]],"condition_text":"","deadline_text":"后天","collaborators_text":""]]]
        _ = try ExtractionStore.store(payload, transcriptID: 10, now: stamp, in: queue)
        let candidate = try queue.read { try PersonalActionStore.candidates(in: $0)[0] }
        XCTAssertTrue(candidate.quoteIsCurrent)
        XCTAssertFalse(candidate.pending)
        let id = try queue.write { try PersonalActionStore.adopt(candidate, now: stamp, in: $0) }
        XCTAssertNil(try queue.read { try PersonalActionStore.actions(in: $0).first { $0.id == id }?.sourceWarning })
    }
}
