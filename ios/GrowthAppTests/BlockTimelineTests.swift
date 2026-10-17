import XCTest
import GRDB
@testable import GrowthApp

/// 块的真实起点与时长(M1-4d / M1-13a 的 `offsetMs` 那半条)。
///
/// 🔴 **这个文件守的是一句被写进注释、而且是假的结论**:
/// 「不裁剪就是恒等情况,时间轴仍然对得上」。它假设每块都是 300 秒,而
/// `BlockCutPolicy` 的窗口是 **270–330 秒**(`targetMs ± windowMs`),
/// 且 `RecordingKernel` 注入的是真探针 `EnergyGate` —— **切在 300 秒之后是常态**。
///
/// 那句话是假的会带来两个后果,而**两个都不报错**:
/// · 块 >300 秒 ⇒ `restoreToBlockTime` 抛 → `pump` 的 `try?` 吞掉 →
///   任务永久停在 `running`,重启也救不回;
/// · 块 ≠300 秒 ⇒ `offsetMs` 逐块累积偏移 ⇒ **跳原话跳到错的位置**。
final class BlockTimelineTests: XCTestCase {

    // MARK: - 常数活该被打

    /// `BlockCutPolicy` 自己就说了块长不是定值。
    /// **这条是上面所有推理的前提** —— 前提要是变了(比如窗口收成 0),
    /// 下面几条的理由就得跟着重写(仓规 6)。
    func testBlockLengthIsNotAConstant() {
        XCTAssertEqual(BlockCutPolicy.targetMs, 300_000)
        XCTAssertGreaterThan(BlockCutPolicy.latestMs, 300_000,
                             "块长上界要是不超过 300 秒,那个硬编码本来就没错")
        XCTAssertEqual(BlockCutPolicy.latestMs, 330_000)
        XCTAssertEqual(BlockCutPolicy.earliestMs, 270_000)
    }

    // MARK: - 超过 300 秒的块不许抛

    /// 一个 310 秒的块,末尾那句话在 308 秒处。
    ///
    /// 按老口径(`keptIntervals = [0, 300_000]`)它会抛 `timestampOutOfKeptRange`,
    /// 而抛出去的结局是**任务永久卡在 `running`**。按真时长就该正常还原。
    func testLineBeyond300sSurvivesWhenKeptIntervalIsReal() throws {
        let restored = try TranscriptFreeze.restoreToBlockTime(
            trimmedMs: 308_000,
            keptIntervals: [KeptInterval(startMs: 0, endMs: 310_000)],
            blockSeq: 0)
        XCTAssertEqual(restored, 308_000)
    }

    /// 反过来钉一遍:老口径**确实会抛**。
    /// 没有这一条,上面那条通过了也说明不了问题 —— 可能它本来就不会抛。
    func testOldConstantWouldHaveThrown() {
        XCTAssertThrowsError(
            try TranscriptFreeze.restoreToBlockTime(
                trimmedMs: 308_000,
                keptIntervals: [KeptInterval(startMs: 0, endMs: 300_000)],
                blockSeq: 0),
            "老口径必须会抛 —— 不抛的话这一整条修复就是无的放矢")
    }

    // MARK: - 🔴 时间轴不许逐块漂

    /// 三块,块长分别 310 / 280 / 300 秒,**首尾相接不留空洞**。
    ///
    /// 按老口径第 2 块的偏移是 `1 × 300_000 = 300_000`,而真值是 **310_000** ——
    /// 差 10 秒;到第 3 块差 -10 秒。这些偏移直接进冻结层(不可变),
    /// 于是**跳原话永久跳错位置,而且没有任何报错**。
    func testOffsetsFollowRealBlockStartsNotAMultipleOf300() throws {
        let lengths = [310_000, 280_000, 300_000]
        var starts: [Int] = []
        var acc = 0
        for l in lengths { starts.append(acc); acc += l }
        XCTAssertEqual(starts, [0, 310_000, 590_000])

        let blocks = zip(starts, lengths).enumerated().map { i, pair in
            BlockTranscript(
                blockSeq: i,
                offsetMs: pair.0,
                keptIntervals: [KeptInterval(startMs: 0, endMs: pair.1)],
                // 每块的最后一句都贴着块尾 —— 越界与否最容易在这儿露头
                lines: [ASRLine(startMs: pair.1 - 2_000, endMs: pair.1 - 1_000,
                                text: "第 \(i) 块的最后一句")])
        }

        let assembled = try TranscriptFreeze.assemble(blocks: blocks, missing: [])
        XCTAssertEqual(assembled.map(\.startMs),
                       [308_000, 588_000, 888_000],
                       "偏移必须跟着真实块起点走;按 blockSeq × 300_000 会得到 298/578/888")
    }

