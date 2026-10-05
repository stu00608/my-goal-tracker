import XCTest
import UIKit

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
        var direction = -1.0
        for _ in 0..<18 {
            if item.exists {
                let frame = item.frame
                if item.isHittable && frame.minY >= app.frame.minY + 120 && frame.maxY <= app.frame.maxY - 110 { return }
                direction = frame.midY < app.frame.midY ? 1 : -1
            }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55 + direction * 0.2))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(rawValue: 220), thenHoldForDuration: 0.2)
        }
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
        let app = launch(extra: ["--milestone-long-checkbox"])
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
        let app = launch(extra: ["--milestone-compare-layout"], large: true)
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
        let comparison = app.switches["achievement.debug.flat"]
        reveal(app, comparison); comparison.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        capture(app, "Completion alternative static left-aligned poster")
        comparison.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.swipeDown()
        let poster = element(app, "achievement.poster")
        let initialY = poster.frame.minY
        poster.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).press(forDuration: 0.1, thenDragTo: poster.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        XCTAssertEqual(poster.frame.minY, initialY, accuracy: 2, "Horizontal relief must not scroll the page")
        poster.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).press(forDuration: 0.05, thenDragTo: poster.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)), withVelocity: XCUIGestureVelocity(rawValue: 220), thenHoldForDuration: 0.2)
        XCTAssertLessThan(poster.frame.minY, initialY - 20, "Vertical starts must scroll the page")
        app.swipeDown()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.4)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.4)))
        XCTAssertTrue(history.waitForExistence(timeout: 5), "The native edge-back gesture must remain available")
        history.tap()
        reveal(app, app.buttons["achievement.copy"])
        app.buttons["achievement.copy"].tap()
        XCTAssertTrue(app.staticTexts["achievement.export.notice"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["achievement.export.notice"].label, "Image copied.")
        XCTAssertTrue(UIPasteboard.general.hasImages, "Copy must publish an image, not only display a notice")
        capture(app, "Native completion image copy confirmed")
        app.buttons["achievement.share"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10) || app.buttons["Copy"].waitForExistence(timeout: 5))
        capture(app, "Native image sharing sheet")
        app.terminate()
        let reopened = XCUIApplication(); reopened.launchArguments = ["--uitesting", "-language", "en", "-homeLayout", "list"]; reopened.launch()
        openGoal(reopened, "MANUAL")
        reveal(reopened, reopened.buttons["tracker.reopen"]); reopened.buttons["tracker.reopen"].tap()
        XCTAssertTrue(reopened.sheets.firstMatch.waitForExistence(timeout: 5))
        reopened.sheets.buttons["Reopen goal"].tap()
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
            reveal(app, additions.firstMatch)
            let count = additions.count
            XCTAssertGreaterThan(count, 0)
            let addCondition = additions.element(boundBy: count - 1)
            reveal(app, addCondition)
            let metadata = XCTAttachment(string: "app frame: \(app.frame); add-condition frame: \(addCondition.frame)")
            metadata.name = "New group add-condition hit area"; metadata.lifetime = .keepAlways; self.add(metadata)
            capture(app, "New group before condition menu")
            addCondition.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
            capture(app, "Native condition menu after direct label tap")
            let weekdays = app.buttons["Weekdays"]
            XCTAssertTrue(weekdays.waitForExistence(timeout: 5))
            weekdays.tap()
            for day in 1...7 { XCTAssertTrue(element(app, "condition.weekday.\(day)").waitForExistence(timeout: 10)) }
            let sunday = element(app, "condition.weekday.1")
            let sundayY = sunday.frame.midY
            for day in 2...7 { XCTAssertEqual(element(app, "condition.weekday.\(day)").frame.midY, sundayY, accuracy: 1) }
            sunday.tap(); XCTAssertEqual(sunday.value as? String, "Off")
            XCTAssertEqual(element(app, "condition.weekday.2").value as? String, "On")
            capture(app, "Seven independent localized weekday toggles")
            app.buttons["condition.confirm"].tap()
            XCTAssertFalse(app.buttons["condition.confirm"].exists)
            let leaves = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conditions.editor.leaf."))
            XCTAssertGreaterThan(leaves.count, 2)
            let deletions = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conditions.editor.deleteGroup."))
            let deletion = deletions.element(boundBy: deletions.count - 1)
            reveal(app, deletion); deletion.tap()
            XCTAssertTrue(app.sheets.buttons["conditions.editor.confirmDelete"].waitForExistence(timeout: 5))
            capture(app, "Nonempty group deletion confirmation")
            app.sheets.buttons["conditions.editor.cancelDelete"].tap()
            XCTAssertTrue(deletion.exists)
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
    @MainActor private func addCondition(_ app: XCUIApplication, kind: String) {
        let add = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conditions.editor.addCondition.")).firstMatch
        reveal(app, add)
        add.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        let item = app.buttons.matching(identifier: "conditions.editor.add." + kind).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
        XCTAssertTrue(app.buttons["condition.confirm"].waitForExistence(timeout: 10))
    }
    @MainActor func testWeekdayConditionLocalizedAtMaximumType() {
        for (language, edit) in [("en", "Edit tracker"), ("ja", "項目を編集"), ("zh-Hant", "編輯追蹤項目")] {
            let app = launch(language: language, dark: true, large: true)
            openGoal(app, "MANUAL"); app.buttons["tracker.menu"].tap(); app.buttons[edit].tap()
            addCondition(app, kind: "weekdays")
            let sunday = element(app, "condition.weekday.1")
            XCTAssertTrue(sunday.waitForExistence(timeout: 5)); sunday.tap()
            for day in 1...7 {
                let item = element(app, "condition.weekday.\(day)")
                XCTAssertGreaterThanOrEqual(item.frame.width, 44)
                XCTAssertGreaterThanOrEqual(item.frame.height, 44)
                XCTAssertEqual(item.frame.midY, sunday.frame.midY, accuracy: 1)
            }
            capture(app, "Weekday on and off outlines dark AX maximum " + language)
            app.buttons["condition.cancel"].tap(); app.buttons["tracker.cancel"].tap(); app.terminate()
        }
    }
    @MainActor func testTypedConditionsPersistAfterEditing() {
        let app = launch()
        openGoal(app, "MANUAL"); app.buttons["tracker.menu"].tap(); app.buttons["Edit tracker"].tap()
        addCondition(app, kind: "time")
        XCTAssertTrue(element(app, "condition.time.start").exists && element(app, "condition.time.end").exists)
        capture(app, "Native inclusive time interval condition")
        app.buttons["condition.confirm"].tap()
        addCondition(app, kind: "steps")
        let steps = app.textFields["condition.health.threshold"]
        steps.tap(); steps.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "9000")
        app.buttons["condition.keyboard.done"].tap()
        element(app, "condition.health.comparison").tap(); app.buttons["Less than"].tap()
        element(app, "condition.health.window").tap(); app.buttons["This month so far"].tap()
        capture(app, "Read-only monthly strict steps condition")
        app.buttons["condition.confirm"].tap()
        addCondition(app, kind: "sleep")
        capture(app, "Read-only daily sleep-hours condition")
        app.buttons["condition.confirm"].tap()
        addCondition(app, kind: "weekdays")
        element(app, "condition.weekday.1").tap(); app.buttons["condition.confirm"].tap()
        let outer = element(app, "tracker.conditions.outerCombination"); reveal(app, outer)
        XCTAssertFalse(outer.isEnabled, "A sole group disables the outer operator")
        let inner = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conditions.editor.combination.")).firstMatch
        XCTAssertTrue(inner.isEnabled, "Multiple leaves retain an active inner operator")
        app.buttons["tracker.save"].tap()
        XCTAssertTrue(app.buttons["tracker.menu"].waitForExistence(timeout: 10))
        app.buttons["tracker.menu"].tap(); app.buttons["Edit tracker"].tap()
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conditions.editor.leaf.")).firstMatch
        reveal(app, first)
        let stepsLeaf = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "conditions.editor.leaf.", "9000")).firstMatch
        reveal(app, stepsLeaf)
        XCTAssertTrue(stepsLeaf.label.contains("<") && stepsLeaf.label.contains("This month so far"))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "conditions.editor.leaf.", "Sleep > 7")).firstMatch.exists)
        stepsLeaf.tap()
        XCTAssertEqual(app.textFields["condition.health.threshold"].value as? String, "9000")
        XCTAssertTrue(element(app, "condition.health.window").label.contains("This month so far"))
        capture(app, "Typed condition threshold and period restored")
        app.buttons["condition.cancel"].tap(); app.buttons["tracker.cancel"].tap()
    }
    @MainActor func testConditionPreviewRemainsResponsiveAcrossMinuteUpdates() {
        let app = launch(extra: ["--condition-gate=unmet"])
        button(app, prefix: "card.", name: "GROUPED").tap()
        XCTAssertTrue(element(app, "conditions.overall").waitForExistence(timeout: 10))
        capture(app, "Condition preview before minute updates")
        // Two real minute boundaries catch the observed native TimelineView/List layout loop.
        for _ in 0..<3 { RunLoop.current.run(until: Date().addingTimeInterval(41)) }
        let start = Date()
        app.buttons["conditions.refresh"].tap()
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "The form must remain responsive after timeline updates")
        XCTAssertTrue(element(app, "conditions.overall").exists)
        capture(app, "Condition preview after two real minute updates")
        app.buttons["entry.cancel"].tap()
        XCTAssertFalse(app.buttons["entry.save"].exists)
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
