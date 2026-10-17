import XCTest
import GRDB
@testable import GrowthApp

/// 取段(方案 S5 的选段那一半)。
///
/// 这一层错了不会报错:挑到定位不到的行 ⇒ 拿别人的音频去判人;
/// 塞进 1.5 秒的碎段 ⇒ 错误率是 3 秒的 7 倍,而分数看着完全正常。
final class SpeakerSegmentsTests: XCTestCase {

    /// 测试造数时块按名义 300 秒排布,所以块起点给名义值 ——
    /// 这一层验的是「选段规则」,块起点从哪来是 `BlockTiming` 的事。
    private var nominalOffsets: [Int: Int] {
        Dictionary(uniqueKeysWithValues: (0...9).map { ($0, $0 * 300_000) })
    }

    private func c(_ tag: String, _ lineID: Int64, blk: Int? = 0,
                   startMs: Int = 0, ms: Int = 5_000, chars: Int = 30)
    -> SpeakerSegments.Candidate {
        .init(clusterTag: tag, lineID: lineID, blockSeq: blk,
              startMs: startMs, endMs: startMs + ms, charCount: chars)
    }

    // MARK: - 定位不到的行必须出局

    /// 🔴 **`block_seq` 为 nil 的行一段都不出。**
    /// 它定位不到音频,而唯一能兜底的算法(`t_start_ms / 300_000`)有歧义,
    /// 会取到另一个人的声音 —— 那是这条链最贵的错法。
    func testLinesWithoutBlockSeqAreDropped() {
        let out = SpeakerSegments.select([c("speaker_0", 1, blk: nil)])
        XCTAssertTrue(out.isEmpty, "定位不到的行居然被选中了")
    }

    /// 一簇里一段都挑不出来时,**那一簇不出现在结果里** ——
    /// 不给空数组假装挑过,下游据此判「这簇没法判」。
    func testAClusterWithNoUsableLineIsAbsentNotEmpty() {
        let out = SpeakerSegments.select([
            c("speaker_0", 1, blk: nil),
            c("speaker_1", 2, ms: 6_000),
        ])
        XCTAssertNil(out["speaker_0"])
        XCTAssertEqual(out["speaker_1"]?.count, 1)
    }

    // MARK: - 段长

    /// 🔴 ~~不足 3 秒的行不参与~~ **2026-08-21 用户拍板撤掉这条限制**(仓规 6:前提变了,结论重写)。
    ///
    /// 原话:「你只要能切割开就认,不用做任何限制」。撤得掉的理由不是「短段变可靠了」,
    /// 是**短段的失败模式变了** —— 换成 τ 差距判据之后,不稳的嵌入跟两个人的分数咬得近
    /// ⇒ 差距不够 ⇒ 自动拒识,而不是像旧的绝对分那样可能虚高到安错名字。
    /// ⇒ 多一个短段最坏是白算,不再是多一次错名机会。
    func testAnyLineTheModelCanChewIsAccepted() {
        // 碎句照收 —— 全时录音里绝大多数话本来就不到 3 秒
        XCTAssertNotNil(SpeakerSegments.window(of: c("t", 1, ms: 2_900)))
        XCTAssertNotNil(SpeakerSegments.window(of: c("t", 1, ms: 800)))
    }

    /// **只剩物理下限**:短到梅尔前端都出不了帧的,还是得挡 ——
    /// 那不是「政策上不要」,是**模型跑不动**(`MelFrontend` 要求 ≥ `winLength` 个采样点)。
    func testBelowTheModelsPhysicalFloorIsStillExcluded() {
        let floorMs = Int(SpeakerSegments.minSeconds * 1000)
        XCTAssertNil(SpeakerSegments.window(of: c("t", 1, ms: max(0, floorMs - 1))))
        XCTAssertNotNil(SpeakerSegments.window(of: c("t", 1, ms: floorMs)))
        XCTAssertLessThan(SpeakerSegments.minSeconds, 0.1,
                          "下限该是模型的物理底线(25 毫秒量级),不是又一个算法上的保守值")
    }

    /// 取**中段**:一句话的头尾常粘着上一个人的尾音与下一个人的起头。
    func testWindowIsTakenFromTheMiddle() {
        let w = SpeakerSegments.window(of: c("t", 1, startMs: 10_000, ms: 10_000))!
        // 10 秒的行取中间 4 秒 ⇒ 从 +3 秒处开始
        XCTAssertEqual(w.startMs, 13_000)
        XCTAssertEqual(w.endMs, 17_000)
        XCTAssertEqual(w.seconds, 4, accuracy: 0.001)
    }

