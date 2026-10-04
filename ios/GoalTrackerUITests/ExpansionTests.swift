import XCTest

nonisolated final class ExpansionTests: XCTestCase {
    @MainActor private func launch(extra: [String] = [], reset: Bool = true, language: String = "en", appearance: String = "light", large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--feature-test-fixture", "--goalooker-test-fixture", "-language", language, "-appearance", appearance, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if reset { app.launchArguments.append("--reset-test-store") }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
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
    @MainActor func testLocationGateFailurePreservesDraftAndListCannotBypassIt() {
        continueAfterFailure = false
        let app = launch(extra: ["--condition-gate=unmet", "-homeLayout", "list"])
        let complete = button(app, prefix: "complete.", text: "OFFICE")
        for _ in 0..<6 { if complete.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(complete.waitForExistence(timeout: 10)); complete.tap()
        XCTAssertTrue(app.buttons["entry.save"].waitForExistence(timeout: 10), "Gated quick completion must open the editor")
        let note = app.textFields["entry.note"]
        for _ in 0..<6 { if note.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(note.waitForExistence(timeout: 10)); note.tap(); note.typeText("Office draft remains")
        app.buttons["entry.save"].tap()
        let error = app.staticTexts["editor.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10)); XCTAssertTrue(error.isHittable)
        XCTAssertTrue(error.label.contains("conditions"))
        XCTAssertEqual(note.value as? String, "Office draft remains")
        screenshot(app, "Unmet place gate preserves draft and visible inline notice")
        app.buttons["entry.cancel"].tap()
        XCTAssertTrue(complete.waitForExistence(timeout: 10))
        XCTAssertTrue(complete.label.contains("Mark complete"), "Failed gate cannot silently create a completion")
    }
    @MainActor func testLocationGateSuccessRecordsSilently() {
        continueAfterFailure = false
        let app = launch(extra: ["--condition-gate=met", "-homeLayout", "list"])
        let complete = button(app, prefix: "complete.", text: "OFFICE")
        for _ in 0..<6 { if complete.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(complete.waitForExistence(timeout: 10)); complete.tap()
        XCTAssertTrue(app.buttons["entry.save"].waitForExistence(timeout: 10)); app.buttons["entry.save"].tap()
        XCTAssertTrue(complete.waitForExistence(timeout: 10)); XCTAssertTrue(complete.label.contains("Undo completion"))
        XCTAssertFalse(app.staticTexts["editor.error"].exists); XCTAssertFalse(app.alerts.firstMatch.exists)
        screenshot(app, "Satisfied place gate saves with no extra success prompt")
    }

    @MainActor func testTrackerMetadataPhotoBoundsAndProgress() {
        continueAfterFailure = false
        let app = launch()
        app.tabBars.buttons.element(boundBy: 1).tap()
        button(app, prefix: "tracker.", text: "SCORE").tap()
        XCTAssertTrue(app.staticTexts["tracker.description"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["tracker.website"].exists)
        let photo = app.buttons["tracker.photo.0"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10)); photo.tap()
        XCTAssertTrue(app.buttons["photo.close"].waitForExistence(timeout: 10))
        screenshot(app, "Tracker-owned photo opens full screen")
        app.buttons["photo.close"].tap()
        let view = app.segmentedControls["snapshot.view"]
        for _ in 0..<8 { if view.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(view.waitForExistence(timeout: 10)); view.buttons["Goal progress"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "snapshot.progress").firstMatch.waitForExistence(timeout: 10))
        screenshot(app, "Signed numeric goal progress ring")
        app.buttons["tracker.menu"].tap(); app.buttons["Edit tracker"].tap()
        let lower = app.textFields["tracker.axisLower"], upper = app.textFields["tracker.axisUpper"]
        for _ in 0..<12 { if lower.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(lower.waitForExistence(timeout: 10)); XCTAssertEqual(lower.value as? String, "0")
        lower.tap(); lower.typeText(XCUIKeyboardKey.delete.rawValue + "10")
        app.buttons["tracker.keyboard.done"].tap()
        upper.tap(); upper.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "30")
        app.buttons["tracker.keyboard.done"].tap()
        screenshot(app, "Optional chart bounds grouped with explanation")
        app.buttons["tracker.save"].tap()
        XCTAssertTrue(app.buttons["tracker.menu"].waitForExistence(timeout: 10))
        app.buttons["tracker.menu"].tap(); app.buttons["Edit tracker"].tap()
        for _ in 0..<12 { if lower.isHittable { break }; app.swipeUp() }
        XCTAssertEqual(lower.value as? String, "10"); XCTAssertEqual(upper.value as? String, "30")
        app.buttons["Cancel"].tap()
    }
    @MainActor func testLocationConditionEditorAndAllCombinationPersist() {
        continueAfterFailure = false
        let app = launch()
        app.tabBars.buttons.element(boundBy: 1).tap()
        let office = button(app, prefix: "tracker.", text: "OFFICE")
        for _ in 0..<8 { if office.isHittable { break }; app.swipeUp() }
        office.tap(); app.buttons["tracker.menu"].tap(); app.buttons["Edit tracker"].tap()
        let condition = button(app, prefix: "tracker.condition.", text: "Office A")
        for _ in 0..<12 { if condition.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(condition.waitForExistence(timeout: 10)); condition.tap()
        let map = app.descendants(matching: .any).matching(identifier: "condition.map").firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 10))
        screenshot(app, "Chosen searchable place editor with fixed boundary")
        let relation = app.segmentedControls["condition.relation"]
        for _ in 0..<6 { if relation.isHittable { break }; app.swipeUp() }
        relation.buttons["Outside"].tap()
        app.buttons["condition.confirm"].tap()
        let combination = app.buttons["tracker.conditions.combination"]
        XCTAssertTrue(combination.waitForExistence(timeout: 10)); combination.tap()
        app.buttons["All conditions"].tap()
        screenshot(app, "Multiple location conditions and ALL combination")
        app.buttons["tracker.save"].tap()
        XCTAssertTrue(app.buttons["tracker.menu"].waitForExistence(timeout: 10))
        app.buttons["tracker.menu"].tap(); app.buttons["Edit tracker"].tap()
        for _ in 0..<12 { if condition.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(condition.label.contains("Outside"))
        XCTAssertTrue(combination.label.contains("All conditions"))
        app.buttons["Cancel"].tap()
    }

    @MainActor func testExpansionLocalizedLightDarkAndMaximumType() {
        continueAfterFailure = false
        for (language, edit, cancel) in [("en", "Edit tracker", "Cancel"), ("zh-Hant", "編輯追蹤項目", "取消"), ("ja", "項目を編集", "キャンセル")] {
            for (appearance, large) in [("light", false), ("dark", true)] {
                let app = launch(language: language, appearance: appearance, large: large)
                let suffix = language + " " + appearance + (large ? " AX XXXL" : "")
                XCTAssertTrue(button(app, prefix: "card.", text: "SCORE").waitForExistence(timeout: 10))
                screenshot(app, "Goalooker overview " + suffix)
                app.tabBars.buttons.element(boundBy: 2).tap()
                screenshot(app, "Settings native tab " + suffix)
                app.tabBars.buttons.element(boundBy: 1).tap()
                button(app, prefix: "tracker.", text: "SCORE").tap()
                screenshot(app, "Tracker metadata and photos " + suffix)
                let view = app.segmentedControls["snapshot.view"]
                for _ in 0..<12 { if view.isHittable { break }; app.swipeUp() }
                XCTAssertTrue(view.waitForExistence(timeout: 10)); view.buttons.element(boundBy: 1).tap()
                let progress = app.descendants(matching: .any).matching(identifier: "snapshot.progress").firstMatch
                for _ in 0..<6 { if progress.isHittable { break }; app.swipeUp() }
                XCTAssertTrue(progress.waitForExistence(timeout: 10))
                screenshot(app, "Numeric ring " + suffix)
                app.buttons["tracker.menu"].tap(); app.buttons[edit].tap()
                XCTAssertTrue(app.textFields["tracker.name"].waitForExistence(timeout: 10))
                screenshot(app, "Tracker metadata editor " + suffix)
                let axis = app.textFields["tracker.axisLower"]
                for _ in 0..<16 { if axis.isHittable { break }; app.swipeUp() }
                screenshot(app, "Chart bounds editor " + suffix)
                app.buttons[cancel].tap()
                app.navigationBars["SCORE"].buttons["BackButton"].tap()
                let office = button(app, prefix: "tracker.", text: "OFFICE")
                for _ in 0..<8 { if office.isHittable { break }; app.swipeUp() }
                office.tap(); app.buttons["tracker.menu"].tap(); app.buttons[edit].tap()
                let place = button(app, prefix: "tracker.condition.", text: "Office A")
                for _ in 0..<18 { if place.isHittable { break }; app.swipeUp() }
                XCTAssertTrue(place.waitForExistence(timeout: 10))
                screenshot(app, "Tracker location conditions " + suffix)
                place.tap()
                XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "condition.map").firstMatch.waitForExistence(timeout: 10))
                screenshot(app, "Place selector and fixed region " + suffix)
                app.terminate()
            }
        }
    }
    @MainActor func testMapFirstAlternativeHasSamePlaceControls() {
        continueAfterFailure = false
        let app = launch(extra: ["--condition-map-first"])
        app.tabBars.buttons.element(boundBy: 1).tap()
        let office = button(app, prefix: "tracker.", text: "OFFICE")
        for _ in 0..<8 { if office.isHittable { break }; app.swipeUp() }
        office.tap(); app.buttons["tracker.menu"].tap(); app.buttons["Edit tracker"].tap()
        let place = button(app, prefix: "tracker.condition.", text: "Office A")
        for _ in 0..<12 { if place.isHittable { break }; app.swipeUp() }
        place.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "condition.map").firstMatch.waitForExistence(timeout: 10))
        screenshot(app, "Alternative map-first native location editor")
        XCTAssertTrue(app.buttons["condition.confirm"].isEnabled)
    }

    @MainActor func testDeletingAnchorRequiresConfirmationAndCancellationPreservesData() {
        continueAfterFailure = false
        let app = launch(extra: ["--goalooker-orphan-fixture"])
        app.tabBars.buttons.element(boundBy: 1).tap()
        button(app, prefix: "tracker.", text: "SCORE").tap()
        let anchor = button(app, prefix: "entry.", text: "Anchor value")
        for _ in 0..<12 { if anchor.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(anchor.waitForExistence(timeout: 10)); anchor.tap()
        let delete = app.buttons["entry.delete"]
        for _ in 0..<8 { if delete.isHittable { break }; app.swipeUp() }
        delete.tap(); app.buttons["Delete record"].tap()
        XCTAssertTrue(app.alerts["Keep later change records?"].waitForExistence(timeout: 10))
        screenshot(app, "Anchor removal has explicit conversion proposal")
        app.alerts.buttons["Cancel"].tap()
        app.buttons["entry.cancel"].tap()
        XCTAssertTrue(anchor.waitForExistence(timeout: 10), "Canceling conversion cannot delete the baseline")
        anchor.tap()
        for _ in 0..<8 { if delete.isHittable { break }; app.swipeUp() }
        delete.tap(); app.buttons["Delete record"].tap()
        app.alerts.buttons["Convert first change to a value"].tap()
        XCTAssertTrue(anchor.waitForNonExistence(timeout: 10))
        let retained = button(app, prefix: "entry.", text: "Derived change")
        XCTAssertTrue(retained.waitForExistence(timeout: 10)); retained.tap()
        let display = app.descendants(matching: .any).matching(identifier: "entry.value.scrubber").firstMatch
        XCTAssertTrue(display.waitForExistence(timeout: 10)); display.tap()
        XCTAssertEqual(app.textFields["entry.value"].value as? String, "18.75")
        screenshot(app, "Explicit conversion retains the previous derived value")
        app.buttons["entry.cancel"].tap()
    }

}
