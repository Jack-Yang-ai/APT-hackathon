import XCTest
@testable import GrowthApp

/// 「按词边界把一行切成两行」(M1-19)。
///
/// 这一组打的是**切错的那些形态**,不是「切通了」:
/// 切分是破坏性的 —— 切坏一行干净话的代价,比不切高得多。
final class SpeakerCutTests: XCTestCase {

    /// 照真实报文的形状造:词自带标点,逐词拼起来正好等于整句。
    /// (实测 StepFun:`看`/`一`/`下。`/`在`/`说`/`中。` → 「看一下。在说中。」)
    private func line(_ pairs: [(Int, Int, String)],
                      speaker: String? = "speaker_0") -> ASRLine {
        let words = pairs.map { ASRWord(startMs: $0.0, endMs: $0.1, text: $0.2) }
        return ASRLine(startMs: pairs.first!.0, endMs: pairs.last!.1,
                       text: words.map(\.text).joined(), speaker: speaker, words: words)
    }

    /// 一句 6 秒、中间换人,切点落在第 4 个词的起点。
    private var sample: ASRLine {
        line([(0, 900, "他说"), (900, 1900, "交付时间"), (1900, 3000, "要重排。"),
              (3000, 4000, "那"), (4000, 5000, "我这边"), (5000, 6000, "没问题。")])
    }

    // MARK: - 切对了

    func testItCutsOnTheWordBoundaryAndKeepsEveryCharacter() throws {
        let (a, b) = try XCTUnwrap(SpeakerCut.split(sample, atMs: 3000))
        XCTAssertEqual(a.text, "他说交付时间要重排。")
        XCTAssertEqual(b.text, "那我这边没问题。")
        // 🔴 **两半拼起来必须逐字等于原文** —— 少一个字不会报错,
        // 只会让「引文是原文子串」那条校验在下游莫名其妙地挂掉。
        XCTAssertEqual(a.text + b.text, sample.text)
    }

    /// 外沿用原行的、内沿用词的真值 —— 切分不许顺手改了这一行的起止。
    func testTheOuterEdgesStayOnTheOriginalLine() throws {
        let (a, b) = try XCTUnwrap(SpeakerCut.split(sample, atMs: 3000))
        XCTAssertEqual(a.startMs, sample.startMs, "前半的起点被切分改了")
        XCTAssertEqual(b.endMs, sample.endMs, "后半的终点被切分改了")
        XCTAssertEqual(a.endMs, 3000)      // 前半最后一个词的真实终点
        XCTAssertEqual(b.startMs, 3000)    // 后半第一个词的真实起点
    }

    /// 刀口落在词**中间**时:整个词归一侧,**不劈开**;结果与刀口落在该词末尾一致。
    ///
    /// ⚠️ 归**前**一侧是有依据的选择,不是随手定的:词从 3000ms 开始说,
    /// 而换人点在 3400ms —— 开口那一刻还没换人。
    /// (第一版这条测试断言它该归后半,**是断言写错了,不是代码错**;
    ///  两种都说得通,而真正该钉的不变量是下面那条:一个词都不许丢、不许劈开。)
    func testACutInsideAWordKeepsTheWordWhole() throws {
        let mid = try XCTUnwrap(SpeakerCut.split(sample, atMs: 3400))   // 落在「那」(3000–4000)中间
        let onEdge = try XCTUnwrap(SpeakerCut.split(sample, atMs: 4000))
        XCTAssertEqual(mid.0.text, onEdge.0.text)
        XCTAssertEqual(mid.1.text, onEdge.1.text)
        XCTAssertTrue(mid.0.words.contains(where: { $0.text == "那" }),
                      "开口时还没换人,这个词该整个归前半")
    }

