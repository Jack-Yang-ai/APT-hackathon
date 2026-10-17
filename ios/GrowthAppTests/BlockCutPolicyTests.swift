import XCTest
@testable import GrowthApp

/// 分段切点策略(§3.1.6「切点对齐静音」)。
///
/// 端侧 VAD 是 U6b 的活(本任务禁区),所以这里注入假探针,把两条分支都走一遍:
/// 窗口内遇静音 → 软切;走到右端还没静音 → 硬切并标 `hard_cut=true`。
final class BlockCutPolicyTests: XCTestCase {

    private struct AlwaysSilent: SilenceProbe { func isSilentNow() -> Bool { true } }

    private let target = BlockCutPolicy.targetMs
    private let window = BlockCutPolicy.windowMs

    func testDoesNotCutBeforeWindowEvenInSilence() {
        // 一静音就切的话块会碎成一堆,送检次数跟着涨。
        XCTAssertNil(BlockCutPolicy.shouldCut(elapsedMs: target - window - 1,
                                              probe: AlwaysSilent()))
    }

    func testCutsAtSilenceInsideWindow() {
        let cut = BlockCutPolicy.shouldCut(elapsedMs: target - window, probe: AlwaysSilent())
        XCTAssertEqual(cut, BlockCutPolicy.Cut(hardCut: false))
    }

    func testKeepsRecordingInsideWindowWhenNotSilent() {
        XCTAssertNil(BlockCutPolicy.shouldCut(elapsedMs: target, probe: NeverSilent()))
    }

    func testHardCutsAtWindowRightEdge() {
        // 块无限长会让「断电最多丢一段」失效 —— 右端无论如何都要切。
        let cut = BlockCutPolicy.shouldCut(elapsedMs: target + window, probe: NeverSilent())
        XCTAssertEqual(cut, BlockCutPolicy.Cut(hardCut: true))
    }

    func testSilenceAtRightEdgeIsNotMarkedHardCut() {
        // 恰好在右端遇到静音时,切点**确实**对齐了静音。标成 hard_cut 是往
        // 如实的元数据里掺假话,下游会以为这里有截断句而其实没有。
        let cut = BlockCutPolicy.shouldCut(elapsedMs: target + window, probe: AlwaysSilent())
        XCTAssertEqual(cut, BlockCutPolicy.Cut(hardCut: false))
    }

    func testDefaultProbeNeverFindsSilenceSoEveryCutIsMarkedHard() {
        // U6b 之前的如实状态:每块都硬切,每块元数据都带 hard_cut=true。
        // 这条测试将来会随 U6b 一起改 —— 改动它就是在承认端侧 VAD 接进来了。
        XCTAssertFalse(NeverSilent().isSilentNow())
        XCTAssertEqual(BlockCutPolicy.shouldCut(elapsedMs: target + window, probe: NeverSilent()),
                       BlockCutPolicy.Cut(hardCut: true))
    }
}
