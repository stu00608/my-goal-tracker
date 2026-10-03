import XCTest

nonisolated final class WidgetTests: XCTestCase {
    @MainActor func testWidgetSharingAndTodayLink() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-test-store", "--widgettesting", "-language", "en", "-appearance", "system"]
        app.launch()
        app.launchArguments.removeAll { $0 == "--reset-test-store" }
        app.buttons["tracker.create"].tap()
        let name = app.textFields["tracker.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap(); name.typeText("VOLFORCE\n")
        let toggle = app.switches["goal.enabled"]
        for _ in 0..<6 { if toggle.isHittable { break }; app.swipeUp() }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let target = app.textFields["goal.target"]
        XCTAssertTrue(target.waitForExistence(timeout: 10)); target.tap(); target.typeText("20")
        app.buttons["tracker.save"].tap()
        let snapshot = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "snapshot.")).firstMatch
        XCTAssertTrue(snapshot.waitForExistence(timeout: 10)); snapshot.tap()
        let value = app.textFields["entry.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 10)); value.tap(); value.typeText("18.500")
        app.buttons["entry.save"].tap()
        XCTAssertTrue(app.staticTexts["18.500"].waitForExistence(timeout: 10))
        app.buttons["tracker.create"].tap()
        name.tap(); name.typeText("煮飯\n")
        app.buttons["tracker.kind"].tap(); app.buttons["Daily completion"].tap()
        let dailyGoal = app.switches["goal.enabled"]
        for _ in 0..<6 { if dailyGoal.isHittable { break }; app.swipeUp() }
        dailyGoal.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["tracker.save"].tap()
        let complete = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "complete.")).firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 10)); complete.tap()
        app.buttons["tracker.create"].tap()
        name.tap(); name.typeText("日本語の長い目標名\n"); app.buttons["tracker.save"].tap()
        XCTAssertFalse(app.alerts["Action failed"].exists, "The App Group summary must publish successfully")
        let detail = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "tracker.", "VOLFORCE")).firstMatch
        detail.tap()
        XCTAssertTrue(app.navigationBars["VOLFORCE"].waitForExistence(timeout: 10))
        app.open(URL(string: "goaltracker://today")!)
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Goals"].tap()
        app.open(URL(string: "goaltracker://today")!)
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["18.500"].exists)
        XCTAssertTrue(app.staticTexts["1 / 2 · This week"].exists)
        attach(app, "Widget link opens Today with saved records")
    }
    @MainActor func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
