import Testing
import Foundation
import UIKit
import ImageIO
@testable import GoalTracker

struct AchievementTests {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func tracker(_ kind: TrackerKind = .number) -> Tracker {
        Tracker(name: "達成 日本語 Achievement", kind: kind, timeZoneID: "UTC",
                createdAt: date("2024-01-01T00:00:00Z"))
    }
    private func number(_ tracker: Tracker, at time: String, value: String? = nil, change: String? = nil) -> Entry {
        let time = date(time)
        return Entry(occurredAt: time, localDay: tracker.day(time), value: value, change: change, createdAt: time, updatedAt: time)
    }
    private func rule(at time: String = "2024-01-01T00:00:00Z", target: String = "10", direction: Direction = .up) -> GoalRule {
        GoalRule(period: .deadline, target: target, effectiveAt: date(time), deadline: date("2024-12-31T23:59:59Z"), direction: direction)
    }
    private func daily(_ tracker: Tracker, day: String, at time: String? = nil) -> Entry {
        let occurred = time.map(date) ?? tracker.date(for: day)!.addingTimeInterval(3600)
        return Entry(occurredAt: occurred, localDay: day, createdAt: occurred, updatedAt: occurred)
    }
    private let now = ISO8601DateFormatter().date(from: "2024-01-20T12:00:00Z")!

    @Test func numericUsesCommonHistoricalHitAndStableRuleIdentity() throws {
        var t = tracker()
        t.rules = [rule(at: "2024-01-10T00:00:00Z")]
        let hit = number(t, at: "2024-01-02T00:00:00Z", value: "12")
        t.entries = [hit, number(t, at: "2024-01-11T00:00:00Z", value: "1")]
        let snapshot = try #require(CompletionEngine.snapshots(for: t, until: now).first)
        let common = try #require(t.achievement(for: t.rules[0], now: now))
        #expect(snapshot.evidenceEntryID == common.evidenceEntryID)
        #expect(snapshot.achievedAt == common.achievedAt && snapshot.achievedAt == t.rules[0].effectiveAt)
        #expect(snapshot.value == "12" && snapshot.startedAt == t.rules[0].effectiveAt)
        #expect(CompletionEngine.snapshots(for: t, until: now) == [snapshot])
        #expect(t.manualCompletion == nil)
    }

    @Test func decimalThresholdAndRawDeltaRemainExactAfterEvidenceEditAndDelete() throws {
        var t = tracker()
        t.rules = [rule(target: "1.000000000000000000000000001")]
        let baseline = number(t, at: "2024-01-01T00:00:00Z", value: "1")
        let change = number(t, at: "2024-01-02T00:00:00Z", change: "0.000000000000000000000000001")
        t.entries = [baseline, change]
        let raw = t.entries
        #expect(CompletionEngine.snapshots(for: t, until: now).first?.value == t.rules[0].target)
        #expect(t.entries == raw && t.entries[1].value == nil)
        t.entries[0].value = "0"
        #expect(CompletionEngine.snapshots(for: t, until: now).isEmpty)
        t.entries = [baseline]
        #expect(CompletionEngine.snapshots(for: t, until: now).isEmpty)
    }

    @Test func downDirectionAndFutureEvidenceAreHandledByCommonHelper() {
        var t = tracker()
        t.rules = [rule(target: "-10", direction: .down)]
        t.entries = [number(t, at: "2024-01-01T00:00:00Z", value: "0"),
                     number(t, at: "2024-02-01T00:00:00Z", value: "-10")]
        #expect(!CompletionEngine.isCompleted(tracker: t, now: now))
        #expect(CompletionEngine.snapshots(for: t, until: now).isEmpty)
        let later = date("2024-02-01T00:00:00Z")
        #expect(CompletionEngine.isCompleted(tracker: t, now: later))
    }

