import XCTest

nonisolated final class ExpansionTests: XCTestCase {
    @MainActor private func launch(extra: [String] = [], reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--feature-test-fixture", "--goalooker-test-fixture", "-language", "en", "-appearance", "light", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if reset { app.launchArguments.append("--reset-test-store") }
        app.launchArguments += extra
        app.launch()
        return app
    }
    @MainActor private func button(_ app: XCUIApplication, prefix: String, text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", prefix, text)).firstMatch
    }
    @MainActor private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testDeltaEditorUsesRawChangeAndRecomputesCurrentValue() {
        continueAfterFailure = false
        let app = launch()
        XCTAssertTrue(app.staticTexts["18.750"].waitForExistence(timeout: 10))
        app.tabBars.buttons.element(boundBy: 1).tap()
        button(app, prefix: "tracker.", text: "SCORE").tap()
        let delta = button(app, prefix: "entry.", text: "Derived change")
        for _ in 0..<10 { if delta.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(delta.waitForExistence(timeout: 10)); delta.tap()
        let display = app.descendants(matching: .any).matching(identifier: "entry.change.scrubber").firstMatch
        XCTAssertTrue(display.waitForExistence(timeout: 10)); display.tap()
        let field = app.textFields["entry.change"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "0.25", "Editing must load the original delta, not its derived absolute value")
        field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "-0.125")
        app.buttons["entry.save"].tap()
        app.tabBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["18.375"].waitForExistence(timeout: 10))
        screenshot(app, "Raw delta edit recomputes resolved current value")
        app.terminate()
        let reopened = launch(reset: false)
        XCTAssertTrue(reopened.staticTexts["18.375"].waitForExistence(timeout: 10))
    }
    @MainActor func testSettingsIsThirdTabAndHasGlobalReminderControl() {
        continueAfterFailure = false
        let app = launch()
        XCTAssertEqual(app.tabBars.buttons.count, 3)
        XCTAssertFalse(app.buttons["settings.open"].exists, "Settings has one primary route through its tab")
        app.tabBars.buttons.element(boundBy: 2).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["settings.done"].exists)
        let reminders = app.switches["settings.remindersEnabled"]
        for _ in 0..<8 { if reminders.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(reminders.waitForExistence(timeout: 10)); XCTAssertEqual(reminders.value as? String, "1")
        reminders.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(reminders.value as? String, "0")
        screenshot(app, "Settings tab and disabled global reminders")
        XCTAssertFalse(app.staticTexts["Private by default. Stored on this iPhone. No account or server."].exists)
    }
}
