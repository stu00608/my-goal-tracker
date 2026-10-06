import XCTest
import UIKit

@MainActor private func tapEditorBack(_ app: XCUIApplication) {
    let back = app.navigationBars.buttons.matching(identifier: "BackButton").allElementsBoundByIndex.first { $0.isHittable }
    XCTAssertNotNil(back)
    back?.tap()
}

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
        for _ in 0..<50 {
            let exists = item.exists
            if exists {
                let frame = item.frame
                if item.isHittable && frame.height > 0 && frame.midY >= app.frame.minY + 120 { return }
                direction = frame.midY < app.frame.midY ? 1 : -1
            }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55 + direction * (exists ? 0.2 : 0.36)))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(rawValue: 220), thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(item.exists); XCTAssertTrue(item.isHittable)
    }
    @MainActor private func openEditorPage(_ app: XCUIApplication, _ id: String) {
        let row = app.buttons.matching(identifier: id).firstMatch; reveal(app, row); row.tap()
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func openGoal(_ app: XCUIApplication, _ name: String) {
        app.tabBars.buttons.element(boundBy: 1).tap()
        let goal = button(app, prefix: "tracker.", name: name); reveal(app, goal); goal.tap()
        XCTAssertTrue(app.buttons["tracker.menu"].waitForExistence(timeout: 10))
    }
    @MainActor func testRingCenterIgnoresHiddenCornerAndKeepsDatePreference() {
        for (language, dark, large) in [("en", false, false), ("ja", true, false), ("zh-Hant", true, true)] {
            let app = launch(extra: ["--milestone-corner=hidden", "--milestone-fraction"], language: language, dark: dark, large: large)
            let score = button(app, prefix: "card.", name: "SCORE")
            XCTAssertTrue(score.waitForExistence(timeout: 10))
            capture(app, "Centered ring with hidden corner preference " + language)
            if language == "en" {
                openGoal(app, "SCORE")
                app.buttons["tracker.menu"].tap(); if app.buttons["Edit tracker"].waitForExistence(timeout: 1) { app.buttons["Edit tracker"].tap() }
                openEditorPage(app, "tracker.appearance")
                let date = app.switches["card.showLastRecorded"]
                reveal(app, date)
                XCTAssertFalse(element(app, "card.textPosition").exists)
                XCTAssertTrue(element(app, "card.ringStyle").exists)
                capture(app, "Ring editor has value style and date without a position picker")
                date.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
                XCTAssertEqual(date.value as? String, "0")
                app.buttons["tracker.save"].tap()
                app.tabBars.buttons.element(boundBy: 0).tap()
                XCTAssertTrue(score.waitForExistence(timeout: 10))
                capture(app, "Centered ring with date hidden")
                // Each tab retains its navigation stack; Goals resumes the open SCORE detail.
                app.tabBars.buttons.element(boundBy: 1).tap()
                XCTAssertTrue(app.buttons["tracker.menu"].waitForExistence(timeout: 10))
                app.buttons["tracker.menu"].tap(); if app.buttons["Edit tracker"].waitForExistence(timeout: 1) { app.buttons["Edit tracker"].tap() }
                openEditorPage(app, "tracker.appearance")
                reveal(app, app.switches["card.showLastRecorded"])
                XCTAssertEqual(app.switches["card.showLastRecorded"].value as? String, "0")
                tapEditorBack(app); app.buttons["tracker.cancel"].tap()
            }
            app.terminate()
        }
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
        let app = launch()
        let card = button(app, prefix: "card.", name: "HEALTH"); reveal(app, card); card.tap()
        XCTAssertTrue(element(app, "conditions.overall").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "conditions.overall").label.contains("Cannot determine yet"))
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "conditions.leaf.")).count, 0)
        element(app, "conditions.overall").tap()
        // Exercise the actual asynchronous HealthKit read/status result, with no gate override.
        // A completed read must appear immediately, before the next minute-clock tick.
        let readResult = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@)",
            "conditions.leaf.", "Set up Apple Health", "No readable samples yet",
            "Could not read Apple Health data", "Apple Health is unavailable" )).firstMatch
        XCTAssertTrue(readResult.waitForExistence(timeout: 10), "Fresh async Health results must not wait for a minute tick")
        XCTAssertFalse(app.buttons["conditions.connectHealth"].exists)
        XCTAssertFalse(app.buttons["conditions.refresh"].exists)
        capture(app, "Health unknown without permanent connection or refresh actions")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Opening a record must not implicitly request permission")
    }
    @MainActor func testHealthSetupConnectsDuringEditingAndRemovesObsoleteButton() {
        for (language, dark, large) in [("en", false, false), ("ja", true, false), ("zh-Hant", true, true)] {
            let app = launch(extra: ["--health-setup=needed"], language: language, dark: dark, large: large)
            openGoal(app, "HEALTH")
            app.buttons["tracker.menu"].tap()
            let editItem = app.buttons[language == "ja" ? "項目を編集" : language == "zh-Hant" ? "編輯追蹤項目" : "Edit tracker"]
            if editItem.waitForExistence(timeout: 1) { editItem.tap() }
            openEditorPage(app, "tracker.conditions")
            let connection = app.buttons["health.connect"]; reveal(app, connection)
            capture(app, "Health connection belongs to tracker setup " + language)
            connection.tap()
            XCTAssertTrue(element(app, "health.configured").waitForExistence(timeout: 10))
            XCTAssertFalse(connection.exists)
            capture(app, "Configured health automatic readable data status " + language)
            app.buttons["health.manage"].tap()
            capture(app, "Health read access guidance " + language)
            app.terminate()
        }
    }
    @MainActor func testAccessibleHealthGuidanceUsesAvailableHeight() {
        let app = launch(extra: ["--health-setup=configured"], dark: true, large: true)
        openGoal(app, "HEALTH")
        app.buttons["tracker.menu"].tap(); if app.buttons["Edit tracker"].waitForExistence(timeout: 1) { app.buttons["Edit tracker"].tap() }
        openEditorPage(app, "tracker.conditions")
        let manage = app.buttons["health.manage"]; reveal(app, manage); manage.tap()
        let title = app.navigationBars["Manage health access"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertLessThan(title.frame.minY, app.frame.height * 0.25)
        capture(app, "AX health access guidance opens at full available sheet height")
    }
    @MainActor func testToastDoesNotShiftGridAndIsDismissible() {
        for language in ["en", "ja", "zh-Hant"] {
            for dark in [false, true] {
                let app = launch(extra: ["--condition-gate=unmet"], language: language, dark: dark, large: language == "zh-Hant")
                let card = button(app, prefix: "card.", name: "GROUPED")
                let action = button(app, prefix: "complete.", name: "GROUPED")
                reveal(app, action); let before = card.frame
                action.tap()
                let toast = app.staticTexts["home.conditions.error"]
                XCTAssertTrue(toast.waitForExistence(timeout: 10))
                XCTAssertEqual(card.frame.minY, before.minY, accuracy: 1)
                XCTAssertTrue(app.buttons["tracker.create"].isHittable, "Toast must not cover navigation")
                capture(app, "Native toast without layout shift " + language + (dark ? " dark" : " light"))
                app.buttons["home.conditions.error.dismiss"].tap()
                XCTAssertFalse(toast.exists)
                XCTAssertFalse(app.buttons["entry.save"].exists)
                app.terminate()
            }
        }
    }
    @MainActor func testManualCompletionExportAndReopen() {
        let app = launch(extra: ["--milestone-compare-layout"], large: true)
        openGoal(app, "MANUAL")
        reveal(app, app.buttons["tracker.complete"]); app.buttons["tracker.complete"].tap()
        reveal(app, app.buttons["tracker.reopen"])
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
        for _ in 0..<4 { app.swipeDown() }
        capture(app, "Completion alternative static left-aligned poster")
        reveal(app, comparison); comparison.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        for _ in 0..<4 { app.swipeDown() }
        let poster = element(app, "achievement.poster")
        let initialFrame = poster.frame
        // At maximum Dynamic Type the poster is taller than the screen. Coordinates based
        // on its full height can hit a tab instead; gesture only within its visible portion.
        let visible = initialFrame.intersection(app.frame.insetBy(dx: 20, dy: 140))
        XCTAssertGreaterThan(visible.height, 200)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let horizontalStart = origin.withOffset(CGVector(dx: visible.minX + visible.width * 0.3, dy: visible.minY + visible.height * 0.4))
        let horizontalEnd = origin.withOffset(CGVector(dx: visible.minX + visible.width * 0.7, dy: visible.minY + visible.height * 0.5))
        horizontalStart.press(forDuration: 0.1, thenDragTo: horizontalEnd)
        XCTAssertEqual(poster.frame.minY, initialFrame.minY, accuracy: 2, "Horizontal relief must not scroll the page")
        let verticalStart = origin.withOffset(CGVector(dx: visible.midX, dy: visible.midY + 75))
        let verticalEnd = origin.withOffset(CGVector(dx: visible.midX, dy: visible.midY - 75))
        verticalStart.press(forDuration: 0.05, thenDragTo: verticalEnd, withVelocity: XCUIGestureVelocity(rawValue: 220), thenHoldForDuration: 0.2)
        XCTAssertTrue(poster.waitForExistence(timeout: 5), "A short scroll within the card must keep its detail open")
        XCTAssertLessThan(poster.frame.minY, initialFrame.minY - 20, "Vertical starts must scroll the page")
        capture(app, "Visible poster vertical start scrolls without switching tabs")
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
            openGoal(app, "GROUPED"); app.buttons["tracker.menu"].tap(); if app.buttons["Edit tracker"].waitForExistence(timeout: 1) { app.buttons["Edit tracker"].tap() }
            openEditorPage(app, "tracker.conditions")
            let outer = element(app, "tracker.conditions.outerCombination"); reveal(app, outer)
            XCTAssertTrue(outer.isEnabled)
            let firstLeaf = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conditions.editor.leaf.")).firstMatch
            reveal(app, firstLeaf)
            capture(app, alternative ? "Condition groups alternative expanded form" : "Condition groups chosen disclosure form")
            let add = app.buttons["conditions.editor.addGroup"]; reveal(app, add); add.tap()
            let additions = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conditions.editor.addCondition."))
            reveal(app, additions.element(boundBy: additions.count - 1))
            // The visible button belongs to the newly inserted group. Preserve its identity:
            // lazy Form rows can reorder/disappear in the accessibility query during scrolling.
            let newGroupButtonID = additions.element(boundBy: additions.count - 1).identifier
            let addCondition = app.buttons[newGroupButtonID]
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
            sunday.tap(); XCTAssertEqual(sunday.value as? String, "0")
            XCTAssertEqual(element(app, "condition.weekday.2").value as? String, "1")
            capture(app, "Seven independent localized weekday toggles")
            app.buttons["condition.confirm"].tap()
            XCTAssertFalse(app.buttons["condition.confirm"].exists)
            let leaves = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conditions.editor.leaf."))
            XCTAssertGreaterThan(leaves.count, 2)
            let groupID = newGroupButtonID.replacingOccurrences(of: "conditions.editor.addCondition.", with: "")
            let deletion = app.buttons["conditions.editor.deleteGroup." + groupID]
            reveal(app, deletion); deletion.tap()
            XCTAssertTrue(app.buttons.matching(identifier: "conditions.editor.confirmDelete").firstMatch.waitForExistence(timeout: 5))
            capture(app, "Nonempty group deletion confirmation")
            let cancelDeletion = app.buttons.matching(identifier: "conditions.editor.cancelDelete").firstMatch
            if cancelDeletion.exists { cancelDeletion.tap() }
            else {
                // iOS 26 presents this native confirmation as a popover: cancel is tapping outside.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.6)).tap()
            }
            XCTAssertTrue(app.buttons.matching(identifier: "conditions.editor.confirmDelete").firstMatch.waitForNonExistence(timeout: 5))
            XCTAssertTrue(deletion.exists)
            tapEditorBack(app); app.buttons["tracker.cancel"].tap(); app.terminate()
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
        XCTAssertTrue(monday.waitForExistence(timeout: 5))
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
        if app.textFields["tracker.name"].exists { openEditorPage(app, "tracker.conditions") }
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
            openGoal(app, "MANUAL"); app.buttons["tracker.menu"].tap(); if app.buttons[edit].waitForExistence(timeout: 1) { app.buttons[edit].tap() }
            addCondition(app, kind: "weekdays")
            let sunday = element(app, "condition.weekday.1")
            XCTAssertTrue(sunday.waitForExistence(timeout: 5)); sunday.tap()
            for day in 1...7 {
                let item = element(app, "condition.weekday.\(day)")
                XCTAssertGreaterThanOrEqual(item.frame.width.rounded(), 44)
                XCTAssertGreaterThanOrEqual(item.frame.height.rounded(), 44)
                XCTAssertEqual(item.frame.midY, sunday.frame.midY, accuracy: 1)
            }
            capture(app, "Weekday on and off outlines dark AX maximum " + language)
            app.buttons["condition.cancel"].tap(); tapEditorBack(app); app.buttons["tracker.cancel"].tap(); app.terminate()
        }
    }
    @MainActor func testTypedConditionsPersistAfterEditing() {
        let app = launch()
        openGoal(app, "MANUAL"); app.buttons["tracker.menu"].tap(); if app.buttons["Edit tracker"].waitForExistence(timeout: 1) { app.buttons["Edit tracker"].tap() }
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
        let outer = element(app, "tracker.conditions.outerCombination")
        XCTAssertFalse(outer.exists, "A sole group hides the outer operator")
        let inner = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conditions.editor.combination.")).firstMatch
        XCTAssertTrue(inner.isEnabled, "Multiple leaves retain an active inner operator")
        app.buttons["tracker.save"].tap()
        XCTAssertTrue(app.buttons["tracker.menu"].waitForExistence(timeout: 10))
        app.buttons["tracker.menu"].tap(); if app.buttons["Edit tracker"].waitForExistence(timeout: 1) { app.buttons["Edit tracker"].tap() }
        openEditorPage(app, "tracker.conditions")
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
        app.buttons["condition.cancel"].tap(); tapEditorBack(app); app.buttons["tracker.cancel"].tap()
    }
    @MainActor func testConditionPreviewRemainsResponsiveAcrossMinuteUpdates() {
        let app = launch(extra: ["--condition-gate=unmet"])
        button(app, prefix: "card.", name: "GROUPED").tap()
        XCTAssertTrue(element(app, "conditions.overall").waitForExistence(timeout: 10))
        capture(app, "Condition preview before minute updates")
        // Two real minute boundaries catch the observed native TimelineView/List layout loop.
        for _ in 0..<3 { RunLoop.current.run(until: Date().addingTimeInterval(41)) }
        let start = Date()
        XCTAssertFalse(app.buttons["conditions.refresh"].exists)
        app.buttons["entry.cancel"].tap()
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "The form must remain responsive after timeline updates")
        XCTAssertFalse(app.buttons["entry.save"].exists)
        capture(app, "Condition preview remains cancellable after automatic minute updates")
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

