import XCTest
@testable import GrowthApp

/// 音量门。它决定 5 分钟块的切点落在哪一秒。
///
/// 在它之前,探针是 `NeverSilent` —— **每一块都硬切**。
/// 2026-08-13 真机账本上四个块的 `hardCut` 全是 true,就是这个的实测形态。
/// 硬切意味着每个 5 分钟边界都可能把一句话拦腰砍断,而下游转写就在这些边界上。
final class EnergyGateTests: XCTestCase {

    /// 造一段给定音量的音频。`dB` 是相对满刻度。
    private func tone(_ db: Float, samples n: Int = 1600) -> [Float] {
        let amp = pow(10, db / 20)
        return (0..<n).map { _ in Float.random(in: -amp...amp) }
    }

    private func feed(_ gate: EnergyGate, _ buf: [Float]) {
        buf.withUnsafeBufferPointer { gate.feed($0.baseAddress!, count: $0.count) }
    }

    /// 明显高于底噪 = 有人在说,而且不该报静音。
    func testLoudAudioIsNotSilence() {
        let gate = EnergyGate()
        gate._resetForTesting(noiseFloorDB: -60)
        feed(gate, tone(-20))
        XCTAssertTrue(gate.hasSpeechNow, "比底噪高 40 dB 却判成没人说话")
        XCTAssertFalse(gate.isSilentNow())
    }

    /// 贴着底噪 = 静音,但**要持续够久才算**。
    ///
    /// 不加持续时长的话,句子之间的换气(200–400ms)会被当成切点 ——
    /// 那正好把一句话从中间劈开,与硬切没有区别。
    func testSilenceMustBeSustainedBeforeItCounts() {
        let gate = EnergyGate()
        gate._resetForTesting(noiseFloorDB: -60)
        feed(gate, tone(-62))
        XCTAssertFalse(gate.isSilentNow(), "刚安静一瞬就报静音 —— 换气会被当成切点")
        XCTAssertFalse(gate.hasSpeechNow)

        Thread.sleep(forTimeInterval: Double(EnergyGate.sustainedSilenceMs) / 1000 + 0.05)
        feed(gate, tone(-62))
        XCTAssertTrue(gate.isSilentNow(), "持续安静够久了却还不报静音 —— 会退回每块硬切")
    }

    /// 一说话就立刻清掉静音计时,不能残留。
    func testSpeechImmediatelyCancelsSilence() {
        let gate = EnergyGate()
        gate._resetForTesting(noiseFloorDB: -60)
        feed(gate, tone(-62))
        Thread.sleep(forTimeInterval: Double(EnergyGate.sustainedSilenceMs) / 1000 + 0.05)
        feed(gate, tone(-62))
        XCTAssertTrue(gate.isSilentNow())

        feed(gate, tone(-20))
        XCTAssertFalse(gate.isSilentNow(), "有人开口了还报静音 —— 会在说话中间切块")
    }

    /// ⚠️ **底噪只在静音期更新。**
    /// 用说话期的能量更新地板,地板会被自己的声音顶上去 —— 越说越判不出静音,
    /// 最后退化成 `NeverSilent`,而且没有任何东西会报错。
    func testNoiseFloorDoesNotChaseSpeech() {
        let gate = EnergyGate()
        gate._resetForTesting(noiseFloorDB: -60)
        for _ in 0..<200 { feed(gate, tone(-20)) }     // 一直大声说
        feed(gate, tone(-58))                          // 停下来,回到接近底噪
        Thread.sleep(forTimeInterval: Double(EnergyGate.sustainedSilenceMs) / 1000 + 0.05)
        feed(gate, tone(-58))
        XCTAssertTrue(gate.isSilentNow(),
                      "说了很久之后判不出静音 —— 底噪被自己的声音顶上去了")
    }

    /// 环境突然变安静时,地板要**快速**跟下来;否则地板卡在高位,之后全判成静音。
    func testFloorFallsQuicklyWhenTheRoomGetsQuiet() {
        let gate = EnergyGate()
        gate._resetForTesting(noiseFloorDB: -20)       // 之前很吵
        for _ in 0..<10 { feed(gate, tone(-70)) }      // 一下子安静了
        Thread.sleep(forTimeInterval: Double(EnergyGate.sustainedSilenceMs) / 1000 + 0.05)
        feed(gate, tone(-70))
        XCTAssertTrue(gate.isSilentNow())
        // 地板跟下来之后,正常说话仍要能判成有声
        feed(gate, tone(-45))
        XCTAssertTrue(gate.hasSpeechNow, "地板没跟下来,正常说话被当成了静音")
    }

    /// 接进切点策略:有静音就软切,`hardCut=false`。
    func testCutPolicyTakesTheSoftCutWhenTheGateReportsSilence() {
        let gate = EnergyGate()
        gate._resetForTesting(noiseFloorDB: -60)
        feed(gate, tone(-62))
        Thread.sleep(forTimeInterval: Double(EnergyGate.sustainedSilenceMs) / 1000 + 0.05)
        feed(gate, tone(-62))

        let cut = BlockCutPolicy.shouldCut(elapsedMs: BlockCutPolicy.earliestMs + 1, probe: gate)
        XCTAssertEqual(cut?.hardCut, false, "窗口内遇静音却没软切")
    }
}
