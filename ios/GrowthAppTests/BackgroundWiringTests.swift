import XCTest
import GRDB
@testable import GrowthApp

/// 真后台的接线(M1-4c)。
///
/// 打的是**几处「对不上也不报错」的接缝**。它们的共同点是:错了以后
/// 后台永远不跑,而界面上和「后台跑了但没活干」一模一样 —— 靠眼睛发现不了。
final class BackgroundWiringTests: XCTestCase {

    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
    }
    override func tearDownWithError() throws { dbQueue = nil }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - 🔴 声明与代码必须是同一个字符串

    /// `BGTaskScheduler.register` 的标识符必须出现在 `Info.plist` 的
    /// `BGTaskSchedulerPermittedIdentifiers` 里。**对不上不会崩、不会报错** ——
    /// register 返回 false,后台从此永远不跑。
    ///
    /// 这里查的是 `project.yml`(Info.plist 由它生成,且 plist 本身不进版本库)。
    func testProcessingTaskIDIsDeclaredInProjectYML() throws {
        let yml = try String(contentsOf: Self.repoRoot.appendingPathComponent("ios/project.yml"),
                             encoding: .utf8)
        XCTAssertTrue(yml.contains("BGTaskSchedulerPermittedIdentifiers"),
                      "project.yml 里没有 BGTaskSchedulerPermittedIdentifiers —— BGTask 注册会失败")
        XCTAssertTrue(yml.contains(AppDelegate.processingTaskID),
                      "代码里用的是 \(AppDelegate.processingTaskID),而 project.yml 里没有这个串")
    }

    /// 没有 `processing` 这个后台模式,`BGProcessingTask` 根本不会被调度。
    func testProcessingBackgroundModeIsDeclared() throws {
        let yml = try String(contentsOf: Self.repoRoot.appendingPathComponent("ios/project.yml"),
                             encoding: .utf8)
        guard let modes = yml.range(of: "UIBackgroundModes:") else {
            return XCTFail("project.yml 里没有 UIBackgroundModes")
        }
        let tail = yml[modes.upperBound...].prefix(300)
        XCTAssertTrue(tail.contains("- audio"), "原话试听的后台播放要 audio")
        XCTAssertTrue(tail.contains("- processing"), "后台续跑要 processing")
    }

    // MARK: - 事件流水:验收仪器本身要好用

    func testEventsRecordTriggerAndReadBackNewestFirst() throws {
        let t = Date(timeIntervalSince1970: 1_786_000_000)
        ProcessingEvents.record(trigger: .foreground, outcome: "一", at: t, in: dbQueue)
        ProcessingEvents.record(trigger: .background, outcome: "二",
                                at: t.addingTimeInterval(60), in: dbQueue)
        ProcessingEvents.record(trigger: .transferCallback, outcome: "三",
                                at: t.addingTimeInterval(120), in: dbQueue)

        let recent = try ProcessingEvents.recent(in: dbQueue)
        XCTAssertEqual(recent.map(\.outcome), ["三", "二", "一"], "最近的要在最前面")
        // ⚠️ **触发源是这套仪器的全部意义。** 没有它,「出稿了」分不清是后台
        // 干完的还是刚打开 App 才干的 —— 而那正是要验的东西。
        XCTAssertEqual(recent.map(\.trigger), ["传输回调", "后台唤醒", "前台"])
        XCTAssertEqual(try ProcessingEvents.latest(in: dbQueue)?.outcome, "三")
    }

    func testEventsAreCappedSoTheyDoNotOutgrowTheContent() throws {
        for i in 0..<(ProcessingEvents.keep + 30) {
            ProcessingEvents.record(trigger: .foreground, outcome: "第 \(i) 条", in: dbQueue)
        }
        let count = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM processing_events")
        }
        XCTAssertEqual(count, ProcessingEvents.keep)
        // 砍掉的必须是**旧的**那一头
        XCTAssertEqual(try ProcessingEvents.latest(in: dbQueue)?.outcome,
                       "第 \(ProcessingEvents.keep + 29) 条")
    }

    /// 记不进去**不能拖垮处理** —— 仪器坏了不该让被测的东西停摆。
    func testRecordingAnEventNeverThrows() throws {
        let empty = try DatabaseQueue()          // 没建表
        ProcessingEvents.record(trigger: .foreground, outcome: "写不进去的", in: empty)
    }

    // MARK: - 设置页显示的时间

    /// 验收时要拿它和「我什么时候打开的 App」比 —— **必须到分钟**。
    func testShortTimeKeepsMinutes() {
        XCTAssertEqual(SettingsView.shortTime("2026-08-14T03:14:07+08:00"), "08-14 03:14")
        // 看不懂的串原样返回,不崩也不编一个时间出来
        XCTAssertEqual(SettingsView.shortTime("坏的"), "坏的")
    }
}
