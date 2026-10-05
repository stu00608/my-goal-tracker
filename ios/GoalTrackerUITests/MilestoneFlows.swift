import XCTest

nonisolated final class MilestoneFlows: XCTestCase {
    @MainActor private func launch(extra: [String] = [], language: String = "en", dark: Bool = false, large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-test-store", "--feature-test-fixture", "--goalooker-test-fixture", "--milestones-test-fixture", "-language", language, "-appearance", dark ? "dark" : "light", "-homeLayout", "grid", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch(); return app
    }
    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    @MainActor private func button(_ app: XCUIApplication, prefix: String, name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", prefix, name)).firstMatch
    }
    @MainActor private func reveal(_ app: XCUIApplication, _ item: XCUIElement) {
        for _ in 0..<12 { if item.exists && item.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(item.exists); XCTAssertTrue(item.isHittable)
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func openGoal(_ app: XCUIApplication, _ name: String) {
        app.tabBars.buttons.element(boundBy: 1).tap()
        let goal = button(app, prefix: "tracker.", name: name); reveal(app, goal); goal.tap()
        XCTAssertTrue(app.buttons["tracker.menu"].waitForExistence(timeout: 10))
    }
    @MainActor func testGridCompletionHasIndependentDirectToggle() {
        let app = launch()
        let toggle = button(app, prefix: "complete.", name: "CHECK")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10)); toggle.tap()
        let checked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Undo completion"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [checked], timeout: 10), .completed)
        XCTAssertFalse(app.buttons["entry.save"].exists)
        capture(app, "Grid direct completion and centered full ring")
        toggle.tap()
        let undone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Mark complete"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [undone], timeout: 10), .completed)
        button(app, prefix: "card.", name: "CHECK").tap()
        XCTAssertTrue(app.buttons["entry.save"].waitForExistence(timeout: 10))
        capture(app, "Card surface opens recording sheet")
    }
    @MainActor func testGroupedGatePreviewAndFreshSave() {
        let app = launch(extra: ["--condition-gate=unmet"])
        button(app, prefix: "card.", name: "GROUPED").tap()
        let overall = element(app, "conditions.overall")
        XCTAssertTrue(overall.waitForExistence(timeout: 10))
        XCTAssertTrue(overall.label.contains("Conditions not met"))
        capture(app, "Live grouped conditions before input")
        app.buttons["entry.save"].tap()
        XCTAssertTrue(app.staticTexts["editor.error"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["editor.error"].label.lowercased().contains("draft"))
        app.buttons["entry.cancel"].tap()
        app.terminate()
        let met = launch(extra: ["--condition-gate=met"])
        let toggle = button(met, prefix: "complete.", name: "GROUPED"); reveal(met, toggle); toggle.tap()
        let checked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Undo completion"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [checked], timeout: 10), .completed)
        XCTAssertFalse(met.buttons["entry.save"].exists); XCTAssertFalse(met.alerts.firstMatch.exists)
    }
    @MainActor func testHealthUnknownIsVisibleBeforeInput() {
        let app = launch(extra: ["--condition-gate=unknown"])
        let card = button(app, prefix: "card.", name: "HEALTH"); reveal(app, card); card.tap()
        XCTAssertTrue(element(app, "conditions.overall").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "conditions.overall").label.contains("Cannot determine yet"))
        reveal(app, app.buttons["conditions.connectHealth"])
        XCTAssertTrue(app.buttons["conditions.connectHealth"].exists)
        capture(app, "Readable Health unknown and explicit connection")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Opening a record must not implicitly request permission")
    }
    @MainActor func testManualCompletionExportAndReopen() {
        let app = launch(extra: ["--milestone-compare-layout"])
        openGoal(app, "MANUAL")
        reveal(app, app.buttons["tracker.complete"]); app.buttons["tracker.complete"].tap()
        XCTAssertTrue(app.buttons["tracker.reopen"].waitForExistence(timeout: 10))
        app.tabBars.buttons.element(boundBy: 2).tap()
        let collection = button(app, prefix: "achievements.tracker.", name: "MANUAL")
        XCTAssertTrue(collection.waitForExistence(timeout: 10)); collection.tap()
        let history = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "achievement.open.")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10)); history.tap()
        XCTAssertTrue(element(app, "achievement.poster").waitForExistence(timeout: 10))
        capture(app, "Manual completion relief card with no fabricated number")
        let poster = element(app, "achievement.poster")
        poster.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).press(forDuration: 0.1, thenDragTo: poster.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        app.buttons["achievement.copy"].tap()
        XCTAssertTrue(app.staticTexts["achievement.export.notice"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["achievement.export.notice"].label, "Image copied.")
        capture(app, "Flat content-only completion image copied")
        app.buttons["achievement.share"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10) || app.buttons["Copy"].waitForExistence(timeout: 5))
        capture(app, "Native image sharing sheet")
        app.terminate()
        let reopened = XCUIApplication(); reopened.launchArguments = ["--uitesting", "-language", "en", "-homeLayout", "list"]; reopened.launch()
        openGoal(reopened, "MANUAL")
        reveal(reopened, reopened.buttons["tracker.reopen"]); reopened.buttons["tracker.reopen"].tap()
        let confirm = reopened.buttons.matching(NSPredicate(format: "label == %@", "Reopen goal"))
        confirm.element(boundBy: confirm.count - 1).tap()
        XCTAssertTrue(reopened.buttons["tracker.complete"].waitForExistence(timeout: 10))
    }
    @MainActor func testGroupedEditorAndAlternativeLayout() {
        for alternative in [false, true] {
            let app = launch(extra: alternative ? ["--conditions-flat-expanded"] : [])
            openGoal(app, "GROUPED"); app.buttons["tracker.menu"].tap(); app.buttons["Edit tracker"].tap()
            let outer = element(app, "tracker.conditions.outerCombination"); reveal(app, outer)
            XCTAssertTrue(outer.isEnabled)
            capture(app, alternative ? "Condition groups alternative expanded form" : "Condition groups chosen disclosure form")
            let add = app.buttons["conditions.editor.addGroup"]; reveal(app, add); add.tap()
            let additions = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conditions.editor.addCondition."))
            let addCondition = additions.element(boundBy: additions.count - 1)
            reveal(app, addCondition); addCondition.tap(); app.buttons["conditions.editor.add.weekdays"].tap()
            for day in 1...7 { XCTAssertTrue(element(app, "condition.weekday.\(day)").waitForExistence(timeout: 10)) }
            capture(app, "Seven independent localized weekday toggles")
            app.buttons["condition.cancel"].tap()
            app.buttons["tracker.cancel"].tap(); app.terminate()
        }
    }
    @MainActor func testWeekdayPreferenceReordersCalendarWithoutChangingRecords() {
        let app = launch()
        app.tabBars.buttons.element(boundBy: 3).tap()
        let order = element(app, "settings.firstWeekday"); reveal(app, order); order.tap()
        app.buttons["Monday"].tap()
        openGoal(app, "CHECK")
        let monday = element(app, "calendar.weekday.2"); reveal(app, monday)
        let sunday = element(app, "calendar.weekday.1")
        XCTAssertTrue(sunday.exists)
        XCTAssertLessThan(monday.frame.minX, sunday.frame.minX)
        capture(app, "Monday-first calendar retains true weekday identifiers")
        app.tabBars.buttons.element(boundBy: 3).tap()
        let changed = element(app, "settings.firstWeekday"); reveal(app, changed); changed.tap()
        app.buttons["Sunday"].tap()
        app.tabBars.buttons.element(boundBy: 1).tap()
        let first = element(app, "calendar.weekday.1"); reveal(app, first)
        XCTAssertLessThan(first.frame.minX, element(app, "calendar.weekday.2").frame.minX)
        capture(app, "Sunday-first calendar preference")
    }
    @MainActor func testLocalizedDarkLargeCompletionAndPreferences() {
        for language in ["en", "ja", "zh-Hant"] {
            let app = launch(language: language, dark: true, large: true)
            capture(app, "Milestone grid dark AX maximum " + language)
            app.tabBars.buttons.element(boundBy: 2).tap()
            let score = button(app, prefix: "achievements.tracker.", name: "SCORE")
            XCTAssertTrue(score.waitForExistence(timeout: 10)); score.tap()
            let history = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "achievement.open.")).firstMatch
            XCTAssertTrue(history.waitForExistence(timeout: 10)); history.tap()
            XCTAssertTrue(element(app, "achievement.poster").waitForExistence(timeout: 10))
            capture(app, "Achievement dark AX maximum " + language)
            reveal(app, app.buttons["achievement.copy"])
            XCTAssertTrue(app.buttons["achievement.copy"].isHittable)
            app.tabBars.buttons.element(boundBy: 3).tap()
            reveal(app, element(app, "settings.firstWeekday"))
            XCTAssertTrue(element(app, "settings.firstWeekday").exists)
            capture(app, "First weekday preferences " + language)
            app.terminate()
        }
    }
}
