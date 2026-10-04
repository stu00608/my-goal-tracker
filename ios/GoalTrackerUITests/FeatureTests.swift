import XCTest

nonisolated final class FeatureTests: XCTestCase {
    @MainActor func app(language: String = "en", appearance: String = "light", large: Bool = false, reset: Bool = true, fixedLayout: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-test-store", "--feature-test-fixture", "-language", language, "-appearance", appearance, "-homeLayout", "grid", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if !reset { app.launchArguments.removeAll { $0 == "--reset-test-store" } }
        // Foundation's argument domain overrides runtime preference changes.
        if !fixedLayout, let index = app.launchArguments.firstIndex(of: "-homeLayout") {
            app.launchArguments.removeSubrange(index...index + 1)
        }
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
        app.buttons["photo.next"].tap()
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
        for (label, id) in [("Bar chart", "completion.chart"), ("Progress bar", "completion.progress")] {
            for _ in 0..<4 { if app.descendants(matching: .any).matching(identifier: "completion.view").firstMatch.isHittable { break }; app.swipeDown() }
            app.descendants(matching: .any).matching(identifier: "completion.view").firstMatch.tap(); app.buttons[label].tap()
            let presentation = app.descendants(matching: .any).matching(identifier: id).firstMatch
            XCTAssertTrue(presentation.waitForExistence(timeout: 10))
            if id == "completion.chart" { XCTAssertTrue(app.staticTexts["Target"].exists) }
            else { XCTAssertEqual(presentation.value as? String, "1 / 2") }
            attach(app, label)
        }
        app.navigationBars["COOK"].buttons["BackButton"].tap()
        element(app, prefix: "tracker.", name: "EMPTY").tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "snapshot.chart").firstMatch.waitForExistence(timeout: 10))
        for label in ["30 days", "90 days", "All", "Custom"] {
            app.descendants(matching: .any).matching(identifier: "snapshot.period").firstMatch.tap()
            app.buttons[label].tap()
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "snapshot.chart").firstMatch.exists)
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
            app.buttons["entry.cancel"].tap()
            app.tabBars.buttons.element(boundBy: 1).tap()
            element(app, prefix: "tracker.", name: "COOK").tap()
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "completion.view").firstMatch.waitForExistence(timeout: 10))
            attach(app, "Completion calendar " + language)
            app.terminate()
        }
    }
    @MainActor func testRecordedMapOpensEntry() {
        continueAfterFailure = false
        let app = app()
        app.tabBars.buttons["Goals"].tap()
        element(app, prefix: "tracker.", name: "TRAVEL").tap()
        let pin = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "location.")).firstMatch
        for _ in 0..<6 { if pin.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(pin.waitForExistence(timeout: 10))
        attach(app, "Recorded location map")
        pin.tap()
        XCTAssertTrue(app.textFields["entry.value"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["entry.value"].value as? String, "1")
        XCTAssertEqual(app.switches["entry.location"].value as? String, "1")
        app.buttons["entry.cancel"].tap()
    }

    @MainActor func testGridReorderPersistsAndLayoutSwitches() {
        continueAfterFailure = false
        let app = app()
        let cook = element(app, prefix: "card.", name: "COOK")
        let score = element(app, prefix: "card.", name: "SCORE")
        XCTAssertTrue(cook.waitForExistence(timeout: 10))
        let id = String(cook.identifier.dropFirst("card.".count))
        app.buttons["home.edit"].tap()
        app.buttons["card.moveEarlier." + id].tap()
        XCTAssertLessThan(cook.frame.minX, score.frame.minX)
        attach(app, "Grid reordered in edit mode")
        app.buttons["home.edit"].tap()
        app.terminate()
        let reopened = self.app(reset: false, fixedLayout: false)
        let first = element(reopened, prefix: "card.", name: "COOK")
        let second = element(reopened, prefix: "card.", name: "SCORE")
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertLessThan(first.frame.minX, second.frame.minX)
        second.press(forDuration: 1, thenDragTo: first)
        XCTAssertLessThan(second.frame.minX, first.frame.minX)
        attach(reopened, "Grid reordered by long press drag")
        reopened.buttons["settings.open"].tap()
        reopened.buttons["settings.homeLayout"].tap()
        reopened.buttons["List"].tap()
        reopened.buttons["settings.done"].tap()
        XCTAssertTrue(element(reopened, prefix: "tracker.", name: "COOK").waitForExistence(timeout: 10))
        attach(reopened, "Native list selected from settings")
    }

    @MainActor func testLocationDenialStillSavesRecord() {
        continueAfterFailure = false
        let app = app()
        element(app, prefix: "card.", name: "SCORE").tap()
        let value = app.textFields["entry.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 10)); value.tap(); value.typeText("20")
        let toggle = app.switches["entry.location"]
        for _ in 0..<5 { if toggle.isHittable { break }; app.swipeUp() }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deny = springboard.alerts.buttons.matching(NSPredicate(format: "label MATCHES[c] %@", "don.t allow|不允許|許可しない")).firstMatch
        if deny.waitForExistence(timeout: 5) { deny.tap() }
        let status = app.staticTexts["entry.location.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let denied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "denied"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [denied], timeout: 10), .completed)
        attach(app, "Location denied without blocking save")
        app.buttons["entry.save"].tap()
        XCTAssertTrue(app.staticTexts["20.000"].waitForExistence(timeout: 10))
    }

}
