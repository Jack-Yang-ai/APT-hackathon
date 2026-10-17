import XCTest
@testable import GrowthApp

/// `Info.plist` 与代码之间那几处**必须逐字对上**的约定。
///
/// ## 为什么单开一组
///
/// `AppDelegate` 自己就写着这句:
///
/// > 这个字符串必须同时出现在 `Info.plist` 的 `BGTaskSchedulerPermittedIdentifiers` 里。
/// > **对不上不会报错**,只是 `register` 返回 false、任务永远不跑 —— 一种完全静默的失效。
///
/// 它把危害说清楚了,却**没有任何东西守着它** —— 而「一件事在两处各存一份、
/// 只有一份被维护」是这个仓 2026-08 反复出现的形态(复核六轮抓到八次)。
/// 运行时那条 `ProcessingEvents.record("BGTask 注册失败")` 只在**真机跑过之后**
/// 才看得见,而改错这个字符串的人当场就该被拦住。
final class InfoPlistContractTests: XCTestCase {

    /// 读 `Info.plist`。**从源码树读,不从 bundle 读** ——
    /// 测试 target 没有宿主 App(见 M1-13c),`Bundle.main` 拿到的不是 App 那份。
    private func plist(app: String = "GrowthApp") throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("\(app)/Info.plist")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            "Info.plist 解析不出来")
    }

    /// 🔴 **后台任务 id 两处必须逐字一致。**
    ///
    /// 对不上的表现:`register` 返回 false ⇒ 后台永远不被叫醒 ⇒
    /// 用户点完结束、锁屏、第二天打开发现纪要还没出 —— 而**没有任何报错**,
    /// 因为「后台没跑」和「后台跑了但没活干」在界面上一模一样。
    func testTheBackgroundTaskIDMatchesTheOneInInfoPlist() throws {
        let ids = try XCTUnwrap(
            plist()["BGTaskSchedulerPermittedIdentifiers"] as? [String],
            "Info.plist 里没有 BGTaskSchedulerPermittedIdentifiers —— BGTask 注册会被系统拒")
        XCTAssertTrue(ids.contains(AppDelegate.processingTaskID),
                      "代码里注册的是 \(AppDelegate.processingTaskID),而 plist 里只有 \(ids) —— "
                      + "register 会返回 false,后台永远不跑,而且不报错")
    }

    /// 🔴 **两个后台模式缺一不可,而缺了都不报错。**
    ///
    /// · `audio` 用于原话试听;本版采集在Watch,手机不请求麦克风。
    /// · `processing` 没了 ⇒ `BGProcessingTask` 提交时抛,后台那条腿整个消失
    ///   (前台那条还在,所以打开 App 又会开始处理 —— 更难发现)。
    func testTheBackgroundModesTheAppActuallyNeedsAreDeclared() throws {
        let modes = try XCTUnwrap(plist()["UIBackgroundModes"] as? [String],
                                  "Info.plist 里没有 UIBackgroundModes")
        XCTAssertTrue(modes.contains("audio"), "少了 audio —— 原话试听不能在后台继续")
        XCTAssertTrue(modes.contains("processing"), "少了 processing —— BGTask 提交会抛")
    }

    /// 手机不采集;Watch必须声明麦克风与后台录音,才能锁屏持续采集。
    func testOnlyWatchDeclaresMicrophoneCapture() throws {
        XCTAssertNil(try plist()["NSMicrophoneUsageDescription"])
        let watch = try plist(app: "GrowthWatch")
        let why = try XCTUnwrap(watch["NSMicrophoneUsageDescription"] as? String)
        XCTAssertGreaterThan(why.count, 8)
        XCTAssertTrue(why.contains("手表"))
        XCTAssertTrue((watch["UIBackgroundModes"] as? [String] ?? []).contains("audio"))
    }
}