nonisolated final class TrackerEditorFlows: XCTestCase {
    @MainActor private func launch(_ language: String = "en", dark: Bool = false, large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-test-store", "--feature-test-fixture", "--goalooker-test-fixture", "--milestones-test-fixture", "--health-setup=needed", "-language", language, "-appearance", dark ? "dark" : "light", "-homeLayout", "grid", "-firstWeekday", "2", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch(); return app
    }
    @MainActor private func item(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    @MainActor private func reveal(_ app: XCUIApplication, _ item: XCUIElement) {
        for _ in 0..<50 {
            if item.exists && item.isHittable && item.frame.midY > 160 { return }
            let direction = item.exists && item.frame.midY < app.frame.midY ? 1.0 : -1.0
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55 + direction * (item.exists ? 0.2 : 0.36)))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(rawValue: 220), thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(item.isHittable)
    }
    @MainActor private func page(_ app: XCUIApplication, _ id: String) {
        let row = app.buttons.matching(identifier: id).firstMatch; reveal(app, row); row.tap()
    }
    @MainActor private func back(_ app: XCUIApplication) { tapEditorBack(app) }
    @MainActor private func edit(_ app: XCUIApplication, _ name: String) {
        app.tabBars.buttons.element(boundBy: 1).tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "tracker.", name)).firstMatch
        reveal(app, row); row.tap(); app.buttons["tracker.menu"].tap()
        let edit = app.buttons.matching(NSPredicate(format: "label IN %@", ["Edit tracker", "編輯追蹤項目", "項目を編集"])).firstMatch
        if edit.waitForExistence(timeout: 1) { edit.tap() }
    }
    @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.7)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "W2_" + name
        attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testFirstConditionAndSubpagesPreserveDraft() {
        let app = launch()
        app.buttons["tracker.create"].tap()
        let name = app.textFields["tracker.name"]
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Creation autofocuses the name")
        if app.buttons["Continue"].waitForExistence(timeout: 1) { app.buttons["Continue"].tap() }
        name.typeText("EDITOR DRAFT\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        page(app, "tracker.conditions")
        XCTAssertFalse(item(app, "tracker.conditions.gate").exists)
        XCTAssertFalse(app.buttons["conditions.editor.addGroup"].exists)
        XCTAssertFalse(app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conditions.editor.name.")).firstMatch.exists)
        shot(app, "Empty_conditions")
        let add = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conditions.editor.addCondition.")).firstMatch
        add.tap(); app.buttons["conditions.editor.add.weekdays"].tap()
        let monday = item(app, "condition.weekday.2"), sunday = item(app, "condition.weekday.1")
        XCTAssertTrue(monday.waitForExistence(timeout: 5))
        XCTAssertLessThan(monday.frame.minX, sunday.frame.minX)
        sunday.tap(); XCTAssertEqual(sunday.value as? String, "0")
        app.buttons["condition.confirm"].tap()
        XCTAssertTrue(item(app, "tracker.conditions.gate").waitForExistence(timeout: 5))
        XCTAssertFalse(item(app, "tracker.conditions.outerCombination").exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conditions.editor.combination.")).firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conditions.editor.deleteGroup.")).firstMatch.exists)
        let groupName = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conditions.editor.name.")).firstMatch
        let groupNameID = groupName.identifier
        groupName.tap(); groupName.typeText("DRAFT GROUP"); app.buttons["tracker.keyboard.done"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conditions.editor.leaf.")).firstMatch.press(forDuration: 1)
        app.buttons.matching(NSPredicate(format: "label == %@", "Delete condition")).firstMatch.tap()
        XCTAssertFalse(item(app, "tracker.conditions.gate").exists)
        XCTAssertFalse(groupName.exists)
        add.tap(); app.buttons["conditions.editor.add.weekdays"].tap(); app.buttons["condition.confirm"].tap()
        XCTAssertEqual(app.textFields[groupNameID].value as? String, "DRAFT GROUP", "Replacing the last condition preserves the group's identity and name")
        back(app)
        XCTAssertTrue(app.buttons["tracker.conditions"].label.contains("1 condition"))
        page(app, "tracker.content")
        let text = item(app, "tracker.description")
        text.tap(); text.typeText("Draft description")
        app.buttons["tracker.keyboard.done"].tap(); back(app)
        page(app, "tracker.content")
        XCTAssertEqual(text.value as? String, "Draft description")
        app.buttons["tracker.save"].tap()
        XCTAssertTrue(app.buttons["tracker.create"].waitForExistence(timeout: 10))
        edit(app, "EDITOR DRAFT"); page(app, "tracker.conditions")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conditions.editor.leaf.")).count, 1)
        back(app); app.buttons["tracker.cancel"].tap()
    }
    @MainActor func testEditorArchiveAndConfirmedDeleteDismiss() {
        var app = launch(); edit(app, "MANUAL")
        page(app, "tracker.archive")
        XCTAssertTrue(app.buttons["tracker.cancel"].waitForNonExistence(timeout: 5))
        app.tabBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "card.", "MANUAL")).firstMatch.exists)
        app.terminate(); app = launch(); edit(app, "MANUAL")
        page(app, "tracker.delete")
        XCTAssertTrue(app.buttons["tracker.delete.confirm"].waitForExistence(timeout: 5))
        shot(app, "Delete_confirmation")
        app.buttons.matching(identifier: "tracker.delete.confirm").firstMatch.tap()
        XCTAssertTrue(app.buttons["tracker.cancel"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Tracker removed"].waitForExistence(timeout: 5))
    }
    @MainActor func testDraftGoalPreviewUsesEditedTarget() {
        let app = launch(); edit(app, "SCORE")
        let target = app.textFields["goal.target"]
        reveal(app, target); target.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.5)).tap()
        let prior = target.value as? String ?? ""
        target.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: prior.count) + "42")
        XCTAssertEqual(target.value as? String, "42")
        app.buttons["tracker.keyboard.done"].tap()
        page(app, "tracker.appearance")
        let background = item(app, "tracker.cardBackground")
        if !(background.label + " " + (background.value as? String ?? "")).contains("Goal progress") {
            background.tap()
            let choices = app.buttons.matching(NSPredicate(format: "label == %@", "Goal progress"))
            let choice = choices.allElementsBoundByIndex.first { $0.isHittable }
            XCTAssertNotNil(choice); choice?.tap()
            if app.buttons.matching(NSPredicate(format: "label == %@", "Chart")).allElementsBoundByIndex.contains(where: { $0.isHittable }) {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
            }
        }
        let preview = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "tracker.preview", "SCORE")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let value = preview.value as? String ?? ""
        shot(app, "Edited_target_preview")
        XCTAssertTrue(value.contains("42.000"), "Preview uses the edited goal at the same reference time: " + value)
        back(app); app.buttons["tracker.cancel"].tap()
    }
    @MainActor func testSharedWeekdaysReminderPersists() {
        let app = launch(); edit(app, "MANUAL")
        page(app, "tracker.reminders"); page(app, "tracker.reminders.schedule")
        let enabled = app.switches["reminder.enabled"]
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let sunday = item(app, "reminder.weekday.1"), monday = item(app, "reminder.weekday.2")
        XCTAssertTrue(monday.waitForExistence(timeout: 5))
        XCTAssertLessThan(monday.frame.minX, sunday.frame.minX)
        sunday.tap(); XCTAssertEqual(sunday.value as? String, "0")
        back(app); back(app); app.buttons["tracker.save"].tap()
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.waitForExistence(timeout: 3) {
            let allow = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "允許", "許可"])).firstMatch
            if allow.exists { allow.tap() }
        }
        XCTAssertTrue(app.buttons["tracker.menu"].waitForExistence(timeout: 10))
        app.buttons["tracker.menu"].tap(); if app.buttons["Edit tracker"].waitForExistence(timeout: 1) { app.buttons["Edit tracker"].tap() }
        page(app, "tracker.reminders"); page(app, "tracker.reminders.schedule")
        XCTAssertEqual(item(app, "reminder.weekday.1").value as? String, "0")
        XCTAssertEqual(item(app, "reminder.weekday.2").value as? String, "1")
    }
}