    @Test func frequencyUsesFirstNDistinctRecordedLocalDaysNotOccurrenceTimezone() throws {
        var t = tracker(.daily)
        t.createdAt = date("2024-01-03T00:00:00Z")
        t.rules = [GoalRule(period: .weekly, target: "2", effectiveAt: t.createdAt)]
        let first = daily(t, day: "2024-01-03", at: "2024-01-04T01:00:00Z")
        let second = daily(t, day: "2024-01-04", at: "2024-01-04T02:00:00Z")
        t.entries = [second, first, daily(t, day: "2024-01-04", at: "2024-01-04T03:00:00Z"), daily(t, day: "2024-01-05")]
        let snapshot = try #require(CompletionEngine.snapshots(for: t, until: now).first)
        #expect(snapshot.evidenceEntryID == second.id)
        #expect(snapshot.achievedAt == second.occurredAt && snapshot.value == "2")
        #expect(snapshot.periodStart == date("2024-01-01T00:00:00Z"))
        #expect(snapshot.startedAt == t.createdAt)
        #expect(snapshot.id.contains(t.rules[0].id.uuidString))
    }

    @Test func frequencyExcludesFutureInstantAndFutureRecordedDay() {
        var t = tracker(.daily)
        t.rules = [GoalRule(period: .monthly, target: "2", effectiveAt: t.createdAt)]
        t.entries = [daily(t, day: "2024-01-01"),
                     daily(t, day: "2024-01-02", at: "2024-01-21T00:00:00Z"),
                     daily(t, day: "2024-01-21", at: "2024-01-02T00:00:00Z")]
        #expect(CompletionEngine.snapshots(for: t, until: now).isEmpty)
    }

    @Test func changedFrequencyKeepsSplitPartialPeriodsAndDifferentRuleKeys() throws {
        var t = tracker(.daily)
        t.rules = [GoalRule(period: .weekly, target: "1", effectiveAt: t.createdAt),
                   GoalRule(period: .monthly, target: "2", effectiveAt: date("2024-01-04T00:00:00Z"))]
        t.entries = [daily(t, day: "2024-01-01"), daily(t, day: "2024-01-04"), daily(t, day: "2024-01-05")]
        let snapshots = CompletionEngine.snapshots(for: t, until: now)
        #expect(snapshots.count == 2 && Set(snapshots.map(\.id)).count == 2)
        #expect(snapshots[0].ruleID == t.rules[1].id && snapshots[0].periodStart == t.rules[1].effectiveAt)
        #expect(snapshots[1].ruleID == t.rules[0].id)
        #expect(t.frequencyHistory(until: now).contains { $0.3 })
        #expect(snapshots.allSatisfy { $0.startedAt <= $0.achievedAt })
    }

    @Test func dailyDeletionRemovesInvalidAchievementAndNewEvidenceRetainsKey() throws {
        var t = tracker(.daily)
        t.rules = [GoalRule(period: .weekly, target: "2", effectiveAt: t.createdAt)]
        t.entries = [daily(t, day: "2024-01-01"), daily(t, day: "2024-01-02"), daily(t, day: "2024-01-03")]
        let original = try #require(CompletionEngine.snapshots(for: t, until: now).first)
        t.entries.remove(at: 1)
        let updated = try #require(CompletionEngine.snapshots(for: t, until: now).first)
        #expect(updated.id == original.id && updated.evidenceEntryID != original.evidenceEntryID)
        t.entries.removeLast()
        #expect(CompletionEngine.snapshots(for: t, until: now).isEmpty)
    }

    @Test func finiteUsesCurrentGoalWhileOngoingRemainsActiveAndArchivedIsIndependent() {
        var t = tracker()
        t.rules = [rule()]
        t.entries = [number(t, at: "2024-01-02T00:00:00Z", value: "10")]
        #expect(CompletionEngine.isCompleted(tracker: t, now: now))
        t.archived = true
        #expect(CompletionEngine.isCompleted(tracker: t, now: now))
        t.lifecycle = .ongoing
        #expect(!CompletionEngine.isCompleted(tracker: t, now: now))
        #expect(CompletionEngine.snapshots(for: t, until: now).count == 1)
        t.lifecycle = .finite
        t.rules.append(rule(at: "2024-01-10T00:00:00Z", target: "20"))
        #expect(!CompletionEngine.isCompleted(tracker: t, now: now))
        #expect(CompletionEngine.snapshots(for: t, until: now).count == 1)
    }

