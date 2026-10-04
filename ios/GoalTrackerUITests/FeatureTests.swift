import XCTest

nonisolated final class FeatureTests: XCTestCase {
    @MainActor func app(language: String = "en", appearance: String = "light", large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-test-store", "--feature-test-fixture", "-language", language, "-appearance", appearance, "-homeLayout", "grid"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch(); return app
    }
    @MainActor func element(_ app: XCUIApplication, prefix: String, name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", prefix, name)).firstMatch
    }
    @MainActor func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testGridRecordPhotoViewerAndChangeAmount() {
        continueAfterFailure = false
        let app = app()
        let score = element(app, prefix: "card.", name: "SCORE")
        XCTAssertTrue(score.waitForExistence(timeout: 10))
        attach(app, "Bento with chart photo map and empty cards")
        score.tap()
        XCTAssertTrue(app.textFields["entry.value"].waitForExistence(timeout: 10))
        let location = app.switches["entry.location"]
        XCTAssertEqual(location.value as? String, "0")
        app.buttons["entry.inputMode"].tap()
        app.buttons["Change amount"].tap()
        let change = app.textFields["entry.change"]
        XCTAssertTrue(change.waitForExistence(timeout: 10)); change.tap(); change.typeText("-0.125")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "entry.result").firstMatch.waitForExistence(timeout: 10))
        attach(app, "Change amount preview")
        app.buttons["entry.save"].tap()
        XCTAssertTrue(app.staticTexts["18.375"].waitForExistence(timeout: 10))
        element(app, prefix: "card.", name: "COOK").tap()
        XCTAssertTrue(app.textFields["entry.note"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["entry.note"].value as? String, "Synthetic completion")
        XCTAssertEqual(location.value as? String, "1")
        for _ in 0..<5 { if app.buttons["entry.photo.0"].isHittable { break }; app.swipeUp() }
        app.buttons["entry.photo.0"].tap()
        XCTAssertTrue(app.buttons["photo.close"].waitForExistence(timeout: 10))
        attach(app, "Full screen photo")
        let image = app.descendants(matching: .any).matching(identifier: "photo.page.0").firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        image.doubleTap()
        XCTAssertNotEqual(image.value as? String, "100%")
        attach(app, "Zoomed photo")
        app.buttons["Next photo"].tap()
        app.buttons["photo.close"].tap()
        XCTAssertTrue(app.buttons["entry.save"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
    }
    @MainActor func testCalendarAndEmptyCustomChart() {
        continueAfterFailure = false
        let app = app()
        app.tabBars.buttons["Goals"].tap()
        element(app, prefix: "tracker.", name: "COOK").tap()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let month = calendar.date(byAdding: .month, value: -1, to: Date())!
        app.buttons["Previous month"].tap()
        let year = calendar.component(.year, from: month), number = calendar.component(.month, from: month)
        for day in [1, 6, 7, calendar.range(of: .day, in: .month, for: month)!.last!] {
            let id = String(format: "calendar.day.%04d-%02d-%02d", year, number, day)
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 10), id)
        }
        attach(app, "Completion calendar includes first six days")
        let first = String(format: "calendar.day.%04d-%02d-01", year, number)
        app.buttons[first].tap()
        XCTAssertTrue(app.buttons["entry.save"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        app.navigationBars["COOK"].buttons["BackButton"].tap()
        element(app, prefix: "tracker.", name: "EMPTY").tap()
        XCTAssertTrue(app.otherElements["snapshot.chart"].waitForExistence(timeout: 10))
        for label in ["30 days", "90 days", "All", "Custom"] {
            app.segmentedControls["snapshot.period"].buttons[label].tap()
            XCTAssertTrue(app.otherElements["snapshot.chart"].exists)
        }
        XCTAssertTrue(app.datePickers["snapshot.custom.start"].exists)
        XCTAssertTrue(app.datePickers["snapshot.custom.end"].exists)
        attach(app, "Empty chart remains visible in custom range")
    }
    @MainActor func testGridLocalizedAndAccessible() {
        continueAfterFailure = false
        for (language, appearance, large) in [("zh-Hant", "light", false), ("ja", "dark", false), ("en", "dark", true)] {
            let app = app(language: language, appearance: appearance, large: large)
            XCTAssertTrue(element(app, prefix: "card.", name: "SCORE").waitForExistence(timeout: 10))
            attach(app, "Bento " + language + (large ? " accessibility XXXL" : ""))
            element(app, prefix: "card.", name: "SCORE").tap()
            XCTAssertTrue(app.buttons["entry.save"].waitForExistence(timeout: 10))
            attach(app, "Record editor " + language)
            app.terminate()
        }
    }
}