    /// 🔴 **最硬的那条不变量:切完之后,词一个不少、一个不多、一个不劈。**
    ///
    /// 丢一个词不会报错 —— 转写照样有内容、顺序照样对,只是**少了一句里的一小截**,
    /// 而这正是本仓最贵的失败形态。所以对每一个可能的刀口都验一遍。
    func testNoWordIsEverLostOrSplit() throws {
        for cut in stride(from: 0, through: 6000, by: 100) {
            guard let (a, b) = SpeakerCut.split(sample, atMs: cut) else { continue }
            XCTAssertEqual(a.words + b.words, sample.words,
                           "刀口 \(cut):词的序列变了(丢了、重了、或被劈开)")
            XCTAssertEqual(a.text + b.text, sample.text, "刀口 \(cut):文字拼不回原文")
        }
    }

    // MARK: - 🔴 簇标签不许照抄

    /// **这条是本组最要紧的。**
    ///
    /// ASR 的 `speaker` 是整句一个,而「这两半是不同的人」正是要推翻它的地方。
    /// 照抄的后果是:切是切开了,而两半仍挂同一个人 —— **看起来一切正常**,
    /// 归属却和没切时一样错。
    func testNeitherHalfInheritsTheSpeakerLabel() throws {
        let (a, b) = try XCTUnwrap(SpeakerCut.split(sample, atMs: 3000))
        XCTAssertNil(a.speaker, "前半照抄了 ASR 的簇标签 —— 切了等于没切")
        XCTAssertNil(b.speaker, "后半照抄了 ASR 的簇标签 —— 切了等于没切")
        XCTAssertEqual(sample.speaker, "speaker_0", "夹具没造对:原行本来就该带标签")
    }

    // MARK: - 🔴 四条 fail-open,每条一个对照

    /// 没有逐词时间戳 ⇒ 拒绝切,**不按比例摊字**。
    func testWithoutWordTimestampsItRefusesToCut() {
        let noWords = ASRLine(startMs: 0, endMs: 6000, text: "他说交付时间要重排。那我这边没问题。",
                              speaker: "speaker_0")
        XCTAssertNil(SpeakerCut.split(noWords, atMs: 3000),
                     "没有逐词时间戳还敢切 —— 那只能猜切口,会把字劈成半个")
    }

    /// 刀口在整行之前 / 之后 ⇒ 没得切。
    func testACutOutsideTheLineYieldsNothing() {
        XCTAssertNil(SpeakerCut.split(sample, atMs: 0), "刀口在行首,前半是空的")
        XCTAssertNil(SpeakerCut.split(sample, atMs: 99_999), "刀口在行尾之后,后半是空的")
    }

    /// 切出来的片段太短 ⇒ 不切。太短的片段认人本来就不可靠。
    func testAPieceShorterThanTheFloorIsNotCut() {
        // 第一个词只有 300ms,切在它后面会切出一个 300ms 的前半
        let l = line([(0, 300, "嗯"), (300, 4000, "那我这边没问题。")])
        XCTAssertNil(SpeakerCut.split(l, atMs: 300),
                     "切出了一个 300ms 的片段 —— 低于 \(SpeakerCut.minPieceMs)ms 的地板")
    }

    /// 🔴 地板本身要可证伪:跨过它,判断必须翻面。
    /// 少了这条,`minPieceMs` 改成任何值都不会有测试变红。
    func testTheFloorActuallySeparates() throws {
        let below = line([(0, SpeakerCut.minPieceMs - 100, "嗯"),
                          (SpeakerCut.minPieceMs - 100, 9000, "那我这边没问题。")])
        let above = line([(0, SpeakerCut.minPieceMs + 100, "嗯呢"),
                          (SpeakerCut.minPieceMs + 100, 9000, "那我这边没问题。")])
        XCTAssertNil(SpeakerCut.split(below, atMs: SpeakerCut.minPieceMs - 100), "地板以下该拒绝")
        XCTAssertNotNil(try SpeakerCut.split(above, atMs: SpeakerCut.minPieceMs + 100),
                        "地板以上该切得动")
    }

