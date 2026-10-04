import Foundation

nonisolated enum NumericEntryMode: String {
    case direct, change
    static func initial(preference: String, hasBaseline: Bool, editing: Bool) -> Self {
        !editing && hasBaseline && preference == Self.change.rawValue ? .change : .direct
    }
}
nonisolated struct NumericEntryResult: Equatable {
    let value: String
    let rawInput: String
    let baseline: Entry?
}
nonisolated struct NumericEntryMutation {
    // Entirely in-memory candidate. An orphan requires explicit user confirmation before saving.
    let tracker: Tracker
    let orphan: Entry?
}

nonisolated enum NumericEntry {
    static func quantum(precision: Int) throws -> Decimal {
        guard (0...8).contains(precision) else { throw DataError.invalidNumber }
        let text = precision == 0 ? "1" : "0." + String(repeating: "0", count: precision - 1) + "1"
        guard let value = Numbers.decimal(text) else { throw DataError.invalidNumber }
        return value
    }

    // Geometry determines an integer tick count only; it never holds a record's numeric value.
    static func scrubSteps(translation: Double) -> Int? {
        guard translation.isFinite else { return nil }
        return Int(exactly: (-translation / 12).rounded(.towardZero))
    }

    static func adjust(_ input: String, precision: Int, steps: Int, locale: Locale = .current) throws -> String {
        var quantum = try quantum(precision: precision)
        guard steps != 0 else { return input }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let unsignedPrefix = trimmed.hasPrefix("+") ? String(trimmed.dropFirst()) : trimmed
        if trimmed.hasPrefix("+"), unsignedPrefix.hasPrefix("-") { throw DataError.invalidNumber }
        let canonical = try Numbers.parse(trimmed.isEmpty ? "0" : unsignedPrefix, locale: locale)
        guard var start = Numbers.decimal(canonical) else { throw DataError.invalidNumber }
        var count = Decimal(steps), delta = Decimal(), result = Decimal()
        guard NSDecimalMultiply(&delta, &quantum, &count, .plain) == .noError,
              NSDecimalAdd(&result, &start, &delta, .plain) == .noError,
              !result.isNaN else { throw DataError.invalidNumber }
        let value = try Numbers.parse(NSDecimalNumber(decimal: result).stringValue, locale: Locale(identifier: "en_US_POSIX"))
        return value.replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }

    static func flipSign(_ input: String, locale: Locale = .current) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "+" { return "-" }
        if trimmed == "-" { return "" }
        let raw = trimmed.hasPrefix("+") ? String(trimmed.dropFirst()) : trimmed
        if trimmed.hasPrefix("+"), raw.hasPrefix("-") { throw DataError.invalidNumber }
        let separator = locale.decimalSeparator ?? "."
        // Flipping a sign must not discard an in-progress decimal separator or trailing zeros.
        let validation = raw.hasSuffix(separator) ? String(raw.dropLast(separator.count)) : raw
        _ = try Numbers.parse(validation, locale: locale)
        return raw.hasPrefix("-") ? String(raw.dropFirst()) : "-" + raw
    }

    static func baseline(in tracker: Tracker, at date: Date, excluding id: UUID? = nil, position: Entry? = nil) -> Entry? {
        try? resolvedBaseline(in: tracker, at: date, excluding: id, position: position)
    }
    private static func resolvedBaseline(in tracker: Tracker, at date: Date, excluding id: UUID?, position: Entry?) throws -> Entry? {
        let position = position ?? tracker.entries.first { $0.id == id }
        var prior = tracker
        prior.entries = tracker.entries.filter { entry in
            guard entry.id != id, entry.occurredAt <= date else { return false }
            guard entry.occurredAt == date, let position else { return true }
            return (entry.createdAt, entry.id.uuidString) < (position.createdAt, position.id.uuidString)
        }
        return try prior.resolveEntries().last
    }
    // Preview resolves the same raw event that save persists, without caching its absolute result.
    static func calculate(_ input: String, mode: NumericEntryMode, tracker: Tracker, at date: Date,
                          excluding id: UUID? = nil, position: Entry? = nil, locale: Locale = .current) throws -> NumericEntryResult {
        if mode == .direct {
            let raw = try Numbers.parse(input, locale: locale)
            return NumericEntryResult(value: raw, rawInput: raw, baseline: nil)
        }
        guard let baseline = try resolvedBaseline(in: tracker, at: date, excluding: id, position: position),
              let prior = baseline.value else { throw NumericEntryError.missingBaseline }
        let canonical = try rawInput(input, mode: mode, locale: locale)
        return NumericEntryResult(value: try Numbers.add(prior, canonical), rawInput: canonical, baseline: baseline)
    }
    static func rawInput(_ input: String, mode: NumericEntryMode, locale: Locale = .current) throws -> String {
        if mode == .direct { return try Numbers.parse(input, locale: locale) }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let signed = trimmed.hasPrefix("+") ? String(trimmed.dropFirst()) : trimmed
        if trimmed.hasPrefix("+"), signed.hasPrefix("-") { throw DataError.invalidNumber }
        return try Numbers.parse(signed, locale: locale)
    }

    static func mutation(in original: Tracker, replacing entry: Entry? = nil, deleting id: UUID? = nil) throws -> NumericEntryMutation {
        let before = try original.resolveEntries()
        var candidate = original
        if let id { candidate.entries.removeAll { $0.id == id } }
        if let entry { candidate.put(entry) }
        var orphan: Entry?
        do { _ = try candidate.resolveEntries() }
        catch NumericEntryError.orphanedChange(let id) {
            guard let previous = before.first(where: { $0.id == id }), let absolute = previous.value,
                  let index = candidate.entries.firstIndex(where: { $0.id == id }) else { throw NumericEntryError.missingBaseline }
            orphan = previous
            candidate.entries[index].value = absolute
            candidate.entries[index].change = nil
            candidate.entries[index].updatedAt = Date()
            _ = try candidate.resolveEntries()
        }
        try Backup(trackers: [candidate]).validate()
        return NumericEntryMutation(tracker: candidate, orphan: orphan)
    }

    static func requiresGate(in tracker: Tracker, for entry: Entry, editing id: UUID?) -> Bool {
        guard tracker.requiresLocationGate else { return false }
        guard let id, let old = tracker.entries.first(where: { $0.id == id }) else { return true }
        return old.value != entry.value || old.change != entry.change || old.occurredAt != entry.occurredAt || old.localDay != entry.localDay
    }
}
