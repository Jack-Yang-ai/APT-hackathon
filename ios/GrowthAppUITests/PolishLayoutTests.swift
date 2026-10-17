import XCTest

/// 在既有的独立演示模拟器验布局；不发送问题、不删除来源。
final class PolishLayoutTests: XCTestCase {
    private let app = XCUIApplication()

    override func tearDownWithError() throws {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()
    }

    func testRecordBackgroundPrefillsAndSourceStillOpens() {
        app.launch()
        XCTAssertEqual(Set(app.tabBars.buttons.allElementsBoundByIndex.map(\.label)), ["此刻", "行动", "我"])
        let followup = app.buttons["继续问"].firstMatch
        XCTAssertTrue(followup.waitForExistence(timeout: 10), "走查素材必须包含理解结果")
        followup.tap()
        XCTAssertTrue(app.buttons["移除这份背景"].waitForExistence(timeout: 10))
        let input = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "向问问提问")).firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertFalse((input.value as? String ?? "").isEmpty)
        let quote = app.buttons["原话 1"].firstMatch
        XCTAssertTrue(quote.waitForExistence(timeout: 10), "走查素材必须包含有出处的历史回答")
        quote.tap()
        XCTAssertTrue(app.navigationBars["原话 · 前后各 3 句"].waitForExistence(timeout: 10))
        app.buttons["完成"].tap()
        app.buttons["移除这份背景"].tap()
        XCTAssertFalse(app.buttons["移除这份背景"].exists)
        XCTAssertTrue(input.exists)
    }

    func testAccessibilityTextKeepsCalendarAndKeyboardUsable() {
        app.launch()
        app.tabBars.buttons["我"].tap()
        let voice = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "我的声音")).firstMatch
        XCTAssertTrue(voice.waitForExistence(timeout: 10))
        let regularHeight = voice.frame.height
        app.terminate()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        app.tabBars.buttons["我"].tap()
        XCTAssertTrue(voice.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(voice.frame.height, regularHeight + 10, "必须真的启用辅助字号，不能空验")
        let day = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "，有录音")).firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 10))
        day.tap()
        XCTAssertTrue(app.navigationBars.buttons["BackButton"].waitForExistence(timeout: 10))
        app.tabBars.buttons["此刻"].tap()
        let followup = app.buttons["继续问"].firstMatch
        XCTAssertTrue(followup.waitForExistence(timeout: 10))
        followup.tap()
        let input = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "向问问提问")).firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        XCTAssertTrue(input.isHittable)
        XCTAssertTrue(app.buttons["发送问题"].isHittable, "开键盘后发送栏必须可达")
        XCTAssertTrue(app.buttons["移除这份背景"].isHittable)
    }
}
