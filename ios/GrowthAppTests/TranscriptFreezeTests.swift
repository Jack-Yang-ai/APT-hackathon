import XCTest
import GRDB
@testable import GrowthApp

/// 转写冻结链路(§3.1.6)。
///
/// 主场景照验收造:3 块、中间一块缺失。除了「跑通」,重点验三件在生产里
/// 出了错也不会有人发现的事:行序有没有洞、占位行在不在正确的位置、
/// 时间轴有没有因为 VAD 挖洞而算歪。
final class TranscriptFreezeTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-08T15:00:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, '2026-08-08T14:00:00+08:00', '2026-08-08', 'recording', 'closed')
                """)
        }
    }

    override func tearDownWithError() throws { dbQueue = nil }

    // 5 分钟一块。块 0 中间有 100 秒静音被 VAD 挖掉,块 1 缺失,块 2 完整。
    private var block0: BlockTranscript {
        BlockTranscript(
            blockSeq: 0, offsetMs: 0,
            keptIntervals: [KeptInterval(startMs: 0, endMs: 100_000),
                            KeptInterval(startMs: 200_000, endMs: 300_000)],
            lines: [ASRLine(startMs: 0,       endMs: 5_000,   text: "开场"),
                    ASRLine(startMs: 99_000,  endMs: 100_000, text: "静音前最后一句"),
                    ASRLine(startMs: 100_000, endMs: 105_000, text: "静音后第一句")])
    }
    private let missing1 = MissingBlock(blockSeq: 1, offsetMs: 300_000, durationMs: 300_000)
    private var block2: BlockTranscript {
        BlockTranscript(
            blockSeq: 2, offsetMs: 600_000,
            keptIntervals: [KeptInterval(startMs: 0, endMs: 300_000)],
            lines: [ASRLine(startMs: 0,      endMs: 4_000,  text: "第三块第一句"),
                    ASRLine(startMs: 10_000, endMs: 15_000, text: "第三块第二句")])
    }

    private func freezeThreeBlocks() throws -> FreezeResult {
        // 块顺序故意打乱,证明拼接靠的是 block_seq 而不是入参顺序
        try TranscriptFreeze.freeze(sessionID: 1, asrModel: "step-asr-v1",
                                    blocks: [block2, block0], missing: [missing1],
                                    now: now, in: dbQueue)
    }

    private func rows() throws -> [Row] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT seq, t_start_ms, t_end_ms, text, char_offset, is_gap
                  FROM transcript_lines ORDER BY seq
                """)
        }
    }

    // MARK: - 验收(M1-30 ①):账本丢了中间一块

    /// 🔴 **账本(磁盘)与 `upload_jobs`(库)分叉时,这一场原来会自称完整。**
    ///
    /// `missing` 是拿账本作差算的 ⇒ 账本丢掉的块**同时**从 `timing` 和 `missing`
    /// 里消失 ⇒ 既不进 partial、也不插占位行,而 exit code 全绿、行数在涨。
    /// 这是本仓最贵的失败形态。
    func testLedgerLostBlockStillFreezesAsPartial() throws {
        let r = try TranscriptFreeze.freeze(
            sessionID: 1, asrModel: "step-asr-v1",
            blocks: [block0, block2], missing: [], unplaceable: [1],
            now: now, in: dbQueue)
        XCTAssertEqual(r.status, "partial", """
            账本丢了一块却落成 \(r.status) —— 这一场自称完整,
            而卡片会说「好了」。这正是 M1-30 ① 要挡的形态。
            """)
    }

    /// 占位行**摆在正确的槽位**,而且**不谎报长度**。
    func testLedgerLostBlockGetsAnUnknownExtentPlaceholder() throws {
        _ = try TranscriptFreeze.freeze(
            sessionID: 1, asrModel: "step-asr-v1",
            blocks: [block0, block2], missing: [], unplaceable: [1],
            now: now, in: dbQueue)
        let all = try rows()
        let gaps = all.filter { $0["is_gap"] as Int == 1 }
        XCTAssertEqual(gaps.count, 1, "账本丢的那一块没有占位行 —— 逐字稿上这个洞就消失了")
        XCTAssertEqual(gaps[0]["text"] as String, TranscriptFreeze.gapTextUnknownExtent, """
            占位文案不对。⚠️ **绝不能复用 `gapText(seconds: 0)`** ——
            那会写出「此处缺失 0 秒」,是一句当场就假的话:
            长度只在账本里,而账本正是丢掉的那一份。
            """)
        // 槽位:它必须**夹在块 0 与块 2 之间**。
        // ⚠️ 不数「第几行」—— 那要跟着每块几行走,改一句夹具就假红一次
        // (第一版就是这么写的,当场被 block0 的 3 行打脸)。断性质,不断计数。
        let seqs = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT block_seq, is_gap FROM transcript_lines ORDER BY seq")
        }
        let gapAt = seqs.firstIndex { $0["is_gap"] as Int == 1 }
        XCTAssertNotNil(gapAt, "占位行不在")
        XCTAssertEqual(seqs[gapAt!]["block_seq"] as Int?, 1, "占位行记的块号不对")
        XCTAssertTrue(seqs[..<gapAt!].allSatisfy { ($0["block_seq"] as Int?) == 0 }, """
            占位行前面混进了别的块 —— 它应该紧跟在块 0 之后。
            实际块号序列:\(seqs.map { $0["block_seq"] as Int? })
            """)
        XCTAssertTrue(seqs[(gapAt! + 1)...].allSatisfy { ($0["block_seq"] as Int?) == 2 }, """
            占位行后面不全是块 2 —— 槽位错了。
            实际块号序列:\(seqs.map { $0["block_seq"] as Int? })
            """)
    }

    /// 照妖镜:**不给 `unplaceable` 就该是 `frozen`** —— 即修复前那个形态。
    func testWithoutUnplaceableItIsStillFrozen() throws {
        let r = try TranscriptFreeze.freeze(
            sessionID: 1, asrModel: "step-asr-v1",
            blocks: [block0, block2], missing: [], unplaceable: [],
            now: now, in: dbQueue)
        XCTAssertEqual(r.status, "frozen", """
            这条是照妖镜:它必须是 frozen,否则上面两条证明不了任何东西
            (说明是别的原因把状态推成了 partial)。
            """)
    }

    // MARK: - 验收:3 块中间缺一块

    func testFreezesAsPartialWithGapPlaceholder() throws {
        let result = try freezeThreeBlocks()
        XCTAssertEqual(result.status, "partial", "有缺块就是 partial,不是 frozen")
        XCTAssertEqual(result.lineCount, 6)   // 3 + 占位 1 + 2
        XCTAssertEqual(result.gapCount, 1)
    }

    /// 行序无洞 —— 断言 A2 的原话:MAX(seq)+1 必须等于 COUNT(*)。
    func testSeqHasNoHoles() throws {
        try freezeThreeBlocks()
        let holes = try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM (
                  SELECT transcript_id FROM transcript_lines
                   GROUP BY transcript_id HAVING MAX(seq) + 1 != COUNT(*))
                """) ?? -1
        }
        XCTAssertEqual(holes, 0)
        XCTAssertEqual(try rows().map { $0["seq"] as Int }, [0, 1, 2, 3, 4, 5])
    }

    /// 占位行在位:正好夹在块 0 与块 2 之间,且跨度就是缺块那一段。
    func testGapPlaceholderSitsInTheRightSlot() throws {
        try freezeThreeBlocks()
        let all = try rows()
        let gaps = all.filter { $0["is_gap"] as Int == 1 }
        XCTAssertEqual(gaps.count, 1)
        let gap = try XCTUnwrap(gaps.first)

        XCTAssertEqual(gap["seq"] as Int, 3, "块 0 的 3 行之后、块 2 之前")
        XCTAssertEqual(gap["t_start_ms"] as Int, 300_000)
        XCTAssertEqual(gap["t_end_ms"] as Int, 600_000)
        XCTAssertEqual(gap["text"] as String, "〔此处缺失 300 秒〕")
    }

    /// 时间戳连续。
    ///
    /// 注意「连续」不等于「每一毫秒都有行盖住」:VAD 会挖掉静音,一块的末尾
    /// 本来就可能没有任何行(块 0 的行到 205s 就没了,而块跨到 300s)。
    /// 真正要守的是两条——**整场单调不减**,以及**缺块那一段被占位行严丝合缝地占住**,
    /// 没有别的行越界跑进缺块的时间范围里。
    func testTimestampsAreContinuous() throws {
        try freezeThreeBlocks()
        let all = try rows()
        let starts = all.map { $0["t_start_ms"] as Int }
        let ends = all.map { $0["t_end_ms"] as Int }

        XCTAssertEqual(starts, starts.sorted(), "起点必须单调不减")
        for (s, e) in zip(starts, ends) { XCTAssertLessThanOrEqual(s, e) }

        // 占位行正好盖住缺块那一段
        XCTAssertEqual(starts[3], 300_000)
        XCTAssertEqual(ends[3], 600_000)

        // 缺块之前的行全部收在 300_000 之前,之后的行全部起于 600_000 之后
        for row in all where (row["seq"] as Int) < 3 {
            XCTAssertLessThanOrEqual(row["t_end_ms"] as Int, 300_000,
                                     "块 0 的行不该越界进缺块时间段")
        }
        for row in all where (row["seq"] as Int) > 3 {
            XCTAssertGreaterThanOrEqual(row["t_start_ms"] as Int, 600_000,
                                        "块 2 的行不该越界进缺块时间段")
        }
    }

    // MARK: - 时间轴还原(VAD 挖洞)

    /// 这是整条链路最容易悄悄算歪的一步:ASR 给的是**裁剪后**的时间戳,
    /// 落库要的是**场次绝对**毫秒。算错了没人会发现——行照样有、顺序照样对,
    /// 只是跳转原话会跳到别处,分人 spans 的重叠率抽查(A8)也会莫名其妙地低。
    func testTimelineIsRestoredThroughKeptIntervals() throws {
        try freezeThreeBlocks()
        let all = try rows()

        XCTAssertEqual(all[0]["t_start_ms"] as Int, 0)          // 裁剪后 0 → 原始 0
        XCTAssertEqual(all[1]["t_start_ms"] as Int, 99_000)     // 仍在第一段保留区间内
        // 裁剪后 100_000 落在第二段保留区间的起点 —— 中间那 100 秒静音被跳过
        XCTAssertEqual(all[2]["t_start_ms"] as Int, 200_000,
                       "被 VAD 挖掉的 100 秒必须在还原后重新出现")
        XCTAssertEqual(all[2]["t_end_ms"] as Int, 205_000)
        // 块 2 没有裁剪,只加块偏移
        XCTAssertEqual(all[4]["t_start_ms"] as Int, 600_000)
        XCTAssertEqual(all[5]["t_start_ms"] as Int, 610_000)
    }

    func testRestoreRejectsTimestampBeyondKeptTotal() throws {
        // 保留区间总长 200_000,给它 200_001 —— 说明区间表与送检音频对不上
        XCTAssertThrowsError(try TranscriptFreeze.restoreToBlockTime(
            trimmedMs: 200_001,
            keptIntervals: [KeptInterval(startMs: 0, endMs: 100_000),
                            KeptInterval(startMs: 200_000, endMs: 300_000)],
            blockSeq: 0)) { error in
            guard case TranscriptFreeze.Failure.timestampOutOfKeptRange = error else {
                return XCTFail("应当报 timestampOutOfKeptRange,实际 \(error)")
            }
        }
    }

    // MARK: - char_offset 是冻结口径

    /// 偏移一次算定,下游不许按 text 重算;**占位行按自己的占位文本长度参与累计**
    /// (§3.1.2 明写)。漏掉这一条,缺块之后的所有偏移都会整体错开。
    func testCharOffsetIsCumulativeAndCountsGapText() throws {
        try freezeThreeBlocks()
        let all = try rows()

        var running = 0
        for row in all {
            XCTAssertEqual(row["char_offset"] as Int, running, "seq \(row["seq"] as Int) 偏移对不上")
            running += (row["text"] as String).count
        }
        // 单拎出来:占位行之后那一行的偏移,必须已经把占位文本算进去
        let gapOffset = all[3]["char_offset"] as Int
        let gapLen = (all[3]["text"] as String).count
        XCTAssertEqual(all[4]["char_offset"] as Int, gapOffset + gapLen)
    }

    // MARK: - 全到齐 / 打自己的实现

    func testAllBlocksPresentFreezesClean() throws {
        let block1 = BlockTranscript(blockSeq: 1, offsetMs: 300_000,
                                     keptIntervals: [KeptInterval(startMs: 0, endMs: 300_000)],
                                     lines: [ASRLine(startMs: 0, endMs: 2_000, text: "中间块")])
        let r = try TranscriptFreeze.freeze(sessionID: 1, asrModel: "step-asr-v1",
                                            blocks: [block0, block1, block2],
                                            now: now, in: dbQueue)
        XCTAssertEqual(r.status, "frozen")
        XCTAssertEqual(r.gapCount, 0)
        XCTAssertEqual(r.lineCount, 6)
    }

    func testDuplicateBlockSeqIsRejected() throws {
        XCTAssertThrowsError(try TranscriptFreeze.assemble(blocks: [block0, block0], missing: []))
    }

    /// 缺块的 seq 与某个到齐的块撞车,同样是拼接顺序不可判定。
    func testMissingBlockCollidingWithPresentBlockIsRejected() throws {
        XCTAssertThrowsError(try TranscriptFreeze.assemble(
            blocks: [block0], missing: [MissingBlock(blockSeq: 0, offsetMs: 0, durationMs: 1000)]))
    }

    /// ASR 行乱序是上游的缺陷,这里抛出来,不悄悄重排。
    func testOutOfOrderLinesAreRejected() throws {
        let bad = BlockTranscript(blockSeq: 0, offsetMs: 0,
                                  keptIntervals: [KeptInterval(startMs: 0, endMs: 10_000)],
                                  lines: [ASRLine(startMs: 5_000, endMs: 6_000, text: "后"),
                                          ASRLine(startMs: 1_000, endMs: 2_000, text: "先")])
        XCTAssertThrowsError(try TranscriptFreeze.assemble(blocks: [bad], missing: []))
    }

    func testEmptyInputIsRejected() throws {
        XCTAssertThrowsError(try TranscriptFreeze.assemble(blocks: [], missing: []))
    }

    // MARK: - 冻结之后

    /// 落库即冻结:这条链路产出的行受 A1 保护,改不动。
    func testFrozenLinesAreImmutable() throws {
        try freezeThreeBlocks()
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "UPDATE transcript_lines SET text = '改一下' WHERE seq = 0")
        })
    }

    /// 界面默认展示 active_transcript_id(§3.1.4)。冻结完不指过去,
    /// 就是「写成功了但界面找不到」。
    func testActiveTranscriptPointerIsSet() throws {
        let r = try freezeThreeBlocks()
        let active = try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT active_transcript_id FROM sessions WHERE id = 1")
        }
        XCTAssertEqual(active, r.transcriptID)
    }

    /// 占位行不该被搜出来,正常行该搜得到。
    func testGapIsNotSearchableButRealLinesAre() throws {
        try freezeThreeBlocks()
        func hits(_ q: String) throws -> Int {
            try dbQueue.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM transcript_lines_fts WHERE transcript_lines_fts MATCH ?
                    """, arguments: [q]) ?? -1
            }
        }
        XCTAssertEqual(try hits("\"静音后第一句\""), 1)
        XCTAssertEqual(try hits("\"此处缺失\""), 0)
    }

    // MARK: - block_seq(迁移 v15,声纹取段的前置)

    /// 🔴 **`t_start_ms` 反推不出块号,所以每行必须自己记住来自哪块。**
    ///
    /// 真实块长是 `[270s, 330s]`(`BlockCutPolicy` 目标 300s ± 30s 窗口),
    /// 而块偏移用的是**名义值** `blockSeq * 300_000`。于是:
    ///
    ///     块 0 第 310 秒的行  → t_start_ms = 0       + 310_000 = 310000
    ///     块 1 第  10 秒的行  → t_start_ms = 300_000 +  10_000 = 310000
    ///
    /// **一模一样。** 下游按 `t_start_ms / 300_000` 去找 `block-%04d.m4a`
    /// 会给块 0 那一行取到**块 1 的音频** —— 而块 1 是另一个人在说话。
    /// 不报错、不越界、时间戳看着完全正常。
    ///
    /// 这条测试就是那把尺子:两行的 `t_start_ms` 相同,`block_seq` 必须不同。
    func testTwoLinesCanShareTStartMsSoBlockSeqIsTheOnlyWayToLocateAudio() throws {
        // 块 0 跑满了 330 秒(硬切上限),所以它有一行落在第 310 秒
        let longBlock0 = BlockTranscript(
            blockSeq: 0, offsetMs: 0,
            keptIntervals: [KeptInterval(startMs: 0, endMs: 330_000)],
            lines: [ASRLine(startMs: 310_000, endMs: 315_000, text: "块0的尾巴")])
        let block1 = BlockTranscript(
            blockSeq: 1, offsetMs: 300_000,
            keptIntervals: [KeptInterval(startMs: 0, endMs: 300_000)],
            lines: [ASRLine(startMs: 10_000, endMs: 15_000, text: "块1的开头")])

        try TranscriptFreeze.freeze(sessionID: 1, asrModel: "step-asr-v1",
                                    blocks: [longBlock0, block1], now: now, in: dbQueue)

        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT text, t_start_ms, block_seq FROM transcript_lines ORDER BY seq
                """)
        }
        let byText = Dictionary(uniqueKeysWithValues:
            rows.map { ($0["text"] as String, ($0["t_start_ms"] as Int, $0["block_seq"] as Int?)) })

        // 前提:两行的 t_start_ms 确实撞在一起 —— 撞不上的话这条测试就没在测东西
        XCTAssertEqual(byText["块0的尾巴"]?.0, 310_000)
        XCTAssertEqual(byText["块1的开头"]?.0, 310_000)
        // 结论:块号把它们分开了
        XCTAssertEqual(byText["块0的尾巴"]?.1, 0)
        XCTAssertEqual(byText["块1的开头"]?.1, 1)
    }

    /// 占位行也要记块号 —— 它代表的正是**缺的那一块**。
    /// 不记的话「哪一块没转写成功」这个信息在库里就只剩文案里那句人话。
    func testGapLinesCarryTheMissingBlockSeq() throws {
        try TranscriptFreeze.freeze(sessionID: 1, asrModel: "step-asr-v1",
                                    blocks: [block0, block2], missing: [missing1],
                                    now: now, in: dbQueue)
        let gap = try dbQueue.read { db in
            try Row.fetchOne(db, sql:
                "SELECT block_seq FROM transcript_lines WHERE is_gap = 1")
        }
        XCTAssertEqual(gap?["block_seq"] as Int?, 1)
    }
}

// MARK: - 送 Mac 的那条腿:块内原始毫秒 → 裁剪后时间轴(M2-认10 ③)

/// 🔴 这组守的是「声纹取到别处的音频,而且一直不会红」。
///
/// 送去 Mac 的是**裁过静音的 wav**,而行的时间戳是**块内原始**毫秒 —— 两条时间轴。
/// 直接把原始毫秒当 wav 下标,取到的就是别处的声音。
/// 实测(用户真机某场次):`kept_json = [[94512, 330126]]`,每一句都取到 94.5 秒
/// 之后的内容;全库约 130 句取错位置、275 句因「超出块尾」被跳过。
///
/// ⚠️ 它不会红,是因为**入库那条腿读的是手机本地 m4a(没裁过)** —— 确认→入库全对,
/// 只有送 Mac 那条腿错位。两条腿各自看都正常。
final class WavTimelineTests: XCTestCase {

    /// 前面被裁掉一段:所有时间戳整体前移,而且**位移量就是被裁掉的量**。
    func testTimestampsShiftByExactlyWhatWasTrimmed() throws {
        let kept = [KeptInterval(startMs: 94_512, endMs: 330_126)]
        XCTAssertEqual(TranscriptFreeze.trimmedTime(blockMs: 94_512, keptIntervals: kept), 0)
        XCTAssertEqual(TranscriptFreeze.trimmedTime(blockMs: 100_000, keptIntervals: kept), 5_488)
        let w = TranscriptFreeze.wavRange(blockStart: 100_000, blockEnd: 104_000, keptIntervals: kept)
        XCTAssertEqual(w?.start, 5_488)
        XCTAssertEqual(w?.end, 9_488, "行长变了 —— 取出来的音频会短一截或长一截")
    }

    /// 与 `restoreToBlockTime` 必须互为反函数 —— 两个方向各算各的就是两个出处。
    func testItIsTheInverseOfRestoreToBlockTime() throws {
        let kept = [KeptInterval(startMs: 1_000, endMs: 3_000),
                    KeptInterval(startMs: 10_000, endMs: 12_500)]
        for blockMs in [1_000, 1_500, 2_999, 10_000, 11_111, 12_500] {
            let t = TranscriptFreeze.trimmedTime(blockMs: blockMs, keptIntervals: kept)
            XCTAssertNotNil(t, "块内 \(blockMs) 明明在保留区间里,却映不到裁剪后时间轴")
            XCTAssertEqual(try TranscriptFreeze.restoreToBlockTime(
                trimmedMs: t!, keptIntervals: kept, blockSeq: 0), blockMs,
                "来回换算对不上 —— 两个方向各算各的,总有一天会分叉")
        }
    }

    /// 落在**被裁掉的空隙**里返回 nil。「这一刻的音频没送上去」不能用 0 表示。
    func testAMomentThatWasTrimmedAwayHasNoPlace() throws {
        let kept = [KeptInterval(startMs: 1_000, endMs: 3_000),
                    KeptInterval(startMs: 10_000, endMs: 12_500)]
        XCTAssertNil(TranscriptFreeze.trimmedTime(blockMs: 0, keptIntervals: kept))
        XCTAssertNil(TranscriptFreeze.trimmedTime(blockMs: 5_000, keptIntervals: kept))
        XCTAssertNil(TranscriptFreeze.trimmedTime(blockMs: 99_999, keptIntervals: kept))
    }

    /// 🔴 **跨过一条裁剪缝的行必须丢掉。**
    ///
    /// 它在 wav 里是被拼接过的:中间那段已经不在了。取一段「连续」音频等于把
    /// 相隔 7 秒的两处话接在一起送去比对 —— 那比取不到更坏,因为它看起来正常。
    func testALineStraddlingATrimSeamIsDropped() throws {
        let kept = [KeptInterval(startMs: 1_000, endMs: 3_000),
                    KeptInterval(startMs: 10_000, endMs: 12_500)]
        XCTAssertNil(TranscriptFreeze.wavRange(blockStart: 2_000, blockEnd: 11_000,
                                               keptIntervals: kept), """
            跨裁剪缝的行被放行了 —— 它在 wav 里是两处话拼起来的,
            而拼接处的「声音」不属于任何人。
            """)
        // 整段都在同一个保留区间里的照常放行
        XCTAssertNotNil(TranscriptFreeze.wavRange(blockStart: 10_100, blockEnd: 12_000,
                                                  keptIntervals: kept))
    }
}
