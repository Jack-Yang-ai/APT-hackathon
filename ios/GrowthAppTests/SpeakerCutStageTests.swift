import XCTest
@testable import GrowthApp

/// 切分接进流水线那一步(M1-19 第三块)。
///
/// 这一层自己几乎没有算法 —— 探针在 `SpeakerCut`,切行也在 `SpeakerCut`。
/// 它唯一的活是**在两个时间轴之间换算**,而那正是本仓栽过的形状:
/// 换算错了**不报错**,只是取到同一块里别处的声音,探针照样给出一个看着正常的切点。
final class SpeakerCutStageTests: XCTestCase {

    private let rate = AudioImport.sampleRate

    private func word(_ s: Int, _ e: Int, _ t: String) -> ASRWord {
        ASRWord(startMs: s, endMs: e, text: t)
    }

    /// 一块:音频 30 秒,而 VAD 只留了 **10–20 秒**那一段。
    /// 于是裁剪后时间轴的 0 毫秒 = 块内 10 秒。
    private func block(lines: [ASRLine]) -> BlockTranscript {
        BlockTranscript(blockSeq: 3, offsetMs: 900_000,
                        keptIntervals: [KeptInterval(startMs: 10_000, endMs: 20_000)],
                        lines: lines)
    }

    /// 30 秒音频:**只有块内 10–20 秒是 1,其余全是 0。**
    /// 探针若取错了地方,拿到的就全是 0 —— 下面那条断言据此把换算钉死。
    private func audio() -> [Float] {
        (0..<(30 * rate)).map { $0 >= 10 * rate && $0 < 20 * rate ? 1 : 0 }
    }

    // MARK: - 🔴 两个时间轴不许搞混

    /// 行在**裁剪后**时间轴上是 0–8 秒;它真正对应的音频是**块内 10–18 秒**。
    /// 探针拿到的每一个窗都必须落在那一段里。
    ///
    /// ⚠️ 这条测试的价值全在「反过来会怎样」:直接拿裁剪后坐标去切音频的话,
    /// 取到的是块内 0–8 秒 —— 而那是 VAD 判定的**静音**,一个字都没说。
    /// 后果不是报错,是**探针在一段没人说话的音频上找换人点**,
    /// 然后把它找到的位置用来切一行真话。本仓已经在
    /// 「`blockSeq × 300_000` 反推偏移」上栽过一模一样的形状(M1-13a)。
    func testTheProbeReadsAudioAtBlockTimeNotTrimmedTime() throws {
        let line = ASRLine(startMs: 0, endMs: 8000, text: "一二三四",
                           speaker: "speaker_0",
                           words: [word(0, 2000, "一"), word(2000, 4000, "二"),
                                   word(4000, 6000, "三"), word(6000, 8000, "四")])
        var sawSilence = false
        var frames = 0
        _ = try SpeakerCutStage.plan(for: block(lines: [line]), samples: audio()) { w in
            frames += 1
            if w.contains(0) { sawSilence = true }
            return [1, 0]
        }
        XCTAssertGreaterThan(frames, 0, "一个窗都没嵌 —— 这一行根本没被探,下面的断言是空转的")
        XCTAssertFalse(sawSilence,
                       "探针取到了块内 0–10 秒那段静音 —— 说明它把裁剪后坐标当块坐标用了。"
                       + "这个错法不报错,只是让切点与这一行毫无关系")
    }

    /// 切点回程也走词的**裁剪后**坐标,不做逆映射 —— 刀只落在词边界上。
    func testTheCutIsReportedInTrimmedCoordinatesSoItCanFeedSplit() throws {
        let line = ASRLine(startMs: 0, endMs: 8000, text: "一二三四",
                           speaker: "speaker_0",
                           words: [word(0, 2000, "一"), word(2000, 4000, "二"),
                                   word(4000, 6000, "三"), word(6000, 8000, "四")])
        // 前半段一个向量、后半段另一个 ⇒ 中间某处分离度突起
        let plans = try SpeakerCutStage.plan(for: block(lines: [line]), samples: audio()) { w in
            w.count > 0 && w.first == w.last ? [1, 0] : [0, 1]
        }
        for p in plans {
            XCTAssertTrue(line.words.contains { $0.startMs == p.atTrimmedMs },
                          "切点 \(p.atTrimmedMs) 不落在任何一个词的起点上 —— "
                          + "那它就没法喂给 `SpeakerCut.split`,回程映射错了")
            XCTAssertEqual(p.blockSeq, 3)
        }
    }

    // MARK: - 该跳过的都跳过(fail-open)

    /// 没有保留区间表 ⇒ 换算没有依据 ⇒ **不探**,而不是拿裁剪后坐标硬凑。
    func testABlockWithoutKeptIntervalsIsNotProbed() throws {
        let line = ASRLine(startMs: 0, endMs: 8000, text: "一二",
                           speaker: nil,
                           words: [word(0, 4000, "一"), word(4000, 8000, "二")])
        let b = BlockTranscript(blockSeq: 3, offsetMs: 0, keptIntervals: [], lines: [line])
        var called = false
        let plans = try SpeakerCutStage.plan(for: b, samples: audio()) { _ in called = true; return [1, 0] }
        XCTAssertEqual(plans, [])
        XCTAssertFalse(called, "没有保留区间表却还是探了 —— 那它是在一段猜出来的位置上找切点")
    }

