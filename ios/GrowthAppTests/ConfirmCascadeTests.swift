import XCTest
import GRDB
@testable import GrowthApp








final class ConfirmCascadeTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-09-01T20:00:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status, active_transcript_id)
                VALUES (9, ?, '2026-09-01', 'recording', 'closed', 9)
                """, arguments: [now])
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (9, 9, 1, 1, 'step-asr', 'frozen', ?)
                """, arguments: [now])
            for (id, name, src) in [(1 as Int64, "人物甲" as String?, "用户创建"),
                                    (82, "人物戊", "用户创建"),
                                    (90, nil, "声纹聚类")] {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO persons (id, name, source, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [id, name, src, now, now])
            }
            for i in 0..<6 {
                try db.execute(sql: """
                    INSERT INTO transcript_lines
                      (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, block_seq)
                    VALUES (?, 9, ?, ?, ?, '一句话', 0, 0)
                    """, arguments: [200 + i, i, i * 10_000, i * 10_000 + 5_000])
            }
        }
    }
    override func tearDownWithError() throws { dbQueue = nil }

    private func attribute(_ lineID: Int64, tag: String?, source: String, person: Int64? = nil) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO line_speakers
                  (line_id, person_id, cluster_tag, confidence, source, updated_at)
                VALUES (?, ?, ?, 0.5, ?, ?)
                """, arguments: [lineID, person, tag, source, now])
        }
    }
    private func state(_ lineID: Int64) throws -> (Int64?, String) {
        try dbQueue.read { db in
            let r = try Row.fetchOne(db, sql:
                "SELECT person_id, source FROM line_speakers WHERE line_id = ?",
                arguments: [lineID])!
            return (r["person_id"], r["source"])
        }
    }





    func testConfirmingOneHalfAlsoTakesTheHalfWithTheUnrewrittenTag() throws {
        try attribute(200, tag: "9-speaker_0", source: "声纹识别", person: 90)
        try attribute(201, tag: "9-speaker_0", source: "声纹识别", person: 90)
        try attribute(202, tag: "speaker_0",   source: "系统整理")

        let (r, cascaded) = try ConfirmCascade.confirm(lines: [200, 201], person: 1,
                                                       now: now, in: dbQueue)
        XCTAssertEqual(r.changedLines.sorted(), [200, 201])
        XCTAssertEqual(cascaded, [202], """
            同一个上游说话人剩下的行没跟着走 —— 它会在待确认里再出现一次,
            而内容出自同一个人同一场,用户看到的就是「刚认过的话又来问我」。
            """)
        XCTAssertEqual(try state(202).0, 1, "带过去了但没归对人")
    }





    func testCascadedLinesStayOverwritable() throws {
        try attribute(200, tag: "9-speaker_0", source: "声纹识别", person: 90)
        try attribute(201, tag: "speaker_0",   source: "系统整理")

        _ = try ConfirmCascade.confirm(lines: [200], person: 1, now: now, in: dbQueue)
        XCTAssertEqual(try state(200).1, AttributionSource.userConfirmed.rawValue)
        XCTAssertEqual(try state(201).1, AttributionSource.crossValidated.rawValue, """
            级联的行被写成了不可覆盖的来源 —— 下一轮声纹判出别的结果也盖不掉,
            而这些行没有任何声学证据支撑。
            """)

        _ = try AssignSpeaker.assignSpeaker(lines: [201], person: 82, clusterTag: nil,
                                            source: .voiceprint, confidence: 0.9,
                                            actor: .system, now: now, in: dbQueue)
        XCTAssertEqual(try state(201).0, 82, "级联的行盖不掉 —— 那它就不该是自动来源")
    }





    func testALineAlreadyOwnedByARealPersonIsNeverAbsorbed() throws {
        try attribute(200, tag: "speaker_1", source: "用户确认", person: 82)   // 人物戊
        try attribute(201, tag: "speaker_1", source: "声纹识别", person: 90)   // 匿名人格
        try attribute(202, tag: "speaker_1", source: "系统整理")               // 没有身份

        let (_, cascaded) = try ConfirmCascade.confirm(lines: [201], person: 1,
                                                       now: now, in: dbQueue)
        XCTAssertEqual(cascaded, [202], "把已经归给人物戊的那行也吸走了 —— 那是确定的错归属")
        XCTAssertEqual(try state(200).0, 82, "人物戊的行被改掉了")
    }


    func testTheCascadeJudgmentPointsBackAtTheConfirmation() throws {
        try attribute(200, tag: "9-speaker_0", source: "声纹识别", person: 90)
        try attribute(201, tag: "speaker_0",   source: "系统整理")

        let (r, _) = try ConfirmCascade.confirm(lines: [200], person: 1, now: now, in: dbQueue)
        let caused = try dbQueue.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT caused_by FROM judgments WHERE actor = 'system-cascade' AND caused_by IS NOT NULL
                """)
        }
        XCTAssertEqual(caused, [r.judgmentID], "级联没有回链,账上看不出它是因为哪一次确认")
    }






    func testRetroactivePlanTakesTheUnownedLinesOfAConfirmedTag() throws {
        try attribute(200, tag: "9-speaker_0", source: "用户确认", person: 1)
        try attribute(201, tag: "speaker_0",   source: "系统整理")            // 无身份
        try attribute(202, tag: "speaker_0",   source: "声纹识别", person: 90) // 匿名人格
        try attribute(203, tag: "speaker_1",   source: "系统整理")            // 别的牌,不该动

        let plan = try dbQueue.read { try ConfirmCascade.retroactivePlan(in: $0) }
        XCTAssertEqual(plan.map(\.line), [201, 202], "存量该带上的行没找全/找错了")
        XCTAssertEqual(Set(plan.map(\.person)), [1])
    }





    func testRetroactivePlanSkipsATagThatConfirmsTwoPeople() throws {
        try attribute(200, tag: "9-speaker_0", source: "用户确认", person: 1)
        try attribute(201, tag: "speaker_0",   source: "用户确认", person: 82)
        try attribute(202, tag: "speaker_0",   source: "系统整理")

        XCTAssertEqual(try dbQueue.read { try ConfirmCascade.retroactivePlan(in: $0) }.count, 0, """
            一张牌下有两个人还照样归 —— 那是在两个人里瞎猜一个,
            而被猜错的那些行在界面上与判对的长得一模一样。
            """)
    }


    func testLinesWithoutAnUpstreamTagCascadeNothing() throws {
        try attribute(200, tag: nil, source: "声纹识别", person: 90)
        try attribute(201, tag: nil, source: "系统整理")

        let (_, cascaded) = try ConfirmCascade.confirm(lines: [200], person: 1, now: now, in: dbQueue)
        XCTAssertEqual(cascaded, [], "没有上游标签也把别的行带走了 —— 那是按「都没有牌子」并人")
    }
}