    /// 行比 4 秒短但 ≥3 秒时,**整行都用上**,不硬凑 4 秒。
    func testAShortButUsableLineIsTakenWhole() {
        let w = SpeakerSegments.window(of: c("t", 1, startMs: 500, ms: 3_500))!
        XCTAssertEqual(w.startMs, 500)
        XCTAssertEqual(w.endMs, 4_000)
    }

    // MARK: - 挑哪几行

    /// 长的在前 —— P4a 只量过长句,碎句只知道「更差」、没量过。
    func testLongerLinesWin() {
        let out = SpeakerSegments.select([
            c("t", 1, ms: 5_000, chars: 8),
            c("t", 2, ms: 5_000, chars: 40),
            c("t", 3, ms: 5_000, chars: 25),
        ])
        XCTAssertEqual(out["t"]?.map(\.lineID), [2, 3, 1])
    }

    /// 每簇最多 5 行 —— P4f 实测模板数在 5 条之后收益走平。
    func testAtMostFiveLinesPerCluster() {
        let out = SpeakerSegments.select((1...9).map { c("t", Int64($0), ms: 5_000) })
        XCTAssertEqual(out["t"]?.count, SpeakerSegments.maxLinesPerCluster)
    }

    /// 同长度时按 line_id 定序 —— **可复现**。
    /// 不定序的话同一场跑两次可能挑到不同的段,而分数会跟着变,
    /// 「为什么这次没认出来」就永远查不清。
    func testSelectionIsReproducible() {
        let input = (1...5).map { c("t", Int64($0), ms: 5_000, chars: 20) }
        XCTAssertEqual(SpeakerSegments.select(input)["t"]?.map(\.lineID),
                       SpeakerSegments.select(input.reversed())["t"]?.map(\.lineID))
    }

    // MARK: - 从库里取候选

    func testCandidatesSkipGapRedactedAndAlreadyAttributed() throws {
        let db = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(db)
        try TestPeople.seed(in: db)
        try db.write { d in
            try d.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status, active_transcript_id)
                VALUES (1, '2026-08-17T10:00:00+08:00', '2026-08-17', 'recording', 'closed', 1)
                """)
            try d.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (1, 1, 1, 1, 'a', 'frozen', 'x')
                """)
            let rows: [(Int64, Int, Int, String, Int, Int)] = [
                // line_id, is_gap, redacted, text, block_seq, 用不用
                (10, 0, 0, "正常的一句话应该被选中", 0, 1),
                (11, 1, 0, "【此处缺失】",           0, 0),
                (12, 0, 1, "脱敏掉的",              0, 0),
                (13, 0, 0, "已经有身份了",           0, 0),
            ]
            for (lid, gap, red, text, blk, _) in rows {
                try d.execute(sql: """
                    INSERT INTO transcript_lines
                      (line_id, transcript_id, seq, t_start_ms, t_end_ms, text,
                       char_offset, is_gap, redacted, block_seq)
                    VALUES (?, 1, ?, 0, 5000, ?, 0, ?, ?, ?)
                    """, arguments: [lid, lid, text, gap, red, blk])
                try d.execute(sql: """
                    INSERT INTO line_speakers (line_id, person_id, cluster_tag, source, updated_at)
                    VALUES (?, ?, 'speaker_0', '系统整理', 'x')
                    """, arguments: [lid, lid == 13 ? 7 : nil])
            }
        }
        let cands = try db.read { try SpeakerSegments.candidates(sessionID: 1, offsets: nominalOffsets, in: $0) }
        XCTAssertEqual(cands.map(\.lineID), [10],
                       "占位行 / 脱敏行 / 已有身份的行都不该进来")
    }

    /// 块内偏移用**块号换算**,不是拿时间反推块号 —— 后者才是那个坑。
    func testOffsetIsDerivedFromBlockSeqNotTheOtherWayAround() throws {
        let db = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(db)
        try db.write { d in
            try d.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status, active_transcript_id)
                VALUES (1, '2026-08-17T10:00:00+08:00', '2026-08-17', 'recording', 'closed', 1)
                """)
            try d.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (1, 1, 1, 1, 'a', 'frozen', 'x')
                """)
            // 块 1 里第 10 秒的行:场次绝对 310000,块内应是 10000
            try d.execute(sql: """
                INSERT INTO transcript_lines
                  (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, block_seq)
                VALUES (20, 1, 0, 310000, 315000, '块1的开头', 0, 1)
                """)
            try d.execute(sql: """
                INSERT INTO line_speakers (line_id, cluster_tag, source, updated_at)
                VALUES (20, 'speaker_0', '系统整理', 'x')
                """)
        }
        let c = try db.read { try SpeakerSegments.candidates(sessionID: 1, offsets: nominalOffsets, in: $0) }[0]
        XCTAssertEqual(c.blockSeq, 1)
        XCTAssertEqual(c.startMs, 10_000, "块内偏移算错了 —— 会去块 1 的第 310 秒取音频")
    }
}
