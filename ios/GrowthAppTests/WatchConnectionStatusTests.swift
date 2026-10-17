import XCTest
import WatchConnectivity
@testable import GrowthApp

final class WatchConnectionStatusTests: XCTestCase {
    func testUnknownActivationNeverPretendsUnpaired() {
        XCTAssertEqual(WatchConnectionStatus(supported: true, activation: .notActivated, paired: false, installed: false, reachable: false), .connecting)
        XCTAssertEqual(WatchConnectionStatus(supported: true, activation: .inactive, paired: true, installed: true, reachable: true), .connecting)
    }
    func testPairingAndInstallationAreDistinct() {
        XCTAssertEqual(WatchConnectionStatus(supported: true, activation: .activated, paired: false, installed: false, reachable: false), .unpaired)
        XCTAssertEqual(WatchConnectionStatus(supported: true, activation: .activated, paired: true, installed: false, reachable: false), .appMissing)
    }
    func testReachabilityDoesNotClaimRecordingOrBlockBackgroundTransfer() {
        let waiting = WatchConnectionStatus(supported: true, activation: .activated, paired: true, installed: true, reachable: false)
        XCTAssertEqual(waiting, .waiting)
        XCTAssertTrue(waiting.detail.contains("后台同步"))
        XCTAssertTrue(waiting.detail.contains("不表示录音停止"))
        XCTAssertEqual(WatchConnectionStatus(supported: true, activation: .activated, paired: true, installed: true, reachable: true), .reachable)
        XCTAssertTrue(WatchConnectionStatus.reachable.detail.contains("以手表为准"))
    }
    func testUnsupportedAndActivationFailureAreVisible() {
        XCTAssertEqual(WatchConnectionStatus(supported: false, activation: .notActivated, paired: false, installed: false, reachable: false), .unsupported)
        XCTAssertEqual(WatchConnectionStatus(supported: true, activation: .notActivated, paired: true, installed: true, reachable: false, error: "失败原因"), .failed("失败原因"))
    }
}
