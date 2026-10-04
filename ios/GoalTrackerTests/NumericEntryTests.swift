import Foundation
import Testing
@testable import GoalTracker

struct NumericEntryTests {
    @Test func defaultModeAppliesOnlyToNewEntriesWithBaseline() {
        #expect(NumericEntryMode.initial(preference: "change", hasBaseline: true, editing: false) == .change)
        #expect(NumericEntryMode.initial(preference: "change", hasBaseline: false, editing: false) == .direct)
        #expect(NumericEntryMode.initial(preference: "change", hasBaseline: true, editing: true) == .direct)
        #expect(NumericEntryMode.initial(preference: "direct", hasBaseline: true, editing: false) == .direct)
        #expect(NumericEntryMode.initial(preference: "unknown", hasBaseline: true, editing: false) == .direct)
    }

    @Test func scrubQuantumCoversEveryDisplayPrecisionWithoutRoundingStoredDigits() throws {
        for precision in 0...8 {
            let expected = precision == 0 ? "1" : "0." + String(repeating: "0", count: precision - 1) + "1"
            #expect(try NumericEntry.adjust("", precision: precision, steps: 1, locale: locale) == expected)
            #expect(try NumericEntry.adjust("", precision: precision, steps: -1, locale: locale) == "-" + expected)
        }
        #expect(try NumericEntry.adjust("1.123456789012345678901234567", precision: 3, steps: 1, locale: locale) == "1.124456789012345678901234567")
        #expect(try NumericEntry.adjust("1,123456789", precision: 8, steps: -2, locale: Locale(identifier: "fr_FR")) == "1,123456769")
        #expect(try NumericEntry.adjust("-0.01", precision: 2, steps: 2, locale: locale) == "0.01")
        #expect(throws: DataError.invalidNumber) { try NumericEntry.adjust("9999999999999999999999999999", precision: 0, steps: 1, locale: locale) }
        #expect(throws: DataError.invalidNumber) { try NumericEntry.quantum(precision: 9) }
    }

    @Test func scrubUsesFrozenOriginAndTwelvePointTicksIncludingReturnToRawOrigin() throws {
        #expect(NumericEntry.scrubSteps(translation: -11.99) == 0)
        #expect(NumericEntry.scrubSteps(translation: -12) == 1)
        #expect(NumericEntry.scrubSteps(translation: -35.99) == 2)
        #expect(NumericEntry.scrubSteps(translation: 24) == -2)
        #expect(NumericEntry.scrubSteps(translation: .infinity) == nil)
        #expect(NumericEntry.scrubSteps(translation: .nan) == nil)
        let origin = "01.2300"
        #expect(try NumericEntry.adjust(origin, precision: 2, steps: 3, locale: locale) == "1.26")
        #expect(try NumericEntry.adjust(origin, precision: 2, steps: -1, locale: locale) == "1.22")
        #expect(try NumericEntry.adjust(origin, precision: 2, steps: 0, locale: locale) == origin)
        #expect(try NumericEntry.adjust("", precision: 8, steps: 0, locale: locale) == "")
    }

    @Test func signAccessorySupportsLargeNegativeChangesAndLocalizedDrafts() throws {
        let raw = "12345678901234567890.12345678"
        #expect(try NumericEntry.flipSign(raw, locale: locale) == "-" + raw)
        #expect(try NumericEntry.flipSign("-" + raw, locale: locale) == raw)
        #expect(try NumericEntry.flipSign("+2,125", locale: Locale(identifier: "fr_FR")) == "-2,125")
        #expect(try NumericEntry.flipSign("2,1200", locale: Locale(identifier: "fr_FR")) == "-2,1200")
        #expect(try NumericEntry.flipSign("1.", locale: locale) == "-1.")
        #expect(try NumericEntry.flipSign("", locale: locale) == "-")
        #expect(try NumericEntry.flipSign("-", locale: locale) == "")
        #expect(try NumericEntry.flipSign("-0", locale: locale) == "0")
        #expect(throws: DataError.invalidNumber) { try NumericEntry.flipSign("+-1", locale: locale) }
    }

    private let locale = Locale(identifier: "en_US_POSIX")
    private func entry(_ seconds: TimeInterval, value: String, created: TimeInterval = 0) -> Entry {
        Entry(occurredAt: Date(timeIntervalSince1970: seconds), localDay: "2024-01-01", value: value,
              createdAt: Date(timeIntervalSince1970: created))
    }
    private func tracker(_ entries: [Entry]) -> Tracker {
        var tracker = Tracker(name: "Number", kind: .number)
        tracker.entries = entries
        return tracker
    }

