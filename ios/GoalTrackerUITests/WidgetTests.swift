import XCTest

nonisolated final class WidgetTests: XCTestCase {
    @MainActor func numericField(_ app: XCUIApplication) -> XCUIElement {
        let display = app.descendants(matching: .any).matching(identifier: "entry.value.scrubber").firstMatch
        if display.waitForExistence(timeout: 10) { display.tap() }
        let field = app.textFields["entry.value"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        return field
    }
    @MainActor func testWidgetSharingAndTodayLink() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-test-store", "--widgettesting", "-language", "en", "-appearance", "system", "-homeLayout", "list"]
        app.launch(); app.tabBars.buttons.element(boundBy: 1).tap()
        app.launchArguments.removeAll { $0 == "--reset-test-store" }
        createTracker(app)
        let name = app.textFields["tracker.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap(); name.typeText("VOLFORCE\n")
        let toggle = app.switches["goal.enabled"]
        for _ in 0..<6 { if toggle.isHittable { break }; app.swipeUp() }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let target = app.textFields["goal.target"]
        XCTAssertTrue(target.waitForExistence(timeout: 10)); target.tap(); target.typeText("20")
        app.buttons["tracker.save"].tap()
        let snapshot = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "snapshot.")).firstMatch
        XCTAssertTrue(snapshot.waitForExistence(timeout: 10))
        let trackerID = String(snapshot.identifier.dropFirst("snapshot.".count))
        snapshot.tap()
        let value = numericField(app)
        XCTAssertTrue(value.waitForExistence(timeout: 10)); value.tap(); value.typeText("18.500")
        app.buttons["entry.save"].tap()
        XCTAssertTrue(app.staticTexts["18.500"].waitForExistence(timeout: 10))
        createTracker(app)
        name.tap(); name.typeText("煮飯\n")
        app.buttons["tracker.kind"].tap(); app.buttons["Completion record"].tap()
        let dailyGoal = app.switches["goal.enabled"]
        for _ in 0..<6 { if dailyGoal.isHittable { break }; app.swipeUp() }
        dailyGoal.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["tracker.save"].tap()
        let complete = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "complete.")).firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 10)); complete.tap()
        createTracker(app)
        name.tap(); name.typeText("日本語の長い目標名\n"); app.buttons["tracker.save"].tap()
        XCTAssertFalse(app.alerts["Action failed"].exists, "The App Group summary must publish successfully")
        let detail = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "tracker.", "VOLFORCE")).firstMatch
        app.tabBars.buttons.element(boundBy: 1).tap()
        detail.tap()
        XCTAssertTrue(app.navigationBars["VOLFORCE"].waitForExistence(timeout: 10))
        app.open(URL(string: "goaltracker://today")!)
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        app.tabBars.buttons.element(boundBy: 1).tap()
        app.open(URL(string: "goaltracker://today")!)
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        let todayRecords = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today.record."))
        XCTAssertTrue(todayRecords.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "VOLFORCE", "18.500")).firstMatch.exists)
        XCTAssertTrue(todayRecords.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "煮飯", "Done")).firstMatch.exists)
        app.open(URL(string: "goaltracker://record/" + trackerID)!)
        XCTAssertEqual(numericField(app).value as? String, "Value")
        attach(app, "Widget record link opens new snapshot sheet")
        app.buttons["entry.cancel"].tap()
        app.tabBars.buttons.element(boundBy: 3).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        app.open(URL(string: "goaltracker://record/" + trackerID)!)
        _ = numericField(app)
        app.buttons["entry.cancel"].tap()
        app.open(URL(string: "goaltracker://record/00000000-0000-0000-0000-000000000000")!)
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        attach(app, "Widget link opens Today with saved records")
    }
    @MainActor private func createTracker(_ app: XCUIApplication) {
        app.buttons["goals.add"].tap()
        app.buttons["folder.createTracker"].tap()
    }
    @MainActor func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