    /// 老口径在同一份数据上给出的是**错的**答案 —— 而它不抛异常。
    /// 这一条是上面那条的照妖镜:证明「按 300 秒乘」确实会算错,不是我在杞人忧天。
    func testMultipleOf300ProducesWrongTimeline() throws {
        let lengths = [310_000, 280_000, 300_000]
        let blocks = lengths.enumerated().map { i, len in
            BlockTranscript(
                blockSeq: i,
                offsetMs: i * 300_000,                 // ← 老口径
                keptIntervals: [KeptInterval(startMs: 0, endMs: len)],
                lines: [ASRLine(startMs: len - 2_000, endMs: len - 1_000, text: "x")])
        }
        let assembled = try TranscriptFreeze.assemble(blocks: blocks, missing: [])
        XCTAssertNotEqual(assembled.map(\.startMs), [308_000, 588_000, 888_000],
                          "老口径要是碰巧也对,说明这条修复没有意义")
        XCTAssertEqual(assembled.map(\.startMs), [308_000, 578_000, 898_000])
    }

    // MARK: - 空洞要占位置

    /// 两块之间停了 60 秒(中断/暂停)。第二块的偏移要把这 60 秒算进去 ——
    /// §3.1.2 的「场次内绝对毫秒」算的是**用户以为在录的那段真实时间**,
    /// 不是音频累计时长(`BlockRecord` 的注释与 `gapText` 说的是同一件事)。
    func testGapBetweenBlocksOccupiesTheTimeline() throws {
        let blocks = [
            BlockTranscript(blockSeq: 0, offsetMs: 0,
                            keptIntervals: [KeptInterval(startMs: 0, endMs: 300_000)],
                            lines: [ASRLine(startMs: 1_000, endMs: 2_000, text: "第一块")]),
            // 第一块 300 秒结束,停 60 秒,第二块从 360 秒开始
            BlockTranscript(blockSeq: 1, offsetMs: 360_000,
                            keptIntervals: [KeptInterval(startMs: 0, endMs: 300_000)],
                            lines: [ASRLine(startMs: 1_000, endMs: 2_000, text: "第二块")]),
        ]
        let assembled = try TranscriptFreeze.assemble(blocks: blocks, missing: [])
        XCTAssertEqual(assembled.map(\.startMs), [1_000, 361_000],
                       "空洞被吃掉的话,第二块会从 301 秒开始 —— 那 60 秒凭空消失")
    }

    // MARK: - 保留区间取 max 的理由

    /// 音频比墙钟戳略长时(编码器按帧收尾,差几十毫秒是正常的),
    /// **末尾那句话不许因此越界**。
    ///
    /// 生产代码取 `max(墙钟时长, ASR 报的最大时间戳)` 正是为了这个 ——
    /// 只用墙钟的话这里会抛,而抛出去就是又一次永久卡死。
    func testKeptIntervalCoversTimestampsSlightlyPastWallClock() throws {
        let wallClockMs = 310_000
        let lines = [ASRLine(startMs: 309_500, endMs: 310_120, text: "贴着块尾的一句")]
        let endMs = max(wallClockMs, lines.map(\.endMs).max() ?? 0)

        XCTAssertEqual(endMs, 310_120, "取 max 才能盖住比墙钟略长的那一点")
        XCTAssertNoThrow(
            try TranscriptFreeze.restoreToBlockTime(
                trimmedMs: 310_120,
                keptIntervals: [KeptInterval(startMs: 0, endMs: endMs)],
                blockSeq: 0))

        // 只用墙钟就会抛 —— 证明这个 max 不是可有可无的保险。
        XCTAssertThrowsError(
            try TranscriptFreeze.restoreToBlockTime(
                trimmedMs: 310_120,
                keptIntervals: [KeptInterval(startMs: 0, endMs: wallClockMs)],
                blockSeq: 0))
    }
}