    @Test func changeUsesClosestPriorSnapshotAndExcludesEditingEntry() throws {
        let first = entry(100, value: "10")
        let second = entry(200, value: "20")
        let future = entry(300, value: "1000")
        let tracker = tracker([future, first, second])
        let backfill = try NumericEntry.calculate("+2", mode: .change, tracker: tracker,
                                                 at: Date(timeIntervalSince1970: 150), locale: locale)
        #expect(backfill.value == "12" && backfill.baseline == first)
        let atSameTime = try NumericEntry.calculate("-5", mode: .change, tracker: tracker,
                                                   at: second.occurredAt, locale: locale)
        #expect(atSameTime.value == "15" && atSameTime.baseline == second)
        let excluding = try NumericEntry.calculate("2", mode: .change, tracker: tracker,
                                                  at: second.occurredAt, excluding: second.id, locale: locale)
        #expect(excluding.value == "12" && excluding.baseline == first)
        #expect(tracker.entries == [future, first, second])
    }

    @Test func exactChangePreservesFractionalDigitsAndAllowsNegativeResults() throws {
        let tracker = tracker([entry(100, value: "0.123456789012345678901234567")])
        let result = try NumericEntry.calculate("-0.000000000000000000000000001", mode: .change, tracker: tracker,
                                               at: Date(timeIntervalSince1970: 200), locale: locale)
        #expect(result.value == "0.123456789012345678901234566")
        let negative = try NumericEntry.calculate("-20.25", mode: .change, tracker: self.tracker([entry(100, value: "10.5")]),
                                                 at: Date(timeIntervalSince1970: 200), locale: locale)
        #expect(negative.value == "-9.75")
        let localized = try NumericEntry.calculate("+1,25", mode: .change, tracker: self.tracker([entry(100, value: "2.5")]),
                                                  at: Date(timeIntervalSince1970: 200), locale: Locale(identifier: "fr_FR"))
        #expect(localized.value == "3.75")
        let positive = try NumericEntry.calculate("+0.125", mode: .change, tracker: self.tracker([entry(100, value: "2.5")]),
                                                 at: Date(timeIntervalSince1970: 200), locale: locale)
        #expect(positive.value == "2.625")
    }

