import XCTest
import GRDB
@testable import GrowthApp

















final class VoiceprintJobPayloadTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-28T22:56:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status, active_transcript_id)
                VALUES (7, ?, '2026-08-28', 'recording', 'closed', 7)
                """, arguments: [now])
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (7, 7, 1, 1, 'step-asr', 'frozen', ?)
                """, arguments: [now])

            for (id, name) in [(1 as Int64, "人物甲"), (82, "人物戊"), (83, nil as String?)] {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO persons (id, name, source, created_at, updated_at)
                    VALUES (?, ?, '用户创建', ?, ?)
                    """, arguments: [id, name, now, now])
            }
            for i in 0..<4 {
                try db.execute(sql: """
                    INSERT INTO transcript_lines
                      (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, block_seq)
                    VALUES (?, 7, ?, ?, ?, '一句话', 0, 0)
                    """, arguments: [100 + i, i, i * 10_000, i * 10_000 + 5_000])
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







    private func sent() throws -> [(Int64, String?)] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: VoiceprintRemote.lineSelectSQL, arguments: [7])
                .map { ($0["line_id"] as Int64, $0["tag"] as String?) }
        }
    }
    private func tags() throws -> [String?] { try sent().map(\.1) }





    func testUserConfirmedLinesStillCarryTheUpstreamTag() throws {
        try attribute(100, tag: "speaker_0", source: "系统整理")
        try attribute(101, tag: "speaker_0", source: "用户确认", person: -1)
        try attribute(102, tag: "speaker_1", source: "用户确认", person: 1)
        try attribute(103, tag: "speaker_1", source: "系统整理")

        XCTAssertEqual(try tags(), ["speaker_0", "speaker_0", "speaker_1", "speaker_1"], """
            用户确认过的行丢了簇标签 —— 它们会各自变成单段簇,
            而单段簇一律「不够判」⇒ 整场内容根本进不了比对。
            """)
    }






    func testVoiceprintWrittenKeysAreNormalisedBackAndAreIdempotent() throws {
        try attribute(100, tag: "7-speaker_0", source: "声纹识别", person: 82)
        try attribute(101, tag: "7-speaker_0", source: "声纹识别", person: 82)
        try attribute(102, tag: "speaker_1", source: "系统整理")
        try attribute(103, tag: "7-speaker_1", source: "声纹识别", person: 83)

        let first = try tags()
        XCTAssertEqual(first, ["speaker_0", "speaker_0", "speaker_1", "speaker_1"],
                       "声纹写回来的 `<场次>-` 前缀没被剥掉 —— 重判会在自己的键上再套一层")


        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE line_speakers SET cluster_tag = '7-' || cluster_tag
                 WHERE cluster_tag NOT LIKE '7-%'
                """)
        }
        XCTAssertEqual(try tags(), first, """
            重判一轮之后分组变了 —— 同一个人在轮与轮之间会被归进不同的组,
            而每一轮都会为此新立一个匿名人格。
            """)
    }









    func testATagProvenToMixTwoPeopleDropsOnlyItsConfirmedLines() throws {
        try dbQueue.write { db in
            for i in 4..<6 {
                try db.execute(sql: """
                    INSERT INTO transcript_lines
                      (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, block_seq)
                    VALUES (?, 7, ?, ?, ?, '一句话', 0, 0)
                    """, arguments: [100 + i, i, i * 10_000, i * 10_000 + 5_000])
            }
        }

        try attribute(100, tag: "speaker_0", source: "用户确认", person: 1)
        try attribute(101, tag: "speaker_0", source: "用户确认", person: 82)
        try attribute(102, tag: "speaker_0", source: "系统整理")

        try attribute(103, tag: "speaker_1", source: "用户确认", person: 1)
        try attribute(104, tag: "speaker_1", source: "系统整理")
        try attribute(105, tag: nil, source: "系统整理")

        let got = try sent()
        XCTAssertEqual(got.map(\.0), [102, 103, 104, 105], """
            送出去的行不对。混标签(speaker_0)已确认的 100/101 必须丢掉 ——
            留着它们就会聚出一个「两个人」的质心,而质心是拿来判别人的;
            而 103(干标签下的已确认行)必须留着 —— 104 全靠跟它同组才判得出来。
            """)
        XCTAssertEqual(got.map(\.1), ["speaker_0", "speaker_1", "speaker_1", nil],
                       "剩下的行的分组变了")
    }



    func testLinesWithNoUpstreamDiarizationStayNil() throws {
        try attribute(100, tag: nil, source: "系统整理")
        XCTAssertEqual(try tags().first ?? "非空", String?.none)
    }
}


final class SpeakerReviewsTests: XCTestCase {

    private func db() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(q)
        let now = "2026-09-02T15:00:00+08:00"
        try q.write { d in
            try d.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status, active_transcript_id)
                VALUES (21, ?, '2026-09-02', 'recording', 'closed', 21)
                """, arguments: [now])
            try d.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (21, 21, 1, 1, 'step-asr', 'frozen', ?)
                """, arguments: [now])
            try d.execute(sql: """
                INSERT OR IGNORE INTO persons (id, name, source, created_at, updated_at)
                VALUES (1, '人物甲', '声纹种子', ?, ?)
                """, arguments: [now, now])
            for i in 0..<2 {
                try d.execute(sql: """
                    INSERT INTO transcript_lines
                      (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, block_seq)
                    VALUES (?, 21, ?, ?, ?, '一句话', 0, 0)
                    """, arguments: [500 + i, i, i * 1000, i * 1000 + 900])
            }
        }
        return q
    }





    func testAnsweredLinesAreNotAskedAgainOnRejudge() throws {
        let q = try db()
        let now = "2026-09-02T15:00:00+08:00"
        try q.write { d in
            try SpeakerReviews.enqueue(lineID: 500, person: 1, score: 0.2,
                                       clusterKey: "21-speaker_0", now: now, in: d)
        }
        try SpeakerReviews.answer(lineID: 500, .rejected, now: now, in: q)

        try q.write { d in
            try SpeakerReviews.enqueue(lineID: 500, person: 1, score: 0.2,
                                       clusterKey: "21-speaker_0", now: now, in: d)
        }
        let state = try q.read { d in
            try String.fetchOne(d, sql: "SELECT state FROM speaker_reviews WHERE line_id = 500")
        }
        XCTAssertEqual(state, "不是本人", """
            重判把用户答过的行重置成「待复查」了 —— 他会以为上次白答了,
            而这正是 `M2-认11` 那条 bug 的形状。
            """)
        XCTAssertEqual(try q.read { try SpeakerReviews.pendingCount(in: $0) }, 0)
    }





    func testOldVerdictsWithoutReviewStillDecode() throws {
        let json = """
        {"cluster_key":"21-speaker_0",
         "verdict":{"kind":"person","person_id":1},
         "centroid":[0.1,0.2],"lines":[500,501]}
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(VoiceprintRemote.Cluster.self, from: json)
        XCTAssertNil(c.review)
        XCTAssertEqual(c.lines, [500, 501])
    }
}
