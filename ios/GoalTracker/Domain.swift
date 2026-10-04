import Foundation
import ImageIO

nonisolated enum TrackerKind: String, Codable, CaseIterable { case number, daily }
nonisolated enum Direction: String, Codable, CaseIterable { case up, down }
nonisolated enum Period: String, Codable, CaseIterable { case weekly, monthly, deadline }

nonisolated struct Entry: Codable, Identifiable, Equatable {
    static let photoLimit = 10
    var id = UUID()
    var occurredAt: Date
    var localDay: String
    var value: String?
    var note = ""
    var photos: [Data] = []
    var createdAt = Date()
    var updatedAt = Date()
}

nonisolated struct GoalRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var period: Period
    var target: String
    var effectiveAt: Date
    var deadline: Date?
    var direction = Direction.up
}

nonisolated struct Reminder: Codable, Equatable {
    var hour: Int
    var minute: Int
    var weekdays: [Int] // Calendar weekdays: Sunday = 1
}

nonisolated struct Tracker: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kind: TrackerKind
    var unit = ""
    var precision = 3
    var direction = Direction.up
    var timeZoneID = TimeZone.current.identifier
    var createdAt = Date()
    var archived = false
    var entries: [Entry] = []
    var rules: [GoalRule] = []
    var reminder: Reminder?

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: timeZoneID) ?? .gmt
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }
    func day(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    func date(for day: String) -> Date? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, (1...9999).contains(p[0]), let date = calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2])), self.day(date) == day else { return nil }
        return date
    }
    var sortedEntries: [Entry] {
        entries.sorted { ($0.occurredAt, $0.createdAt, $0.id.uuidString) < ($1.occurredAt, $1.createdAt, $1.id.uuidString) }
    }
    var latest: Entry? { sortedEntries.last }
    var best: Decimal? {
        let values = entries.compactMap { $0.value.flatMap(Numbers.decimal) }
        return direction == .up ? values.max() : values.min()
    }
    func rule(at date: Date) -> GoalRule? { rules.filter { $0.effectiveAt <= date }.max { $0.effectiveAt < $1.effectiveAt } }
    func interval(_ date: Date, period: Period) -> DateInterval {
        calendar.dateInterval(of: period == .weekly ? .weekOfYear : .month, for: date)!
    }
    func count(in interval: DateInterval) -> Int {
        Set(entries.filter { entry in
            guard let date = date(for: entry.localDay) else { return false }
            return date >= interval.start && date < interval.end
        }.map(\.localDay)).count
    }
    func achieved(_ rule: GoalRule) -> Bool {
        guard let target = Numbers.decimal(rule.target), let deadline = rule.deadline else { return false }
        return entries.contains {
            guard $0.occurredAt <= deadline, let v = $0.value.flatMap(Numbers.decimal) else { return false }
            return rule.direction == .up ? v >= target : v <= target
        }
    }
    func frequencyHistory(until now: Date) -> [(DateInterval, Int, Int, Bool)] {
        guard kind == .daily, let initial = rules.min(by: { $0.effectiveAt < $1.effectiveAt }) else { return [] }
        var cursor = interval(max(createdAt, initial.effectiveAt), period: initial.period).start
        var result: [(DateInterval, Int, Int, Bool)] = []
        while cursor <= now {
            guard let rule = rule(at: max(cursor, initial.effectiveAt)) else { break }
            let whole = interval(cursor, period: rule.period)
            let nextChange = rules.filter { $0.effectiveAt > max(cursor, initial.effectiveAt) }.map(\.effectiveAt).min()
            let window = DateInterval(start: cursor, end: min(whole.end, nextChange ?? whole.end))
            let partial = calendar.startOfDay(for: createdAt) > whole.start || cursor != whole.start || window.end != whole.end || rule.effectiveAt > whole.start
            result.append((window, count(in: window), Int(rule.target) ?? 1, partial))
            cursor = window.end
        }
        return result
    }
    mutating func put(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id || (kind == .daily && $0.localDay == entry.localDay) }
        entries.append(entry)
    }
    mutating func setFrequency(_ period: Period, target: Int, now: Date) {
        let effective = rules.isEmpty ? now : interval(now, period: period).end
        rules.removeAll { $0.effectiveAt > now }
        rules.append(GoalRule(period: period, target: String(target), effectiveAt: effective))
    }
}

nonisolated enum Numbers {
    static func decimal(_ text: String) -> Decimal? { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) }
    static func parse(_ input: String, locale: Locale = .current) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: locale.decimalSeparator ?? ".", with: ".")
        guard text.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              text.filter(\.isNumber).count <= 28, let value = decimal(text), !value.isNaN else { throw DataError.invalidNumber }
        return NSDecimalNumber(decimal: value).stringValue
    }
    static func display(_ value: Decimal, precision: Int, locale: Locale) -> String {
        let f = NumberFormatter()
        f.locale = locale; f.numberStyle = .decimal
        f.minimumFractionDigits = precision; f.maximumFractionDigits = precision
        return f.string(from: NSDecimalNumber(decimal: value)) ?? NSDecimalNumber(decimal: value).stringValue
    }
}