    @Test func missingBaselineBlocksChangeButDirectInputNeedsNone() throws {
        let future = entry(300, value: "10")
        let tracker = tracker([future])
        let date = Date(timeIntervalSince1970: 100)
        #expect(NumericEntry.baseline(in: tracker, at: date) == nil)
        #expect(throws: NumericEntryError.missingBaseline) {
            try NumericEntry.calculate("2", mode: .change, tracker: tracker, at: date, locale: locale)
        }
        let direct = try NumericEntry.calculate("-5.25", mode: .direct, tracker: tracker, at: date, locale: locale)
        #expect(direct.value == "-5.25" && direct.baseline == nil)
        #expect(NumericEntry.baseline(in: tracker, at: future.occurredAt, excluding: future.id) == nil)
    }

    @Test func overflowPrecisionAndMalformedChangeAreRejected() {
        let tracker = tracker([entry(100, value: "9999999999999999999999999999")])
        let date = Date(timeIntervalSince1970: 200)
        #expect(throws: DataError.invalidNumber) {
            try NumericEntry.calculate("1", mode: .change, tracker: tracker, at: date, locale: locale)
        }
        #expect(throws: DataError.invalidNumber) {
            try NumericEntry.calculate("0.1", mode: .change, tracker: tracker, at: date, locale: locale)
        }
        #expect(throws: DataError.invalidNumber) {
            try NumericEntry.calculate("0.000000000000000000000000001", mode: .change, tracker: tracker, at: date, locale: locale)
        }
        #expect(throws: DataError.invalidNumber) {
            try NumericEntry.calculate("++1", mode: .change, tracker: tracker, at: date, locale: locale)
        }
        #expect(throws: DataError.invalidNumber) {
            try NumericEntry.calculate("+-1", mode: .change, tracker: tracker, at: date, locale: locale)
        }
        #expect(throws: DataError.invalidNumber) {
            try NumericEntry.calculate("1e2", mode: .change, tracker: tracker, at: date, locale: locale)
        }
    }

    @Test func equalTimeBaselineUsesStableCreationOrderAndRejectsMalformedValues() {
        let earlier = entry(100, value: "10", created: 10)
        let later = entry(100, value: "20", created: 20)
        let missing = Entry(occurredAt: Date(timeIntervalSince1970: 150), localDay: "2024-01-01")
        let tracker = tracker([later, missing, earlier])
        #expect(NumericEntry.baseline(in: tracker, at: missing.occurredAt) == nil)
        #expect(NumericEntry.baseline(in: tracker, at: missing.occurredAt, excluding: missing.id) == later)
        var sameCreatedA = earlier
        var sameCreatedB = earlier
        sameCreatedA.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        sameCreatedB.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        #expect(NumericEntry.baseline(in: self.tracker([sameCreatedB, sameCreatedA]), at: missing.occurredAt) == sameCreatedB)
        #expect(NumericEntry.baseline(in: self.tracker([sameCreatedA, sameCreatedB]), at: missing.occurredAt) == sameCreatedB)
    }

    private func delta(_ seconds: TimeInterval, _ change: String, created: TimeInterval = 0) -> Entry {
        Entry(occurredAt: Date(timeIntervalSince1970: seconds), localDay: "2024-01-01", change: change,
              createdAt: Date(timeIntervalSince1970: created))
    }
    @Test func insertionEditDeletionPropagateUntilUnrelatedAbsoluteAnchor() throws {
        let anchor = entry(100, value: "100")
        let plusFive = delta(200, "5"), plusTwo = delta(300, "2")
        let reset = entry(400, value: "200"), afterReset = delta(500, "-1")
        let original = tracker([afterReset, plusTwo, anchor, reset, plusFive])
        let inserted = delta(150, "3")
        let insertion = try NumericEntry.mutation(in: original, replacing: inserted)
        #expect(insertion.orphan == nil)
        #expect(insertion.tracker.resolvedEntries.compactMap(\.value) == ["100", "103", "108", "110", "200", "199"])
        #expect(original.entries == [afterReset, plusTwo, anchor, reset, plusFive])
        #expect(insertion.tracker.entries.filter { $0.id != inserted.id } == original.entries)
        var changedAnchor = anchor; changedAnchor.value = "90"
        let anchorEdit = try NumericEntry.mutation(in: original, replacing: changedAnchor)
        #expect(anchorEdit.tracker.resolvedEntries.compactMap(\.value) == ["90", "95", "97", "200", "199"])
        #expect(anchorEdit.tracker.entries.first { $0.id == plusTwo.id } == plusTwo)
        var edited = inserted; edited.change = "-4"
        let edit = try NumericEntry.mutation(in: insertion.tracker, replacing: edited)
        #expect(edit.tracker.resolvedValue(for: plusTwo.id) == "103")
        #expect(edit.tracker.entries.first { $0.id == plusFive.id } == plusFive)
        let deletion = try NumericEntry.mutation(in: edit.tracker, deleting: plusFive.id)
        #expect(deletion.tracker.resolvedEntries.compactMap(\.value) == ["100", "96", "98", "200", "199"])
        #expect(deletion.tracker.entries.first { $0.id == afterReset.id } == afterReset)
    }
    @Test func deltaDateEditsUseNewPriorPositionAndPreviewMatchesSavedResolution() throws {
        let anchor = entry(100, value: "0.123456789012345678901234567")
        let first = delta(200, "0.000000000000000000000000001")
        let second = delta(300, "-0.000000000000000000000000002")
        let original = tracker([second, anchor, first])
        var moved = second; moved.occurredAt = Date(timeIntervalSince1970: 150)
        let preview = try NumericEntry.calculate(moved.change!, mode: .change, tracker: original, at: moved.occurredAt,
                                                excluding: moved.id, position: moved, locale: locale)
        let mutation = try NumericEntry.mutation(in: original, replacing: moved)
        #expect(preview.rawInput == moved.change && preview.value == "0.123456789012345678901234565")
        #expect(mutation.tracker.resolvedValue(for: moved.id) == preview.value)
        #expect(mutation.tracker.resolvedValue(for: first.id) == "0.123456789012345678901234566")
        #expect(mutation.tracker.entries.first { $0.id == first.id } == first)
        #expect(mutation.tracker.entries.first { $0.id == moved.id }?.value == nil)
    }
    @Test func equalTimestampEditingUsesOnlyPriorStablePositionIncludingUUID() throws {
        var anchor = entry(100, value: "10", created: 1)
        var first = delta(100, "2", created: 2)
        var second = delta(100, "3", created: 2)
        anchor.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        first.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        second.id = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let original = tracker([second, first, anchor])
        #expect(original.sortedEntries.map(\.id) == [anchor.id, first.id, second.id])
        #expect(original.resolvedEntries.compactMap(\.value) == ["10", "12", "15"])
        let result = try NumericEntry.calculate("5", mode: .change, tracker: original, at: first.occurredAt,
                                               excluding: first.id, locale: locale)
        #expect(result.value == "15" && result.baseline?.id == anchor.id)
        var edited = first; edited.change = result.rawInput
        let mutation = try NumericEntry.mutation(in: original, replacing: edited)
        #expect(mutation.tracker.resolvedValue(for: second.id) == "18")
        #expect(NumericEntry.baseline(in: original, at: anchor.occurredAt, excluding: anchor.id) == nil)
    }
    @Test func removingOrMovingAnchorRequiresExplicitInMemoryConversionAtPreviousValue() throws {
        let anchor = entry(100, value: "100.1234567890123456789")
        let first = delta(200, "-5"), second = delta(300, "2")
        let original = tracker([anchor, first, second])
        let rawOriginal = original.entries
        let deletion = try NumericEntry.mutation(in: original, deleting: anchor.id)
        #expect(deletion.orphan?.id == first.id)
        #expect(deletion.orphan?.value == "95.1234567890123456789")
        #expect(original.entries == rawOriginal) // Cancelling this proposal has no mutations to undo.
        #expect(deletion.tracker.entries.first { $0.id == first.id }?.change == nil)
        #expect(deletion.tracker.entries.first { $0.id == first.id }?.value == "95.1234567890123456789")
        #expect(deletion.tracker.entries.first { $0.id == second.id } == second)
        #expect(deletion.tracker.resolvedValue(for: second.id) == original.resolvedValue(for: second.id))
        var moved = anchor; moved.occurredAt = Date(timeIntervalSince1970: 250)
        let move = try NumericEntry.mutation(in: original, replacing: moved)
        #expect(move.orphan?.id == first.id)
        #expect(move.tracker.resolvedValue(for: second.id) == "102.1234567890123456789")
        var orphaned = first; orphaned.occurredAt = Date(timeIntervalSince1970: 50)
        let deltaMove = try NumericEntry.mutation(in: original, replacing: orphaned)
        #expect(deltaMove.orphan?.id == first.id)
        #expect(deltaMove.tracker.entries.first { $0.id == first.id }?.value == original.resolvedValue(for: first.id))
        #expect(original.entries == rawOriginal)
    }
    @Test func overflowInLaterDeltaRejectsWholeMutationEvenAfterAnAbsolutePreviewSucceeds() throws {
        let anchor = entry(100, value: "1")
        let change = delta(200, "1")
        let original = tracker([anchor, change])
        var edited = anchor; edited.value = "9999999999999999999999999999"
        #expect(throws: DataError.invalidNumber) { try NumericEntry.mutation(in: original, replacing: edited) }
        #expect(original.resolvedEntries.compactMap(\.value) == ["1", "2"])
        #expect(throws: NumericEntryError.missingBaseline) {
            try NumericEntry.mutation(in: tracker([]), replacing: delta(100, "1"))
        }
    }
    @Test func gateCoversNewBackfillsRawChangesAndDatesButExemptsNotesPhotosAndLocation() {
        let old = entry(100, value: "10")
        var tracker = tracker([old])
        tracker.conditions = [PlaceCondition(name: "Home", location: RecordedLocation(latitude: 35, longitude: 139))]
        tracker.gateSave = true
        #expect(NumericEntry.requiresGate(in: tracker, for: entry(50, value: "1"), editing: nil))
        #expect(!NumericEntry.requiresGate(in: tracker, for: old, editing: old.id))
        var changed = old; changed.note = "notes"; changed.photos = [Data([1])]
        changed.location = RecordedLocation(latitude: 36, longitude: 140)
        #expect(!NumericEntry.requiresGate(in: tracker, for: changed, editing: old.id))
        changed.value = "11"
        #expect(NumericEntry.requiresGate(in: tracker, for: changed, editing: old.id))
        changed = old; changed.value = nil; changed.change = "0"
        #expect(NumericEntry.requiresGate(in: tracker, for: changed, editing: old.id))
        changed = old; changed.occurredAt = old.occurredAt.addingTimeInterval(-1)
        #expect(NumericEntry.requiresGate(in: tracker, for: changed, editing: old.id))
        changed = old; changed.localDay = "2023-12-31"
        #expect(NumericEntry.requiresGate(in: tracker, for: changed, editing: old.id))
        tracker.kind = .daily
        #expect(NumericEntry.requiresGate(in: tracker, for: Entry(occurredAt: old.occurredAt, localDay: old.localDay), editing: nil))
        tracker.gateSave = false
        #expect(!NumericEntry.requiresGate(in: tracker, for: changed, editing: nil))
    }
}
