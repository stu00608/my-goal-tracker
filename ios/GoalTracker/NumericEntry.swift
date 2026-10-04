import Foundation

nonisolated enum NumericEntryMode { case direct, change }
nonisolated enum NumericEntryError: Error { case missingBaseline }
nonisolated struct NumericEntryResult: Equatable {
    let value: String
    let baseline: Entry?
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

    static func baseline(in tracker: Tracker, at date: Date, excluding id: UUID? = nil) -> Entry? {
        tracker.entries.filter { entry in
            guard entry.id != id, entry.occurredAt <= date,
                  let value = entry.value.flatMap(Numbers.decimal), !value.isNaN else { return false }
            return true
        }.max { ($0.occurredAt, $0.createdAt, $0.id.uuidString) < ($1.occurredAt, $1.createdAt, $1.id.uuidString) }
    }

    // Preview and save share this calculation; only the resulting absolute value is stored.
    static func calculate(_ input: String, mode: NumericEntryMode, tracker: Tracker, at date: Date,
                          excluding id: UUID? = nil, locale: Locale = .current) throws -> NumericEntryResult {
        if mode == .direct {
            return NumericEntryResult(value: try Numbers.parse(input, locale: locale), baseline: nil)
        }
        guard let baseline = baseline(in: tracker, at: date, excluding: id),
              var prior = baseline.value.flatMap(Numbers.decimal) else { throw NumericEntryError.missingBaseline }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let signed = trimmed.hasPrefix("+") ? String(trimmed.dropFirst()) : trimmed
        if trimmed.hasPrefix("+"), signed.hasPrefix("-") { throw DataError.invalidNumber }
        let canonical = try Numbers.parse(signed, locale: locale)
        guard var change = Numbers.decimal(canonical) else { throw DataError.invalidNumber }
        var result = Decimal()
        guard NSDecimalAdd(&result, &prior, &change, .plain) == .noError, !result.isNaN else { throw DataError.invalidNumber }
        let absolute = try Numbers.parse(NSDecimalNumber(decimal: result).stringValue, locale: Locale(identifier: "en_US_POSIX"))
        return NumericEntryResult(value: absolute, baseline: baseline)
    }
}
