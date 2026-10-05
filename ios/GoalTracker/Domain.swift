import Foundation
import ImageIO

nonisolated enum TrackerKind: String, Codable, CaseIterable { case number, daily }
nonisolated enum Direction: String, Codable, CaseIterable { case up, down }
nonisolated enum Period: String, Codable, CaseIterable { case weekly, monthly, deadline }
nonisolated enum NumericEntryError: Error, Equatable { case missingBaseline, orphanedChange(UUID) }

nonisolated enum CardTextPosition: String, Codable, CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing, hidden
    static func available(for background: CardBackground) -> [Self] {
        background == .map ? [.topLeading, .topTrailing, .hidden] : allCases
    }
    func resolved(for background: CardBackground) -> Self {
        guard background == .map else { return self }
        switch self { case .bottomLeading: return .topLeading; case .bottomTrailing: return .topTrailing; default: return self }
    }
}
nonisolated enum RingProgressStyle: String, Codable, CaseIterable { case percent, fraction }
nonisolated enum TrackingLifecycle: String, Codable, CaseIterable { case ongoing, finite }
nonisolated enum WeekdayOrder {
    static func days(starting firstWeekday: Int) -> [Int] {
        let first = firstWeekday == 2 ? 2 : 1
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }
}
nonisolated enum HealthWindow: String, Codable, CaseIterable, Hashable { case day, week, month }
nonisolated enum ThresholdComparison: String, Codable, CaseIterable { case greater, less }
nonisolated struct TimeCondition: Codable, Equatable {
    var startMinute: Int
    var endMinute: Int
}
nonisolated struct HealthThreshold: Codable, Equatable {
    var comparison: ThresholdComparison
    var threshold: String
    var window: HealthWindow
}
nonisolated enum ConditionPayload: Codable, Equatable {
    case place(PlaceCondition)
    case time(TimeCondition)
    case weekdays([Int])
    case steps(HealthThreshold)
    case sleep(HealthThreshold)
}
nonisolated struct AchievementCondition: Codable, Identifiable, Equatable {
    var id = UUID()
    var payload: ConditionPayload
    var place: PlaceCondition? { if case .place(let p) = payload { p } else { nil } }
    var isHealth: Bool { switch payload { case .steps, .sleep: true; default: false } }
}
nonisolated struct ConditionGroup: Codable, Identifiable, Equatable {
    static let limit = 10
    var id = UUID()
    var name: String?
    var combination = ConditionCombination.all
    var conditions: [AchievementCondition] = []
}
nonisolated struct AchievementPlotPoint: Codable, Equatable {
    var date: Date
    var value: String
}
/// Automatic achievements are derived from source records; only explicit manual completion is persisted.
nonisolated struct AchievementSnapshot: Codable, Identifiable, Equatable {
    var id: String
    var trackerID: UUID
    var ruleID: UUID?
    var evidenceEntryID: UUID?
    var periodStart: Date?
    var achievedAt: Date
    var startedAt: Date
    var name: String
    var kind: TrackerKind
    var unit: String
    var precision: Int
    var value: String?
    var target: String?
    var timeZoneID: String
    var background: CardBackground
    var thumbnail: Data?
    var plot: [AchievementPlotPoint] = []
    var locations: [RecordedLocation] = []
    var manual = false
}
nonisolated struct NumericAchievement: Equatable {
    var evidenceEntryID: UUID
    var achievedAt: Date
    var value: String
}

nonisolated enum CardBackground: String, Codable, CaseIterable { case plot, photo, trackerPhoto, map, progress }
nonisolated struct RecordedLocation: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var isValid: Bool { latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) }
}

