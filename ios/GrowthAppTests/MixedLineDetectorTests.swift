import XCTest
import GRDB
@testable import GrowthApp

/// 混合行检测(预研 P4 §7.2③ · §8 第 7 条)。
///
/// 主验收是**在人工金标上复现预研的数字**,不是「跑通」——
/// 一个总是返回空集的检测器也能「跑通」,而且看起来误报率极低。
final class MixedLineDetectorTests: XCTestCase {
    // MARK: - 检测器本身的边界

    func testSameSpeakerOverlapIsNotMixed() {
        // 同一个 speaker 的两条重叠是切分抖动,不是两个人。
        let u = [Utterance(startMs: 0, endMs: 5000, speakerID: "s0"),
                 Utterance(startMs: 3000, endMs: 8000, speakerID: "s0")]
        XCTAssertTrue(MixedLineDetector.detect(u).isEmpty)
    }

    func testOverlapAtExactlyTheThresholdDoesNotCount() {
        // 终态写的是「**超过** 0.3s」。边界上算不算,差一条就能让复现对不上。
        let u = [Utterance(startMs: 0, endMs: 5000, speakerID: "s0"),
                 Utterance(startMs: 4700, endMs: 9000, speakerID: "s1")]
        XCTAssertTrue(MixedLineDetector.detect(u, thresholdMs: 300).isEmpty)
        XCTAssertEqual(MixedLineDetector.detect(u, thresholdMs: 299).count, 2)
    }

    func testBothSidesOfAnOverlapAreMarked() {
        // 重叠那段音频**两条里都含着**,谁也不比谁干净。只标一条会漏掉一半。
        let u = [Utterance(startMs: 0, endMs: 5000, speakerID: "s0"),
                 Utterance(startMs: 1000, endMs: 2000, speakerID: "s1")]
        XCTAssertEqual(MixedLineDetector.detect(u).map(\.index), [0, 1])
    }

    func testUnsortedInputGivesTheSameResult() {
        let a = [Utterance(startMs: 0, endMs: 5000, speakerID: "s0"),
                 Utterance(startMs: 1000, endMs: 2000, speakerID: "s1")]
        let b = Array(a.reversed())
        XCTAssertEqual(Set(MixedLineDetector.detect(a).map { a[$0.index] }),
                       Set(MixedLineDetector.detect(b).map { b[$0.index] }))
    }

    func testMaxOverlapIsReported() {
        let u = [Utterance(startMs: 0, endMs: 10000, speakerID: "s0"),
                 Utterance(startMs: 1000, endMs: 2000, speakerID: "s1"),
                 Utterance(startMs: 5000, endMs: 9000, speakerID: "s2")]
        let hits = MixedLineDetector.detect(u)
        XCTAssertEqual(hits.first { $0.index == 0 }?.maxOverlapMs, 4000)
    }
}

