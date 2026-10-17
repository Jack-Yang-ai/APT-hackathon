import XCTest
@testable import GrowthApp

/// 忘了按结束时自己收尾(M1-16d)。
///
/// 🔴 **两种错法的代价差着量级,而这组测试守的是便宜那一边。**
/// 多录几小时只是费空间;提前收尾会把一场真的三小时会议劈成两半,**不可逆**。
/// 所以凡是拿不准的情况,一律不收尾。
final class AutoStopPolicyTests: XCTestCase {

    /// 静音够久就收尾。
    func testLongSilenceStops() {
        XCTAssertTrue(AutoStopPolicy.shouldStop(silentForMs: AutoStopPolicy.silenceMs))
        XCTAssertTrue(AutoStopPolicy.shouldStop(silentForMs: AutoStopPolicy.silenceMs + 1))
    }

    /// 差一毫秒都不收 —— 边界上宁可多录。
    func testJustUnderThresholdKeepsRecording() {
        XCTAssertFalse(AutoStopPolicy.shouldStop(silentForMs: AutoStopPolicy.silenceMs - 1))
    }

    /// 🔴 **此刻有声 → 不收尾。** 这是「连续」的全部含义:
    /// 会议中间的沉默、有人咳嗽一声,都会把计时清零。
    func testAnySoundResetsTheCountdown() {
        XCTAssertFalse(AutoStopPolicy.shouldStop(silentForMs: nil))
    }

    /// 探针答不上来(`NeverSilent`、测试桩)时**永不收尾** ——
    /// 默认实现返回 nil,而那是安全的一边。
    func testAProbeThatCannotAnswerNeverStopsTheSession() {
        XCTAssertNil(NeverSilent().silentForMs)
        XCTAssertFalse(AutoStopPolicy.shouldStop(silentForMs: NeverSilent().silentForMs))
    }

    /// 阈值照 PRD §4.1.5 的「2 小时 (初)」。
    /// 钉住它是因为这个数会被回填,而改它的人要同时改 PRD ——
    /// 不钉的话两边悄悄分叉,谁都说不出哪个算数。
    func testThresholdMatchesThePRD() {
        XCTAssertEqual(AutoStopPolicy.silenceMs, 2 * 60 * 60 * 1000)
    }

    // MARK: - 状态机

    /// 自动收尾与手动结束**落一样的状态和副作用** —— 场次就是结束了。
    func testAutoStopEndsTheSessionLikeAManualStop() {
        let auto = RecordingStateMachine.next(state: .recording, event: .autoStopped)
        let manual = RecordingStateMachine.next(state: .recording, event: .userStop)
        XCTAssertEqual(auto.state, .stopped)
        XCTAssertEqual(auto.effects, manual.effects,
                       "自动收尾漏了某个副作用 —— 最后那一块会丢")
        XCTAssertTrue(auto.effects.contains(.mark(.sessionEnded)),
                      "账本上没有 sessionEnded ⇒ 这一场永远是「录音中」,永不入队")
    }

    /// 暂停期间引擎是停的,音频线程不会来问 —— 到不了,但也不能崩。
    func testAutoStopDoesNothingWhilePaused() {
        for state in [RecordingState.pausedByUser, .pausedBySystem] {
            let t = RecordingStateMachine.next(state: state, event: .autoStopped)
            XCTAssertEqual(t.state, state)
            XCTAssertTrue(t.effects.isEmpty)
        }
    }

    // MARK: - 计时器只有一个

    /// `silentForMs` 与 `isSilentNow()` **共用同一个计时**。
    /// 两套的话会出现「切块说有声、自动结束说静音」,而没人查得出来。
    func testTheGateHasOneSilenceClock() {
        let gate = EnergyGate()
        gate._resetForTesting(noiseFloorDB: -60)
        XCTAssertNil(gate.silentForMs, "刚重置就说自己静音了")

        // 喂一段远低于「底噪 + 12dB」的静音
        let quiet = [Float](repeating: 1e-6, count: 512)
        quiet.withUnsafeBufferPointer { gate.feed($0.baseAddress!, count: $0.count) }
        XCTAssertNotNil(gate.silentForMs, "静音了却答不上来静了多久")

        // 再喂一段响的 —— 两个说法要同时翻过来
        let loud = [Float](repeating: 0.5, count: 512)
        loud.withUnsafeBufferPointer { gate.feed($0.baseAddress!, count: $0.count) }
        XCTAssertNil(gate.silentForMs)
        XCTAssertFalse(gate.isSilentNow())
    }
}
