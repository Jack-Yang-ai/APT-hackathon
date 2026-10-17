import XCTest
@testable import GrowthApp

/// 取段这一步的人声门(M1-9 的 ①)。
///
/// 🔴 **它挡的是「根本不是人声」,不挡「别人的人声」。**
/// 这条界线要在测试里写死 —— 否则下一个人会以为加了这道门就不会认错人了,
/// 而认错人是这条链最贵的失败,靠的是阈值 + 投票,不是这道门。
final class SpeechGateTests: XCTestCase {

    private let yes = SileroVAD.speechThreshold + 0.2
    private let no  = SileroVAD.speechThreshold - 0.2

    func testMostlySpeechPasses() {
        XCTAssertTrue(SpeechGate.passes(Array(repeating: yes, count: 10)))
        // 8/10 = 0.8 ≥ 0.6
        XCTAssertTrue(SpeechGate.passes(Array(repeating: yes, count: 8)
                                        + Array(repeating: no, count: 2)))
    }

    /// ASR 把空调声、关门声聚成一个「说话人」—— 这类段要在取段这步出局。
    /// 不挡的话它们照样进投票、照样占「至少 2 段」的名额,
    /// 把本来能判的簇拖成拒识。
    func testMostlyNoiseIsRejected() {
        XCTAssertFalse(SpeechGate.passes(Array(repeating: no, count: 10)))
        // 5/10 = 0.5 < 0.6
        XCTAssertFalse(SpeechGate.passes(Array(repeating: yes, count: 5)
                                          + Array(repeating: no, count: 5)))
    }

    /// 🔴 **一帧都没量到时不通过。**
    /// 返回「通过」的话,解码失败会被当成「这段挺好」放行 ——
    /// 而那正是静默降级(§3.2):后面照样算嵌入、照样投票,只是喂进去的是空气。
    func testNoFramesMeansNoPass() {
        XCTAssertEqual(SpeechGate.speechRatio([]), 0)
        XCTAssertFalse(SpeechGate.passes([]))
    }

    /// 边界:正好等于阈值算过。宁可多放一段进去让投票去筛,
    /// 也不要在门这一步把一段真人声挡掉 —— 少一段就可能掉到「不够 2 段」。
    func testExactlyAtTheRatioPasses() {
        // 6/10 = 0.6
        XCTAssertTrue(SpeechGate.passes(Array(repeating: yes, count: 6)
                                        + Array(repeating: no, count: 4)))
    }

    /// 用的是 `SileroVAD` 的那个阈值,**不另立一个** ——
    /// 两个「多少算人声」的数迟早分叉,而分叉之后没人说得出哪个算数。
    func testItUsesTheVADsOwnSpeechThreshold() {
        XCTAssertEqual(SpeechGate.speechRatio([SileroVAD.speechThreshold]), 1)
        XCTAssertEqual(SpeechGate.speechRatio([SileroVAD.speechThreshold - 0.001]), 0)
    }
}

/// 切片与余弦 —— 编排层里仅有的两处算术。
final class VoiceprintChainMathTests: XCTestCase {

    /// 🔴 **越界返回 nil,不夹取。**
    /// 夹出来的段会短于 3 秒下限,而那一档的错误率是 3 秒的 7 倍 ——
    /// 而它不会报错:分数照样算得出来,只是错的。
    func testAnOutOfRangeCutRefusesInsteadOfClamping() {
        let pcm = [Float](repeating: 0, count: 16_000)   // 1 秒
        XCTAssertNil(VoiceprintChain.cut(pcm, startMs: 0, endMs: 2_000))
        XCTAssertNil(VoiceprintChain.cut(pcm, startMs: -100, endMs: 500))
        XCTAssertNil(VoiceprintChain.cut(pcm, startMs: 500, endMs: 500))
    }

    func testANormalCutTakesExactlyThatSpan() throws {
        let pcm = (0..<16_000).map { Float($0) }
        let slice = try XCTUnwrap(VoiceprintChain.cut(pcm, startMs: 250, endMs: 750))
        XCTAssertEqual(slice.count, 8_000)
        XCTAssertEqual(slice.first, 4_000)
    }

    /// 余弦要与量纲无关 —— 底库那侧是别的运行时算出来的,
    /// 拿没归一化的点积去比会随音量漂。
    func testCosineIsScaleInvariant() {
        let a: [Float] = [1, 2, 3], b: [Float] = [2, 4, 6]
        XCTAssertEqual(VoiceprintChain.cosine(a, b), 1, accuracy: 1e-5)
        XCTAssertEqual(VoiceprintChain.cosine(a, a.map { $0 * 100 }), 1, accuracy: 1e-5)
    }

    /// 维度对不上或全零时返回 -1(最低分),**不返回 0** ——
    /// 0 在余弦里是「正交」,是个正常取值;而这里发生的是「算不了」。
    func testAnUncomparablePairScoresLowestNotNeutral() {
        XCTAssertEqual(VoiceprintChain.cosine([1, 2], [1, 2, 3]), -1)
        XCTAssertEqual(VoiceprintChain.cosine([0, 0], [1, 2]), -1)
        XCTAssertEqual(VoiceprintChain.cosine([], []), -1)
    }
}