/// 混合行的两条下游纪律:不给真名、不进声纹匹配(预研 P4 §7.2③ 终态)。
///
/// 闸收在 `assignSpeaker` 里而不是靠调用方自觉 —— 与铁律 3 同一个道理:
/// 归属只有一条路可写,那这条路上就该拦住所有不该写的。
final class MixedLineGateTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-10T20:00:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try TestPeople.seed(in: dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, '2026-08-10T09:00:00+08:00', '2026-08-10', 'recording', 'closed')
                """)
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (1, 1, 1, 1, 'fake', 'frozen', ?)
                """, arguments: [now])
            for seq in 0..<3 {
                try db.execute(sql: """
                    INSERT INTO transcript_lines
                      (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
                    VALUES (?, 1, ?, ?, ?, '一句话', 0)
                    """, arguments: [seq + 1, seq, seq * 1000, seq * 1000 + 900])
            }
        }
        try MixedLineStore.record([.init(lineID: 2, overlapMs: 1200)],
                                  transcriptID: 1, thresholdMs: 300, now: now, in: dbQueue)
    }
    override func tearDownWithError() throws { dbQueue = nil }

    // 这一组打的是混合行闸,与簇标签无关,所以一律 clusterTag: nil ——
    // 声纹匹配那条路只产出 person,本来就拿不到簇标签(簇标签是分人那一步的产物)。
    // 簇标签在混合行上的落法单列一条 testClusterTagStillLandsOnAMixedLine。

    func testAutomaticSourceCannotNameAMixedLine() throws {
        let r = try AssignSpeaker.assignSpeaker(
            lines: [1, 2, 3], person: 7, clusterTag: nil, source: .voiceprint, confidence: 0.9,
            actor: .user, now: now, in: dbQueue)
        XCTAssertEqual(r.blockedByMixedLine, [2], "混合行被自动来源安上了真名")
        XCTAssertEqual(r.changedLines, [1, 3])

        let person2 = try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT person_id FROM line_speakers WHERE line_id = 2")
        }
        XCTAssertNil(person2, "混合行不该有真名")
    }

    func testUserConfirmationCanStillNameAMixedLine() throws {
        // 只有人分得清那一行到底算谁的。挡住用户等于把一条可修复的错变成死结。
        let r = try AssignSpeaker.assignSpeaker(
            lines: [2], person: 7, clusterTag: nil, source: .userConfirmed, confidence: nil,
            actor: .user, now: now, in: dbQueue)
        XCTAssertEqual(r.blockedByMixedLine, [])
        XCTAssertEqual(r.changedLines, [2])
    }

    /// 混合行照样收得下簇标签 —— 而且它最需要:混合行正是分人自己出了矛盾的地方,
    /// 抽取那侧的「说话人一致」校验在这些行上最该有对撞对象。
    ///
    /// 闸挡的是「自动来源给真名」(person != nil),分人写簇标签时 person 是 nil,
    /// 走的不是那条判断,所以不会被误伤。
    func testClusterTagStillLandsOnAMixedLine() throws {
        let r = try AssignSpeaker.assignSpeaker(
            lines: [1, 2, 3], person: nil, clusterTag: "说话人3", source: .systemOrganized,
            confidence: 0.5, actor: .user, now: now, in: dbQueue)
        XCTAssertEqual(r.blockedByMixedLine, [], "写簇标签没给真名,不该被闸挡")
        XCTAssertEqual(r.changedLines, [1, 2, 3])

        let tag = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT cluster_tag FROM line_speakers WHERE line_id = 2")
        }
        XCTAssertEqual(tag, "说话人3")
    }

    func testUnassigningAMixedLineIsAllowed() throws {
        // person=nil 是「撤销归属」,不是「安真名」。挡它只会让混合行永远撤不掉。
        try AssignSpeaker.assignSpeaker(lines: [2], person: 7, clusterTag: nil,
                                        source: .userConfirmed,
                                        confidence: nil, actor: .user, now: now, in: dbQueue)
        let r = try AssignSpeaker.assignSpeaker(
            lines: [2], person: nil, clusterTag: nil, source: .systemOrganized, confidence: 0.1,
            actor: .user, now: now, in: dbQueue)
        XCTAssertEqual(r.blockedByMixedLine, [])
    }

    func testMixedLinesAreExcludedFromVoiceprintMatching() throws {
        // 混合音频的嵌入是两个人混出来的,比出来的分数既不属于甲也不属于乙 ——
        // 而分数照样落在某个区间里,看起来完全正常。最难查的一类污染。
        XCTAssertEqual(try MixedLineStore.eligibleForVoiceprint([1, 2, 3], in: dbQueue), [1, 3])
    }

    func testRerunOverwritesInsteadOfAccumulating() throws {
        // 换阈值重跑是**整场重写**。叠加的话,旧阈值标出来的行会永远留着,
        // 而没人查得出来它是旧的。
        try MixedLineStore.record([.init(lineID: 3, overlapMs: 800)],
                                  transcriptID: 1, thresholdMs: 800, now: now, in: dbQueue)
        let ids = try dbQueue.read { db in
            try Int64.fetchAll(db, sql: "SELECT line_id FROM mixed_lines ORDER BY line_id")
        }
        XCTAssertEqual(ids, [3], "上一次的标记没被清掉")
    }
}