nonisolated enum DataError: Error { case invalidNumber, invalidBackup, unsupportedVersion, saveFailed, photoFailed, tooManyPhotos, tooLarge, tooManyReminders, duplicateDay }

nonisolated struct Backup: Codable, Equatable {
    var format = "my-goal-tracker"
    var version = 1
    var exportedAt = Date()
    var trackers: [Tracker]

    func validate() throws {
        guard Self.validDate(exportedAt) else { throw DataError.invalidBackup }
        guard format == "my-goal-tracker" else { throw DataError.invalidBackup }
        guard version == 1 else { throw DataError.unsupportedVersion }
        guard trackers.count <= 1000, Set(trackers.map(\.id)).count == trackers.count else { throw DataError.invalidBackup }
        var entryIDs = Set<UUID>()
        var ruleIDs = Set<UUID>()
        for t in trackers {
            guard !t.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, t.name.count <= 120, t.unit.count <= 30,
                  (0...8).contains(t.precision), TimeZone(identifier: t.timeZoneID) != nil, Self.validDate(t.createdAt),
                  t.entries.count <= 100000, t.rules.count <= 10000 else { throw DataError.invalidBackup }
            var days = Set<String>()
            for e in t.entries {
                guard entryIDs.insert(e.id).inserted, t.date(for: e.localDay) != nil, e.note.count <= 10000,
                      Self.validDate(e.occurredAt), Self.validDate(e.createdAt), Self.validDate(e.updatedAt),
                      e.photos.count <= Entry.photoLimit, e.photos.allSatisfy(Self.validPhoto) else { throw DataError.invalidBackup }
                if t.kind == .daily {
                    guard e.value == nil, days.insert(e.localDay).inserted else { throw DataError.invalidBackup }
                } else {
                    guard let value = e.value, (try? Numbers.parse(value, locale: Locale(identifier: "en_US_POSIX"))) == value else { throw DataError.invalidBackup }
                }
            }
            for r in t.rules {
                guard ruleIDs.insert(r.id).inserted, Self.validDate(r.effectiveAt) else { throw DataError.invalidBackup }
                if t.kind == .daily {
                    guard r.period != .deadline, let n = Int(r.target), (1...(r.period == .weekly ? 7 : 31)).contains(n), r.deadline == nil else { throw DataError.invalidBackup }
                } else {
                    guard r.period == .deadline, let due = r.deadline, Self.validDate(due), due >= r.effectiveAt,
                          (try? Numbers.parse(r.target, locale: Locale(identifier: "en_US_POSIX"))) == r.target else { throw DataError.invalidBackup }
                }
            }
            if let r = t.reminder {
                guard (0...23).contains(r.hour), (0...59).contains(r.minute), !r.weekdays.isEmpty,
                      Set(r.weekdays).count == r.weekdays.count, r.weekdays.allSatisfy({ (1...7).contains($0) }) else { throw DataError.invalidBackup }
            }
        }
    }
    static func validDate(_ date: Date) -> Bool {
        // Reject dates outside the supported four-digit Gregorian year range before Calendar arithmetic.
        (-62_135_596_800..<253_402_300_800).contains(date.timeIntervalSince1970)
    }
    static func validPhoto(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= 2_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else { return false }
        return (1...1600).contains(width) && (1...1600).contains(height)
    }
    func encoded() throws -> Data {
        try validate()
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        let data = try e.encode(self)
        guard data.count <= 100_000_000 else { throw DataError.tooLarge }
        return data
    }
    static func decode(_ data: Data) throws -> Backup {
        guard data.count <= 100_000_000 else { throw DataError.tooLarge }
        let b = try JSONDecoder().decode(Backup.self, from: data)
        try b.validate()
        return b
    }
    func csv() -> String {
        func escape(_ s: String, protect: Bool) -> String {
            // Spreadsheet formula protection; JSON backup preserves the original text.
            let candidate = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let formula = ["=", "+", "-", "@"].contains(where: candidate.hasPrefix)
            let safe = protect && formula ? "'" + s : s
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let iso = ISO8601DateFormatter()
        var rows = ["tracker_id,name,kind,unit,entry_id,occurred_at,local_day,time_zone,value,note"]
        for t in trackers { for e in t.sortedEntries {
            let fields = [t.id.uuidString, t.name, t.kind.rawValue, t.unit, e.id.uuidString, iso.string(from: e.occurredAt), e.localDay, t.timeZoneID, e.value ?? "", e.note]
            rows.append(fields.enumerated().map { escape($0.element, protect: [1, 3, 9].contains($0.offset)) }.joined(separator: ","))
        } }
        return rows.joined(separator: "\r\n") + "\r\n"
    }
}