    /// 行太短(短于 `minProbeMs`)⇒ 连候选点都凑不够,**不探**,省掉注定为 nil 的前向。
    func testAShortLineIsNotProbedAtAll() throws {
        let short = ASRLine(startMs: 0, endMs: 1000, text: "一二",
                            speaker: nil,
                            words: [word(0, 500, "一"), word(500, 1000, "二")])
        var called = false
        _ = try SpeakerCutStage.plan(for: block(lines: [short]), samples: audio()) { _ in
            called = true; return [1, 0]
        }
        XCTAssertFalse(called, "\(SpeakerCutStage.minProbeMs) 毫秒以下的行被探了 —— 白烧前向")
    }

    /// 没有逐词时间戳的行 ⇒ 就算找到切点也切不动文字,**不探**。
    func testALineWithoutWordsIsNotProbed() throws {
        let noWords = ASRLine(startMs: 0, endMs: 8000, text: "一二三四", speaker: nil, words: [])
        var called = false
        _ = try SpeakerCutStage.plan(for: block(lines: [noWords]), samples: audio()) { _ in
            called = true; return [1, 0]
        }
        XCTAssertFalse(called, "没有逐词时间戳还去探 —— 找到切点也只能按比例摊字,那是猜")
    }

    /// 嵌入器抛出 ⇒ **抛上去**。与 `SpeakerCut` 同一条纪律:
    /// 吞掉的形态是「所有行都不切」,和「本来没有需要切的行」一模一样。
    func testAnEmbedderFailurePropagates() {
        let line = ASRLine(startMs: 0, endMs: 8000, text: "一二",
                           speaker: nil,
                           words: [word(0, 4000, "一"), word(4000, 8000, "二")])
        struct Boom: Error {}
        XCTAssertThrowsError(
            try SpeakerCutStage.plan(for: block(lines: [line]), samples: audio()) { _ in throw Boom() })
    }

    // MARK: - 落刀

    /// 🔴 切出来的两半**簇标签一律置空**。
    ///
    /// ASR 给的 `speaker` 是整句一个,而「这两半是不同的人」正是我们要推翻它的地方。
    /// 照抄的后果是:切是切开了,两半仍挂同一个人,**看起来一切正常**。
    func testBothHalvesLoseTheASRClusterTag() {
        let line = ASRLine(startMs: 0, endMs: 8000, text: "一二三四",
                           speaker: "speaker_0",
                           words: [word(0, 2000, "一"), word(2000, 4000, "二"),
                                   word(4000, 6000, "三"), word(6000, 8000, "四")])
        let out = SpeakerCutStage.apply(
            [.init(blockSeq: 3, lineIndex: 0, atTrimmedMs: 4000, atBlockMs: 14_000)],
            to: [block(lines: [line])])
        XCTAssertEqual(out[0].lines.count, 2, "没切成两行")
        XCTAssertEqual(out[0].lines.map(\.speaker), [nil, nil],
                       "切出来的两半还挂着 ASR 那个整句标签 —— "
                       + "切开了而两半仍是同一个人,看起来一切正常,这正是最坏的形态")
        XCTAssertEqual(out[0].lines.map(\.text).joined(), "一二三四", "文字丢了或重了")
    }

    /// 没有计划的块**原样返回**,连 `keptIntervals` / `offsetMs` 都不许动。
    func testBlocksWithoutAPlanComeBackUntouched() {
        let line = ASRLine(startMs: 0, endMs: 8000, text: "一二", speaker: "speaker_0",
                           words: [word(0, 4000, "一"), word(4000, 8000, "二")])
        let b = block(lines: [line])
        XCTAssertEqual(SpeakerCutStage.apply([], to: [b]), [b])
        XCTAssertEqual(SpeakerCutStage.apply(
            [.init(blockSeq: 99, lineIndex: 0, atTrimmedMs: 4000, atBlockMs: 0)], to: [b]), [b],
            "计划指的是别的块,这一块却被动了")
    }

    /// 计划有、而 `split` 切不动(片太短)⇒ **留原行**,不许弄丢。
    func testAnUnsplittableLineIsKeptWhole() {
        let line = ASRLine(startMs: 0, endMs: 8000, text: "一二",
                           speaker: "speaker_0",
                           words: [word(0, 100, "一"), word(100, 8000, "二")])
        // 切在 100 毫秒处 ⇒ 头片只有 100 毫秒,短于 `SpeakerCut.minPieceMs`
        let out = SpeakerCutStage.apply(
            [.init(blockSeq: 3, lineIndex: 0, atTrimmedMs: 100, atBlockMs: 10_100)],
            to: [block(lines: [line])])
        XCTAssertEqual(out[0].lines, [line], "切不动却把行弄丢了 —— fail-open 的意思是留原样")
    }

    // MARK: - 🔴 灰度闸

    /// **参数定版之前不许真切。**
    ///
    /// `SpeakerCut.separationMargin` 至今没有实测依据(见它的注释),
    /// 而方案的落地第 3 步写的就是「灰度只切不写:并行跑,只记日志不改归属」。
    /// 这条断言不是测逻辑,是**把「还没定版」这件事钉在测试里** ——
    /// 哪天有人把它打开,得先让这条红,而红的时候会读到为什么。
    func testCutsAreNotAppliedUntilTheMarginIsCalibrated() {
        XCTAssertFalse(SpeakerCutStage.appliesCuts,
                       "灰度闸被打开了。打开它之前必须先有 50 段人工金标上的参数定版结果 —— "
                       + "否则就是拿一个猜出来的数去切用户的话")
    }
}
