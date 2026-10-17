import XCTest
import GRDB
@testable import GrowthApp






final class ReassignSpeakerTests: XCTestCase {

    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try TestPeople.seed(in: dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, ended_at, day, source, status)
                VALUES (1, '2026-08-14T10:00:00+08:00', '2026-08-14T10:30:00+08:00',
                        '2026-08-14', 'recording', 'closed')
                """)
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (7, 1, 1, 1, 'step-asr-v1', 'frozen', '2026-08-14T10:30:00+08:00')
                """)
            for i in 0..<3 {
                try db.execute(sql: """
                    INSERT INTO transcript_lines
                      (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
                    VALUES (?, 7, ?, ?, ?, ?, 0)
                    """, arguments: [100 + i, i, i * 1000, i * 1000 + 800, "第 \(i) 句"])
                try db.execute(sql: """
                    INSERT INTO line_speakers (line_id, person_id, cluster_tag, source, confidence, updated_at)
                    VALUES (?, ?, ?, '声纹识别', 0.7, '2026-08-14T10:30:00+08:00')
                    """, arguments: [100 + i, i == 0 ? 1 : 2, "S\(i == 0 ? 0 : 1)"])
            }
        }
    }

    override func tearDownWithError() throws { dbQueue = nil }

    private func now() -> String { "2026-08-14T12:00:00+08:00" }






    private static func bypassPattern() throws -> NSRegularExpression {
        try NSRegularExpression(
            pattern: #"(INSERT(\s+OR\s+\w+)?\s+INTO|REPLACE\s+INTO|UPDATE(\s+OR\s+\w+)?|DELETE\s+FROM)\s+[`"\[]?(\w+\.)?line_speakers"#,
            options: [.caseInsensitive])
    }




    func testReassignLeavesAttributionAndJudgmentAgreeing() throws {
        let r = try AssignSpeaker.assignSpeaker(
            lines: [101], person: 1, clusterTag: nil,
            source: .userConfirmed, confidence: nil, actor: .user,
            now: now(), in: dbQueue)

        XCTAssertEqual(r.changedLines, [101])
        XCTAssertNotNil(r.judgmentID, "改动了却没留判断记录 —— 事后查不出是谁改的")

        try dbQueue.read { db in
            let row = try XCTUnwrap(try Row.fetchOne(db, sql: """
                SELECT person_id, source FROM line_speakers WHERE line_id = 101
                """))
            XCTAssertEqual(row["person_id"] as Int64?, 1)
            XCTAssertEqual(row["source"] as String?, "用户确认")

            let j = try XCTUnwrap(try Row.fetchOne(db, sql: """
                SELECT action, actor, target_id, basis_line_ids FROM judgments WHERE id = ?
                """, arguments: [r.judgmentID]), "判断表里找不到这次改动")
            XCTAssertEqual(j["actor"] as String?, "user")


            XCTAssertTrue((j["basis_line_ids"] as String? ?? "").contains("101"),
                          "判断记录里没写清改了哪几行:\(j["basis_line_ids"] as String? ?? "nil")")
        }
    }




    func testAssigningTheSamePersonIsANoOp() throws {
        _ = try AssignSpeaker.assignSpeaker(
            lines: [100], person: 1, clusterTag: nil,
            source: .userConfirmed, confidence: nil, actor: .user, now: now(), in: dbQueue)
        let second = try AssignSpeaker.assignSpeaker(
            lines: [100], person: 1, clusterTag: nil,
            source: .userConfirmed, confidence: nil, actor: .user, now: now(), in: dbQueue)
        XCTAssertTrue(second.isNoOp, "重复点同一个选项不该再写一条判断")
    }



    func testAutomaticSourceCannotOverwriteAUserCorrection() throws {
        _ = try AssignSpeaker.assignSpeaker(
            lines: [101], person: 1, clusterTag: nil,
            source: .userConfirmed, confidence: nil, actor: .user, now: now(), in: dbQueue)

        let auto = try AssignSpeaker.assignSpeaker(
            lines: [101], person: 2, clusterTag: nil,
            source: .voiceprint, confidence: 0.9, actor: .user, now: now(), in: dbQueue)

        XCTAssertEqual(auto.blockedByUserConfirmation, [101])
        try dbQueue.read { db in
            XCTAssertEqual(try Int64.fetchOne(db, sql:
                "SELECT person_id FROM line_speakers WHERE line_id = 101"), 1,
                "自动来源把用户的纠正覆盖掉了")
        }
    }











    func testNothingOutsideAssignSpeakerWritesToTheAttributionTable() throws {




        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GrowthAppTests
            .deletingLastPathComponent()   // ios

        let fm = FileManager.default
        let files = fm.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 10, "一个 .swift 都没扫到,这条断言是空转的")



        let exempt = ["GrowthApp/Database/AssignSpeaker.swift",
                      "GrowthApp/Database/AppDatabase.swift"]
        let writeVerb = try Self.bypassPattern()




        let flatFiles = ["Theme.swift", "DesignSystem.swift",
                         "RootView.swift", "TimelineComponents.swift"]
        func inTarget(_ rel: String) -> Bool {
            rel.hasPrefix("GrowthApp/") || flatFiles.contains(rel)
        }
        let scanned = files.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
                           .filter(inTarget)

        for f in flatFiles {
            XCTAssertTrue(scanned.contains(f), "\(f) 不在扫描范围里,而它是实编的")
        }

        var offenders: [String] = []
        for f in files {
            let rel = f.path.replacingOccurrences(of: root.path + "/", with: "")
            guard inTarget(rel), !exempt.contains(rel) else { continue }
            let text = try String(contentsOf: f, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            if writeVerb.firstMatch(in: text, range: range) != nil {
                offenders.append(rel)
            }
        }
        XCTAssertEqual(offenders, [],
                       "这些文件绕过 assignSpeaker 直接写归属层:\(offenders) —— 违反铁律 3")
    }



    func testTheSourceScanActuallyCatchesABypass() throws {
        let writeVerb = try Self.bypassPattern()


        for bad in ["try db.execute(sql: \"INSERT INTO line_speakers (line_id) VALUES (1)\")",
                    "UPDATE line_speakers SET person_id = 2",
                    "delete from line_speakers where line_id = 1",
                    "INSERT OR REPLACE INTO line_speakers (line_id) VALUES (1)",
                    "REPLACE INTO line_speakers (line_id) VALUES (1)",
                    "UPDATE OR IGNORE line_speakers SET person_id = 2",
                    "UPDATE OR REPLACE line_speakers SET person_id = 2",
                    "INSERT INTO main.line_speakers (line_id) VALUES (1)",
                    "INSERT INTO \"line_speakers\" (line_id) VALUES (1)"] {
            let r = NSRange(bad.startIndex..., in: bad)
            XCTAssertNotNil(writeVerb.firstMatch(in: bad, range: r),
                            "这条违规没被抓到:\(bad)")
        }

        let ok = "SELECT person_id FROM line_speakers WHERE line_id = ?"
        XCTAssertNil(writeVerb.firstMatch(in: ok, range: NSRange(ok.startIndex..., in: ok)),
                     "把读也当成写了,这条断言会天天误报,最后被人关掉")
    }
}



