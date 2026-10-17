import XCTest
import GRDB
@testable import GrowthApp

/// 事件落库与详情页投影(`M5-1` 件 3)。
final class SummaryEventsTests: XCTestCase {

    private var db: DatabaseQueue!
    private let now = "2026-10-12T15:00:00+08:00"

    /// 一场 14:00 开始;6 行,行 10–12 在第一段(我 + S1),行 13–15 在第二段(S2)。
    override func setUpWithError() throws {
        db = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(db)
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, '2026-10-12T14:00:00+08:00', '2026-10-12', 'recording', 'closed')
                """)
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (1, 1, 1, 1, 'step-asr-v1', 'frozen', ?)
                """, arguments: [now])
            for i in 0..<6 {
                try db.execute(sql: """
                    INSERT INTO transcript_lines (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
                    VALUES (?, 1, ?, ?, ?, ?, 0)
                    """, arguments: [10 + i, i, i * 300_000, i * 300_000 + 60_000, "第\(i)句"])
            }
            let who: [(Int, Int64?, String?)] = [(10, -1, nil), (11, nil, "S1"), (12, -1, nil),
                                                 (13, nil, "S2"), (14, nil, "S2"), (15, nil, "S2")]
            for (line, person, tag) in who {
                try db.execute(sql: """
                    INSERT INTO line_speakers (line_id, person_id, cluster_tag, source, confidence, updated_at)
                    VALUES (?, ?, ?, '声纹识别', 0.9, ?)
                    """, arguments: [line, person, tag, now])
            }
        }
    }

    override func tearDownWithError() throws { db = nil }

    private func payload(events: [[String: Any]]) -> [String: Any] {
        [
            "one_liner": "定了提测日期",
            "key_points": [["point": "11 月 2 日提测", "quote": "第0句", "line_id": 10]],
            "commitments": [
                ["what": "整理评审意见", "quote": "第2句", "line_id": 12],                       // 我说的,没「对谁」
                ["what": "先测一周", "quote": "第3句", "line_id": 13, "to_whom_text": "大家"],   // 别人的
            ],
            "stances": [], "pendings": [],
            "topic_keys": [["key": "提测时间", "line_ids": [11, 10]], ["key": "声纹", "line_ids": [14]]],
            "action_protocol": ActionExtraction.protocolVersion,
            "personal_actions": [["kind": "accepted", "title": "整理评审意见", "line_id": 12, "quote": "第2句",
                "evidence": [["line_id":12,"quote":"第2句"]], "condition_text":"", "deadline_text":"", "collaborators_text":""]],
            "events": events,
        ]
    }

    private let twoEvents: [[String: Any]] = [
        ["event_id": "E1", "title": "提测时间", "summary": "定了 11 月 2 日。", "line_from": 10, "line_to": 12],
        ["event_id": "E2", "title": "声纹", "summary": "先测一周。", "line_from": 13, "line_to": 15],
    ]

    /// 🔴 **走生产那条路:validate → store**(2026-10-12 对抗审查抓到 validate 把 events 丢了,
    /// 而上面几条都直接调 store,所以一直绿)。坏事件跳过并计数,坏范围只去掉范围。
    func testEventsSurviveValidateIntoTheStore() throws {
        let lines = (10...15).map { ExtractValidate.Line(lineID: Int64($0), text: "第\($0 - 10)句") }
        let events: [[String: Any]] = twoEvents + [
            ["event_id": "E3", "title": "  ", "summary": "没标题的"],                       // 跳过
            ["event_id": "E4", "title": "范围颠倒", "summary": "s", "line_from": 15, "line_to": 13], // 去掉范围
            ["event_id": "E5", "title": "范围越界", "summary": "s", "line_from": 10, "line_to": 999], // 去掉范围
        ]
        let (clean, stats) = try ExtractValidate.validate(payload(events: events), lines: lines)
        XCTAssertEqual(stats.eventsDropped, 1)
        XCTAssertEqual(stats.eventRangesDropped, 2)
        try ExtractionStore.store(clean, transcriptID: 1, now: now, in: db)
        let rows = try db.read { try Row.fetchAll($0, sql: "SELECT title, first_line_id FROM summary_events ORDER BY seq") }
        XCTAssertEqual(rows.map { $0["title"] as String }, ["提测时间", "声纹", "范围颠倒", "范围越界"])
        XCTAssertEqual(rows.map { $0["first_line_id"] as Int64? }, [10, 13, nil, nil])
    }

    /// 我说的、缺「对谁」的承诺已经列在「你要做的」里 ⇒ 不许再算进「另有 N 条没有列出」。
    func testWithheldCountExcludesWhatIsAlreadyListedAsMine() throws {
        try ExtractionStore.store(payload(events: twoEvents), transcriptID: 1, now: now, in: db)
        let d = try XCTUnwrap(SessionDetailProjection.detail(sessionID: 1, in: db))
        XCTAssertEqual(d.commitmentsWithheld, 0, "\(d.myCommitments.map(\.lead))")
    }

    /// 第一段被移出记忆 ⇒ 标题退到下一段,不许拿墓碑字样当整场标题。
    func testTombstonedFirstEventDoesNotBecomeTheTitle() throws {
        try ExtractionStore.store(payload(events: twoEvents), transcriptID: 1, now: now, in: db)
        try MemoryRemoval.removeLines([11], audioFiles: [], in: db)
        let d = try XCTUnwrap(SessionDetailProjection.detail(sessionID: 1, in: db))
        XCTAssertEqual(d.title, "声纹")
        let cards = try HomeProjection.storedSummaries(day: "2026-10-12", in: db)
        XCTAssertEqual(cards[1]?.title, "声纹", "此刻页列表与详情页同一个标题(唯一出处 sessionTitle)")
    }

    /// 只有一头的范围被表约束挡住(否则「删几行」的墓碑清不到它)。
    func testHalfRangeIsRejectedByTheTable() throws {
        XCTAssertThrowsError(try db.write { try $0.execute(sql: """
            INSERT INTO summary_events (transcript_id, seq, title, summary, first_line_id) VALUES (1, 9, 't', 's', 10)
            """) })
    }

    func testExistingV46DatabaseReceivesForwardRangeConstraintWithoutLosingContent() throws {
        let old = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(old, upTo: "v46_summary_events")
        try old.write { d in
            try d.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status) VALUES (90, '2026-10-12T10:00:00+08:00', '2026-10-12', 'recording', 'closed');
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (90, 90, 1, 1, 'x', 'frozen', '2026-10-12T10:00:00+08:00');
                INSERT INTO transcript_lines (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
                VALUES (900, 90, 0, 0, 1000, 'old', 0);
                INSERT INTO summary_events (id, transcript_id, seq, title, summary, first_line_id)
                VALUES (90, 90, 0, '保留的旧标题', '保留的旧摘要', 900);
                """)
        }
        try AppDatabase.makeMigrator().migrate(old)
        try old.read { d in
            let row = try XCTUnwrap(Row.fetchOne(d, sql: "SELECT * FROM summary_events WHERE id = 90"))
            XCTAssertEqual(row["title"] as String, "保留的旧标题")
            XCTAssertEqual(row["summary"] as String, "保留的旧摘要")
            XCTAssertNil(row["first_line_id"] as Int64?)
            XCTAssertNil(row["last_line_id"] as Int64?)
        }
        XCTAssertThrowsError(try old.write { try $0.execute(sql: """
            INSERT INTO summary_events (transcript_id, seq, title, summary, first_line_id) VALUES (90, 1, 't', 's', 900)
            """) })
    }

    func testEventsAreStoredWithTheirRanges() throws {
        try ExtractionStore.store(payload(events: twoEvents), transcriptID: 1, now: now, in: db)
        let rows = try db.read { try Row.fetchAll($0, sql: "SELECT * FROM summary_events ORDER BY seq") }
        XCTAssertEqual(rows.map { $0["title"] as String }, ["提测时间", "声纹"])
        XCTAssertEqual(rows.map { $0["first_line_id"] as Int64 }, [10, 13])
        XCTAssertEqual(rows.map { $0["last_line_id"] as Int64 }, [12, 15])
    }

    /// 标题是契约必填:缺了点名报错,**不塞空串**,而且整份不落(同一个事务)。
    func testMissingTitleIsRejectedNotBlanked() throws {
        let bad: [[String: Any]] = [["event_id": "E1", "summary": "x", "line_from": 10, "line_to": 12]]
        XCTAssertThrowsError(try ExtractionStore.store(payload(events: bad), transcriptID: 1, now: now, in: db)) {
            XCTAssertTrue("\($0)".contains("events"), "\($0)")
        }
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM summaries") }, 0)
    }

    /// 范围指到不存在的行 ⇒ 拒(与其他四类同一条规矩:不新造悬空引用)。
    func testRangeOnUnknownLineIsRejected() throws {
        let bad: [[String: Any]] = [["event_id": "E1", "title": "a", "summary": "b", "line_from": 10, "line_to": 999]]
        XCTAssertThrowsError(try ExtractionStore.store(payload(events: bad), transcriptID: 1, now: now, in: db))
    }

    func testDetailProjectsClockSpeakersAndTopicsPerEvent() throws {
        try ExtractionStore.store(payload(events: twoEvents), transcriptID: 1, now: now, in: db)
        let d = try XCTUnwrap(SessionDetailProjection.detail(sessionID: 1, in: db))
        XCTAssertEqual(d.title, "提测时间")
        XCTAssertEqual(d.events.count, 2)
        let e1 = d.events[0], e2 = d.events[1]
        XCTAssertEqual(e1.clockRange, "14:00–14:11")   // 行 10 起 0ms,行 12 止 660s
        XCTAssertEqual(e1.speakers.count, 2, "我 + S1")
        XCTAssertEqual(e1.speakers.first, "我")
        XCTAssertEqual(e1.topics, [.init(key: "提测时间", firstLineID: 10)], "取段里最早出现的那一行")
        XCTAssertEqual(e2.speakers.count, 1)
        XCTAssertEqual(e2.topics.map(\.key), ["声纹"])
    }

    /// 我说的承诺不做三要素过滤(没有「对谁」也是我要做的事);别人的照旧过滤。
    func testMyCommitmentsIgnoreTheThreeElementRule() throws {
        try ExtractionStore.store(payload(events: twoEvents), transcriptID: 1, now: now, in: db)
        let d = try XCTUnwrap(SessionDetailProjection.detail(sessionID: 1, in: db))
        XCTAssertEqual(d.myCommitments.map(\.lead), ["整理评审意见"])
        XCTAssertEqual(d.commitments.map(\.lead), ["先测一周"], "缺「对谁」的那条不进三要素列表")
    }

    /// 认人改了,「你要做的」跟着变 —— 读时现算,不落快照。
    func testMyCommitmentsFollowAttribution() throws {
        try ExtractionStore.store(payload(events: twoEvents), transcriptID: 1, now: now, in: db)
        try db.write { try $0.execute(sql: "UPDATE line_speakers SET person_id = NULL, cluster_tag = 'S1' WHERE line_id = 12") }
        let d = try XCTUnwrap(SessionDetailProjection.detail(sessionID: 1, in: db))
        XCTAssertTrue(d.myCommitments.isEmpty)
    }

    /// 老产物没有事件:详情为空(界面如实说),标题退回 nil(界面用一句话)。
    func testOldPayloadHasNoEvents() throws {
        var p = payload(events: [])
        p.removeValue(forKey: "events")
        try ExtractionStore.store(p, transcriptID: 1, now: now, in: db)
        let d = try XCTUnwrap(SessionDetailProjection.detail(sessionID: 1, in: db))
        XCTAssertTrue(d.events.isEmpty)
        XCTAssertNil(d.title)
    }

    /// 没有行范围的老事件:不编钟点、不编在场的人;只有一段时话题整场挂上。
    func testEventWithoutRangeInventsNothing() throws {
        try ExtractionStore.store(payload(events: [["event_id": "E1", "title": "t", "summary": "s"]]),
                                  transcriptID: 1, now: now, in: db)
        let e = try XCTUnwrap(SessionDetailProjection.detail(sessionID: 1, in: db)?.events.first)
        XCTAssertNil(e.clockRange)
        XCTAssertTrue(e.speakers.isEmpty)
        XCTAssertEqual(e.topics.map(\.key), ["提测时间", "声纹"])
    }

    /// 移出记忆:删掉的那句落在哪一段,哪一段的标题与摘要整段清掉;别的段不动。
    func testRemovingLinesTombstonesOnlyTheCoveringEvent() throws {
        try ExtractionStore.store(payload(events: twoEvents), transcriptID: 1, now: now, in: db)
        try MemoryRemoval.removeLines([14], audioFiles: [], in: db)
        let rows = try db.read { try Row.fetchAll($0, sql: "SELECT title, summary FROM summary_events ORDER BY seq") }
        XCTAssertEqual(rows[0]["summary"] as String, "定了 11 月 2 日。")
        XCTAssertEqual(rows[1]["summary"] as String, MemoryRemoval.tombstoneText)
        XCTAssertEqual(rows[1]["title"] as String, MemoryRemoval.tombstoneText)
    }

    /// 没有范围的老事件:不知道盖没盖到 ⇒ 按盖到处理(隐私上宁可多清)。
    func testRemovingLinesTombstonesRangelessEvents() throws {
        try ExtractionStore.store(payload(events: [["event_id": "E1", "title": "t", "summary": "s"]]),
                                  transcriptID: 1, now: now, in: db)
        try MemoryRemoval.removeLines([11], audioFiles: [], in: db)
        XCTAssertEqual(try db.read { try String.fetchOne($0, sql: "SELECT summary FROM summary_events") },
                       MemoryRemoval.tombstoneText)
    }

    func testSingleEventDetailAndTranscriptExcludeOtherEvents() throws {
        try ExtractionStore.store(payload(events:twoEvents),transcriptID:1,now:now,in:db)
        let id=try db.read { try XCTUnwrap(Int64.fetchOne($0,sql:"SELECT id FROM summary_events WHERE seq=1")) }
        let detail=try XCTUnwrap(SessionDetailProjection.detail(sessionID:1,eventID:id,in:db))
        XCTAssertEqual(detail.title,"声纹")
        XCTAssertEqual(detail.oneLiner,"先测一周。")
        XCTAssertEqual(detail.events.map(\.id),[id])
        XCTAssertEqual(detail.lineCount,3)
        XCTAssertTrue(detail.keyPoints.isEmpty)
        XCTAssertTrue(detail.myCommitments.isEmpty)
        XCTAssertEqual(detail.commitments.map(\.lineID),[13])
        XCTAssertEqual(try SessionDetailProjection.transcript(sessionID:1,eventID:id,in:db).map(\.id),[13,14,15])
        XCTAssertEqual(try SessionDetailProjection.quoteContext(lineID:13,eventID:id,in:db).lines.map(\.id),[13,14,15],"事件边界处的原话弹层不能带入上一件事")
        XCTAssertThrowsError(try SessionDetailProjection.quoteContext(lineID:12,eventID:id,in:db))
        XCTAssertThrowsError(try SessionDetailProjection.quoteContext(lineID:13,eventID:99999,in:db))
    }

    func testForeignReplacedAndRemovedEventsNeverFallBackToWholeSession() throws {
        try ExtractionStore.store(payload(events:twoEvents),transcriptID:1,now:now,in:db)
        let id=try db.read { try XCTUnwrap(Int64.fetchOne($0,sql:"SELECT id FROM summary_events WHERE seq=0")) }
        XCTAssertThrowsError(try SessionDetailProjection.detail(sessionID:1,eventID:99999,in:db))
        XCTAssertThrowsError(try SessionDetailProjection.transcript(sessionID:1,eventID:99999,in:db))
        _ = try MemoryRemoval.removeLines([10],audioFiles:[],in:db)
        XCTAssertThrowsError(try SessionDetailProjection.detail(sessionID:1,eventID:id,in:db))
        XCTAssertThrowsError(try SessionDetailProjection.transcript(sessionID:1,eventID:id,in:db))
        XCTAssertEqual(try HomeProjection.eventDays(in:db),["2026-10-12"])
        _ = try MemoryRemoval.removeLines([13],audioFiles:[],in:db)
        XCTAssertTrue(try HomeProjection.eventDays(in:db).isEmpty)
    }

    func testRangelessEventShowsItsSummaryWithoutBorrowingOtherContent() throws {
        try ExtractionStore.store(payload(events:[["title":"范围尚未标出","summary":"只展示本事件摘要"]]),transcriptID:1,now:now,in:db)
        let id=try db.read { try XCTUnwrap(Int64.fetchOne($0,sql:"SELECT id FROM summary_events")) }
        let detail=try XCTUnwrap(SessionDetailProjection.detail(sessionID:1,eventID:id,in:db))
        XCTAssertEqual(detail.title,"范围尚未标出")
        XCTAssertEqual(detail.oneLiner,"只展示本事件摘要")
        XCTAssertEqual(detail.lineCount,0)
        XCTAssertTrue(detail.keyPoints.isEmpty)
        XCTAssertTrue(detail.myCommitments.isEmpty)
        XCTAssertTrue(try SessionDetailProjection.transcript(sessionID:1,eventID:id,in:db).isEmpty)
        XCTAssertTrue(try db.read { try AskScope(sessionID:1,eventID:id).materials(for:"说了什么",in:$0).isEmpty })
    }

    func testEventContinuationIncludesOnlyItsFragmentsAcrossParts() throws {
        try ExtractionStore.store(payload(events:twoEvents),transcriptID:1,now:now,in:db)
        let root=try db.read { try XCTUnwrap(Int64.fetchOne($0,sql:"SELECT id FROM summary_events WHERE seq=0")) }
        try db.write { d in
            try d.execute(sql:"INSERT INTO transcripts(id,session_id,version,part,asr_model,status,created_at) VALUES(2,1,1,2,'test','frozen',?)",arguments:[now])
            try d.execute(sql:"INSERT INTO transcript_lines(line_id,transcript_id,seq,t_start_ms,t_end_ms,text,char_offset) VALUES(20,2,0,2000000,2060000,'后续讨论',0),(21,2,1,2060000,2100000,'另一件事',4)")
            try d.execute(sql:"INSERT INTO summary_events(transcript_id,seq,title,summary,first_line_id,last_line_id,continuation_id) VALUES(2,0,'提测时间','补充讨论',20,20,?),(2,1,'另一件事','独立讨论',21,21,NULL)",arguments:[root])
        }
        let detail=try XCTUnwrap(SessionDetailProjection.detail(sessionID:1,eventID:root,in:db))
        XCTAssertEqual(detail.lineCount,4)
        XCTAssertEqual(try SessionDetailProjection.transcript(sessionID:1,eventID:root,in:db).map(\.id),[10,11,12,20])
        XCTAssertFalse(detail.commitments.contains { $0.lineID==13 })
        _ = try MemoryRemoval.removeLines([10],audioFiles:[],in:db)
        let after=try XCTUnwrap(SessionDetailProjection.detail(sessionID:1,eventID:root,in:db))
        XCTAssertEqual(after.lineCount,1)
        XCTAssertEqual(after.events.first?.clockRange,"14:33–14:34")
        XCTAssertTrue(after.events.first!.topics.isEmpty,"首片墓碑的主题不能借后片延续重新显示")
        XCTAssertTrue(after.events.first!.speakers.isEmpty)
        XCTAssertEqual(try SessionDetailProjection.transcript(sessionID:1,eventID:root,in:db).map(\.id),[20])
        XCTAssertEqual(try SessionDetailProjection.quoteContext(lineID:20,eventID:root,in:db).lines.map(\.id),[20])
        XCTAssertEqual(try db.read { try AskScope(sessionID:1,eventID:root).label(in:$0) },"提测时间")
        XCTAssertEqual(try db.read { try AskScope(sessionID:1,eventID:root).materials(for:"说了什么",in:$0).map { $0.hit.lineID } },[20])
        XCTAssertThrowsError(try SessionDetailProjection.quoteContext(lineID:10,eventID:root,in:db))
        let foreign=try db.write { d -> Int64 in
            let second=try Int64.fetchOne(d,sql:"SELECT id FROM summary_events WHERE transcript_id=2 AND seq=0")!
            try d.execute(sql:"INSERT INTO transcripts(id,session_id,version,part,asr_model,status,created_at) VALUES(3,1,1,3,'test','frozen',?)",arguments:[now])
            try d.execute(sql:"INSERT INTO transcript_lines(line_id,transcript_id,seq,t_start_ms,t_end_ms,text,char_offset) VALUES(30,3,0,3000000,3060000,'最终确认',0)")
            try d.execute(sql:"INSERT INTO summary_events(transcript_id,seq,title,summary,first_line_id,last_line_id,continuation_id) VALUES(3,0,'最后确认','第三片延续',30,30,?)",arguments:[second])
            try d.execute(sql:"INSERT INTO sessions(id,started_at,day,source,status) VALUES(99,'2026-10-12T15:00:00+08:00','2026-10-12','watch','closed')")
            try d.execute(sql:"INSERT INTO transcripts(id,session_id,version,part,asr_model,status,created_at) VALUES(99,99,1,1,'test','frozen',?)",arguments:[now])
            try d.execute(sql:"INSERT INTO transcript_lines(line_id,transcript_id,seq,t_start_ms,t_end_ms,text,char_offset) VALUES(99,99,0,0,1000,'另一场原话',0)")
            try d.execute(sql:"INSERT INTO summary_events(transcript_id,seq,title,summary,first_line_id,last_line_id) VALUES(99,0,'另一场事件','不得串场',99,99)")
            return d.lastInsertedRowID
        }
        _ = try MemoryRemoval.removeLines([20],audioFiles:[],in:db)
        XCTAssertEqual(try SessionDetailProjection.transcript(sessionID:1,eventID:root,in:db).map(\.id),[30])
        XCTAssertEqual(try db.read { try AskScope(sessionID:1,eventID:root).materials(for:"说了什么",in:$0).map { $0.hit.lineID } },[30])
        XCTAssertEqual(try db.read { try AskScope(sessionID:1,eventID:root).label(in:$0) },"最后确认")
        XCTAssertEqual(try HomeProjection.understoodEvents(day:"2026-10-12",in:db).first { $0.event.id==root }?.latestMillis,3060000)
        XCTAssertThrowsError(try SessionDetailProjection.detail(sessionID:1,eventID:foreign,in:db))
        XCTAssertThrowsError(try SessionDetailProjection.transcript(sessionID:1,eventID:foreign,in:db))
        XCTAssertThrowsError(try db.read { try AskScope(sessionID:1,eventID:foreign).materials(for:"原话",in:$0) })
    }

    /// 重抽(上一次是空产物)时事件一起换,不叠两份。
    func testReextractionReplacesEvents() throws {
        try db.write { db in
            try db.execute(sql: "INSERT INTO summaries (transcript_id, one_liner, created_at) VALUES (1, '', ?)",
                           arguments: [now])
            try db.execute(sql: """
                INSERT INTO summary_events (transcript_id, seq, title, summary) VALUES (1, 0, '旧的', '旧的')
                """)
        }
        try ExtractionStore.store(payload(events: twoEvents), transcriptID: 1, now: now, in: db)
        XCTAssertEqual(try db.read { try String.fetchAll($0, sql: "SELECT title FROM summary_events ORDER BY seq") },
                       ["提测时间", "声纹"])
    }
}
