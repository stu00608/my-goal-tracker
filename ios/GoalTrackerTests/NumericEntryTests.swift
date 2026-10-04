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

    @Test func equalTimeBaselineUsesStableCreationOrderAndSkipsMissingValues() {
        let earlier = entry(100, value: "10", created: 10)
        let later = entry(100, value: "20", created: 20)
        let missing = Entry(occurredAt: Date(timeIntervalSince1970: 150), localDay: "2024-01-01")
        let tracker = tracker([later, missing, earlier])
        #expect(NumericEntry.baseline(in: tracker, at: missing.occurredAt) == later)
        var sameCreatedA = earlier
        var sameCreatedB = earlier
        sameCreatedA.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        sameCreatedB.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        #expect(NumericEntry.baseline(in: self.tracker([sameCreatedB, sameCreatedA]), at: missing.occurredAt) == sameCreatedB)
        #expect(NumericEntry.baseline(in: self.tracker([sameCreatedA, sameCreatedB]), at: missing.occurredAt) == sameCreatedB)
    }
}
