import XCTest

nonisolated final class FlowTests: XCTestCase {
    @MainActor func app(reset: Bool = true, language: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-language", language, "-appearance", "system"]
        if reset { app.launchArguments.append("--reset-test-store") }
        app.launch(); return app
    }
    @MainActor func button(_ app: XCUIApplication, _ prefix: String, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", prefix, name)).firstMatch
    }
    @MainActor func type(_ field: XCUIElement, _ text: String) { XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText(text) }
    @MainActor func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func create(_ app: XCUIApplication, name: String, daily: Bool = false) {
        app.buttons["tracker.create"].tap()
        type(app.textFields["tracker.name"], name)
        if daily {
            app.buttons["tracker.kind"].tap(); app.buttons["Daily completion"].tap()
            let toggle = app.switches["goal.enabled"]
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertEqual(toggle.value as? String, "1")
            screenshot(app, "Frequency goal enabled")
        }
        app.buttons["tracker.save"].tap()
        XCTAssertTrue(button(app, "tracker.", name).waitForExistence(timeout: 10))
    }
    @MainActor func testCoreFlowsAndPersistence() {
        continueAfterFailure = false
        let app = app()
        create(app, name: "VOLFORCE")
        button(app, "snapshot.", "VOLFORCE").tap()
        type(app.textFields["entry.value"], "18.500")
        type(app.textFields["entry.note"], "snapshot note")
        app.buttons["entry.save"].tap()
        XCTAssertTrue(app.staticTexts["18.500"].waitForExistence(timeout: 10))
        button(app, "tracker.", "VOLFORCE").tap()
        screenshot(app, "Single snapshot detail")
        app.buttons["entry.add"].tap()
        type(app.textFields["entry.value"], "19.25")
        app.buttons["entry.save"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["19.250"].waitForExistence(timeout: 10))
        create(app, name: "COOK", daily: true)
        button(app, "complete.", "COOK").tap()
        XCTAssertTrue(app.staticTexts["1 / 2 · This week"].waitForExistence(timeout: 10))
        button(app, "complete.", "COOK").tap()
        XCTAssertTrue(app.staticTexts["0 / 2 · This week"].waitForExistence(timeout: 10))
        button(app, "complete.", "COOK").tap()
        screenshot(app, "Today with number and completion")
        app.terminate()
        let reopened = self.app(reset: false)
        XCTAssertTrue(reopened.staticTexts["19.250"].waitForExistence(timeout: 10))
        XCTAssertTrue(reopened.staticTexts["1 / 2 · This week"].exists)
        button(reopened, "tracker.", "VOLFORCE").tap()
        XCTAssertTrue(reopened.otherElements["snapshot.chart"].waitForExistence(timeout: 10))
        screenshot(reopened, "Snapshot detail")
    }
    @MainActor func testInvalidValueIsNotSaved() {
        let app = app(); create(app, name: "SCORE")
        button(app, "snapshot.", "SCORE").tap(); type(app.textFields["entry.value"], "invalid")
        app.buttons["entry.save"].tap()
        XCTAssertTrue(app.staticTexts["editor.error"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["entry.save"].exists)
    }
    @MainActor func testDarkLargeTypeCalendar() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-test-store", "-language", "en", "-appearance", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        create(app, name: "A daily goal with a long name", daily: true)
        button(app, "tracker.", "A daily goal").tap()
        XCTAssertTrue(app.buttons["entry.add"].waitForExistence(timeout: 10))
        app.swipeUp()
        screenshot(app, "Dark calendar at accessibility XXXL")
        app.buttons["entry.add"].tap()
        type(app.textFields["entry.note"], "Checked with large text")
        app.buttons["entry.save"].tap()
        for _ in 0..<8 {
            if app.staticTexts["Checked with large text"].exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["Checked with large text"].waitForExistence(timeout: 10))
        screenshot(app, "Dark saved record at accessibility XXXL")
    }
    @MainActor func testLocalizedInputAndScreens() {
        for (language, name) in [("zh-Hant", "煮飯"), ("ja", "入浴"), ("en", "Read")] {
            let app = app(language: language)
            app.buttons["tracker.create"].tap(); type(app.textFields["tracker.name"], name)
            app.buttons["tracker.save"].tap()
            XCTAssertTrue(button(app, "tracker.", name).waitForExistence(timeout: 10))
            screenshot(app, "Today " + language)
            app.buttons["settings.open"].tap()
            XCTAssertTrue(app.buttons["backup.export"].waitForExistence(timeout: 10))
            screenshot(app, "Settings " + language)
            app.terminate()
        }
    }
}
