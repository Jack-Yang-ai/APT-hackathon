import XCTest

/// M5-1 的真实导航走查。素材至少两件有效事件,不发问题、不重试付费、不删除真实记录。
/// WALK-INVENTORY-BEGIN
/// 当前三页导航;只登记保留源码的入口。
/// ActionsView.swift         6 走4   NativeActionsLayoutTests 已走新建/详情/编辑/已移除恢复；两处候选/出处需提取素材
/// AppShell.swift            2 走1   NativeActionsLayoutTests 已走中央Agent全屏聊天；无库说明sheet未实际UI走查
/// AskView.swift             3 走1   历史已走;录音出处另有数据测试;新增输入草稿sheet尚未实际UI走查，来源快照/引用由InputMemorySourceTests覆盖
/// AskHistoryView.swift      1 走0   新建/改名话题弹层在 M5-2 模拟器人工走查，自动走查未计
/// DaySessionsView.swift     1 走0   日历某天→单件事件，本轮改变范围，等待有事件的UI素材
/// HomeView.swift            2 走0   单件事件详情/处理失败状态(依赖素材，自动走查未计)
/// MeView.swift              4 走3   我的声音/导入/设置已走；日历本轮改为事件范围
/// MyVoiceView.swift         1 走0   灰区/复查弹层依赖可播放样本,确认语义有7条数据测试
/// SessionDetailView.swift   7 走2   原话destination/原话里长按改人;其他弹层另计
/// SettingsView.swift        3 走0   设置根已走;新增历史处理状态/逐场重试与其它子入口未计UI覆盖，恢复写方由ProcessingRecoveryTests覆盖
/// 合计 11 / 30
/// WALK-INVENTORY-END
final class ScreenWalkTests: XCTestCase {
    private var app: XCUIApplication!
    private let timeout: TimeInterval = 10

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["此刻"].waitForExistence(timeout: timeout), app.debugDescription)
    }

    override func tearDownWithError() throws {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()
    }

    func testEveryTabRootRendersAndMascotOpensAsk() {
        capture("此刻")
        let roots = Set(app.tabBars.buttons.allElementsBoundByIndex.map(\.label))
        XCTAssertEqual(roots, ["此刻", "行动", "我"])
        app.buttons["central-agent"].tap()
        XCTAssertTrue(app.buttons["聊天与话题"].waitForExistence(timeout: timeout))
        capture("问问")
        app.buttons["关闭"].tap()
        app.tabBars.buttons["我"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "我的声音")).firstMatch.waitForExistence(timeout: timeout))
    }

    func testFixtureHasAtLeastTwoEventsAndCalendarOpensADay() {
        app.tabBars.buttons["我"].tap()
        let days = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "，有事件"))
        XCTAssertTrue(days.firstMatch.waitForExistence(timeout: timeout), app.debugDescription)
        days.firstMatch.tap()
        let rows = sessionRows()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: timeout), app.debugDescription)
        XCTAssertGreaterThanOrEqual(rows.count, 2, "走查素材的日期需至少两件事件,不能在空库上假绿")
        back()
        XCTAssertTrue(app.navigationBars["我"].exists)
    }

    func testCalendarDatesStayInTheirWeekdayColumn() {
        app.tabBars.buttons["我"].tap()
        let day = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "，有事件")).firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: timeout))
        let parts = day.label.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
        XCTAssertGreaterThanOrEqual(parts.count, 2)
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        let cal = Calendar(identifier: .gregorian)
        let date = cal.date(from: DateComponents(year: year, month: parts[0], day: parts[1]))!
        let weekday = (cal.component(.weekday, from: date) + 5) % 7
        let heading = app.staticTexts[["一", "二", "三", "四", "五", "六", "日"][weekday]]
        XCTAssertEqual(day.frame.midX, heading.frame.midX, accuracy: 2, "日历日期必须在对应星期列")
        // AX可能只报文字/圆点的固有矩形;验真实边缘点击,不把AX文本框当触控区。
        let title = day.label.components(separatedBy: "，")[0]
        day.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: 20)).tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: timeout), "日期中心下方20pt也必须可点")
    }

    func testHomeShowsEventsAndNoCaptureDashboard() {
        XCTAssertTrue(app.descendants(matching:.any)["watch-connection-status"].firstMatch.waitForExistence(timeout:timeout))
        for label in ["开始录音", "接着录", "暂停录音", "继续录音", "结束今天的录音"] {
            XCTAssertFalse(app.buttons[label].exists,"手机端不应有录音控制: \(label)")
        }
        XCTAssertFalse(app.staticTexts["手表录音尚未结束"].exists)
        XCTAssertFalse(app.staticTexts["已收到的持续记录"].exists)
        XCTAssertFalse(app.staticTexts["暂不可即时连接"].exists)
        capture("事件首页")
    }

    func testMyVoiceAndSettingsAreReachable() {
        app.tabBars.buttons["我"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "我的声音")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["我的声音"].waitForExistence(timeout: timeout))
        capture("我的声音")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "声音样本")).firstMatch.exists)
        back()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "设置")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["库里的场次"].exists)
        back()
    }

    func testImportHasAnExit() {
        app.tabBars.buttons["我"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "导入录音或纪要")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["导入录音"].waitForExistence(timeout: timeout), app.debugDescription)
        capture("导入")
        back()
        XCTAssertTrue(app.navigationBars["我"].exists)
    }

    func testAskHistoryCanBeOpenedAndClosedWithoutSending() {
        app.buttons["central-agent"].tap()
        app.buttons["聊天与话题"].tap()
        XCTAssertTrue(app.navigationBars["聊天与话题"].waitForExistence(timeout: timeout), app.debugDescription)
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["聊天与话题"].waitForExistence(timeout: timeout))
    }

    func testDetailSwitchesPanesAndOpensTranscript() {
        openSession()
        XCTAssertTrue(app.buttons["重点"].exists)
        capture("重点")
        app.buttons["详情"].tap()
        capture("详情")
        XCTAssertTrue(app.buttons["原话"].exists)
        app.buttons["原话"].tap()
        XCTAssertTrue(app.navigationBars["原话"].waitForExistence(timeout: timeout))
        capture("原话")
        XCTAssertTrue(app.staticTexts.count > 0)
        back()
        XCTAssertTrue(app.buttons["重点"].exists)
    }

    func testTranscriptAllowsManualSelfCorrectionEvenWithoutAReview() {
        openSession()
        app.buttons["原话"].tap()
        XCTAssertTrue(app.navigationBars["原话"].waitForExistence(timeout: timeout))
        let stamp = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]{1,2}(:[0-9]{2}){1,2}$")).firstMatch
        XCTAssertTrue(stamp.waitForExistence(timeout: timeout), app.debugDescription)
        stamp.press(forDuration: 1)
        app.buttons["这句是谁说的"].tap()
        XCTAssertTrue(app.navigationBars["纠正说话人"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["是我"].exists)
        XCTAssertTrue(app.buttons["不是我"].exists)
        app.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["原话"].exists)
    }

    private func capture(_ title: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = title
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func openSession() {
        app.tabBars.buttons["我"].tap()
        let days = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "，有事件"))
        XCTAssertTrue(days.firstMatch.waitForExistence(timeout: timeout))
        // 测试副本里的最近有事件日，至少两件事件，避免用全场范围冒充单件。
        days.allElementsBoundByIndex.last!.tap()
        XCTAssertTrue(sessionRows().firstMatch.waitForExistence(timeout: timeout))
        let transcribed = sessionRows().firstMatch
        XCTAssertTrue(transcribed.waitForExistence(timeout: timeout))
        transcribed.tap()
        XCTAssertTrue(app.buttons["重点"].waitForExistence(timeout: timeout), app.debugDescription)
    }

    private func sessionRows() -> XCUIElementQuery {
        app.scrollViews.buttons.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]{2}:[0-9]{2}.*"))
    }

    private func back() {
        let button = app.navigationBars.buttons.matching(NSPredicate(format: "identifier == 'BackButton'")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: timeout), app.debugDescription)
        button.tap()
    }
}