extension ReassignSpeakerTests {


    private func seedAnotherSession() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, ended_at, day, source, status)
                VALUES (2, '2026-08-01T09:00:00+08:00', '2026-08-01T09:20:00+08:00',
                        '2026-08-01', 'recording', 'closed');
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (8, 2, 1, 1, 'step-asr-v1', 'frozen', '2026-08-01T09:20:00+08:00');
                INSERT INTO persons (id, name, source, created_at, updated_at)
                VALUES (77, '人物甲', '用户创建', '2026-08-01T09:00:00+08:00', '2026-08-01T09:00:00+08:00');
                """)

            try db.execute(sql: """
                INSERT INTO transcript_lines
                  (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
                VALUES (200, 8, 0, 0, 900, '别场那个没名字的人说的话', 0);
                INSERT INTO line_speakers (line_id, person_id, cluster_tag, source, confidence, updated_at)
                VALUES (200, NULL, 'S9', '声纹识别', 0.6, '2026-08-01T09:20:00+08:00');
                """)

            try db.execute(sql: """
                INSERT INTO transcript_lines
                  (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
                VALUES (201, 8, 1, 1000, 1900, '人物甲在别场说的话', 0);
                INSERT INTO line_speakers (line_id, person_id, cluster_tag, source, confidence, updated_at)
                VALUES (201, 77, NULL, '用户确认', NULL, '2026-08-01T09:20:00+08:00');
                """)
        }
    }


    private func candidateKeys(forLine lineID: Int64) throws -> Set<String> {
        try dbQueue.read { db in
            let samples = try ReassignSpeakerSheet.samples(in: db, lineID: lineID)
            let named = try PersonStore.names(in: db)
            let inThisSession = Set(samples.keys)
            return Set(try SpeakerNaming.labels(in: db).keys.filter { key in
                inThisSession.contains(key)
                    || SpeakerNaming.personID(of: key).map { named[$0] != nil } == true
            })
        }
    }





    func testACandidateFromAnotherSessionWithNoNameIsNotOffered() throws {
        try seedAnotherSession()
        let keys = try candidateKeys(forLine: 100)
        XCTAssertFalse(keys.contains("c:2:S9"),
                       "别场的无名簇进了候选 —— 用户认不出它是谁,而随手一点就锁死一个错归属:\(keys)")
    }



    func testANamedPersonFromAnotherSessionIsStillOffered() throws {
        try seedAnotherSession()
        let keys = try candidateKeys(forLine: 100)
        XCTAssertTrue(keys.contains("p:77"),
                      "别场已命名的人被滤掉了 —— 那就没法把这一行改判给人物甲:\(keys)")
    }



    func testEverySpeakerFromThisSessionIsStillOffered() throws {
        try seedAnotherSession()
        let keys = try candidateKeys(forLine: 100)

        for k in ["p:1", "p:2"] where !keys.contains(k) {
            XCTFail("本场的簇 \(k) 被滤掉了:\(keys)")
        }
    }




    func testWithoutTheFilterTheStaleCandidateComesBack() throws {
        try seedAnotherSession()
        let unfiltered = try dbQueue.read { db in
            Set(try SpeakerNaming.labels(in: db).keys)     // 过滤前的老口径
        }
        XCTAssertTrue(unfiltered.contains("c:2:S9"),
                      "不过滤时也没有别场的簇 —— 那前面三条断言是在真空里绿的,它们没在验东西")
    }
}
