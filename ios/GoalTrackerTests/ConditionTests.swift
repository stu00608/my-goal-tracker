import Foundation
import CoreLocation
import UserNotifications
import Testing
@testable import GoalTracker

@MainActor struct ConditionTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let center = RecordedLocation(latitude: 0, longitude: 0)

    @Test func distanceBoundaryIncludesUncertaintyAndOutsideIsStrict() {
        #expect(ConditionEvaluation.state(distance: 180, accuracy: 20, relation: .inside) == .met)
        #expect(ConditionEvaluation.state(distance: 180, accuracy: 20, relation: .outside) == .unmet)
        #expect(ConditionEvaluation.state(distance: 200, accuracy: 0, relation: .inside) == .met)
        #expect(ConditionEvaluation.state(distance: 200, accuracy: 0, relation: .outside) == .unmet)
        #expect(ConditionEvaluation.state(distance: 220, accuracy: 20, relation: .inside) == .unknown)
        #expect(ConditionEvaluation.state(distance: 220.001, accuracy: 20, relation: .outside) == .met)
        #expect(ConditionEvaluation.state(distance: 190, accuracy: 20, relation: .inside) == .unknown)
        #expect(ConditionEvaluation.state(distance: 190, accuracy: 20, relation: .outside) == .unknown)
        for accuracy in [-1.0, .infinity, .nan] {
            #expect(ConditionEvaluation.state(distance: 0, accuracy: accuracy, relation: .inside) == .unknown)
        }
        #expect(ConditionEvaluation.state(distance: .nan, accuracy: 0, relation: .outside) == .unknown)
    }

    @Test func liveGeodesicFixMustBeFreshAndValid() {
        let condition = PlaceCondition(name: "Center", location: center)
        let fix = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0.001),
                             altitude: 0, horizontalAccuracy: 10, verticalAccuracy: -1, timestamp: now)
        #expect(ConditionEvaluation.state(condition, fix: fix, now: now) == .met)
        #expect(ConditionEvaluation.state(condition, fix: fix, now: now.addingTimeInterval(60)) == .met)
        #expect(ConditionEvaluation.state(condition, fix: fix, now: now.addingTimeInterval(60.001)) == .unknown)
        #expect(ConditionEvaluation.state(condition, fix: fix, now: now.addingTimeInterval(-6)) == .unknown)
        var invalid = condition; invalid.location.latitude = 91
        #expect(ConditionEvaluation.state(invalid, fix: fix, now: now) == .unknown)
    }

    @Test func conservativeAllAnyAndEmptyConditions() throws {
        #expect(ConditionEvaluation.aggregate([.met, .unknown], combination: .all) == .unknown)
        #expect(ConditionEvaluation.aggregate([.met, .unknown], combination: .any) == .met)
        #expect(ConditionEvaluation.aggregate([.unmet, .unknown], combination: .all) == .unmet)
        #expect(ConditionEvaluation.aggregate([.unmet, .unknown], combination: .any) == .unknown)
        #expect(ConditionEvaluation.aggregate([.met, .met], combination: .all) == .met)
        #expect(ConditionEvaluation.aggregate([.unmet, .unmet], combination: .any) == .unmet)
        #expect(ConditionEvaluation.aggregate([], combination: .all) == .unknown)
        #expect(ConditionEvaluation.aggregate([], combination: .any) == .unknown)
        try ConditionEvaluation.requireMet(.met)
        #expect(throws: ConditionError.self) { try ConditionEvaluation.requireMet(.unknown) }
        #expect(throws: ConditionError.self) { try ConditionEvaluation.requireMet(.unmet) }
        do { try ConditionEvaluation.requireMet(.unknown) }
        catch let error as ConditionError {
            #expect(error.key == "Could not verify the achievement conditions. Check their status and try again.")
        }
    }

    @Test func outsideNativeStateInvertsAndOldStatesStayUnknown() {
        #expect(ConditionPlan.state(inside: .met, date: now, relation: .outside, now: now) == .unmet)
        #expect(ConditionPlan.state(inside: .unmet, date: now, relation: .outside, now: now) == .met)
        #expect(ConditionPlan.state(inside: .unknown, date: now, relation: .outside, now: now) == .unknown)
        #expect(ConditionPlan.state(inside: .met, date: now.addingTimeInterval(-43_200), relation: .inside, now: now) == .met)
        #expect(ConditionPlan.state(inside: .met, date: now.addingTimeInterval(-43_201), relation: .inside, now: now) == .unknown)
        #expect(ConditionPlan.state(inside: .unmet, date: now.addingTimeInterval(-43_201), relation: .outside, now: now) == .unknown)
    }

    @Test func permissionDiagnosticsGlobalOffAndStaleEventsNeverTrigger() {
        #expect(ConditionPlan.mayNotify(transition: true, eventState: .met, eventDate: now, now: now, enabled: true, authorized: true))
        #expect(!ConditionPlan.mayNotify(transition: true, eventState: .unknown, eventDate: now, now: now, enabled: true, authorized: true))
        #expect(!ConditionPlan.mayNotify(transition: true, eventState: .met, eventDate: now, now: now, enabled: false, authorized: true))
        #expect(!ConditionPlan.mayNotify(transition: true, eventState: .met, eventDate: now, now: now, enabled: true, authorized: false))
        #expect(!ConditionPlan.mayNotify(transition: true, eventState: .met, eventDate: now.addingTimeInterval(-61), now: now, enabled: true, authorized: true))
        #expect(!ConditionPlan.mayNotify(transition: false, eventState: .met, eventDate: now, now: now, enabled: true, authorized: true))
    }

    @Test func missingGlobalPreferencePreservesOldRemindersAndCapacityKeepsForeignProviders() throws {
        let suite = "ConditionTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(Reminders.globalEnabled(defaults))
        defaults.set(false, forKey: "remindersEnabled"); #expect(!Reminders.globalEnabled(defaults))
        defaults.set(true, forKey: "remindersEnabled"); #expect(Reminders.globalEnabled(defaults))
        let adding = Reminders.conditionIdentifier(UUID())
        #expect(Reminders.hasCapacity(planned: 58, pending: ["foreign.provider"], adding: adding))
        #expect(!Reminders.hasCapacity(planned: 59, pending: ["foreign.provider"], adding: adding))
        #expect(Reminders.hasCapacity(planned: 59, pending: [adding], adding: adding))
        #expect(!Reminders.hasCapacity(planned: 59, pending: [Reminders.conditionIdentifier(UUID())], adding: adding))
    }

    @Test func newAnyConfigurationWaitsForAllInitialNativeStatesAndPrimesSilently() {
        var state = ConditionTransition(signature: "A")
        let transition1 = state.observe(.met, signature: "A", now: now, initialStatesKnown: false)
        #expect(!transition1)
        #expect(state.aggregate == nil)
        let transition2 = state.observe(.met, signature: "A", now: now, initialStatesKnown: true)
        #expect(!transition2)
        #expect(state.aggregate == true && state.lastNotifiedAt == nil)
        let transition3 = state.observe(.met, signature: "A", now: now.addingTimeInterval(60))
        #expect(!transition3)
        let transition4 = state.observe(.unmet, signature: "A", now: now.addingTimeInterval(120))
        #expect(!transition4)
        let transition5 = state.observe(.met, signature: "A", now: now.addingTimeInterval(180))
        #expect(transition5)
    }

    @Test func warmBackgroundRelaunchPreservesFalseToTrueAndCooldownAcrossEncoding() throws {
        let saved = ConditionTransition(signature: "A", aggregate: false, lastNotifiedAt: now.addingTimeInterval(-7200))
        var state = try JSONDecoder().decode(ConditionTransition.self, from: JSONEncoder().encode(saved))
        let transition6 = state.observe(.met, signature: "A", now: now)
        #expect(transition6)
        state.delivered(at: now)
        let transition7 = state.observe(.met, signature: "A", now: now.addingTimeInterval(1))
        #expect(!transition7)
        let transition8 = state.observe(.unmet, signature: "A", now: now.addingTimeInterval(2))
        #expect(!transition8)
        let transition9 = state.observe(.met, signature: "A", now: now.addingTimeInterval(7199))
        #expect(!transition9)
        let transition10 = state.observe(.unmet, signature: "A", now: now.addingTimeInterval(7200))
        #expect(!transition10)
        let transition11 = state.observe(.met, signature: "A", now: now.addingTimeInterval(7200))
        #expect(transition11)
    }

    @Test func changedConfigurationAndGlobalReenablePrimeWithoutErasingCooldown() {
        var state = ConditionTransition(signature: "A", aggregate: false, lastNotifiedAt: now)
        let transition12 = state.observe(.met, signature: "B", now: now.addingTimeInterval(7200))
        #expect(!transition12)
        #expect(state.signature == "B" && state.aggregate == true)
        state.reset()
        #expect(state.aggregate == nil && state.lastNotifiedAt == now)
        let transition13 = state.observe(.met, signature: "B", now: now.addingTimeInterval(8000))
        #expect(!transition13)
        let transition14 = state.observe(.unknown, signature: "B", now: now.addingTimeInterval(8001))
        #expect(!transition14)
        let transition15 = state.observe(.met, signature: "B", now: now.addingTimeInterval(8002))
        #expect(!transition15)
    }

    @Test func unknownDoesNotManufactureExitButKeepsKnownUnmetTransition() {
        var state = ConditionTransition(signature: "A", aggregate: true)
        let uncertain = state.observe(.unknown, signature: "A", now: now)
        #expect(!uncertain && state.aggregate == true)
        let regained = state.observe(.met, signature: "A", now: now.addingTimeInterval(10))
        #expect(!regained)
        let exit = state.observe(.unmet, signature: "A", now: now.addingTimeInterval(20))
        #expect(!exit && state.aggregate == false)
        let uncertainAfterExit = state.observe(.unknown, signature: "A", now: now.addingTimeInterval(30))
        #expect(!uncertainAfterExit && state.aggregate == false)
        let realEntry = state.observe(.met, signature: "A", now: now.addingTimeInterval(40))
        #expect(realEntry)
    }

    @Test func uniqueRoundedCentersShareCapacityRegardlessOfInsideOutside() throws {
        var trackers: [Tracker] = []
        for index in 0..<20 {
            var t = Tracker(name: "Place \(index)", kind: .daily)
            t.remindWhenMet = true
            let place = RecordedLocation(latitude: Double(index), longitude: 0)
            t.conditions = [PlaceCondition(name: "Inside", location: place),
                            PlaceCondition(name: "Outside", location: place, relation: .outside)]
            trackers.append(t)
        }
        #expect(try ConditionPlan.centers(trackers).count == 20)
        var duplicate = trackers[0]
        duplicate.id = UUID()
        duplicate.conditions = [PlaceCondition(name: "Nearby rounded center", location: RecordedLocation(latitude: 0.000001, longitude: 0.000001))]
        trackers.append(duplicate)
        #expect(try ConditionPlan.centers(trackers).count == 20)
        var extra = duplicate
        extra.id = UUID(); extra.conditions = [PlaceCondition(name: "21st", location: RecordedLocation(latitude: 30, longitude: 0))]
        trackers.append(extra)
        #expect(throws: ConditionError.self) { try ConditionPlan.centers(trackers) }
        trackers[trackers.count - 1].archived = true
        #expect(try ConditionPlan.centers(trackers).count == 20)
        trackers[trackers.count - 1].archived = false; trackers[trackers.count - 1].remindWhenMet = false
        #expect(try ConditionPlan.centers(trackers).count == 20)
    }

    @Test func conditionSignaturesTrackIntentAndIgnoreOrderingAndMetadata() {
        var t = Tracker(name: "Original", kind: .daily)
        t.conditions = [PlaceCondition(name: "A", location: center),
                        PlaceCondition(name: "B", location: RecordedLocation(latitude: 1, longitude: 1))]
        let original = ConditionPlan.signature(t)
        t.name = "Renamed"; t.description = "Notes"; t.conditions?.reverse()
        #expect(ConditionPlan.signature(t) == original)
        t.conditionCombination = .all
        #expect(ConditionPlan.signature(t) != original)
        t.conditionCombination = .any; t.conditions?[0].relation = .outside
        #expect(ConditionPlan.signature(t) != original)
    }

    @Test func reminderCalendarTimezoneDeadlineOwnershipAndArchive() throws {
        var t = Tracker(name: "Calendar", kind: .number)
        t.timeZoneID = "Asia/Tokyo"
        t.reminder = Reminder(hour: 9, minute: 15, weekdays: [1, 2])
        let due = now.addingTimeInterval(86400 * 4)
        t.rules = [GoalRule(period: .deadline, target: "10", effectiveAt: now.addingTimeInterval(-1), deadline: due)]
        let requests = try Reminders.requests([t], now: now)
        #expect(requests.count == 3)
        let weekly = try #require(requests.first?.trigger as? UNCalendarNotificationTrigger)
        #expect(weekly.repeats && weekly.dateComponents.weekday == 1 && weekly.dateComponents.hour == 9)
        #expect(weekly.dateComponents.timeZone?.identifier == "Asia/Tokyo")
        #expect(requests.allSatisfy { Reminders.owns($0.identifier) })
        #expect(requests.allSatisfy { ($0.content.userInfo["url"] as? String) == "goaltracker://record/" + t.id.uuidString })
        #expect(Reminders.owns(Reminders.conditionIdentifier(t.id)))
        for foreign in ["provider.alert", t.id.uuidString + ".8", t.id.uuidString + ".01",
                        "goalooker.condition.provider", t.id.uuidString + ".1.more"] { #expect(!Reminders.owns(foreign)) }
        #expect(try Reminders.requests([t], now: now, enabled: false).isEmpty)
        t.archived = true
        #expect(try Reminders.requests([t], now: now).isEmpty)
    }

    @Test func reminderCapsIncludeLatentConditionSlots() throws {
        var trackers = (0..<8).map { index in
            var t = Tracker(name: "\(index)", kind: .daily)
            t.reminder = Reminder(hour: 12, minute: 0, weekdays: Array(1...7))
            return t
        }
        #expect(try Reminders.requests(trackers).count == 56)
        var extra = Tracker(name: "Extra", kind: .daily)
        extra.reminder = Reminder(hour: 12, minute: 0, weekdays: [1, 2, 3, 4])
        trackers.append(extra)
        #expect(try Reminders.requests(trackers).count == 60)
        trackers[0].remindWhenMet = true
        trackers[0].conditions = [PlaceCondition(name: "Gate", location: center)]
        #expect(throws: DataError.self) { try Reminders.validate(trackers) }
        trackers[8].reminder?.weekdays.append(5)
        #expect(throws: DataError.self) { try Reminders.requests(trackers) }
    }

    @Test func deadlineRemindersUseSuppliedNowAndKeepHistoricalEverHitSemantics() throws {
        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        var t = Tracker(name: "Reference clock", kind: .number)
        t.timeZoneID = "UTC"; t.reminder = Reminder(hour: 12, minute: 0, weekdays: [2])
        let rule = GoalRule(period: .deadline, target: "10", effectiveAt: reference.addingTimeInterval(-3600),
                            deadline: reference.addingTimeInterval(86_400 * 4))
        t.rules = [rule]
        let futureHit = reference.addingTimeInterval(3600)
        t.entries = [Entry(occurredAt: futureHit, localDay: t.day(futureHit), value: "10")]
        #expect(try Reminders.requests([t], now: reference).contains { $0.identifier == t.id.uuidString + ".deadline" })
        #expect(try !Reminders.requests([t], now: futureHit).contains { $0.identifier == t.id.uuidString + ".deadline" })
        let historical = reference.addingTimeInterval(-7200)
        t.entries = [Entry(occurredAt: historical, localDay: t.day(historical), value: "10"),
                     Entry(occurredAt: reference, localDay: t.day(reference), value: "2")]
        #expect(try !Reminders.requests([t], now: reference).contains { $0.identifier == t.id.uuidString + ".deadline" })
    }

    @Test func metadataWebsiteAndDecimalAxisValidationPreservePrecision() throws {
        #expect(try TrackerFields.website("  https://example.com/a?q=1  ") == "https://example.com/a?q=1")
        #expect(try TrackerFields.website("") == nil)
        for bad in ["ftp://example.com", "javascript:alert(1)", "https://", "example.com"] {
            #expect(throws: ConditionError.self) { try TrackerFields.website(bad) }
        }
        let bounds = try TrackerFields.axis(lower: "-0,123456789123456789", upper: "", locale: Locale(identifier: "fr_FR"))
        #expect(bounds.0 == "-0.123456789123456789" && bounds.1 == nil)
        #expect(throws: ConditionError.self) { try TrackerFields.axis(lower: "0", upper: "0", locale: .current) }
        #expect(throws: ConditionError.self) { try TrackerFields.axis(lower: "10", upper: "-10", locale: .current) }
        #expect(throws: DataError.self) { try TrackerFields.axis(lower: "1e3", upper: "", locale: .current) }
    }

    @Test func ungatedSaveAndCanceledTaskNeverRequestLocation() async throws {
        var tracker = Tracker(name: "No gate", kind: .daily)
        tracker.conditions = [PlaceCondition(name: "Place", location: center)]
        #expect(!tracker.requiresLocationGate)
        try await RecordConditions.verify(tracker: tracker)
        tracker.gateSave = true; tracker.conditions = []
        #expect(!tracker.requiresLocationGate)
        try await RecordConditions.verify(tracker: tracker)
        let task = Task { try await RecordConditions.verify(tracker: tracker) }
        task.cancel()
        do { try await task.value; Issue.record("Canceled verification must throw") }
        catch { #expect(error is CancellationError) }
    }
    @Test func unarchiveAndRestoreRejectAggregateCapacityBeforePersisting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store")
        let store = try AppStore(url: url)
        var archived = Tracker(name: "Twenty places", kind: .daily)
        archived.conditions = (0..<20).map { index in
            PlaceCondition(name: "Place \(index)", location: RecordedLocation(latitude: Double(index) / 10_000, longitude: 0))
        }
        archived.remindWhenMet = true; archived.archived = true
        var active = Tracker(name: "Another place", kind: .daily)
        active.conditions = [PlaceCondition(name: "Other", location: RecordedLocation(latitude: 1, longitude: 1))]
        active.remindWhenMet = true
        try store.replace([archived, active])
        let original = store.trackers
        var unarchived = archived; unarchived.archived = false
        let overCapacity = try Backup(version: 2, trackers: [unarchived, active]).encoded()
        let preference = L.defaults.object(forKey: "remindersEnabled")
        defer {
            if let preference { L.defaults.set(preference, forKey: "remindersEnabled") }
            else { L.defaults.removeObject(forKey: "remindersEnabled") }
        }
        for enabled in [false, true] {
            L.defaults.set(enabled, forKey: "remindersEnabled")
            #expect(throws: (any Error).self) { try store.save(unarchived) }
            #expect(throws: (any Error).self) { try store.restore(overCapacity) }
            #expect(store.trackers == original)
            #expect(try AppStore(url: url).trackers == original)
        }
        // Removing the other reminder leaves exactly 20 centers and permits reactivation.
        active.remindWhenMet = false
        try store.save(active); try store.save(unarchived)
        #expect(try ConditionPlan.centers(store.trackers).count == 20)
        #expect(store.trackers.first { $0.id == archived.id }?.archived == false)
    }

}
