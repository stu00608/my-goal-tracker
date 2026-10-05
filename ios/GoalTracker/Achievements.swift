import Foundation

/// Read-only display models. Automatic achievements never become ledger records.
nonisolated enum CompletionEngine {
    static func snapshots(for tracker: Tracker, until now: Date) -> [AchievementSnapshot] {
        var result: [AchievementSnapshot] = []
        if tracker.kind == .number {
            for rule in tracker.rules {
                guard let hit = tracker.achievement(for: rule, now: now) else { continue }
                result.append(snapshot(tracker: tracker, id: numericKey(rule), rule: rule,
                                       evidence: hit.evidenceEntryID, periodStart: nil,
                                       achievedAt: hit.achievedAt, value: hit.value))
            }
        } else {
            // frequencyHistory owns rule changes, calendar boundaries and partial periods.
            // Recount only real, nonfuture, distinct recorded LOCAL days in each window.
            let initial = tracker.rules.map(\.effectiveAt).min()
            for (window, _, target, _) in tracker.frequencyHistory(until: now) {
                guard let initial, target > 0,
                      let rule = tracker.rule(at: max(window.start, initial)) else { continue }
                if tracker.resolvedLifecycle == .finite && result.contains(where: { $0.ruleID == rule.id }) { continue }
                let days = dailyEvidence(tracker: tracker, in: window, until: now)
                guard days.count >= target else { continue }
                let evidence = days[target - 1]
                let achievedAt = max(rule.effectiveAt, days.prefix(target).map(\.occurredAt).max() ?? evidence.occurredAt,
                                     tracker.date(for: evidence.localDay) ?? evidence.occurredAt)
                guard achievedAt <= now else { continue }
                result.append(snapshot(tracker: tracker, id: periodKey(rule, start: window.start),
                                       rule: rule, evidence: evidence.id, periodStart: window.start,
                                       achievedAt: achievedAt, value: String(target)))
            }
        }
        if let manual = tracker.manualCompletion, validManual(manual, tracker: tracker, until: now) {
            result.append(manual)
        }
        // Stable keys survive decode, reopening and repeated view creation.
        return result.sorted { ($0.achievedAt, $0.id) > ($1.achievedAt, $1.id) }
    }

    static func isCompleted(tracker: Tracker, now: Date) -> Bool {
        guard tracker.resolvedLifecycle == .finite else { return false }
        let rule = tracker.rule(at: now)
        if let manual = tracker.manualCompletion,
           validManual(manual, tracker: tracker, until: now),
           manual.achievedAt >= max(tracker.createdAt, rule?.effectiveAt ?? tracker.createdAt) {
            return true
        }
        guard let rule else { return false }
        if tracker.kind == .number { return tracker.achievement(for: rule, now: now) != nil }
        return snapshots(for: tracker, until: now).contains { $0.ruleID == rule.id && !$0.manual }
    }

    /// Call only from the explicit completion action, after Root verifies gates.
    /// Repeated taps while already completed return the same persisted manual identity.
    static func manualSnapshot(tracker: Tracker, now: Date) -> AchievementSnapshot {
        let rule = tracker.rule(at: now)
        if let existing = tracker.manualCompletion,
           validManual(existing, tracker: tracker, until: now),
           existing.achievedAt >= max(tracker.createdAt, rule?.effectiveAt ?? tracker.createdAt) {
            return existing
        }
        let latest = tracker.resolvedEntries.last { $0.occurredAt <= now }
        let window = tracker.kind == .daily ? rule.map { tracker.interval(now, period: $0.period) } : nil
        let value = tracker.kind == .number ? latest?.value
            : String(dailyEvidence(tracker: tracker, in: window, until: now).count)
        var result = snapshot(tracker: tracker, id: "manual:" + UUID().uuidString, rule: rule,
                              evidence: tracker.kind == .number ? latest?.id : nil,
                              periodStart: window?.start, achievedAt: now, value: value)
        result.manual = true
        return result
    }

    private static func validManual(_ snapshot: AchievementSnapshot, tracker: Tracker, until now: Date) -> Bool {
        snapshot.manual && snapshot.trackerID == tracker.id && snapshot.kind == tracker.kind &&
            !snapshot.id.isEmpty && snapshot.achievedAt <= now &&
            snapshot.startedAt <= snapshot.achievedAt && snapshot.value.map(Numbers.isCanonical) != false
    }

    private static func numericKey(_ rule: GoalRule) -> String { "numeric:" + rule.id.uuidString }
    private static func periodKey(_ rule: GoalRule, start: Date) -> String {
        "period:" + rule.id.uuidString + ":" + String(start.timeIntervalSinceReferenceDate)
    }

    private static func dailyEvidence(tracker: Tracker, in window: DateInterval?, until now: Date) -> [Entry] {
        let today = tracker.day(now)
        var seen = Set<String>()
        return tracker.sortedEntries.filter { entry in
            guard entry.occurredAt <= now, entry.localDay <= today,
                  let localDate = tracker.date(for: entry.localDay),
                  window.map({ localDate >= $0.start && localDate < $0.end }) != false else { return false }
            return true
        }.sorted {
            ($0.localDay, $0.occurredAt, $0.createdAt, $0.id.uuidString) <
                ($1.localDay, $1.occurredAt, $1.createdAt, $1.id.uuidString)
        }.filter { seen.insert($0.localDay).inserted }
    }

    private static func snapshot(tracker: Tracker, id: String, rule: GoalRule?, evidence: UUID?,
                                 periodStart: Date?, achievedAt: Date, value: String?) -> AchievementSnapshot {
        let start = min(achievedAt, max(tracker.createdAt, rule?.effectiveAt ?? tracker.createdAt,
                                        periodStart ?? tracker.createdAt))
        let entries = tracker.resolvedEntries.filter {
            $0.occurredAt <= achievedAt && (tracker.kind != .daily || $0.localDay <= tracker.day(achievedAt))
        }
        let background = tracker.resolvedCardBackground
        let photo: Data?
        switch background {
        case .photo: photo = entries.reversed().first { !$0.photos.isEmpty }?.photos.first
        case .trackerPhoto: photo = tracker.photos?.first
        default: photo = nil
        }
        // Reuse Widget's JPEG helper (320px, <=60KB), below the snapshot's 600px limit.
        let thumbnail = photo.flatMap(WidgetRow.makeThumbnail)
        let plot: [AchievementPlotPoint]
        if background == .plot {
            if tracker.kind == .number {
                plot = Array(entries.compactMap { entry -> AchievementPlotPoint? in
                    entry.value.map { AchievementPlotPoint(date: entry.occurredAt, value: $0) }
                }.suffix(50))
            } else {
                plot = dailyEvidence(tracker: tracker, in: nil, until: achievedAt).suffix(50).compactMap {
                    tracker.date(for: $0.localDay).map { AchievementPlotPoint(date: $0, value: "1") }
                }
            }
        } else { plot = [] }
        let locations = background == .map ? Array(entries.compactMap(\.location).filter(\.isValid).suffix(50)) : []
        return AchievementSnapshot(id: id, trackerID: tracker.id, ruleID: rule?.id,
                                   evidenceEntryID: evidence, periodStart: periodStart,
                                   achievedAt: achievedAt, startedAt: start, name: tracker.name,
                                   kind: tracker.kind, unit: tracker.unit, precision: tracker.precision,
                                   value: value, target: rule?.target, timeZoneID: tracker.timeZoneID,
                                   background: background, thumbnail: thumbnail, plot: plot, locations: locations)
    }
}
