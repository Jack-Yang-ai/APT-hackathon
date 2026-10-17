import XCTest
import GRDB
@testable import GrowthApp






final class SessionDetailTests: XCTestCase {

    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try TestPeople.seed(in: dbQueue)
    }

    override func tearDownWithError() throws { dbQueue = nil }



    private func seed(withSpeakers: Bool = true) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, ended_at, day, source, status)
                VALUES (1, '2026-08-14T10:24:00+08:00', '2026-08-14T11:02:00+08:00',
                        '2026-08-14', 'recording', 'closed')
                """)
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (7, 1, 1, 1, 'step-asr-v1', 'frozen', '2026-08-14T11:02:00+08:00')
                """)
            for i in 0..<8 {
                try db.execute(sql: """
                    INSERT INTO transcript_lines
                      (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset,
                       is_gap, redacted)
                    VALUES (?, 7, ?, ?, ?, ?, 0, ?, ?)
                    """, arguments: [100 + i, i, i * 10_000, i * 10_000 + 8_000,
                                     "第 \(i) 句原话", i == 3 ? 1 : 0, i == 5 ? 1 : 0])
                if withSpeakers {
                    try db.execute(sql: """
                        INSERT INTO line_speakers
                          (line_id, person_id, cluster_tag, source, confidence, updated_at)
                        VALUES (?, ?, ?, '声纹识别', 0.8, '2026-08-14T11:02:00+08:00')
                        """, arguments: [100 + i, i % 2 == 0 ? 1 : 2, "S\(i % 2)"])
                }
            }
            try db.execute(sql: """
                INSERT INTO summaries (transcript_id, one_liner, created_at)
                VALUES (7, '把新版本的方向说清楚了', '2026-08-14T11:02:00+08:00')
                """)
            try db.execute(sql: """
                INSERT INTO summary_key_points (transcript_id, line_id, seq, text, quote)
                VALUES (7, 100, 1, '先验证连续使用', '第 0 句原话'),
                       (7, 102, 2, '卡片留在场次里', '第 2 句原话')
                """)

            try db.execute(sql: """
                INSERT INTO summary_commitments
                  (transcript_id, line_id, seq, what, to_whom_text, quote)
                VALUES (7, 100, 1, '周五前给方案', '小李', '第 0 句原话'),
                       (7, 102, 2, '补一版数据',   NULL,   '第 2 句原话')
                """)
            try db.execute(sql: """
                INSERT INTO summary_stances (transcript_id, line_id, seq, stance, premise, quote)
                VALUES (7, 100, 1, '不该现在扩范围', '先把主路径跑通', '第 0 句原话'),
                       (7, 101, 2, '可以先试一版',   NULL,             '第 1 句原话')
                """)
            try db.execute(sql: """
                INSERT INTO summary_pendings (transcript_id, line_id, seq, issue, parties_text, quote)
                VALUES (7, 104, 1, '归属规则还没定', '我和小李', '第 4 句原话')
                """)
        }
    }



    func testAllFiveBlocksAreRead() throws {
        try seed()
        let d = try XCTUnwrap(SessionDetailProjection.detail(sessionID: 1, in: dbQueue))

        XCTAssertEqual(d.oneLiner, "把新版本的方向说清楚了")
        XCTAssertEqual(d.keyPoints.count, 2)
        XCTAssertEqual(d.commitments.count, 1, "三要素齐的只有一条")
        XCTAssertEqual(d.stances.count, 2)
        XCTAssertEqual(d.pendings.count, 1)
        XCTAssertEqual(d.lineCount, 8)
        XCTAssertEqual(d.durationMinutes, 1, "最后一行 t_end_ms = 78000 → 1 分钟")
        XCTAssertEqual(d.speakerCount, 2)
        XCTAssertEqual(d.startTime, "10:24")
    }




    func testIncompleteCommitmentIsWithheldAndCounted() throws {
        try seed()
        let d = try XCTUnwrap(SessionDetailProjection.detail(sessionID: 1, in: dbQueue))
        XCTAssertEqual(d.commitments.map(\.lead), ["周五前给方案"])
        XCTAssertEqual(d.commitmentsWithheld, 1, "被挡下的那条没有被计数 —— 它会静默消失")
    }













    func testCommitmentsAreListedWithBlankWhoWhileAttributionIsPending() throws {
        try seed(withSpeakers: false)
        let d = try XCTUnwrap(SessionDetailProjection.detail(sessionID: 1, in: dbQueue))


        XCTAssertEqual(d.commitments.map(\.lead), ["周五前给方案"],
                       "归属没跑就把承诺全清空了 —— 而那是 M1 的常态")
        XCTAssertNil(d.commitments.first?.speaker, "「谁」该留空,不该编一个")

        XCTAssertEqual(d.commitmentsWithheld, 1,
                       "被挡下的应该只有抽取缺字段那条,不含「还不知道谁说的」")
    }



    func testExtractionGapsAreStillWithheldIncludingWhitespace() throws {
        try seed(withSpeakers: false)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO summary_commitments
                  (transcript_id, line_id, seq, what, to_whom_text, quote)
                VALUES (7, 104, 3, '再跟一次进度', '   ', '第 4 句原话')
                """)
        }
        let d = try XCTUnwrap(SessionDetailProjection.detail(sessionID: 1, in: dbQueue))
        XCTAssertFalse(d.commitments.contains { $0.lead == "再跟一次进度" },
                       "「对谁」是一串空格,被当成三要素齐了")
        XCTAssertEqual(d.commitmentsWithheld, 2)
    }



    func testStanceTitleNeverClaimsItIsMeBeforeConfirmation() throws {
        try seed()
        let d = try XCTUnwrap(SessionDetailProjection.detail(sessionID: 1, in: dbQueue))
        XCTAssertEqual(d.stanceTitle, "表态(按说话人)")
        XCTAssertFalse(d.stanceTitle.contains("我的"), "本人还没确认就不能说「我的表态」")
    }



    func testEmptyBlocksComeBackEmptyNotPlaceholders() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, ended_at, day, source, status)
                VALUES (1, '2026-08-14T10:24:00+08:00', '2026-08-14T10:30:00+08:00',
                        '2026-08-14', 'recording', 'closed')
                """)
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (7, 1, 1, 1, 'step-asr-v1', 'frozen', '2026-08-14T10:30:00+08:00')
                """)
        }
        let d = try XCTUnwrap(SessionDetailProjection.detail(sessionID: 1, in: dbQueue))
        XCTAssertTrue(d.keyPoints.isEmpty && d.commitments.isEmpty
                      && d.stances.isEmpty && d.pendings.isEmpty)
        XCTAssertEqual(d.commitmentsWithheld, 0)
    }



    func testSessionWithoutTranscriptReturnsNilNotAnEmptyShell() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, '2026-08-14T10:24:00+08:00', '2026-08-14', 'recording', 'closed')
                """)
        }
        XCTAssertNil(try SessionDetailProjection.detail(sessionID: 1, in: dbQueue))
    }





    func testSpeakersAreNamedNotShownAsRawIDs() throws {
        try seed()
        let d = try XCTUnwrap(SessionDetailProjection.detail(sessionID: 1, in: dbQueue))

        XCTAssertEqual(d.speakers, ["说话人 1", "说话人 2"])
        for s in d.speakers {
            XCTAssertFalse(s.allSatisfy(\.isNumber), "裸的 person_id「\(s)」漏到界面上了")
            XCTAssertFalse(s.hasPrefix("S"), "cluster_tag「\(s)」漏到界面上了")
        }
        XCTAssertEqual(Set(d.stances.compactMap(\.speaker)), ["说话人 1", "说话人 2"])
    }



    func testSpeakerNumbersFollowFirstAppearance() throws {
        try seed()
        let ctx = try SessionDetailProjection.quoteContext(lineID: 100, in: dbQueue)
        XCTAssertEqual(ctx.lines.first { $0.id == 100 }?.speaker, "说话人 1")
        XCTAssertEqual(ctx.lines.first { $0.id == 101 }?.speaker, "说话人 2")
    }









    func testTwoScreensNeverCallTheSamePersonDifferentNames() throws {
        try seed()


        let d = try XCTUnwrap(SessionDetailProjection.detail(sessionID: 1, in: dbQueue))



        let naming = try dbQueue.read { try SpeakerNaming.labels(in: $0) }


        XCTAssertEqual(naming["p:1"], "说话人 1")
        XCTAssertEqual(naming["p:2"], "说话人 2")
        XCTAssertEqual(Set(d.speakers), Set([naming["p:1"], naming["p:2"]].compactMap { $0 }),
                       "详情页与全局命名表对不上 —— 两屏会把同一个人叫成两个名字")
    }






    func testConfirmedSelfIsCalledMeEverywhere() throws {
        try seed()

        var naming = try dbQueue.read { try SpeakerNaming.labels(in: $0) }
        XCTAssertEqual(naming["p:1"], "说话人 1")




        _ = try AssignSpeaker.assignSpeaker(
            lines: [100, 102, 104, 106], person: SpeakerNaming.mePersonID, clusterTag: nil,
            source: .userConfirmed, confidence: nil, actor: .user,
            now: "2026-08-14T12:00:00+08:00", in: dbQueue)

        naming = try dbQueue.read { try SpeakerNaming.labels(in: $0) }


        XCTAssertEqual(naming[SpeakerNaming.meKey], "我",
                       "确认过本人之后还没改叫「我」")
        XCTAssertEqual(naming["p:2"], "说话人 1", "别人该按剩下的出场顺序重编")
        XCTAssertNil(naming["p:1"], "person 1 的行已经全部转成本人,这个键不该还在")

        let d = try XCTUnwrap(SessionDetailProjection.detail(sessionID: 1, in: dbQueue))
        XCTAssertTrue(d.speakers.contains("我"), "详情页没跟着改口:\(d.speakers)")





        XCTAssertTrue(d.hasConfirmedMe)
        XCTAssertEqual(d.stanceTitle, "我的表态")
    }



    func testAVoiceprintGuessDoesNotEarnTheMyStanceTitle() throws {
        try seed()
        _ = try AssignSpeaker.assignSpeaker(
            lines: [100, 102, 104, 106], person: SpeakerNaming.mePersonID, clusterTag: nil,
            source: .voiceprint, confidence: 0.9, actor: .system,
            now: "2026-08-14T12:00:00+08:00", in: dbQueue)
        let d = try XCTUnwrap(SessionDetailProjection.detail(sessionID: 1, in: dbQueue))
        XCTAssertFalse(d.hasConfirmedMe)
        XCTAssertEqual(d.stanceTitle, "表态(按说话人)")
    }






    func testMePersonIDCannotCollideWithPipelineIDs() {
        XCTAssertLessThan(SpeakerNaming.mePersonID, 0,
                          "本人 id 是正数就会和管线自己编的 person_id 撞上")
    }



    func testPersonOneIsNotCalledMeUntilTheUserSaysSo() throws {
        try seed()   // 夹具全是「声纹识别」,person 1 存在但没人确认过
        let naming = try dbQueue.read { try SpeakerNaming.labels(in: $0) }
        XCTAssertEqual(naming["p:1"], "说话人 1",
                       "没确认就叫「我」—— 那是拿管线编的号冒充用户的判断")
    }








    func testClusterTagsDoNotMergeAcrossSessions() throws {
        try dbQueue.write { db in
            for (sid, tid, lid) in [(1 as Int64, 7 as Int64, 300 as Int64),
                                    (2, 8, 400)] {
                try db.execute(sql: """
                    INSERT INTO sessions (id, started_at, ended_at, day, source, status)
                    VALUES (?, ?, ?, '2026-08-14', 'recording', 'closed')
                    """, arguments: [sid, "2026-08-1\(sid)T10:00:00+08:00",
                                     "2026-08-1\(sid)T10:30:00+08:00"])
                try db.execute(sql: """
                    INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                    VALUES (?, ?, 1, 1, 'step-asr-v1', 'frozen', '2026-08-14T10:30:00+08:00')
                    """, arguments: [tid, sid])
                try db.execute(sql: """
                    INSERT INTO transcript_lines
                      (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
                    VALUES (?, ?, 0, 0, 5000, '这一场的第一句', 0)
                    """, arguments: [lid, tid])

                try db.execute(sql: """
                    INSERT INTO line_speakers (line_id, cluster_tag, source, confidence, updated_at)
                    VALUES (?, 'S0', '声纹识别', 0.8, '2026-08-14T10:30:00+08:00')
                    """, arguments: [lid])
            }
        }
        let naming = try dbQueue.read { try SpeakerNaming.labels(in: $0) }
        XCTAssertEqual(naming.count, 2,
                       "两场的 S0 被合成一个人了 —— 点一次「是我」会把两场都写掉")




        XCTAssertEqual(Set(naming.values).count, 2,
                       "两场的第一个说话人显示成了同一个名字 —— 在待确认列表里分不出来")
        XCTAssertEqual(Set(naming.values), ["08-11 10:00 的说话人 1", "08-12 10:00 的说话人 1"])



        let inSession1 = try dbQueue.read { try SpeakerNaming.labels(in: $0, scope: .session(1)) }
        XCTAssertEqual(Set(inSession1.values), ["说话人 1", "08-12 10:00 的说话人 1"])
    }



    func testPersonIDsDoMergeAcrossSessions() throws {
        try dbQueue.write { db in
            for (sid, tid, lid) in [(1 as Int64, 7 as Int64, 300 as Int64),
                                    (2, 8, 400)] {
                try db.execute(sql: """
                    INSERT INTO sessions (id, started_at, ended_at, day, source, status)
                    VALUES (?, ?, ?, '2026-08-14', 'recording', 'closed')
                    """, arguments: [sid, "2026-08-1\(sid)T10:00:00+08:00",
                                     "2026-08-1\(sid)T10:30:00+08:00"])
                try db.execute(sql: """
                    INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                    VALUES (?, ?, 1, 1, 'step-asr-v1', 'frozen', '2026-08-14T10:30:00+08:00')
                    """, arguments: [tid, sid])
                try db.execute(sql: """
                    INSERT INTO transcript_lines
                      (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
                    VALUES (?, ?, 0, 0, 5000, '这一场的第一句', 0)
                    """, arguments: [lid, tid])
                try db.execute(sql: """
                    INSERT INTO line_speakers (line_id, person_id, source, confidence, updated_at)
                    VALUES (?, 42, '声纹识别', 0.9, '2026-08-14T10:30:00+08:00')
                    """, arguments: [lid])
            }
        }
        let naming = try dbQueue.read { try SpeakerNaming.labels(in: $0) }
        XCTAssertEqual(naming.count, 1, "同一个 person_id 在两场里被拆成了两个人")
        XCTAssertEqual(naming["p:42"], "说话人 1")
    }



    func testNumbersAreGlobalNotPerSession() throws {
        try seed()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, ended_at, day, source, status)
                VALUES (2, '2026-08-14T15:00:00+08:00', '2026-08-14T15:10:00+08:00',
                        '2026-08-14', 'recording', 'closed')
                """)
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (8, 2, 1, 1, 'step-asr-v1', 'frozen', '2026-08-14T15:10:00+08:00')
                """)
            try db.execute(sql: """
                INSERT INTO transcript_lines
                  (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
                VALUES (200, 8, 0, 0, 5000, '第二场第一句', 0)
                """)

            try db.execute(sql: """
                INSERT INTO line_speakers (line_id, person_id, cluster_tag, source, updated_at)
                VALUES (200, 9, 'S9', '声纹识别', '2026-08-14T15:10:00+08:00')
                """)
        }

        let d2 = try XCTUnwrap(SessionDetailProjection.detail(sessionID: 2, in: dbQueue))
        XCTAssertEqual(d2.speakers, ["说话人 3"],
                       "第二场唯一的说话人被重编成了「说话人 1」—— 编号成了本场序号")
    }


    func testTranscriptUsesTheSameSpeakerNames() throws {
        try seed()
        let lines = try SessionDetailProjection.transcript(sessionID: 1, in: dbQueue)
        XCTAssertEqual(Set(lines.compactMap(\.speaker)), ["说话人 1", "说话人 2"])
    }




    func testQuoteContextGivesThreeEachSideAndMarksTheTarget() throws {
        try seed()
        let ctx = try SessionDetailProjection.quoteContext(lineID: 104, in: dbQueue)

        XCTAssertEqual(ctx.lines.map(\.id), [101, 102, 103, 104, 105, 106, 107])
        XCTAssertEqual(ctx.lines.filter(\.isTarget).map(\.id), [104],
                       "高亮的必须且只能是被点的那一行")
    }


    func testQuoteContextClampsAtTheStart() throws {
        try seed()
        let ctx = try SessionDetailProjection.quoteContext(lineID: 100, in: dbQueue)
        XCTAssertEqual(ctx.lines.map(\.id), [100, 101, 102, 103])
        XCTAssertEqual(ctx.lines.first?.isTarget, true)
    }


    func testKeyPointLineIDsResolveToRealLines() throws {
        try seed()
        let d = try XCTUnwrap(SessionDetailProjection.detail(sessionID: 1, in: dbQueue))
        for kp in d.keyPoints {
            let ctx = try SessionDetailProjection.quoteContext(lineID: kp.lineID, in: dbQueue)
            XCTAssertEqual(ctx.lines.filter(\.isTarget).map(\.id), [kp.lineID],
                           "要点「\(kp.lead)」的 lineID 跳不到对应的行")
        }
    }



    func testRedactedLineIsNotEchoedBack() throws {
        try seed()
        let ctx = try SessionDetailProjection.quoteContext(lineID: 105, in: dbQueue)
        let target = try XCTUnwrap(ctx.lines.first { $0.id == 105 })
        XCTAssertEqual(target.text, "(这段已抹除)")
        XCTAssertFalse(ctx.lines.contains { $0.text == "第 5 句原话" }, "抹除的原文漏出来了")
    }


    func testGapLineIsFlaggedNotDisguisedAsContent() throws {
        try seed()
        let ctx = try SessionDetailProjection.quoteContext(lineID: 103, in: dbQueue)
        XCTAssertEqual(ctx.lines.first { $0.id == 103 }?.isGap, true)
    }


    func testFullTranscriptComesBackInOrder() throws {
        try seed()
        let lines = try SessionDetailProjection.transcript(sessionID: 1, in: dbQueue)
        XCTAssertEqual(lines.map(\.id), Array(100...107))
    }
}
