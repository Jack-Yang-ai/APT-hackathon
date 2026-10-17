import XCTest
import GRDB
@testable import GrowthApp






final class SpeakerClaimProjectionTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-25T16:00:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try TestPeople.seed(in: dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (7610, ?, '2026-08-25', ?, ?)
                """, arguments: [self.now, SessionBridge.Source.recording,
                                 SessionBridge.Status.closed])

            try db.execute(sql: """
                INSERT INTO persons (id, name, source, created_at, updated_at)
                VALUES (901, NULL, '声纹聚类', ?, ?), (902, '人物甲', '用户创建', ?, ?)
                """, arguments: [self.now, self.now, self.now, self.now])
        }
    }

    override func tearDownWithError() throws { dbQueue = nil }

    private func cluster(_ key: String, person: Int64,
                         candidate: Int64? = nil, votes: Int? = nil, of: Int? = nil) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO voiceprint_clusters
                  (cluster_key, session_id, person_id, created_at,
                   candidate_person_id, candidate_votes, candidate_of)
                VALUES (?, 7610, ?, ?, ?, ?, ?)
                """, arguments: [key, person, self.now, candidate, votes, of])
        }
    }

    private func claims() throws -> [SpeakerClaimProjection.Claim] {
        try dbQueue.read { db in try SpeakerClaimProjection.claims(in: db) }
    }




    func testTheThreeTiersAreDerivedNotStored() throws {
        try cluster("7610-c0", person: 902)                               // 已命名 ⇒ 高
        try cluster("7610-c1", person: 901, candidate: 902, votes: 1, of: 3)  // 有候选 ⇒ 中
        try cluster("7610-c2", person: 901)                               // 没候选 ⇒ 低

        let byKey = Dictionary(uniqueKeysWithValues: try claims().map { ($0.clusterKey, $0) })
        XCTAssertEqual(byKey["7610-c0"]?.tier, .autoClaimed)
        XCTAssertEqual(byKey["7610-c1"]?.tier, .prefilled, "中置信塌了 —— 三档只剩两档")
        XCTAssertEqual(byKey["7610-c2"]?.tier, .unknown, "没候选却不是「不猜」—— 那是在猜")
    }


    func testTheLowTierNeverCarriesACandidate() throws {
        try cluster("7610-c2", person: 901)
        let c = try XCTUnwrap(try claims().first)
        XCTAssertNil(c.candidatePersonID)
        XCTAssertNil(c.confidenceText, "没有候选却说出了把握 —— 那句话是编的")
    }





    func testConfidenceNeedsBothNumeratorAndDenominator() throws {
        try cluster("7610-c1", person: 901, candidate: 902, votes: 1, of: 3)
        XCTAssertEqual(try claims().first?.confidenceText, "3 段里有 1 段像他")

        try dbQueue.write { db in
            try db.execute(sql: "UPDATE voiceprint_clusters SET candidate_of = NULL")
        }
        XCTAssertNil(try claims().first?.confidenceText, "分母没了还在说把握")
    }




    func testClipsAreRankedByAudibilityAndCapped() throws {
        try cluster("7610-c1", person: 901, candidate: 902, votes: 1, of: 3)
        try dbQueue.write { db in
            for (i, (ratio, ms)) in [(0.7, 4000), (0.95, 3000), (0.9, 5000), (0.6, 6000)].enumerated() {
                try db.execute(sql: """
                    INSERT INTO speaker_clips (cluster_key, session_id, r2_key, duration_ms,
                                               speech_ratio, created_at)
                    VALUES ('7610-c1', 7610, ?, ?, ?, ?)
                    """, arguments: [R2Layout.clipKey(sessionID: 7610, clusterKey: "7610-c1", seq: i),
                                     ms, ratio, self.now])
            }
        }
        let clips = try XCTUnwrap(try claims().first).clips
        XCTAssertEqual(clips.count, SpeakerClipPolicy.maxPerSpeaker, "上限没生效")
        XCTAssertEqual(clips.map(\.speechRatio), [0.95, 0.9, 0.7], "没按人声占比降序 —— 挑的不是最听得清的")
        XCTAssertEqual(clips.first?.seconds, 3.0)
    }










    func testAClipCarriesNoTranscriptText() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("GrowthApp/Presentation/SpeakerClaimProjection.swift")
        let src = try String(contentsOf: file, encoding: .utf8)
        let body = try XCTUnwrap(src.range(of: "struct Clip: Equatable, Identifiable {").map {
            String(src[$0.upperBound...].prefix(while: { $0 != "}" }))
        }, "抠不到 `struct Clip` —— 改了写法就要改这里,别让这条断言空转")
        XCTAssertTrue(body.contains("durationMS"), "抠到的不是 Clip 的定义,这条断言在空转")

        let offenders = body.split(separator: "\n").filter { line in
            let code = line.range(of: "//").map { String(line[line.startIndex..<$0.lowerBound]) }
                        ?? String(line)
            return ["text", "quote", "lineID", "line_id"].contains { code.contains($0) }
        }.map(String.init)
        XCTAssertEqual(offenders, [],
                       "片段上出现了文字/行号:\(offenders) —— "
                       + "片段是按「最长、人声占比最高」挑的一段声音,与任何一行字都没有对应关系。"
                       + "配上字就等于亲手制造 PendingSpeaker.sampleLineID 那条注释要防的事")
    }


    func testEveryUnwiredWriteThrows() {
        let w = UnimplementedSpeakerClaimWriting()
        XCTAssertThrowsError(try w.claim(cluster: "k", as: 1, now: ""))
        XCTAssertThrowsError(try w.reject(candidateOf: "k", now: ""))
        XCTAssertThrowsError(try w.defer_(cluster: "k", now: ""))
    }
}






