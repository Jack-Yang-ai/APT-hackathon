import XCTest
@testable import GrowthApp

final class SpeechTrimTests: XCTestCase {

    private let perFrame = Double(SileroVAD.frameSamples) / 16_000
    private func frames(seconds: Double, speech: Bool) -> [Float] {
        [Float](repeating: speech ? 0.9 : 0.01, count: Int(seconds / perFrame))
    }


    func testAllSpeechKeepsEverythingAndDoesNotFallBack() {
        let p = SpeechTrim.plan(speechProbabilities: frames(seconds: 300, speech: true),
                                durationMs: 300_000)
        XCTAssertFalse(p.fellBack, "全是人声却触发了保底闸")
        XCTAssertEqual(p.intervals.count, 1)
        XCTAssertEqual(p.ratio, 1, accuracy: 0.02)
    }

    func testAGapShorterThanThirtySecondsDoesNotSplit() {
        let f = frames(seconds: 20, speech: true)
              + frames(seconds: 25, speech: false)
              + frames(seconds: 20, speech: true)
        let p = SpeechTrim.plan(speechProbabilities: f, durationMs: 65_000)
        XCTAssertEqual(p.intervals.count, 1, "25 秒的间隔小于 30,不该断开:\(p.intervals)")
    }

    func testAGapLongerThanThirtySecondsSplits() {
        let f = frames(seconds: 20, speech: true)
              + frames(seconds: 60, speech: false)
              + frames(seconds: 20, speech: true)
        let p = SpeechTrim.plan(speechProbabilities: f, durationMs: 100_000)
        XCTAssertEqual(p.intervals.count, 2, "60 秒的间隔该断开:\(p.intervals)")
        XCTAssertLessThan(p.ratio, 0.9, "中间那 60 秒静音该被裁掉")
    }

    func testPaddingIsTwoSecondsAndClampedToTheBlock() {
        let f = frames(seconds: 10, speech: false)
              + frames(seconds: 10, speech: true)
              + frames(seconds: 40, speech: false)
        let p = SpeechTrim.plan(speechProbabilities: f, durationMs: 60_000)
        let i = try! XCTUnwrap(p.intervals.first)
        XCTAssertEqual(Double(i.startMs) / 1000, 8, accuracy: 0.5, "起点该前移 2 秒")
        XCTAssertEqual(Double(i.endMs) / 1000, 22, accuracy: 0.5, "终点该后移 2 秒")

        let head = SpeechTrim.plan(
            speechProbabilities: frames(seconds: 5, speech: true) + frames(seconds: 55, speech: false),
            durationMs: 60_000)
        XCTAssertEqual(head.intervals.first?.startMs, 0, "垫到块外去了")
    }

    func testOverlappingIntervalsAreMergedSoRestoreStaysMonotonic() {
        let f = frames(seconds: 10, speech: true)
              + frames(seconds: 3, speech: false)
              + frames(seconds: 10, speech: true)
              + frames(seconds: 40, speech: false)
        let p = SpeechTrim.plan(speechProbabilities: f, durationMs: 65_000)
        for (a, b) in zip(p.intervals, p.intervals.dropFirst()) {
            XCTAssertLessThanOrEqual(a.endMs, b.startMs, "保留区间重叠了:\(p.intervals)")
        }
        var last = -1
        for ms in stride(from: 0, to: p.keptMs, by: 500) {
            let restored = try! TranscriptFreeze.restoreToBlockTime(
                trimmedMs: ms, keptIntervals: p.intervals, blockSeq: 0)
            XCTAssertGreaterThan(restored, last, "还原不单调 —— 区间表有重叠")
            last = restored
        }
    }


    func testTheSafetyGateFiresWhenAlmostNothingIsKept() {
        let f = frames(seconds: 3, speech: true) + frames(seconds: 445, speech: false)
        let p = SpeechTrim.plan(speechProbabilities: f, durationMs: 448_000)
        XCTAssertTrue(p.fellBack, "保留率这么低,保底闸没响 —— 这一整块会被裁没")
        XCTAssertEqual(p.intervals, [KeptInterval(startMs: 0, endMs: 448_000)],
                       "闸响了就必须整块送")
    }

    func testTheGateReportsTheRealRatioNotOneHundredPercent() {
        let f = frames(seconds: 3, speech: true) + frames(seconds: 445, speech: false)
        let p = SpeechTrim.plan(speechProbabilities: f, durationMs: 448_000)
        XCTAssertLessThan(p.ratio, SpeechTrim.minRetentionRatio,
                          "闸响了却报了个高保留率:\(p.ratio)")
    }

