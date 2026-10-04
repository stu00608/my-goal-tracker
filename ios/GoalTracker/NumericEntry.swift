import Foundation

nonisolated enum NumericEntryMode { case direct, change }
nonisolated enum NumericEntryError: Error { case missingBaseline }
nonisolated struct NumericEntryResult: Equatable {
    let value: String
    let baseline: Entry?
}

nonisolated enum NumericEntry {
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