nonisolated struct Entry: Codable, Identifiable, Equatable {
    static let photoLimit = 10
    var id = UUID()
    var occurredAt: Date
    var localDay: String
    var value: String?
    var change: String?
    var note = ""
    var photos: [Data] = []
    var location: RecordedLocation?
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

nonisolated enum ConditionCombination: String, Codable, CaseIterable { case any, all }
nonisolated enum PlaceRelation: String, Codable, CaseIterable { case inside, outside }
nonisolated struct PlaceCondition: Codable, Identifiable, Equatable {
    static let radius = 200.0
    var id = UUID()
    var name: String
    var location: RecordedLocation
    var relation = PlaceRelation.inside
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
    var cardBackground: CardBackground?
    // Optional keys preserve synthesized decoding of existing version-1 Ledger payloads.
    var description: String?
    var website: String?
    var photos: [Data]?
    var axisLower: String?
    var axisUpper: String?
    var conditions: [PlaceCondition]?
    var conditionCombination: ConditionCombination?
    var gateSave: Bool?
    var remindWhenMet: Bool?
    var conditionGroups: [ConditionGroup]?
    var outerCombination: ConditionCombination?
    var cardTextPosition: CardTextPosition?
    var showLastRecorded: Bool?
    var ringStyle: RingProgressStyle?
    var lifecycle: TrackingLifecycle?
    var manualCompletion: AchievementSnapshot?
    var resolvedTextPosition: CardTextPosition { cardTextPosition ?? .bottomTrailing }
    var resolvedRingStyle: RingProgressStyle { ringStyle ?? .percent }
    var resolvedLifecycle: TrackingLifecycle { lifecycle ?? (kind == .daily ? .ongoing : .finite) }
    var resolvedConditionGroups: [ConditionGroup] {
        if let conditionGroups { return conditionGroups }
        let legacy = conditions ?? []
        // Derive stable group IDs from the tracker, independently of valid legacy leaf IDs.
        return stride(from: 0, to: legacy.count, by: ConditionGroup.limit).map { offset in
            var bytes = id.uuid
            withUnsafeMutableBytes(of: &bytes) { $0[15] ^= UInt8(truncatingIfNeeded: offset / ConditionGroup.limit) }
            return ConditionGroup(id: UUID(uuid: bytes), combination: resolvedCombination,
                                  conditions: legacy[offset..<min(offset + ConditionGroup.limit, legacy.count)].map {
                                      AchievementCondition(id: $0.id, payload: .place($0))
                                  })
        }
    }
    var resolvedOuterCombination: ConditionCombination { outerCombination ?? resolvedCombination }
    var resolvedConditions: [PlaceCondition] { resolvedConditionGroups.flatMap(\.conditions).compactMap(\.place) }
    var requiresConditionGate: Bool { gateSave == true && !resolvedConditionGroups.isEmpty }
    var supportsConditionReminders: Bool {
        let leaves = resolvedConditionGroups.flatMap(\.conditions)
        return leaves.contains { $0.place != nil } && !leaves.contains { $0.isHealth }
    }
    mutating func migrateConditions() {
        if conditionGroups == nil, conditions?.isEmpty != false, gateSave == true { gateSave = false }
        if conditionGroups == nil, conditions?.isEmpty == false {
            conditionGroups = resolvedConditionGroups
            outerCombination = resolvedCombination
        }
        conditions = nil; conditionCombination = nil
    }
    var resolvedCombination: ConditionCombination { conditionCombination ?? .any }
    var requiresLocationGate: Bool { requiresConditionGate }
    var resolvedCardBackground: CardBackground { cardBackground ?? .plot }

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
    // Display copies retain the raw change for provenance. Never persist these copies.
    var resolvedEntries: [Entry] { (try? resolveEntries()) ?? [] }
    func resolvedValue(for id: UUID) -> String? { resolvedEntries.first { $0.id == id }?.value }
    func resolveEntries() throws -> [Entry] {
        guard kind == .number else { return sortedEntries }
        var baseline: String?
        return try sortedEntries.map { raw in
            guard (raw.value == nil) != (raw.change == nil) else { throw DataError.invalidNumber }
            var display = raw
            if let value = raw.value {
                guard Numbers.isCanonical(value) else { throw DataError.invalidNumber }
                baseline = value
            } else if let change = raw.change {
                guard Numbers.isCanonical(change) else { throw DataError.invalidNumber }
                guard let prior = baseline else { throw NumericEntryError.orphanedChange(raw.id) }
                baseline = try Numbers.add(prior, change)
            }
            display.value = baseline
            return display
        }
    }
    var latest: Entry? { resolvedEntries.last }
    var best: Decimal? {
        let values = resolvedEntries.compactMap { $0.value.flatMap(Numbers.decimal) }
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
    /// Preserve the existing "ever reached before the deadline" rule, including historical evidence.
    /// Future evidence is excluded. If evidence predates this goal, the goal is achieved at its effective time.
    func achievement(for rule: GoalRule, now: Date = Date()) -> NumericAchievement? {
        guard kind == .number, rule.effectiveAt <= now,
              let target = Numbers.decimal(rule.target), let deadline = rule.deadline,
              let entry = resolvedEntries.first(where: {
                  guard $0.occurredAt <= min(now, deadline), let value = $0.value.flatMap(Numbers.decimal) else { return false }
                  return rule.direction == .up ? value >= target : value <= target
              }), let value = entry.value else { return nil }
        return NumericAchievement(evidenceEntryID: entry.id, achievedAt: max(rule.effectiveAt, entry.occurredAt), value: value)
    }
    func achieved(_ rule: GoalRule) -> Bool { achievement(for: rule) != nil }
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
    static func isCanonical(_ value: String) -> Bool {
        (try? parse(value, locale: Locale(identifier: "en_US_POSIX"))) == value
    }
    static func add(_ first: String, _ second: String) throws -> String {
        guard var lhs = decimal(first), var rhs = decimal(second), !lhs.isNaN, !rhs.isNaN else { throw DataError.invalidNumber }
        var result = Decimal()
        guard NSDecimalAdd(&result, &lhs, &rhs, .plain) == .noError, !result.isNaN else { throw DataError.invalidNumber }
        return try parse(NSDecimalNumber(decimal: result).stringValue, locale: Locale(identifier: "en_US_POSIX"))
    }
    // Only drawing uses binary floating point; parse the original decimal text once.
    static func plottedValue(_ text: String) -> Double? {
        guard let decimal = decimal(text), !decimal.isNaN, let value = Double(text), value.isFinite else { return nil }
        return value
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
    var version = 3
    var exportedAt = Date()
    var trackers: [Tracker]

    func validate() throws {
        guard Self.validDate(exportedAt) else { throw DataError.invalidBackup }
        guard format == "my-goal-tracker" else { throw DataError.invalidBackup }
        guard (1...3).contains(version) else { throw DataError.unsupportedVersion }
        guard trackers.count <= 1000, Set(trackers.map(\.id)).count == trackers.count else { throw DataError.invalidBackup }
        var entryIDs = Set<UUID>()
        var ruleIDs = Set<UUID>()
        for t in trackers {
            guard !t.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, t.name.count <= 120, t.unit.count <= 30,
                  (0...8).contains(t.precision), TimeZone(identifier: t.timeZoneID) != nil, Self.validDate(t.createdAt),
                  t.entries.count <= 100000, t.rules.count <= 10000 else { throw DataError.invalidBackup }
            try Self.validateMetadata(t, version: version)
            var days = Set<String>()
            for e in t.entries {
                guard entryIDs.insert(e.id).inserted, t.date(for: e.localDay) != nil, e.note.count <= 10000,
                      Self.validDate(e.occurredAt), Self.validDate(e.createdAt), Self.validDate(e.updatedAt),
                      e.photos.count <= Entry.photoLimit,
                      e.location?.isValid != false, e.photos.allSatisfy(Self.validPhoto) else { throw DataError.invalidBackup }
                if t.kind == .daily {
                    guard e.value == nil, e.change == nil, days.insert(e.localDay).inserted else { throw DataError.invalidBackup }
                } else {
                    guard (e.value == nil) != (e.change == nil),
                          version != 1 || e.change == nil,
                          (e.value ?? e.change).map(Numbers.isCanonical) == true else { throw DataError.invalidBackup }
                }
            }
            do { _ = try t.resolveEntries() } catch { throw DataError.invalidBackup }
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
    private static func validateMetadata(_ t: Tracker, version: Int) throws {
        if version < 3 {
            guard t.conditionGroups == nil, t.outerCombination == nil, t.cardTextPosition == nil,
                  t.showLastRecorded == nil, t.ringStyle == nil, t.lifecycle == nil, t.manualCompletion == nil else { throw DataError.invalidBackup }
        }
        guard (t.description?.count ?? 0) <= 10000,
              (t.photos?.count ?? 0) <= Entry.photoLimit,
              t.photos?.allSatisfy(validPhoto) != false else { throw DataError.invalidBackup }
        if let website = t.website {
            guard website.count <= 2048, let url = URLComponents(string: website),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty,
                  website.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { throw DataError.invalidBackup }
        }
        if let lower = t.axisLower, !Numbers.isCanonical(lower) { throw DataError.invalidBackup }
        if let upper = t.axisUpper, !Numbers.isCanonical(upper) { throw DataError.invalidBackup }
        if let lower = t.axisLower.flatMap(Numbers.decimal), let upper = t.axisUpper.flatMap(Numbers.decimal), lower >= upper {
            throw DataError.invalidBackup
        }
        guard (t.conditions?.count ?? 0) <= 20,
              t.conditionGroups == nil || t.conditions == nil && t.conditionCombination == nil else { throw DataError.invalidBackup }
        let groups = t.resolvedConditionGroups
        guard groups.count <= ConditionGroup.limit, Set(groups.map(\.id)).count == groups.count,
              groups.allSatisfy({ ($0.name?.count ?? 0) <= 120 && (1...ConditionGroup.limit).contains($0.conditions.count) }),
              t.gateSave != true || !groups.isEmpty || (version < 3 && t.conditionGroups == nil),
              t.remindWhenMet != true || !groups.isEmpty,
              t.remindWhenMet != true || t.supportsConditionReminders else { throw DataError.invalidBackup }
        let leaves = groups.flatMap(\.conditions)
        guard Set(leaves.map(\.id)).count == leaves.count else { throw DataError.invalidBackup }
        for leaf in leaves {
            switch leaf.payload {
            case .place(let place):
                guard !place.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      place.name.count <= 120, place.location.isValid else { throw DataError.invalidBackup }
            case .time(let time):
                guard (0..<1440).contains(time.startMinute), (0..<1440).contains(time.endMinute) else { throw DataError.invalidBackup }
            case .weekdays(let days):
                guard !days.isEmpty, days.count <= 7, Set(days).count == days.count,
                      days.allSatisfy({ (1...7).contains($0) }) else { throw DataError.invalidBackup }
            case .steps(let threshold), .sleep(let threshold):
                guard Numbers.isCanonical(threshold.threshold), let value = Numbers.decimal(threshold.threshold), value >= 0 else { throw DataError.invalidBackup }
                if case .steps = leaf.payload {
                    guard !threshold.threshold.contains("."), value <= 1_000_000_000 else { throw DataError.invalidBackup }
                } else { guard value <= 24 * 31 else { throw DataError.invalidBackup } }
            }
        }
        if let completion = t.manualCompletion {
            guard completion.manual, completion.trackerID == t.id, completion.kind == t.kind,
                  !completion.id.isEmpty, completion.id.count <= 120,
                  validDate(completion.achievedAt), validDate(completion.startedAt), completion.startedAt <= completion.achievedAt,
                  !completion.name.isEmpty, completion.name.count <= 120, completion.unit.count <= 30,
                  (0...8).contains(completion.precision), TimeZone(identifier: completion.timeZoneID) != nil,
                  completion.value.map(Numbers.isCanonical) != false, completion.target.map(Numbers.isCanonical) != false,
                  completion.thumbnail.map(validPhoto) != false, completion.plot.count <= 50, completion.locations.count <= 50,
                  completion.plot.allSatisfy({ validDate($0.date) && Numbers.isCanonical($0.value) }),
                  completion.locations.allSatisfy(\.isValid) else { throw DataError.invalidBackup }
        }
        let conditions = t.resolvedConditions
        guard conditions.count <= 100, Set(conditions.map(\.id)).count == conditions.count,
              conditions.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 120 && $0.location.isValid }),
              t.remindWhenMet != true || !conditions.isEmpty else { throw DataError.invalidBackup }
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
        var document = self
        if document.version >= 3 {
            document.trackers = trackers.map { tracker in var copy = tracker; copy.migrateConditions(); return copy }
        }
        try document.validate()
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        let data = try e.encode(document)
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
        var rows = ["tracker_id,name,kind,unit,entry_id,occurred_at,local_day,time_zone,value,note,latitude,longitude,input_kind,change"]
        for t in trackers { for e in t.resolvedEntries {
            let fields = [t.id.uuidString, t.name, t.kind.rawValue, t.unit, e.id.uuidString, iso.string(from: e.occurredAt), e.localDay, t.timeZoneID, e.value ?? "", e.note, e.location.map { String($0.latitude) } ?? "", e.location.map { String($0.longitude) } ?? "", t.kind == .daily ? "" : (e.change == nil ? "value" : "change"), e.change ?? ""]
            rows.append(fields.enumerated().map { escape($0.element, protect: [1, 3, 9].contains($0.offset)) }.joined(separator: ","))
        } }
        return rows.joined(separator: "\r\n") + "\r\n"
    }
}