    @Test func finiteDailyKeepsFirstAchievementUntilNewRuleWhileOngoingEmitsEveryPeriod() {
        var t = tracker(.daily)
        t.lifecycle = .finite
        t.rules = [GoalRule(period: .weekly, target: "1", effectiveAt: t.createdAt)]
        t.entries = [daily(t, day: "2024-01-02")]
        #expect(CompletionEngine.isCompleted(tracker: t, now: date("2024-01-03T00:00:00Z")))
        #expect(CompletionEngine.isCompleted(tracker: t, now: now))
        #expect(CompletionEngine.snapshots(for: t, until: now).count == 1)
        t.entries.append(daily(t, day: "2024-01-09"))
        #expect(CompletionEngine.snapshots(for: t, until: now).count == 1)
        t.lifecycle = .ongoing
        #expect(!CompletionEngine.isCompleted(tracker: t, now: now))
        #expect(CompletionEngine.snapshots(for: t, until: now).count == 2)
        t.lifecycle = .finite
        t.rules.append(GoalRule(period: .weekly, target: "2", effectiveAt: date("2024-01-15T00:00:00Z")))
        #expect(!CompletionEngine.isCompleted(tracker: t, now: now))
    }

    @Test func manualCompletionWithoutGoalIsFrozenAndReopenRemovesOnlyManualSnapshot() throws {
        var t = tracker()
        t.entries = [number(t, at: "2024-01-02T00:00:00Z", value: "2.123456789012345678901234567")]
        let frozen = CompletionEngine.manualSnapshot(tracker: t, now: now)
        #expect(frozen.manual && frozen.target == nil && frozen.value == t.entries[0].value)
        #expect(t.manualCompletion == nil)
        t.manualCompletion = frozen
        #expect(CompletionEngine.isCompleted(tracker: t, now: now))
        t.name = "Renamed"; t.entries.removeAll(); t.cardBackground = .map
        #expect(CompletionEngine.snapshots(for: t, until: now) == [frozen])
        #expect(CompletionEngine.manualSnapshot(tracker: t, now: now).id == frozen.id)
        t.manualCompletion = nil
        #expect(!CompletionEngine.isCompleted(tracker: t, now: now))
        #expect(CompletionEngine.manualSnapshot(tracker: t, now: now).id != frozen.id)
    }

    @Test func newRuleInvalidatesOldManualCompletionButRetainsItsHistory() {
        var t = tracker()
        t.manualCompletion = CompletionEngine.manualSnapshot(tracker: t, now: date("2024-01-02T00:00:00Z"))
        let old = t.manualCompletion!
        t.rules = [rule(at: "2024-01-03T00:00:00Z")]
        #expect(!CompletionEngine.isCompleted(tracker: t, now: now))
        #expect(CompletionEngine.snapshots(for: t, until: now) == [old])
        #expect(CompletionEngine.manualSnapshot(tracker: t, now: now).id != old.id)
    }

    @Test func startIsBoundedAndNeverProducesNegativeDurationForBackfilledEvidence() throws {
        var t = tracker()
        t.createdAt = date("2024-01-15T00:00:00Z")
        t.rules = [rule()]
        t.entries = [number(t, at: "2024-01-02T00:00:00Z", value: "10")]
        let snapshot = try #require(CompletionEngine.snapshots(for: t, until: now).first)
        #expect(snapshot.startedAt == snapshot.achievedAt)
        #expect(CompletionEngine.manualSnapshot(tracker: t, now: now).startedAt == t.createdAt)
    }

