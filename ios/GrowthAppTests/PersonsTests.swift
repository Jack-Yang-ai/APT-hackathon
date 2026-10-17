import XCTest
import GRDB
@testable import GrowthApp







final class PersonsTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-17T15:00:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, '2026-08-17T14:00:00+08:00', '2026-08-17', 'recording', 'closed')
                """)
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (1, 1, 1, 1, 'step-asr-v1', 'frozen', '2026-08-17T14:30:00+08:00')
                """)
            for seq in 0..<4 {
                try db.execute(sql: """
                    INSERT INTO transcript_lines
                      (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
                    VALUES (?, 1, ?, ?, ?, ?, 0)
                    """, arguments: [10 + seq, seq, seq * 1000, seq * 1000 + 900, "第\(seq)句"])
            }
        }
    }

    override func tearDownWithError() throws { dbQueue = nil }







    func testDanglingPersonIDIsRejected() throws {
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO line_speakers (line_id, person_id, source, updated_at)
                VALUES (10, 99999, '用户确认', ?)
                """, arguments: [now])
        }, "person_id 指着一个不存在的人竟然写进去了 —— 外键没生效")
    }


    func testVoiceprintForUnknownPersonIsRejected() throws {
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO voiceprints
                  (person_id, embedding, dim, source, created_at, instruction_id, model)
                VALUES (4242, ?, 2, 'test', ?, 'k1', 'm')
                """, arguments: [Data([0, 0, 0, 0, 0, 0, 0, 0]), now])
        }, "底库挂在一个不存在的人身上竟然写进去了 —— 外键没生效")
    }



    func testDeletingAReferencedPersonIsRejected() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO line_speakers (line_id, person_id, source, updated_at)
                VALUES (10, -1, '用户确认', ?)
                """, arguments: [now])
        }
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM persons WHERE id = -1")
        }, "删掉了一个还被归属层引用的人 —— 外键没生效")
    }



    func testMigrationSeedsMe() throws {
        let me = try dbQueue.read { try PersonStore.find(SpeakerNaming.mePersonID, in: $0) }
        XCTAssertEqual(me?.name, "我")
        XCTAssertEqual(me?.source, PersonStore.Source.me.rawValue)
    }







    func testAutoIDStartsAtOneDespiteNegativeSeed() throws {
        let id = try PersonStore.create(name: "人物甲", source: .seed, now: now, in: dbQueue)
        XCTAssertEqual(id, 1)
    }




    func testPersonIDsAreNeverRecycled() throws {
        let first = try PersonStore.create(name: "甲", source: .user, now: now, in: dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM persons WHERE id = ?", arguments: [first])
        }
        let second = try PersonStore.create(name: "乙", source: .user, now: now, in: dbQueue)
        XCTAssertNotEqual(second, first, "新人捡到了被删的人的号")
    }


    func testTwoPeopleMayShareAName() throws {
        let a = try PersonStore.create(name: "张伟", source: .user, now: now, in: dbQueue)
        let b = try PersonStore.create(name: "张伟", source: .user, now: now, in: dbQueue)
        XCTAssertNotEqual(a, b)
    }

    func testEmptyNameIsRejected() throws {
        XCTAssertThrowsError(
            try PersonStore.create(name: "   ", source: .user, now: now, in: dbQueue))
    }



    func testRenamingAGhostThrows() throws {
        XCTAssertThrowsError(
            try PersonStore.rename(777, to: "谁", now: now, in: dbQueue))
    }


    func testNamelessPersonIsAbsentFromNames() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO persons (id, name, source, created_at, updated_at)
                VALUES (9, NULL, '迁移回填', ?, ?)
                """, arguments: [now, now])
        }
        let names = try dbQueue.read { try PersonStore.names(in: $0) }
        XCTAssertNil(names[9])
        XCTAssertEqual(names[-1], "我")
    }



    private func attribute(line: Int64, person: Int64?, cluster: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO line_speakers (line_id, person_id, cluster_tag, source, updated_at)
                VALUES (?, ?, ?, '用户确认', ?)
                """, arguments: [line, person, cluster, now])
        }
    }





    func testNamedPeopleDoNotConsumeNumbers() throws {
        let personA = try PersonStore.create(name: "人物甲", source: .seed, now: now, in: dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO persons (id, name, source, created_at, updated_at)
                VALUES (5, NULL, '迁移回填', ?, ?)
                """, arguments: [now, now])
        }
        try attribute(line: 10, person: personA, cluster: nil)   // 先出现:有名字
        try attribute(line: 11, person: 5, cluster: nil)          // 没名字
        try attribute(line: 12, person: nil, cluster: "speaker_9")// 只有簇标签



        let labels = try dbQueue.read { try SpeakerNaming.labels(in: $0, scope: .session(1)) }
        XCTAssertEqual(labels["p:\(personA)"], "人物甲")

        XCTAssertEqual(labels["p:5"], "说话人 1")



        XCTAssertEqual(labels["c:1:speaker_9"], "说话人 10")
    }











    func testVoiceprintIdentifiedMeIsCalledMeWithoutAsking() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO line_speakers (line_id, person_id, source, confidence, updated_at)
                VALUES (10, -1, '声纹识别', 0.9, ?)
                """, arguments: [now])
        }
        let labels = try dbQueue.read { try SpeakerNaming.labels(in: $0) }
        XCTAssertEqual(labels[SpeakerNaming.meKey], "我",
                       "声纹认出本人了却还叫「说话人 N」—— 而同样被声纹认出的人物甲直接显示名字")
    }



    func testMeIsNotClaimedWhenNoLineBelongsToThem() throws {
        try attribute(line: 11, person: nil, cluster: "speaker_3")
        let labels = try dbQueue.read { try SpeakerNaming.labels(in: $0, scope: .session(1)) }
        XCTAssertNil(labels[SpeakerNaming.meKey], "没有一行归属给本人,却给了他一个名字")
    }


    func testConfirmedMeIsCalledMe() throws {
        try attribute(line: 10, person: -1, cluster: nil)          // 用户确认
        try attribute(line: 11, person: nil, cluster: "speaker_3")
        let labels = try dbQueue.read { try SpeakerNaming.labels(in: $0, scope: .session(1)) }
        XCTAssertEqual(labels[SpeakerNaming.meKey], "我")

        XCTAssertEqual(labels["c:1:speaker_3"], "说话人 4")
    }
}