    func testCompletelySilentBlockIsSentWholeNotEmpty() {
        let p = SpeechTrim.plan(speechProbabilities: frames(seconds: 300, speech: false),
                                durationMs: 300_000)
        XCTAssertTrue(p.fellBack)
        XCTAssertEqual(p.keptMs, 300_000, "全静音块被裁成了空 —— 转写会返回空而不报错")
        XCTAssertEqual(p.ratio, 0, accuracy: 0.001)
    }

    func testZeroDurationDoesNotDivideByZero() {
        let p = SpeechTrim.plan(speechProbabilities: [], durationMs: 0)
        XCTAssertTrue(p.ratio.isFinite, "分母是 0 时算出了 \(p.ratio)")
    }


    func testEncodeDecodeRoundTrips() {
        let intervals = [KeptInterval(startMs: 0, endMs: 12_345),
                         KeptInterval(startMs: 70_000, endMs: 80_500)]
        XCTAssertEqual(SpeechTrim.decode(SpeechTrim.encode(intervals)), intervals)
    }

    func testNilIsNotTheSameAsEmpty() {
        XCTAssertNil(SpeechTrim.decode(nil))
        XCTAssertNil(SpeechTrim.decode("不是 JSON"))
        XCTAssertEqual(SpeechTrim.decode("[]"), [])
    }


    private func energy(_ dbfs: Double, count: Int) -> [Double] {
        [Double](repeating: pow(10, dbfs / 10), count: count)
    }

    func testAQuietBlockIsTrimmedNotSentWhole() {
        let f = frames(seconds: 3, speech: true) + frames(seconds: 297, speech: false)
        let p = SpeechTrim.plan(speechProbabilities: f,
                                frameEnergies: energy(-45, count: f.count),
                                durationMs: 300_000)
        XCTAssertFalse(p.fellBack,
                       "安静块被整块送了 —— 全天 41% 的块都是这一档,省钱全在它们身上")
        XCTAssertLessThan(p.keptMs, 30_000, "该裁的没裁掉")
    }

    func testALoudBlockWithNoDetectedSpeechIsSentWhole() {
        let f = frames(seconds: 3, speech: true) + frames(seconds: 297, speech: false)
        let p = SpeechTrim.plan(speechProbabilities: f,
                                frameEnergies: energy(-22, count: f.count),
                                durationMs: 300_000)
        XCTAssertTrue(p.fellBack,
                      "远场/扩音那一档没被拦住 —— 这一块会被裁成空白,而转写照样返回")
        XCTAssertEqual(p.intervals, [KeptInterval(startMs: 0, endMs: 300_000)])
    }

    func testTheEnergyLineActuallySeparates() {
        let f = frames(seconds: 3, speech: true) + frames(seconds: 297, speech: false)
        let below = SpeechTrim.plan(speechProbabilities: f,
                                    frameEnergies: energy(SpeechTrim.suspiciousEnergyDBFS - 3,
                                                          count: f.count),
                                    durationMs: 300_000)
        let above = SpeechTrim.plan(speechProbabilities: f,
                                    frameEnergies: energy(SpeechTrim.suspiciousEnergyDBFS + 3,
                                                          count: f.count),
                                    durationMs: 300_000)
        XCTAssertFalse(below.fellBack, "线以下该照常裁")
        XCTAssertTrue(above.fellBack, "线以上该整块送")
    }

    func testAMostlySilentBlockWithOneLoudBurstIsStillSuspicious() {
        let f = frames(seconds: 3, speech: true) + frames(seconds: 297, speech: false)
        var e = energy(-60, count: f.count)
        for i in (f.count - f.count * 11 / 100)..<f.count { e[i] = pow(10, -35 / 10.0) }
        let mean = 10 * log10(e.reduce(0, +) / Double(e.count))
        XCTAssertLessThan(mean, SpeechTrim.suspiciousEnergyDBFS,
                          "夹具没造对:均值该落在线以下,才考得住 p90 这个选择")
        let p = SpeechTrim.plan(speechProbabilities: f, frameEnergies: e, durationMs: 300_000)
        XCTAssertTrue(p.fellBack,
                      "只有一小段远场人声的块被判成「安静」裁掉了 —— 用均值就会这样")
    }

    func testMissingEnergyFailsTowardSendingTheWholeBlock() {
        let f = frames(seconds: 3, speech: true) + frames(seconds: 297, speech: false)
        let p = SpeechTrim.plan(speechProbabilities: f, durationMs: 300_000)
        XCTAssertTrue(p.fellBack, "没有能量数据时该保守整块送")
    }
}