final class SpeakerSessionNoteTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-25T20:00:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try TestPeople.seed(in: dbQueue)
        try dbQueue.write { db in
            for (i, id) in [2895, 2928, 7610].enumerated() {
                try db.execute(sql: """
                    INSERT INTO sessions (id, started_at, day, source, status)
                    VALUES (?, ?, '2026-08-25', ?, ?)
                    """, arguments: [id, "2026-08-25T1\(i):00:00+08:00",
                                     SessionBridge.Source.recording, SessionBridge.Status.closed])
            }
            try db.execute(sql: """
                INSERT INTO persons (id, name, source, created_at, updated_at)
                VALUES (901, NULL, '声纹聚类', ?, ?), (902, '人物甲', '用户创建', ?, ?)
                """, arguments: [self.now, self.now, self.now, self.now])
        }
    }

    override func tearDownWithError() throws { dbQueue = nil }

    private func note(_ id: Int64) throws -> SpeakerClaimProjection.SessionNote {
        try dbQueue.read { db in try SpeakerClaimProjection.sessionNote(id, in: db) }
    }

    private func judged(_ id: Int64, gatedOut: Int) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE sessions SET voiceprint_gated_out = ? WHERE id = ?",
                           arguments: [gatedOut, id])
        }
    }

    private func cluster(_ key: String, session: Int64, person: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO voiceprint_clusters (cluster_key, session_id, person_id, created_at)
                VALUES (?, ?, ?, ?)
                """, arguments: [key, session, person, self.now])
        }
    }





    func testANeverJudgedSessionIsNotTheSameAsOneWithNothingUsable() throws {
        XCTAssertEqual(try note(2895), .notJudged)
        try judged(2895, gatedOut: 0)
        XCTAssertNotEqual(try note(2895), .notJudged, "判过了还说「还在判」")
    }


    func testASessionWhereEveryThingWasGatedOutSaysSo() throws {
        try judged(2928, gatedOut: 12)
        XCTAssertEqual(try note(2928), .nothingUsable(gatedOut: 12))
        let t = try note(2928).text
        XCTAssertTrue(t.contains("12"), "没把数说出来 —— 用户看不出是全挡还是没判")

        XCTAssertFalse(t.contains("没人说话"),
                       "说成「没人说话」是假话 —— VAD 不响不等于没人说话(M2-审21)")
        XCTAssertTrue(t.contains("转写不受影响"), "要说清影响面,否则会被读成录音链坏了")
    }


    func testJudgedButNothingMatchedIsItsOwnState() throws {
        try judged(7610, gatedOut: 0)
        try cluster("7610-c0", session: 7610, person: 901)     // 匿名人格
        XCTAssertEqual(try note(7610), .judgedNothingMatched)
    }


    func testAMatchedSessionReportsHowMany() throws {
        try judged(7610, gatedOut: 0)
        try cluster("7610-c0", session: 7610, person: 902)     // 已命名
        XCTAssertEqual(try note(7610), .matched(clusters: 1))
    }


    func testEveryStateHasSomethingToSay() throws {
        for n: SpeakerClaimProjection.SessionNote in [.notJudged, .nothingUsable(gatedOut: 3),
                                                      .judgedNothingMatched, .matched(clusters: 2)] {
            XCTAssertFalse(n.text.isEmpty, "有一种状态没话说 —— 那和「什么都不显示」一样")
        }
    }
}
