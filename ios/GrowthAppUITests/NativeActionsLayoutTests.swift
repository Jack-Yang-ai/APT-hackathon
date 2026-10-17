import XCTest

final class NativeActionsLayoutTests: XCTestCase {
    private let app = XCUIApplication()
    private func field(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
    override func tearDownWithError() throws {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
        app.terminate()
    }
    func testThreePagesKeepCentralAgentAndFloatingInput() {
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["行动"].waitForExistence(timeout: 10))
        XCTAssertEqual(Set(app.tabBars.buttons.allElementsBoundByIndex.map(\.label)), ["此刻", "行动", "我"])
        XCTAssertTrue(app.descendants(matching:.any)["watch-connection-status"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["已收到的持续记录"].exists)
        XCTAssertFalse(app.staticTexts["暂不可即时连接"].exists)
        for page in ["此刻", "行动", "我"] {
            app.tabBars.buttons[page].tap()
            let agent = app.buttons["central-agent"]
            XCTAssertTrue(agent.waitForExistence(timeout: 10))
            XCTAssertEqual(agent.frame.midX, app.frame.midX, accuracy: 3)
            let input = field("向问问提问")
            XCTAssertTrue(input.exists)
            XCTAssertTrue(input.isHittable)
        }
        app.buttons["central-agent"].tap()
        XCTAssertTrue(app.buttons["聊天与话题"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["主聊天"].exists)
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.tabBars.buttons["我"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "我的声音")).firstMatch.exists)
    }
    func testDraftRemainsAcrossChatCloseAndAppRelaunch() {
        app.launch()
        let input = field("向问问提问")
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap(); input.typeText("留住这个草稿")
        app.buttons["central-agent"].tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 10))
        XCTAssertTrue((field("向问问提问").value as? String ?? "").contains("留住这个草稿"))
        app.buttons["关闭"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertTrue((input.value as? String ?? "").contains("留住这个草稿"))
    }
    func testManualActionCanBeCreatedEditedAndCompleted() {
        app.launch()
        app.tabBars.buttons["行动"].tap()
        app.buttons["新增行动"].tap()
        let title = field("行动标题")
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let uniqueTitle="界面走查行动 \(UUID().uuidString.prefix(6))"
        title.tap(); title.typeText(uniqueTitle)
        app.buttons["保存"].tap()
        let saved = app.buttons.matching(NSPredicate(format:"label CONTAINS %@",uniqueTitle)).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10),app.debugDescription); saved.tap()
        XCTAssertTrue(app.buttons["编辑行动"].waitForExistence(timeout: 10))
        app.buttons["编辑行动"].tap()
        let step = field("行动下一步")
        XCTAssertTrue(step.waitForExistence(timeout: 10)); step.tap(); step.typeText("核对时间")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["核对时间"].waitForExistence(timeout: 10))
        app.swipeUp()
        app.buttons["标记已完成"].tap()
        XCTAssertTrue(app.buttons["恢复行动"].waitForExistence(timeout: 10))
        app.terminate(); app.launch(); app.tabBars.buttons["行动"].tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 10),app.debugDescription)
        saved.tap()
        for _ in 0..<3 where !app.buttons["移除行动"].isHittable { app.swipeUp() }
        app.buttons["移除行动"].tap()
        XCTAssertTrue(app.buttons["已移除的行动与候选"].waitForExistence(timeout:10))
        XCTAssertFalse(saved.exists)
        app.buttons["已移除的行动与候选"].tap()
        XCTAssertTrue(app.staticTexts[uniqueTitle].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["移除前 · 已完成"].exists)
        app.buttons["恢复行动"].firstMatch.tap()
        app.navigationBars.buttons.element(boundBy:0).tap()
        XCTAssertTrue(saved.waitForExistence(timeout:10),app.debugDescription)
        saved.tap()
        XCTAssertTrue(app.buttons["恢复行动"].waitForExistence(timeout:10),"恢复移除不能重开完成状态")
        XCTAssertTrue(app.staticTexts["核对时间"].exists)
    }

    func testAccessibilitySizeKeepsAgentInputAndPagesReachable() {
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["行动"].waitForExistence(timeout: 10))
        for page in ["此刻", "行动", "我"] {
            app.tabBars.buttons[page].tap()
            XCTAssertTrue(app.buttons["central-agent"].isHittable)
            XCTAssertTrue(field("向问问提问").isHittable)
        }
        app.buttons["central-agent"].tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 10))
        field("向问问提问").tap()
        field("向问问提问").typeText("字号走查")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Keyboard accessibility hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        let send = app.buttons["发送问题"]
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "发送问题")).count, 1,
                       "聊天盖住业务页后，底下的输入不应进入辅助功能树")
        let reachable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [reachable], timeout: 10), .completed)
    }
}