    @Test func restoreAndRepeatedDerivationPreserveRawDataAndStableAutomaticKeys() throws {
        var t = tracker()
        t.rules = [rule()]
        t.entries = [number(t, at: "2024-01-01T00:00:00Z", value: "5"), number(t, at: "2024-01-02T00:00:00Z", change: "5")]
        let original = CompletionEngine.snapshots(for: t, until: now)
        for version in [1, 2, 3] {
            var candidate = t
            if version == 1 { candidate.entries[1].value = "10"; candidate.entries[1].change = nil }
            let backup = Backup(version: version, exportedAt: now, trackers: [candidate])
            let bytes = try backup.encoded()
            let decoded = try Backup.decode(bytes)
            #expect(CompletionEngine.snapshots(for: decoded.trackers[0], until: now).map(\.id) == original.map(\.id))
            #expect(try decoded.encoded() == bytes)
            #expect(decoded.trackers[0].manualCompletion == nil)
        }
        #expect(CompletionEngine.snapshots(for: t, until: now) == original)
        #expect(t.entries[1].change == "5" && t.entries[1].value == nil)
    }

    @Test func frozenManualBackupRoundTripRetainsLocalTimezoneAndOwnedThumbnail() throws {
        var t = tracker()
        t.timeZoneID = "Asia/Tokyo"
        t.cardBackground = .trackerPhoto
        let image = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 800)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 800))
        }
        t.photos = [try #require(image.jpegData(compressionQuality: 0.8))]
        t.manualCompletion = CompletionEngine.manualSnapshot(tracker: t, now: now)
        let thumbnail = try #require(t.manualCompletion?.thumbnail)
        let source = try #require(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        #expect((properties[kCGImagePropertyPixelWidth as String] as? Int ?? 601) <= 600)
        #expect((properties[kCGImagePropertyPixelHeight as String] as? Int ?? 601) <= 600)
        let restored = try Backup.decode(Backup(exportedAt: now, trackers: [t]).encoded())
        #expect(restored.trackers[0].manualCompletion == t.manualCompletion)
        #expect(restored.trackers[0].manualCompletion?.timeZoneID == "Asia/Tokyo")
    }

    @Test func chartAndMapPayloadsAreBoundedAndDoNotIncludeFutureRecords() {
        var t = tracker()
        t.entries = (0..<100).map { offset in
            let occurred = t.createdAt.addingTimeInterval(Double(offset) * 60)
            return Entry(occurredAt: occurred, localDay: t.day(occurred), value: String(offset),
                         location: RecordedLocation(latitude: 35, longitude: 139))
        }
        t.entries.append(number(t, at: "2024-02-01T00:00:00Z", value: "999"))
        let plot = CompletionEngine.manualSnapshot(tracker: t, now: now)
        #expect(plot.plot.count == 50 && plot.plot.last?.value == "99" && plot.locations.isEmpty)
        t.cardBackground = .map
        let map = CompletionEngine.manualSnapshot(tracker: t, now: now)
        #expect(map.locations.count == 50 && map.plot.isEmpty && map.thumbnail == nil)
    }

    @Test func flatExportCreatesRealImageAndPNGAndRequiresPreparedMap() throws {
        let snapshot = CompletionEngine.manualSnapshot(tracker: tracker(), now: now)
        #expect(snapshot.value == nil && snapshot.target == nil)
        #expect(AchievementText.value(snapshot) == L.text("No snapshots"))
        let image = try #require(AchievementExport.image(snapshot: snapshot))
        #expect(image.size.width == 600 && image.size.height >= 750)
        let png = try #require(AchievementExport.png(snapshot: snapshot))
        #expect(png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
        var map = snapshot
        map.background = .map; map.locations = [RecordedLocation(latitude: 35, longitude: 139)]
        #expect(AchievementExport.image(snapshot: map) == nil)
    }
}