    /// 只有一个词的行:无论刀口在哪都切不出两半。
    func testASingleWordLineIsNeverCut() {
        let one = line([(0, 5000, "嗯")])
        for cut in [0, 1, 2500, 5000, 9999] {
            XCTAssertNil(SpeakerCut.split(one, atMs: cut), "刀口 \(cut) 把独词行切开了")
        }
    }
}

// MARK: - 切点探针

/// 探针这一半:**注入假嵌入器**,不碰 ONNX 就能把算法考透。
/// 生产传的是 `VoiceprintChain.embed`(同一条嵌入路径,不另写一份)。
final class SpeakerCutProbeTests: XCTestCase {

    private let rate = AudioImport.sampleRate

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(rate)))
    }

    /// 假嵌入器:按这一窗的**中点**落在 `changeAtSec` 之前还是之后,返回两个正交向量。
    /// 正交 ⇒ 余弦 0 ⇒ 分离度 1,稳稳过阈。
    private func twoSpeakers(changeAtSec: Double, samples: [Float])
        -> ([Float]) -> [Float] {
        { window in
            // 用窗的长度反推它在整段里的位置是做不到的,所以这里靠内容:
            // 造样本时把「谁在说」写进采样值本身(见下面 `voiced`)。
            let mean = window.reduce(0, +) / Float(max(window.count, 1))
            return mean < 0.5 ? [1, 0] : [0, 1]
        }
    }

    /// 造一段音频:前 `changeAtSec` 秒采样值为 0(A 说),之后为 1(B 说)。
    private func voiced(totalSec: Double, changeAtSec: Double) -> [Float] {
        let n = Int(totalSec * Double(rate))
        let k = Int(changeAtSec * Double(rate))
        return (0..<n).map { $0 < k ? 0 : 1 }
    }

    // MARK: - 找得到

    /// 6 秒的话,第 3 秒换人 ⇒ 切点应落在 3 秒附近(误差不超过一个步长)。
    func testItFindsTheChangePoint() throws {
        let s = voiced(totalSec: 6, changeAtSec: 3)
        let at = try XCTUnwrap(SpeakerCut.changePoint(in: s, embed: twoSpeakers(changeAtSec: 3, samples: s)))
        XCTAssertEqual(Double(at), 3000, accuracy: Double(SpeakerCut.stepMs),
                       "切点偏离真值超过一个步长")
    }

    // MARK: - 🔴 不该切的都不许切

    /// 全程一个人 ⇒ 左右永远一样 ⇒ 分离度 0 ⇒ **不切**。
    ///
    /// 这条比「找得到」更要紧:切坏一行干净话的代价,比漏切一行高得多。
    func testASingleSpeakerLineIsNeverCut() {
        let s = silence(seconds: 6)
        XCTAssertNil(SpeakerCut.changePoint(in: s, embed: { _ in [1, 0] }),
                     "全程同一个人却切了 —— 干净的话被切坏,比漏切贵得多")
    }

    /// 行太短(左右凑不出两个整窗)⇒ 不切,**不凑合用半个窗**。
    func testATooShortLineIsNotProbed() {
        for sec in [0.5, 1.5, 2.9] {                     // 都短于 2×1.5 秒
            XCTAssertNil(SpeakerCut.changePoint(in: silence(seconds: sec), embed: { _ in [1, 0] }),
                         "\(sec) 秒的行被探了 —— 窗都凑不齐,比出来的东西没有意义")
        }
    }

    /// 🔴 判据本身要可证伪:跨过它,判断必须翻面。
    /// 少了这条,`separationMargin` 改成任何值都不会有测试变红。
    func testTheSeparationMarginActuallySeparates() throws {
        let s = voiced(totalSec: 6, changeAtSec: 3)
        // 造一对余弦恰好在判据两侧的向量:分离度 = 1 − cos。
        // 这一行的基线是 0(换人点之外左右同源),所以「峰减基线」就等于这个分离度。
        func pair(separation: Float) -> ([Float]) -> [Float] {
            let cos = 1 - separation
            let b: [Float] = [cos, (1 - cos * cos).squareRoot()]   // 与 [1,0] 的余弦正好是 cos
            return { window in
                let mean = window.reduce(0, +) / Float(max(window.count, 1))
                return mean < 0.5 ? [1, 0] : b
            }
        }
        XCTAssertNil(SpeakerCut.changePoint(
            in: s, embed: pair(separation: SpeakerCut.separationMargin - 0.01)),
            "差距在判据以下还是切了")
        XCTAssertNotNil(try SpeakerCut.changePoint(
            in: s, embed: pair(separation: SpeakerCut.separationMargin + 0.01)),
            "差距在判据以上却没切")
    }

    /// 🔴🔴 **这条是 2026-08-18 换判据的理由本身:整行分离度都很高,也不许切。**
    ///
    /// 造一行「左右**处处**不像」的音频 —— 每个候选点的分离度都是 0.74,
    /// 远高于我原先那个绝对阈值 0.5。旧判据会**当场切下去**,而这一行里
    /// 根本没有换人点,高分是这一行整体的偏移(嗓子/麦/环境)造成的。
    ///
    /// 《模型选型与工作点定案》§五量到的正是这个:同录音**同人** 3–8 秒碎片
    /// 余弦中位数 0.354(即 `1 − cos ≈ 0.646`)、不同人 0.256(≈ 0.744)——
    /// **两者都在 0.5 以上**,只差 0.098 且重叠极深。
    /// 拿绝对分当闸的后果不是「切错一部分」,是**几乎每一行都被切开**。
    ///
    /// 没有这一条测试,把 `separationMargin` 换回绝对比较不会有任何东西变红。
    func testAUniformlyHighButFlatLineIsNeverCut() throws {
        let s = silence(seconds: 6)
        var flip = false
        // 每次嵌入交替给两个夹角固定的向量 ⇒ 相邻窗永远「不像」,而曲线是平的
        let far: [Float] = [0.256, (1 - 0.256 * 0.256).squareRoot()]
        XCTAssertNil(try SpeakerCut.changePoint(in: s) { _ in
            flip.toggle(); return flip ? [1, 0] : far
        }, "整行分离度都高(0.744,远超旧的绝对阈值 0.5)却是平的 —— "
         + "这一行没有换人点,切下去就是把干净的话拆开。绝对阈值正是栽在这里")
    }

    /// 嵌入器抛出 ⇒ **抛上去**,不吞。
    ///
    /// 与 `VoiceprintChain` 那两处同一条纪律:模型坏了是系统性失败,
    /// 吞掉的形态是「所有行都不切」—— 而那和「本来就没有需要切的行」一模一样。
    func testAnEmbedderFailurePropagates() {
        struct Boom: Error {}
        XCTAssertThrowsError(
            try SpeakerCut.changePoint(in: silence(seconds: 6), embed: { _ in throw Boom() }),
            "嵌入器抛了却被吞掉 —— 模型坏了会表现成「没有需要切的行」")
    }

    /// 窗是重叠的,所以一段只该嵌一次 —— 6 秒的行约 14 次前向,不是 26 次。
    func testOverlappingWindowsAreEmbeddedOnce() throws {
        var calls = 0
        _ = try SpeakerCut.changePoint(in: silence(seconds: 6)) { _ in calls += 1; return [1, 0] }
        // 6 秒 / 窗 1.5 秒 / 步 0.25 秒 ⇒ 13 个候选点,各要左右两窗 = 26 次;
        // 而窗起点去重之后是 {0, 0.25, …, 4.5} = **19 个**。
        // (第一版我把这个数算成 16,**是我算错了,不是缓存没生效**。)
        XCTAssertLessThanOrEqual(calls, 19, "重叠窗没有复用,白跑了 \(calls) 次前向")
        XCTAssertLessThan(calls, 26, "一次都没复用 —— 缓存等于没有")
        XCTAssertGreaterThan(calls, 1, "一次都没嵌 —— 这条用例什么都没验")
    }
}
