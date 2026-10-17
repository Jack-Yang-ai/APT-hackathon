import XCTest
import GRDB
@testable import GrowthApp



final class VoiceprintRemoteTests: XCTestCase {
    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-24T15:00:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (7, ?, '2026-08-24', 'mic', 'closed')
                """, arguments: [now])
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status,
                                         created_at, frozen_at)
                VALUES (70, 7, 1, 1, 'x', 'frozen', ?, ?)
                """, arguments: [now, now])
            for i in 0..<4 {
                try db.execute(sql: """
                    INSERT INTO transcript_lines
                      (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, is_gap)
                    VALUES (?, 70, ?, ?, ?, '第\(i)句', 0, 0)
                    """, arguments: [100 + i, i, i * 5000, i * 5000 + 4000])
            }
            try db.execute(sql: "UPDATE sessions SET active_transcript_id = 70 WHERE id = 7")
            try db.execute(sql: """
                INSERT INTO persons (id, name, source, created_at, updated_at)
                VALUES (1, '人物甲', '声纹种子', ?, ?)
                """, arguments: [now, now])
        }
    }
    override func tearDownWithError() throws { dbQueue = nil }

    private func result(model: String = VoiceprintModel.current,
                        clusters: String) -> Data {
        Data("""
        {"schema":1,"model":"\(model)","session":7,"gated_out":1,"clusters":[\(clusters)]}
        """.utf8)
    }

    private let personCluster = """
        {"cluster_key":"7-c0","verdict":{"kind":"person","person_id":1,"votes":2,"of":3},
         "centroid":[0.6,0.8],"lines":[100,101]}
        """
    private let anonCluster = """
        {"cluster_key":"7-c1","verdict":{"kind":"anonymous_candidate","why":"没拉开差距"},
         "centroid":[1.0,0.0],"lines":[102,103]}
        """





    func testForeignModelSpaceIsRejectedWholesale() throws {
        XCTAssertThrowsError(try VoiceprintRemote.merge(
            result(model: "cam++/192d", clusters: personCluster),
            sessionID: 7, now: now, in: dbQueue))
        let rows = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM line_speakers") ?? -1
        }
        XCTAssertEqual(rows, 0, "空间失配的判决被合并进来了 —— 把错的人写满一场,而且不报错")
    }



    func testPersonVerdictLandsViaAssignSpeaker() throws {
        let out = try VoiceprintRemote.merge(result(clusters: personCluster),
                                             sessionID: 7, now: now, in: dbQueue)
        XCTAssertEqual(out.matched, 1)
        try dbQueue.read { db in
            XCTAssertEqual(try Int64.fetchOne(db, sql: """
                SELECT person_id FROM line_speakers WHERE line_id = 100
                """), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT source FROM line_speakers WHERE line_id = 100
                """), "声纹识别")
        }
    }



    func testAnonymousClusterBecomesANamelessPersona() throws {
        let out = try VoiceprintRemote.merge(result(clusters: anonCluster),
                                             sessionID: 7, now: now, in: dbQueue)
        XCTAssertEqual(out.anonymousNew, 1)
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT p.id, p.name, p.source FROM persons p
                  JOIN voiceprint_clusters vc ON vc.person_id = p.id
                 WHERE vc.cluster_key = '7-c1'
                """)
            XCTAssertNotNil(row, "匿名候选没落成人格")
            XCTAssertNil(row?["name"] as String?, "匿名人格被编了名字 —— 展示名只归 SpeakerNaming")
            XCTAssertEqual(row?["source"] as String?, "声纹聚类")















            let pid = row?["id"] as Int64? ?? -999
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM voiceprints WHERE person_id = ?
                """, arguments: [pid]), 0, """
                匿名人格的质心又进底库了 —— 那是毒化环的源头。
                人格本身(persons 行)和 voiceprint_clusters 映射照留(界面要显示「声音A」),
                但**向量不许进**。
                """)
        }
    }



    func testReplayingTheSameResultReusesThePersona() throws {
        _ = try VoiceprintRemote.merge(result(clusters: anonCluster),
                                       sessionID: 7, now: now, in: dbQueue)
        let again = try VoiceprintRemote.merge(result(clusters: anonCluster),
                                               sessionID: 7, now: now, in: dbQueue)
        XCTAssertEqual(again.anonymousNew, 0)
        XCTAssertEqual(again.anonymousReused, 1)
        try dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM persons WHERE source = '声纹聚类'
                """), 1, "重放长出了第二个人格")
        }
    }



    func testSingleLineClusterGetsTagOnlyNoPersona() throws {
        let single = """
            {"cluster_key":"7-c2","verdict":{"kind":"anonymous_candidate","why":"只有 1 段"},
             "centroid":[0.0,1.0],"lines":[102]}
            """
        let out = try VoiceprintRemote.merge(result(clusters: single),
                                             sessionID: 7, now: now, in: dbQueue)
        XCTAssertEqual(out.tagged, 1)
        XCTAssertEqual(out.anonymousNew, 0, "单段簇立了人格 —— 一半是噪声,人格应该 ≥2 段才立")
        try dbQueue.read { db in
            XCTAssertNil(try Int64.fetchOne(db, sql: """
                SELECT person_id FROM line_speakers WHERE line_id = 102
                """) ?? nil)
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT cluster_tag FROM line_speakers WHERE line_id = 102
                """), "7-c2", "单段簇连标签都没挂 —— 用户想手动认都没有入口")
        }
    }



    func testUserConfirmationSurvivesMerge() throws {
        _ = try AssignSpeaker.assignSpeaker(lines: [100], person: 1, clusterTag: nil,
                                            source: .userConfirmed, confidence: nil,
                                            actor: .user, now: now, in: dbQueue)

        let hostile = """
            {"cluster_key":"7-c3","verdict":{"kind":"anonymous_candidate","why":"x"},
             "centroid":[0.5,0.5],"lines":[100,101]}
            """
        _ = try VoiceprintRemote.merge(result(clusters: hostile),
                                       sessionID: 7, now: now, in: dbQueue)
        try dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT source FROM line_speakers WHERE line_id = 100
                """), "用户确认", "自动来源覆盖了用户确认 —— assignSpeaker 那道闸漏了")
        }
    }




    func testAnonymousLabelsAreStableAndSingleSourced() throws {
        _ = try VoiceprintRemote.merge(result(clusters: anonCluster),
                                       sessionID: 7, now: now, in: dbQueue)
        let labels = try dbQueue.read { try SpeakerNaming.anonymousLabels(in: $0) }
        XCTAssertEqual(labels.count, 1)
        XCTAssertEqual(labels.values.first, "声音A")

        let pid = labels.keys.first!
        try dbQueue.write { db in
            try PersonStore.rename(pid, to: "老王", now: now, in: db)
        }
        let after = try dbQueue.read { try SpeakerNaming.anonymousLabels(in: $0) }
        XCTAssertTrue(after.isEmpty, "命名之后还挂着「声音A」—— 两个称呼指同一个人")
    }
}
