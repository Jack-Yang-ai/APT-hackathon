import XCTest
import GRDB
@testable import GrowthApp

final class ActionAdmissionTests: XCTestCase {
    private var db: DatabaseQueue!
    private let now = "2026-10-14T10:00:00+08:00"
    override func setUpWithError() throws {
        db = try DatabaseQueue(); try AppDatabase.makeMigrator().migrate(db); try TestPeople.seed(in: db)
    }
    private func line(_ id: Int64, _ text: String, person: Int64? = SpeakerNaming.mePersonID, tid: Int64 = 1, part: Int = 1, gap: Bool = false) throws {
        try db.write { d in
            try d.execute(sql: "INSERT OR IGNORE INTO sessions(id,started_at,day,source,status) VALUES(1,?,'2026-10-14','watch','closed')", arguments: [now])
            try d.execute(sql: "INSERT OR IGNORE INTO transcripts(id,session_id,version,part,asr_model,status,created_at) VALUES(?,1,1,?,'test','frozen',?)", arguments: [tid,part,now])
            try d.execute(sql: "INSERT INTO transcript_lines(line_id,transcript_id,seq,t_start_ms,t_end_ms,text,char_offset,is_gap) VALUES(?,?,?,1000,2000,?,0,?)", arguments: [id,tid,id,text,gap ? 1 : 0])
            try d.execute(sql: "INSERT INTO line_speakers(line_id,person_id,source,updated_at) VALUES(?,?,'用户确认',?)", arguments: [id,person,now])
        }
    }
    private func action(_ id: Int64, _ quote: String, title: String = "发方案", kind: String = "accepted", evidence: [[String: Any]]? = nil) -> [String: Any] {
        ["kind":kind,"title":title,"line_id":id,"quote":quote,"evidence":evidence ?? [["line_id":id,"quote":quote]],
         "condition_text":"收到资料后","deadline_text":"明天","collaborators_text":"小钱"]
    }
    private func payload(_ actions: [[String: Any]]) -> [String: Any] {
        ["action_protocol":ActionExtraction.protocolVersion,"personal_actions":actions]
    }
    private func assess(_ actions: [[String: Any]]) throws {
        let input = try db.read { (try ActionCandidateStore.sessionLines(1, in: $0), try ActionCandidateStore.sessionRevision(1, in: $0)) }
        _ = try ActionCandidateStore.storeSession(payload(actions), sessionID: 1, now: now, expectedLines: input.0, expectedRevision: input.1, in: db)
    }
    private func candidates() throws -> [ActionCandidate] { try db.read { try PersonalActionStore.candidates(in: $0) } }
    private func adopt(_ candidate: ActionCandidate) throws -> Int64 { try db.write { try PersonalActionStore.adopt(candidate, now: now, in: $0) } }

    func testSpeakerCorrectionInvalidatesCandidateSnapshotAndPreservesExplicitDismissal() throws {
        RecomputeRegistry.resetToM0Defaults()
        try line(1, "我明天发方案")
        try line(2, "我明天修接口")
        try assess([action(1, "我明天发方案"), action(2, "我明天修接口", title: "修接口")])
        let ignored = try XCTUnwrap(candidates().first { $0.lineID == 1 })
        try db.write { try PersonalActionStore.dismissCandidate(ignored, now: now, in: $0) }
        let original = try db.read { try Row.fetchAll($0, sql: "SELECT * FROM action_candidates ORDER BY transcript_id,line_id,seq") }
        _ = try AssignSpeaker.assignSpeaker(lines: [1], person: 7, clusterTag: nil, source: .userConfirmed,
                                            confidence: nil, actor: .user, now: now, in: db)
        XCTAssertFalse(try db.read { try ActionCandidateStore.isCurrent(1, in: $0) })
        XCTAssertTrue(try candidates().isEmpty)
        XCTAssertEqual(try db.read { try Row.fetchAll($0, sql: "SELECT * FROM action_candidates ORDER BY transcript_id,line_id,seq") }, original)
        XCTAssertEqual(try db.read { try String.fetchAll($0, sql: "SELECT source_key FROM action_dismissals") }, [ignored.id])
        XCTAssertEqual(try db.read { try RecomputeCoverage.gaps(schemaTables: RecomputeCoverage.attributionConsumingTables($0), registered: RecomputeRegistry.registered) }, [])
        _ = try AssignSpeaker.assignSpeaker(lines: [1], person: SpeakerNaming.mePersonID, clusterTag: nil,
                                            source: .userConfirmed, confidence: nil, actor: .user, now: now, in: db)
        try assess([action(1, "我明天发方案"), action(2, "我明天修接口", title: "修接口")])
        XCTAssertEqual(try candidates().map(\.lineID), [2], "纠正归属和重识别均不能撤销用户忽略")
    }

