import XCTest

nonisolated final class FeatureTests: XCTestCase {
    @MainActor func app(language: String = "en", appearance: String = "light", large: Bool = false, reset: Bool = true, fixedLayout: Bool = true, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-test-store", "--feature-test-fixture", "-language", language, "-appearance", appearance, "-homeLayout", "grid", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if !reset { app.launchArguments.removeAll { $0 == "--reset-test-store" } }
        // Foundation's argument domain overrides runtime preference changes.
        if !fixedLayout, let index = app.launchArguments.firstIndex(of: "-homeLayout") {
            app.launchArguments.removeSubrange(index...index + 1)
        }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchArguments += extraArguments
        app.launch(); return app
    }
    @MainActor func element(_ app: XCUIApplication, prefix: String, name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", prefix, name)).firstMatch
    }
    @MainActor func numericField(_ app: XCUIApplication, id: String = "entry.value") -> XCUIElement {
        let field = app.textFields[id]
        if !field.exists {
            let display = app.descendants(matching: .any).matching(identifier: id + ".scrubber").firstMatch
            XCTAssertTrue(display.waitForExistence(timeout: 10)); display.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        return field
    }
    @MainActor func photos(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier BEGINSWITH %@", "entry.photo.", "entry.photo.remove."))
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
        _ = numericField(app)
        app.buttons["entry.keyboard.done"].tap()
        let location = app.switches["entry.location"]
        for _ in 0..<6 { if location.exists { break }; app.swipeUp() }
        XCTAssertEqual(location.value as? String, "0")
        for _ in 0..<6 { if app.buttons["entry.inputMode"].isHittable { break }; app.swipeDown() }
        app.buttons["entry.inputMode"].tap()
        app.buttons["Change amount"].tap()
        let change = numericField(app, id: "entry.change")
        change.typeText("0.125")
        XCTAssertTrue(app.buttons["entry.sign"].waitForExistence(timeout: 10)); app.buttons["entry.sign"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "entry.result").firstMatch.waitForExistence(timeout: 10))
        attach(app, "Change amount preview")
        app.buttons["entry.save"].tap()
        XCTAssertTrue(app.staticTexts["18.375"].waitForExistence(timeout: 10))
        element(app, prefix: "card.", name: "COOK").tap()
        for _ in 0..<6 { if app.textFields["entry.note"].exists { break }; app.swipeUp() }
        XCTAssertTrue(app.textFields["entry.note"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["entry.note"].value as? String, "Synthetic completion")
        for _ in 0..<6 { if location.exists { break }; app.swipeUp() }
        XCTAssertEqual(location.value as? String, "1")
        let photo = photos(app).firstMatch
        for _ in 0..<6 { if photo.isHittable { break }; app.swipeDown() }
        photo.tap()
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
        app.tabBars.buttons.element(boundBy: 1).tap()
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
            app.segmentedControls["completion.view"].buttons[label].tap()
            let presentation = app.descendants(matching: .any).matching(identifier: id).firstMatch
            XCTAssertTrue(presentation.waitForExistence(timeout: 10))
            if id == "completion.chart" { XCTAssertTrue(app.staticTexts["Target"].exists) }
            else { XCTAssertEqual(presentation.value as? String, "1 / 2") }
            attach(app, label)
        }
        app.navigationBars["COOK"].buttons["BackButton"].tap()
        element(app, prefix: "tracker.", name: "EMPTY").tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "snapshot.empty").firstMatch.waitForExistence(timeout: 10))
        for label in ["30 days", "90 days", "All", "Custom"] {
            app.segmentedControls["snapshot.period"].buttons[label].tap()
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "snapshot.empty").firstMatch.exists)
        }
        XCTAssertTrue(app.datePickers["snapshot.custom.start"].exists)
        XCTAssertTrue(app.datePickers["snapshot.custom.end"].exists)
        attach(app, "Empty chart remains visible in custom range")
    }
    @MainActor func testCheckboxCornerKeepsTitleAlignedAndValueBesideControl() {
        continueAfterFailure = false
        let app = app(language: "zh-Hant", appearance: "dark", extraArguments: ["--goalooker-test-fixture", "--checkbox-card-layout"])
        let morning = element(app, prefix: "card.", name: "測試早安")
        XCTAssertTrue(morning.waitForExistence(timeout: 10))
        attach(app, "Checkbox map and empty card use full corner width")
        let toggle = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "complete.", "測試早安")).firstMatch
        XCTAssertTrue(toggle.exists); toggle.tap()
        let checked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "取消完成"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [checked], timeout: 10), .completed)
        XCTAssertFalse(app.buttons["entry.save"].exists)
        attach(app, "Checkbox value and direct control update together")
        morning.tap()
        XCTAssertTrue(app.buttons["entry.save"].waitForExistence(timeout: 10))
    }

    @MainActor func testMapOnlyOffersUpperCornersAndCheckboxFollowsCount() {
        continueAfterFailure = false
        let app = app(extraArguments: ["--goalooker-test-fixture", "--checkbox-card-layout"])
        let upperRight = element(app, prefix: "complete.", name: "每月出社")
        let mapCard = element(app, prefix: "card.", name: "每月出社")
        XCTAssertTrue(upperRight.waitForExistence(timeout: 10))
        XCTAssertLessThan(upperRight.frame.midY, mapCard.frame.midY)
        XCTAssertGreaterThan(upperRight.frame.midX, mapCard.frame.midX)
        attach(app, "Map top-right copy and completion keep the pin visible")
        app.tabBars.buttons.element(boundBy: 1).tap()
        let goal = element(app, prefix: "tracker.", name: "每月出社")
        XCTAssertTrue(goal.waitForExistence(timeout: 10)); goal.tap()
        app.buttons["tracker.menu"].tap()
        let position = app.descendants(matching: .any).matching(identifier: "card.textPosition").firstMatch
        for _ in 0..<15 { if position.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(position.isHittable); position.tap()
        XCTAssertTrue(app.buttons["Top left"].exists); XCTAssertTrue(app.buttons["Top right"].exists)
        XCTAssertTrue(app.buttons["Hidden"].exists)
        XCTAssertFalse(app.buttons["Bottom left"].exists); XCTAssertFalse(app.buttons["Bottom right"].exists)
        attach(app, "Map picker offers only upper corners and hidden")
        app.buttons["Top left"].tap(); app.buttons["tracker.save"].tap()
        app.tabBars.buttons.element(boundBy: 0).tap()
        let card = element(app, prefix: "card.", name: "每月出社")
        let control = element(app, prefix: "complete.", name: "每月出社")
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        XCTAssertLessThan(control.frame.midY, card.frame.midY)
        XCTAssertLessThan(control.frame.midX, card.frame.midX)
        attach(app, "Map top-left count and sibling completion share chosen position")
        control.tap() // Existing location needs native undo confirmation.
        XCTAssertTrue(app.buttons["Undo completion"].waitForExistence(timeout: 10))
    }
    @MainActor func testAccessibleMapKeepsControlWithCopyAndAttributionClear() {
        let app = app(appearance: "dark", large: true, extraArguments: ["--goalooker-test-fixture", "--checkbox-card-layout", "--checkbox-map-top-left"])
        let card = element(app, prefix: "card.", name: "每月出社")
        let control = element(app, prefix: "complete.", name: "每月出社")
        for _ in 0..<16 {
            if card.exists && card.frame.minY > app.frame.minY + 120 && card.frame.maxY < app.frame.maxY - 110 { break }
            let down = card.exists && card.frame.minY < app.frame.minY + 120
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).press(forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.78 : 0.32)))
        }
        XCTAssertTrue(control.isHittable)
        XCTAssertLessThan(card.frame.maxY, app.frame.maxY - 100)
        XCTAssertGreaterThanOrEqual(control.frame.minX, card.frame.minX)
        XCTAssertLessThanOrEqual(control.frame.maxX, card.frame.maxX)
        XCTAssertLessThan(control.frame.maxY, card.frame.maxY - 18)
        attach(app, "AX map top-left count and scaled completion clear native attribution")
    }
    @MainActor func testGridTileDimensionsIgnoreLongContent() {
        continueAfterFailure = false
        for extra in [[], ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]] {
            let app = app(extraArguments: ["--ux-extreme-fixture", "--goalooker-test-fixture", "--goalooker-clipping-fixture"] + extra)
            let score = element(app, prefix: "card.", name: "SCORE")
            XCTAssertTrue(score.waitForExistence(timeout: 10))
            attach(app, "Grid with long title large value and clipped data")
            let cook = element(app, prefix: "card.", name: "COOK")
            let travel = element(app, prefix: "card.", name: "TRAVEL")
            let empty = element(app, prefix: "card.", name: "EMPTY")
            for tile in [score, cook, travel, empty] {
                XCTAssertEqual(tile.frame.width, tile.frame.height, accuracy: 1, "Every grid tile must stay square")
                XCTAssertEqual(tile.frame.width, score.frame.width, accuracy: 1)
            }
            XCTAssertEqual(score.frame.minY, cook.frame.minY, accuracy: 1)
            XCTAssertEqual(travel.frame.minY, empty.frame.minY, accuracy: 1)
            XCTAssertEqual(cook.frame.minX - score.frame.maxX, 12, accuracy: 1)
            XCTAssertEqual(travel.frame.minY - score.frame.maxY, 12, accuracy: 1)
            XCTAssertEqual(score.frame.minX, 16, accuracy: 1)
            XCTAssertEqual(cook.frame.maxX, app.frame.maxX - 16, accuracy: 1)
            XCTAssertFalse((score.value as? String)?.contains("outside the chart bounds") == true)
            app.terminate()
        }
    }

    @MainActor func testGridLocalizedAndAccessible() {
        continueAfterFailure = false
        for (language, appearance, large) in [("zh-Hant", "light", false), ("zh-Hant", "dark", true), ("ja", "light", false), ("ja", "dark", true), ("en", "light", false), ("en", "dark", true)] {
            let app = app(language: language, appearance: appearance, large: large)
            XCTAssertTrue(element(app, prefix: "card.", name: "SCORE").waitForExistence(timeout: 10))
            attach(app, "Bento " + language + (large ? " accessibility XXXL" : ""))
            element(app, prefix: "card.", name: "SCORE").tap()
            XCTAssertTrue(app.buttons["entry.save"].waitForExistence(timeout: 10))
            attach(app, "Record editor " + language + " " + appearance + (large ? " accessibility XXXL" : ""))
            app.buttons["entry.cancel"].tap()
            app.tabBars.buttons.element(boundBy: 1).tap()
            element(app, prefix: "tracker.", name: "COOK").tap()
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "completion.view").firstMatch.waitForExistence(timeout: 10))
            attach(app, "Completion calendar " + language + " " + appearance + (large ? " accessibility XXXL" : ""))
            if large {
                let firstDay = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "calendar.day.", "-01")).firstMatch
                for _ in 0..<8 { if firstDay.isHittable { break }; app.swipeUp() }
                XCTAssertTrue(firstDay.exists && firstDay.isHittable)
                attach(app, "Completion day grid " + language + " accessibility XXXL")
            }
            app.terminate()
        }
    }
    @MainActor func testRecordedMapOpensEntry() {
        continueAfterFailure = false
        let app = app()
        app.tabBars.buttons.element(boundBy: 1).tap()
        element(app, prefix: "tracker.", name: "TRAVEL").tap()
        let pin = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "location.")).firstMatch
        for _ in 0..<6 { if pin.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(pin.waitForExistence(timeout: 10))
        attach(app, "Recorded location map")
        pin.tap()
        let field = numericField(app)
        XCTAssertEqual(field.value as? String, "1")
        app.buttons["entry.keyboard.done"].tap()
        for _ in 0..<6 { if app.switches["entry.location"].exists { break }; app.swipeUp() }
        XCTAssertEqual(app.switches["entry.location"].value as? String, "1")
        app.buttons["entry.cancel"].tap()
    }

    @MainActor private func dragCard(_ source: XCUIElement, to target: XCUIElement) async {
        let destinationX = target.frame.minX
        // An explicit interior drop and brief hover allow native lift/transfer on hosted runners.
        // Keep a real long-press drag; accessible move actions are a separate path.
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.35)).press(
            forDuration: 1.2,
            thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.35)),
            withVelocity: XCUIGestureVelocity(rawValue: 220), thenHoldForDuration: 0.75)
        // Read the Swift CGRect directly; CGRect fields are not reliable predicate key paths.
        let deadline = Date().addingTimeInterval(10)
        while abs(source.frame.minX - destinationX) > 1 && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(source.frame.minX, destinationX, accuracy: 1,
                       "The dragged card must reach the target's original column")
    }

    @MainActor func testGridReorderPersistsAndLayoutSwitches() async {
        continueAfterFailure = false
        let app = app()
        let cook = element(app, prefix: "card.", name: "COOK")
        let score = element(app, prefix: "card.", name: "SCORE")
        XCTAssertTrue(cook.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["home.edit"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "card.detail.")).count, 0)
        await dragCard(cook, to: score)
        XCTAssertLessThan(cook.frame.minX, score.frame.minX)
        attach(app, "Grid reordered directly by long press")
        app.terminate()
        let reopened = self.app(reset: false, fixedLayout: false)
        let first = element(reopened, prefix: "card.", name: "COOK")
        let second = element(reopened, prefix: "card.", name: "SCORE")
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertLessThan(first.frame.minX, second.frame.minX)
        await dragCard(second, to: first)
        XCTAssertLessThan(second.frame.minX, first.frame.minX)
        attach(reopened, "Grid reordered by long press drag")
        reopened.tabBars.buttons.element(boundBy: 3).tap()
        reopened.buttons["settings.homeLayout"].tap()
        reopened.buttons["List"].tap()
        reopened.tabBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element(reopened, prefix: "tracker.", name: "COOK").waitForExistence(timeout: 10))
        attach(reopened, "Native list selected from settings")
    }

    @MainActor func testLocationDenialStillSavesRecord() {
        continueAfterFailure = false
        // Authorization survives fixture resets and earlier native Health/place checks.
        XCUIApplication().resetAuthorizationStatus(for: .location)
        let app = app()
        element(app, prefix: "card.", name: "SCORE").tap()
        let value = numericField(app)
        value.typeText("20")
        app.buttons["entry.keyboard.done"].tap()
        app.swipeUp()
        let toggle = app.switches["entry.location"]
        for _ in 0..<5 { if toggle.isHittable { break }; app.swipeUp() }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deny = springboard.alerts.buttons.matching(NSPredicate(format: "label MATCHES[c] %@", "don.t allow|不允許|許可しない")).firstMatch
        XCTAssertTrue(deny.waitForExistence(timeout: 10), "A fresh native location prompt must be denied explicitly")
        deny.tap()
        let status = app.staticTexts["entry.location.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let denied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "denied"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [denied], timeout: 10), .completed)
        attach(app, "Location denied without blocking save")
        app.buttons["entry.save"].tap()
        XCTAssertTrue(app.staticTexts["20.000"].waitForExistence(timeout: 10))
    }


    @MainActor func testNumericVerticalScrubAndTapInput() {
        continueAfterFailure = false
        let app = app()
        element(app, prefix: "card.", name: "SCORE").tap()
        let empty = app.descendants(matching: .any).matching(identifier: "entry.value.scrubber").firstMatch
        XCTAssertEqual(empty.value as? String, "Not entered")
        XCTAssertFalse(app.buttons["entry.save"].isEnabled)
        let field = numericField(app)
        field.typeText("18.500")
        app.buttons["entry.keyboard.done"].tap()
        let display = app.descendants(matching: .any).matching(identifier: "entry.value.scrubber").firstMatch
        XCTAssertTrue(display.waitForExistence(timeout: 10))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let start = display.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -38)))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        for _ in 0..<4 { if display.isHittable { break }; app.swipeDown() }
        XCTAssertEqual(numericField(app).value as? String, "18.500", "Absolute input must not scrub")
        app.buttons["entry.keyboard.done"].tap()
        app.buttons["entry.inputMode"].tap(); app.buttons["Change amount"].tap()
        let change = app.descendants(matching: .any).matching(identifier: "entry.change.scrubber").firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 10))
        let beforeDate = app.datePickers["entry.date"].frame.minY
        let zero = change.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        zero.press(forDuration: 0.05, thenDragTo: zero.withOffset(CGVector(dx: 0, dy: -38)))
        XCTAssertEqual(app.datePickers["entry.date"].frame.minY, beforeDate, accuracy: 2)
        XCTAssertEqual(numericField(app, id: "entry.change").value as? String, "0.003")
        app.buttons["entry.keyboard.done"].tap()
        let reverse = change.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        reverse.press(forDuration: 0.05, thenDragTo: reverse.withOffset(CGVector(dx: 0, dy: 50)))
        XCTAssertEqual(app.datePickers["entry.date"].frame.minY, beforeDate, accuracy: 2)
        XCTAssertEqual(numericField(app, id: "entry.change").value as? String, "-0.001")
        app.buttons["entry.keyboard.done"].tap()
        attach(app, "Vertical signed value scrub without page scrolling or keyboard")
        app.buttons["entry.cancel"].tap()
    }

    @MainActor func testDefaultNumericInputModePersistsAndFallsBackForFirstRecord() {
        continueAfterFailure = false
        let app = app()
        app.tabBars.buttons.element(boundBy: 3).tap()
        app.buttons["settings.numericInputMode"].tap(); app.buttons["Change amount"].tap()
        attach(app, "Default numeric input preference")
        app.tabBars.buttons.element(boundBy: 0).tap()
        element(app, prefix: "card.", name: "SCORE").tap()
        let change = app.descendants(matching: .any).matching(identifier: "entry.change.scrubber").firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 10))
        numericField(app, id: "entry.change").typeText("0.001")
        app.buttons["entry.keyboard.done"].tap()
        attach(app, "Reference centered bare change amount and inline preview")
        app.buttons["entry.cancel"].tap()
        app.terminate()
        let reopened = self.app(reset: false)
        element(reopened, prefix: "card.", name: "SCORE").tap()
        XCTAssertTrue(reopened.descendants(matching: .any).matching(identifier: "entry.change.scrubber").firstMatch.waitForExistence(timeout: 10))
        reopened.buttons["entry.cancel"].tap()
        element(reopened, prefix: "card.", name: "EMPTY").tap()
        XCTAssertTrue(reopened.descendants(matching: .any).matching(identifier: "entry.value.scrubber").firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(reopened.buttons["entry.save"].isEnabled)
        attach(reopened, "First record uses direct input despite preference")
        reopened.buttons["entry.cancel"].tap()
    }

    @MainActor func testLocationDefaultOnlyInitializesNewRecords() {
        continueAfterFailure = false
        let app = app()
        app.tabBars.buttons.element(boundBy: 3).tap()
        let preference = app.switches["settings.recordLocationDefault"]
        XCTAssertTrue(preference.waitForExistence(timeout: 10)); XCTAssertEqual(preference.value as? String, "0")
        preference.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(preference.value as? String, "1")
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
        attach(app, "Location default in Settings without permission request")
        app.tabBars.buttons.element(boundBy: 0).tap()
        element(app, prefix: "card.", name: "SCORE").tap()
        for _ in 0..<6 { if app.switches["entry.location"].exists { break }; app.swipeUp() }
        XCTAssertTrue(app.switches["entry.location"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.switches["entry.location"].value as? String, "1")
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
        app.buttons["entry.cancel"].tap()
        app.terminate()
        let reopened = self.app(reset: false)
        reopened.tabBars.buttons.element(boundBy: 3).tap()
        XCTAssertEqual(reopened.switches["settings.recordLocationDefault"].value as? String, "1")
        reopened.buttons["settings.homeLayout"].tap(); reopened.buttons["List"].tap()
        reopened.tabBars.buttons.element(boundBy: 0).tap()
        // Preference mutation must be observable; the argument-domain layout override is removed on reopen.
        reopened.terminate()
        let list = self.app(reset: false, fixedLayout: false)
        list.buttons["tracker.create"].tap()
        let name = list.textFields["tracker.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap(); name.typeText("DEFAULT COOK")
        list.buttons["tracker.kind"].tap(); list.buttons["Completion record"].tap()
        list.buttons["tracker.save"].tap()
        XCTAssertTrue(list.keyboards.firstMatch.waitForNonExistence(timeout: 10), "Saving a tracker must dismiss its keyboard before returning to Today")
        let completion = element(list, prefix: "complete.", name: "DEFAULT COOK")
        attach(list, "Location default new completion before reveal")
        for _ in 0..<8 { if completion.exists && completion.isHittable { break }; list.swipeUp() }
        attach(list, "Location default new completion after reveal")
        if !completion.isHittable {
            let hierarchy = XCTAttachment(string: list.debugDescription)
            hierarchy.name = "Location default completion hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
        XCTAssertTrue(completion.waitForExistence(timeout: 10)); XCTAssertTrue(completion.isHittable); completion.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let recorded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Undo completion"), object: completion)
        XCTAssertEqual(XCTWaiter.wait(for: [recorded], timeout: 20), .completed)
        XCTAssertFalse(list.buttons["entry.save"].exists, "The checkbox remains a direct action with the optional location default")
        element(list, prefix: "tracker.", name: "DEFAULT COOK").tap()
        XCTAssertTrue(list.buttons["entry.save"].waitForExistence(timeout: 10))
        for _ in 0..<6 { if list.switches["entry.location"].exists { break }; list.swipeUp() }
        XCTAssertTrue(list.switches["entry.location"].exists)
        attach(list, "Direct completion location result inspected in its record")
        list.buttons["entry.cancel"].tap()
        completion.tap()
        let undo = list.buttons["Undo completion"]
        if undo.waitForExistence(timeout: 2) { undo.tap() }
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Mark complete"), object: completion)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        // Create a different record with the default OFF. Turning it ON must not change that saved record.
        list.tabBars.buttons.element(boundBy: 3).tap()
        list.switches["settings.recordLocationDefault"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        list.tabBars.buttons.element(boundBy: 0).tap()
        completion.tap()
        list.tabBars.buttons.element(boundBy: 3).tap()
        list.switches["settings.recordLocationDefault"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        list.tabBars.buttons.element(boundBy: 0).tap()
        element(list, prefix: "tracker.", name: "DEFAULT COOK").tap()
        for _ in 0..<6 { if list.switches["entry.location"].exists { break }; list.swipeUp() }
        XCTAssertEqual(list.switches["entry.location"].value as? String, "0")
        attach(list, "Existing completion retains no-location state despite enabled default")
        list.buttons["entry.cancel"].tap()
    }

    @MainActor func testPhotoRemovalIdentifiesTargetAndPreservesDraft() {
        continueAfterFailure = false
        let app = app()
        element(app, prefix: "card.", name: "COOK").tap()
        let images = photos(app)
        XCTAssertTrue(images.firstMatch.waitForExistence(timeout: 10)); XCTAssertEqual(images.count, 2)
        let first = images.element(boundBy: 0).identifier, second = images.element(boundBy: 1).identifier
        let secondID = String(second.dropFirst("entry.photo.".count))
        let thumbnail = images.element(boundBy: 1)
        let removal = app.buttons["entry.photo.remove." + secondID]
        XCTAssertGreaterThanOrEqual(removal.frame.width, 44)
        XCTAssertGreaterThanOrEqual(removal.frame.height, 44)
        let circleRight = removal.frame.midX + 12
        let circleTop = removal.frame.midY - 12
        XCTAssertGreaterThan(circleRight, thumbnail.frame.maxX)
        XCTAssertLessThan(circleTop, thumbnail.frame.minY)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(removal.frame))
        attach(app, "Photo removal badges protrude from the upper right corners")
        removal.tap()
        XCTAssertTrue(app.buttons["entry.photoRemoval.cancel"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "entry.photoRemoval.preview").firstMatch.exists)
        attach(app, "Specific second photo preview before removing")
        app.buttons["entry.photoRemoval.cancel"].tap()
        XCTAssertEqual(images.count, 2)
        app.buttons["entry.photo.remove." + secondID].tap()
        app.buttons["entry.photoRemoval.confirm"].tap()
        XCTAssertTrue(app.buttons[second].waitForNonExistence(timeout: 10)); XCTAssertTrue(app.buttons[first].exists)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(app.textFields["entry.note"].value as? String, "Synthetic completion")
        app.buttons["entry.cancel"].tap()
        element(app, prefix: "card.", name: "COOK").tap()
        XCTAssertEqual(photos(app).count, 2, "Cancel record must preserve the saved photo copies")
        let target = photos(app).element(boundBy: 1).identifier
        app.buttons["entry.photo.remove." + String(target.dropFirst("entry.photo.".count))].tap()
        app.buttons["entry.photoRemoval.confirm"].tap()
        app.buttons["entry.save"].tap()
        element(app, prefix: "card.", name: "COOK").tap()
        XCTAssertEqual(photos(app).count, 1)
        attach(app, "Compact photo rail preserves the correct saved copy")
        app.buttons["entry.cancel"].tap()
    }

    @MainActor func testKeyboardDismissalAndFirstTapFocus() {
        continueAfterFailure = false
        let app = app()
        app.buttons["tracker.create"].tap()
        let name = app.textFields["tracker.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap(); name.typeText("FOCUS")
        XCTAssertEqual(name.value as? String, "FOCUS")
        app.staticTexts["Tracker"].firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
        let unit = app.textFields["tracker.unit"]
        unit.tap(); unit.typeText("points")
        XCTAssertEqual(unit.value as? String, "points")
        app.buttons["tracker.keyboard.done"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Statistics time zone"].exists)
        app.buttons["tracker.save"].tap()
        element(app, prefix: "card.", name: "SCORE").tap()
        app.buttons["entry.inputMode"].tap(); app.buttons["Change amount"].tap()
        numericField(app, id: "entry.change").typeText("0.125")
        let kindLabel = app.staticTexts["entry.baseline"]
        XCTAssertTrue(kindLabel.waitForExistence(timeout: 10)); kindLabel.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertEqual(numericField(app, id: "entry.change").value as? String, "0.125")
        app.buttons["entry.sign"].tap()
        XCTAssertEqual(app.textFields["entry.change"].value as? String, "-0.125")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.buttons["entry.keyboard.done"].tap()
        let note = app.textFields["entry.note"]
        for _ in 0..<5 { if note.isHittable { break }; app.swipeUp() }
        note.tap(); note.typeText("First tap still enters notes")
        XCTAssertEqual(note.value as? String, "First tap still enters notes")
        attach(app, "Focused notes and preserved numeric draft")
        app.buttons["entry.cancel"].tap()
    }

    @MainActor func testExtremeContentRemainsReadable() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = app(language: "zh-Hant", appearance: appearance, large: true,
                          extraArguments: ["--ux-bright-photo", "--ux-extreme-fixture"])
            let score = element(app, prefix: "card.", name: "SCORE")
            XCTAssertTrue(score.waitForExistence(timeout: 10))
            attach(app, "Extreme long names bright photo and exact large value " + appearance)
            score.tap()
            let field = numericField(app)
            XCTAssertEqual(field.value as? String, field.placeholderValue)
            field.typeText("0.00000001")
            app.buttons["entry.keyboard.done"].tap()
            attach(app, "Extreme numeric workspace accessibility XXXL " + appearance)
            app.buttons["entry.cancel"].tap()
            element(app, prefix: "card.", name: "COOK").tap()
            XCTAssertTrue(app.buttons["entry.photos"].waitForExistence(timeout: 10))
            attach(app, "Extreme photo workspace accessibility XXXL " + appearance)
            app.buttons["entry.cancel"].tap()
            app.terminate()
        }
    }

    @MainActor func testPhotoCapacityAndInputLayoutAlternatives() {
        continueAfterFailure = false
        for (alternative, large) in [(false, false), (true, false), (false, true), (true, true)] {
            let app = app(large: large, extraArguments: ["--ux-many-photos"] + (alternative ? ["--ux-input-alternative"] : []))
            element(app, prefix: "card.", name: "COOK").tap()
            XCTAssertTrue(app.buttons["entry.photos"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["entry.photos"].isEnabled)
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "entry.photos.count").firstMatch.value as? String, "10/10")
            attach(app, (alternative ? "Alternative B compact photo workspace" : "Chosen A compact photo workspace with ten photos") + (large ? " accessibility XXXL" : ""))
            let first = photos(app).firstMatch.identifier
            let removal = app.buttons["entry.photo.remove." + String(first.dropFirst("entry.photo.".count))]
            for _ in 0..<5 { if removal.isHittable { break }; app.swipeUp() }
            removal.tap()
            app.buttons["entry.photoRemoval.confirm"].tap()
            XCTAssertTrue(app.buttons["entry.photos"].isEnabled)
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "entry.photos.count").firstMatch.value as? String, "9/10")
            XCTAssertFalse(app.buttons[first].exists)
            app.buttons["entry.cancel"].tap()
            app.tabBars.buttons.element(boundBy: 1).tap()
            element(app, prefix: "tracker.", name: "SCORE").tap()
            let record = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "entry.", "Synthetic snapshot")).firstMatch
            // Drag in the List gutter, outside the interactive MapKit surface.
            for _ in 0..<12 {
                if record.exists && record.isHittable { break }
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.75))
                    .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.2)))
            }
            XCTAssertTrue(record.waitForExistence(timeout: 10)); record.tap()
            XCTAssertTrue(app.buttons["entry.photos"].waitForExistence(timeout: 10))
            attach(app, (alternative ? "Alternative B numeric and photo workspace" : "Chosen A numeric and photo workspace") + (large ? " accessibility XXXL" : ""))
            app.buttons["entry.cancel"].tap(); app.terminate()
        }
    }
}