    func testLegacyWrongCommitmentIsNotPersonalTodoEvenAfterConfirmingMe() throws {
        try line(1,"好，给我加一点")
        try db.write { d in
            try d.execute(sql: "INSERT INTO summaries(transcript_id,one_liner,created_at) VALUES(1,'服务交流',?)", arguments:[now])
            try d.execute(sql: "INSERT INTO summary_commitments(transcript_id,line_id,seq,what,quote,pending) VALUES(1,1,0,'替对方加水','好',0)")
        }
        XCTAssertTrue(try candidates().isEmpty)
        let detail = try XCTUnwrap(SessionDetailProjection.detail(sessionID: 1, in: db))
        XCTAssertTrue(detail.myCommitments.isEmpty)
        XCTAssertEqual(try db.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM summary_commitments") },1)
    }
    func testAcceptedUnknownOtherAndRequestsHaveDifferentAdmission() throws {
        try line(1,"我明天发方案")
        try line(2,"我先看时间，还没决定",person:nil)
        try line(3,"我明天修接口",person:7)
        try assess([action(1,"我明天发方案"),action(2,"我先看时间，还没决定",title:"确认是否参加",kind:"request"),action(3,"我明天修接口",title:"修接口")])
        XCTAssertEqual(Set(try candidates().map(\.lineID)),[1,2])
        let request = try XCTUnwrap(candidates().first { $0.lineID==2 }); let id=try adopt(request)
        XCTAssertEqual(try db.read { try PersonalActionStore.actions(in:$0).first { $0.id==id }?.status },.confirm)
    }
    func testConditionsAndSourceDeadlineAreEditable() throws {
        try line(1,"收到资料后，我明天发方案");try assess([action(1,"我明天发方案")])
        let id=try adopt(try XCTUnwrap(candidates().first))
        try db.write { d in
            var a=try XCTUnwrap(PersonalActionStore.actions(in:d).first)
            XCTAssertEqual(a.conditions,"收到资料后");XCTAssertEqual(a.extractedDeadline,"明天")
            a.extractedDeadline="";a.deadline=nil;a.conditions="按用户修改";try PersonalActionStore.update(a,now:now,in:d)
        }
        let saved=try db.read { try PersonalActionStore.actions(in:$0).first { $0.id==id } }
        XCTAssertEqual(saved?.extractedDeadline,"");XCTAssertEqual(saved?.conditions,"按用户修改")
    }
    func testManualDeadlineDescriptionIsSavedEditedAndCleared() throws {
        let id = try db.write { try PersonalActionStore.create(title: "发材料", deadline: nil,
            conditions: "", nextStep: "", collaborators: "", deadlineText: "月底前", now: now, in: $0) }
        try db.write { d in
            var saved = try XCTUnwrap(PersonalActionStore.actions(in: d).first { $0.id == id })
            XCTAssertEqual(saved.extractedDeadline, "月底前")
            saved.extractedDeadline = "收到反馈后"
            try PersonalActionStore.update(saved, now: now, in: d)
        }
        try db.write { d in
            var saved = try XCTUnwrap(PersonalActionStore.actions(in: d).first { $0.id == id })
            XCTAssertEqual(saved.extractedDeadline, "收到反馈后")
            saved.extractedDeadline = ""
            try PersonalActionStore.update(saved, now: now, in: d)
        }
        XCTAssertEqual(try db.read { try PersonalActionStore.actions(in: $0).first?.extractedDeadline }, "")
    }
    func testSameLineReorderingDoesNotReviveCompletedOrSuppressUnfinished() throws {
        try line(1,"我明天发方案，约客户，核对材料")
        let a=action(1,"发方案",title:"发方案"),b=action(1,"约客户",title:"约客户"),c=action(1,"核对材料",title:"核对材料")
        try assess([a,b]);let id=try adopt(try XCTUnwrap(candidates().first { $0.title=="发方案" }))
        try db.write { try PersonalActionStore.setStatus(id,status:.done,now:now,in:$0) }
        try assess([b,c,a]);XCTAssertEqual(Set(try candidates().map(\.title)),["约客户","核对材料"])
        try assess([b,a]);XCTAssertEqual(try candidates().map(\.title),["约客户"])
        XCTAssertEqual(try db.read { try PersonalActionStore.actions(in:$0).first?.status },.done)
    }
    func testOnlyContextChangeInvalidatesCandidateAndSavedSource() throws {
        try line(1,"你下周发方案？",person:7);try line(2,"行，我来发")
        try assess([action(2,"行，我来发",evidence:[["line_id":1,"quote":"你下周发方案？"],["line_id":2,"quote":"行，我来发"]])])
        let id=try adopt(try XCTUnwrap(candidates().first))
        _ = try TranscriptRevision.revise(lineID:1,to:"我下周发方案，你不用发",actor:"用户",now:now,in:db)
        XCTAssertTrue(try candidates().isEmpty)
        XCTAssertNotNil(try db.read { try PersonalActionStore.actions(in:$0).first?.sourceWarning })
        XCTAssertThrowsError(try db.write { try PersonalActionStore.revalidate(id,now:now,in:$0) })
    }
    func testRemovingContextErasesDerivedQuotesAndPreservesUserAction() throws {
        try line(1,"你下周发方案？",person:7);try line(2,"行，我来发")
        try assess([action(2,"行，我来发",evidence:[["line_id":1,"quote":"你下周发方案？"],["line_id":2,"quote":"行，我来发"]])])
        let id=try adopt(try XCTUnwrap(candidates().first))
        _ = try MemoryRemoval.removeLines([1],audioFiles:[],in:db)
        XCTAssertEqual(try db.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM action_candidates") },0)
        XCTAssertEqual(try db.read { try PersonalActionStore.actions(in:$0).first?.id },id)
    }
    func testRemovingCrossPartContextErasesAllSessionEvidenceCopies() throws {
        try line(1,"行，我来发")
        try line(2,"资料来了你再发方案",person:7,tid:2,part:2)
        try assess([action(1,"我来发",evidence:[["line_id":1,"quote":"我来发"],["line_id":2,"quote":"资料来了你再发方案"]])])
        let id = try adopt(try XCTUnwrap(candidates().first))
        _ = try MemoryRemoval.removeLines([2],audioFiles:[],in:db)
        try db.read { d in
            XCTAssertEqual(try Int.fetchOne(d,sql:"SELECT COUNT(*) FROM action_candidates"),0)
            XCTAssertEqual(try Int.fetchOne(d,sql:"SELECT COUNT(*) FROM action_assessments"),0)
            XCTAssertEqual(try PersonalActionStore.actions(in:d).first?.id,id)
            XCTAssertNotNil(try PersonalActionStore.actions(in:d).first?.sourceWarning)
        }
    }
    func testLegacyClosedActionsDoNotReappearAfterNewRecognition() throws {
        try line(1,"我明天发方案");try line(2,"我来核对材料")
        try db.write { d in
            for (id,status) in [(1,ActionStatus.done),(2,ActionStatus.cancelled)] {
                try d.execute(sql:"INSERT INTO personal_actions(title,status,resume_status,source_key,source_line_id,created_at,updated_at) VALUES(?,?,'next',?,?,?,?)",arguments:["旧行动",status.rawValue,"commitment:\(id):0",id,now,now])
            }
        }
        try assess([action(1,"发方案"),action(2,"核对材料",title:"核对材料")])
        XCTAssertTrue(try candidates().isEmpty)
        XCTAssertTrue(try db.read { try PersonalActionStore.recognized(in:$0).isEmpty })
        XCTAssertTrue(try XCTUnwrap(SessionDetailProjection.detail(sessionID:1,in:db)).myCommitments.isEmpty)
        XCTAssertEqual(Set(try db.read { try PersonalActionStore.actions(in:$0).map(\.status) }),[.done,.cancelled])
    }
    func testCrossPartFinalStateReplacesOldCandidateWithoutChangingUserFields() throws {
        try line(1,"我明天发方案")
        try assess([action(1,"我明天发方案")]);let id=try adopt(try XCTUnwrap(candidates().first))
        try line(2,"方案已经发完了",tid:2,part:2)
        XCTAssertFalse(try db.read { try ActionCandidateStore.isSessionCurrent(1,in:$0) })
        try assess([]);XCTAssertTrue(try candidates().isEmpty)
        XCTAssertEqual(try db.read { try PersonalActionStore.actions(in:$0).first?.id },id)
        XCTAssertNotNil(try db.read { try PersonalActionStore.actions(in:$0).first?.sourceWarning })
    }
    func testReassessmentQueuesBothExistingAndMissingTaskWithoutResubmittingASR() throws {
        try line(1,"我明天发方案")
        try db.write { try $0.execute(sql:"INSERT INTO summaries(transcript_id,one_liner,created_at) VALUES(1,'旧纪要',?)",arguments:[now]) }
        try ActionCandidateStore.requestReassessment(1,now:now,in:db)
        XCTAssertEqual(try db.read { try String.fetchOne($0,sql:"SELECT state FROM tasks WHERE kind='extract'") },"queued")
        let firstToken = try db.read { try String.fetchOne($0,sql:"SELECT action_request_token FROM tasks WHERE kind='extract'") }
        try db.write { try $0.execute(sql:"UPDATE tasks SET state='done',created_at='2020-01-01',attempts=4") }
        try ActionCandidateStore.requestReassessment(1,now:now,in:db)
        XCTAssertNotEqual(try db.read { try String.fetchOne($0,sql:"SELECT action_request_token FROM tasks WHERE kind='extract'") },firstToken,"同秒手动重试也不能取回旧失败终态")
        XCTAssertEqual(try db.read { try String.fetchOne($0,sql:"SELECT created_at FROM tasks WHERE kind='extract'") },now)
        XCTAssertEqual(try db.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM asr_jobs") },0)
    }
    func testReassessmentDoesNotOverwriteOldNotes() async throws {
        try line(1,"我明天发方案")
        try await db.write { try $0.execute(sql:"INSERT INTO summaries(transcript_id,one_liner,created_at) VALUES(1,'原纪要保持',?)",arguments:[self.now]) }
        var p=payload([action(1,"我明天发方案")]);
        p.merge(["one_liner":"新生成的纪要","key_points":[],"commitments":[],"stances":[],"pendings":[],"topic_keys":[]]) { _,new in new }
        let raw=String(decoding:try JSONSerialization.data(withJSONObject:p),as:UTF8.self)
        let r=try await ExtractionRunner.run(transcriptID:1,now:now,call:{ _ in raw },reassessActions:true,in:db)
        XCTAssertFalse(r.skipped)
        let kept = try await db.read { try String.fetchOne($0,sql:"SELECT one_liner FROM summaries") }
        XCTAssertEqual(kept,"原纪要保持")
    }
    func testBooleanEvidenceIDAndMissingProtocolAreRejected() throws {
        try line(1,"我明天发方案")
        var a=action(1,"我明天发方案");a["evidence"]=[["line_id":true,"quote":"我明天发方案"]]
        XCTAssertThrowsError(try assess([a]))
        let lines=try db.read { try ActionCandidateStore.sessionLines(1,in:$0) }
        XCTAssertThrowsError(try ActionExtraction.validate(["personal_actions":[]],lines:lines))
        XCTAssertThrowsError(try ActionExtraction.validate(["terminal":true],lines:lines))
    }
    func testMissingActionProtocolInOneChunkCannotMarkWholeInputAssessed() async throws {
        for id in 1...ExtractionRunner.chunkSize + 1 { try line(Int64(id),"我明天发方案") }
        var calls = 0
        let call: (String) async throws -> String = { _ in
            calls += 1
            var p: [String: Any] = ["one_liner":"讨论方案","key_points":[],"commitments":[],"stances":[],"pendings":[],"topic_keys":[]]
            if calls == 1 { p["action_protocol"] = ActionExtraction.protocolVersion; p["personal_actions"] = [[String: Any]]() }
            return String(decoding:try JSONSerialization.data(withJSONObject:p),as:UTF8.self)
        }
        do {
            _ = try await ExtractionRunner.run(transcriptID:1,now:now,call:call,requireActions:true,in:db)
            XCTFail("第二块没有行动协议也被接受")
        } catch {
            XCTAssertTrue("\(error)".contains("个人行动识别"))
        }
        XCTAssertEqual(calls,2)
        let counts = try await db.read { (try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM action_assessments"),try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM summaries")) }
        XCTAssertEqual(counts.0,0);XCTAssertEqual(counts.1,0)
    }
    func testCapturedRevisionRejectsABAChangesDuringModelCall() throws {
        try line(1,"我明天发方案");let lines=try db.read { try ActionCandidateStore.sessionLines(1,in:$0) }
        _ = try TranscriptRevision.revise(lineID:1,to:"我不发方案",actor:"用户",now:now,in:db)
        _ = try TranscriptRevision.revise(lineID:1,to:"我明天发方案",actor:"用户",now:now,in:db)
        XCTAssertThrowsError(try ActionCandidateStore.storeSession(payload([action(1,"我明天发方案")]),sessionID:1,now:now,expectedLines:lines,expectedRevision:0,in:db))
        XCTAssertTrue(try candidates().isEmpty)
    }
    func testPersonalActionPromptIsByteEqualToPythonWithoutChangingV1Golden() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let expected=try String(contentsOf:root.appendingPathComponent("eval/fixtures/personal_action_prompt.txt"),encoding:.utf8)
        XCTAssertEqual(ActionExtraction.prompt,expected)
    }

}
