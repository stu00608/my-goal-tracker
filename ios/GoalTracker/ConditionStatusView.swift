import SwiftUI
import Observation

/// Keeps live checks independent of which lazy Form rows happen to be visible.
@MainActor @Observable final class ConditionPreview {
    private(set) var facts = ConditionFacts()
    private(set) var now = Date()
    private(set) var isRefreshing = false
    private(set) var locationAuthorized = false
    @ObservationIgnored private var tracker: Tracker?
    @ObservationIgnored private var observerOwner = UUID()
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    func status(for tracker: Tracker) -> ConditionStatus {
        RecordConditions.status(tracker: tracker, now: now, facts: facts)
    }
    var needsLocationCheck: Bool {
        !(tracker?.resolvedConditions.isEmpty ?? true) && (!locationAuthorized || facts.locationIssue != nil)
    }
    func start(tracker: Tracker, reset: Bool = false) {
        self.tracker = tracker
        if reset { facts = ConditionFacts() }
        let keys = Set(tracker.resolvedConditionGroups.flatMap(\.conditions).compactMap(\.healthKey))
        HealthConditions.shared.observe(keys: keys, owner: observerOwner)
        refresh(allHealth: true)
    }
    func stop() {
        cancelRequest()
        HealthConditions.shared.stopObserving(owner: observerOwner)
    }
    func automaticRefresh() {
        if request != nil { refreshQueued = true; return }
        refresh(allHealth: true)
    }
    func checkLocation(onFailure: @escaping (String) -> Void) { refresh(location: true, onFailure: onFailure) }
    private func cancelRequest() {
        generation = UUID(); request?.cancel(); request = nil; refreshQueued = false; isRefreshing = false
        facts.loadingPlaces = false; facts.loadingHealth = []
    }
    private func refresh(location: Bool = false, allHealth: Bool = false, onFailure: @escaping (String) -> Void = { _ in }) {
        guard let source = tracker else { return }
        cancelRequest(); now = Date()
        let token = generation
        if !source.resolvedConditions.isEmpty { locationAuthorized = RecordConditions.hasLocationAuthorization }
        if let fixture = RecordConditions.previewFixture(tracker: source, now: now) { facts = fixture; return }
        let needed = allHealth ? source.resolvedConditionGroups.flatMap(\.conditions)
            : ConditionEvaluation.neededLeaves(tracker: source, facts: facts, now: now)
        let keys = Set(needed.compactMap(\.healthKey))
        facts.loadingHealth = Set(keys.filter { key in
            guard let fact = facts.health[key] else { return true }
            return fact.start != HealthConditionEvaluation.start(window: key.window, calendar: source.calendar, now: now)
                || !(0...300).contains(now.timeIntervalSince(fact.through))
        })
        facts.loadingPlaces = location; isRefreshing = true
        request = Task {
            var checkingLocation = false
            defer {
                if generation == token {
                    request = nil; isRefreshing = false; facts.loadingHealth = []; facts.loadingPlaces = false; now = Date()
                    if !source.resolvedConditions.isEmpty { locationAuthorized = RecordConditions.hasLocationAuthorization }
                    if refreshQueued { refreshQueued = false; automaticRefresh() }
                }
            }
            do {
                let health = try await HealthConditions.shared.read(keys: keys, tracker: source, now: now)
                try Task.checkCancellation()
                guard generation == token else { return }
                facts.health.merge(health) { _, fresh in fresh }
                if location {
                    checkingLocation = true
                    let fix = try await RecordConditions.checkLocation(tracker: source)
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    facts.fix = fix; facts.locationIssue = nil
                } else if facts.locationIssue == nil && ConditionEvaluation.canVerifyWithLocation(tracker: source, facts: facts, now: Date()) {
                    checkingLocation = true; facts.loadingPlaces = true
                    if let fix = try await RecordConditions.checkAuthorizedLocation(tracker: source) {
                        try Task.checkCancellation()
                        guard generation == token else { return }
                        facts.fix = fix; facts.locationIssue = nil
                    }
                }
            } catch is CancellationError { }
            catch {
                guard generation == token else { return }
                if checkingLocation { facts.fix = nil; facts.locationIssue = (error as? ConditionError)?.key }
                if location { onFailure(L.error(error)) }
            }
        }
    }
}

struct ConditionPreviewUpdates: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let preview: ConditionPreview
    let tracker: Tracker
    private var signature: String { ConditionPlan.signature(tracker) + String(tracker.requiresConditionGate) }
    private var clockID: String { String(describing: scenePhase) + signature }
    func body(content: Content) -> some View {
        content
            .onAppear { if scenePhase == .active && tracker.requiresConditionGate { preview.start(tracker: tracker) } }
            .onChange(of: signature) { _, _ in
                if scenePhase == .active && tracker.requiresConditionGate { preview.start(tracker: tracker, reset: true) }
                else { preview.stop() }
            }
            .onChange(of: HealthConditions.shared.revision) { _, _ in
                if scenePhase == .active && tracker.requiresConditionGate { preview.automaticRefresh() }
            }
            .task(id: clockID) {
                guard scenePhase == .active && tracker.requiresConditionGate else { return }
                do {
                    while !Task.isCancelled {
                        let wait = 60 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
                        try await Task.sleep(for: .seconds(wait))
                        try Task.checkCancellation()
                        preview.automaticRefresh()
                    }
                } catch { }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active && tracker.requiresConditionGate { preview.start(tracker: tracker, reset: true) }
                else { preview.stop() }
            }
            .onDisappear { preview.stop() }
    }
}

struct ConditionStatusView: View {
    let tracker: Tracker
    let snapshot: ConditionStatus
    let preview: ConditionPreview
    var onFailure: (String) -> Void = { _ in }
    @State private var expanded = false

    var body: some View {
        Group {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 16) {
                    if tracker.resolvedConditionGroups.count > 1 {
                        Text(L.text(tracker.resolvedOuterCombination == .all ? "All groups" : "Any group"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(tracker.resolvedConditionGroups.enumerated()), id: \.element.id) { index, group in
                        if let result = snapshot.groups.first(where: { $0.id == group.id }) {
                            VStack(alignment: .leading, spacing: 12) {
                                if tracker.resolvedConditionGroups.count > 1 {
                                    Text(ConditionLabels.group(group, index: index)).fontWeight(.semibold)
                                        .accessibilityIdentifier("conditions.group." + group.id.uuidString)
                                    if group.conditions.count > 1 {
                                        Text(ConditionLabels.combination(group.combination)).foregroundStyle(.secondary)
                                    }
                                }
                                ForEach(group.conditions) { condition in
                                    if let leaf = result.leaves.first(where: { $0.id == condition.id }) {
                                        leafRow(condition: condition, status: leaf)
                                    }
                                }
                            }
                        }
                    }
                }.font(.subheadline).padding(.top, 8)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    stateSymbol(snapshot.state, loading: snapshot.loading)
                    Text(L.text(snapshot.loading ? "Checking conditions…" : snapshot.state == .met ? "Conditions met" : snapshot.state == .unmet ? "Conditions not met" : "Cannot determine yet"))
                        .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)
                    .accessibilityIdentifier("conditions.overall")
            }
            if preview.needsLocationCheck {
                Button(L.text("Check current location")) { preview.checkLocation(onFailure: onFailure) }
                    .buttonStyle(.borderless).disabled(preview.isRefreshing).frame(minHeight: 44)
                    .accessibilityIdentifier("conditions.checkLocation")
            }
        }
    }
    private func stateSymbol(_ state: ConditionState, loading: Bool) -> some View {
        Image(systemName: loading ? "questionmark.circle.fill" : state == .met ? "checkmark.circle.fill" : state == .unmet ? "xmark.circle.fill" : "questionmark.circle.fill")
            .foregroundStyle(loading ? Color.secondary : state == .met ? .green : state == .unmet ? .orange : .secondary)
            .accessibilityHidden(true)
    }
    private func leafRow(condition: AchievementCondition, status: ConditionLeafStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ConditionLabels.leaf(condition)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                if let value = status.measurement, let key = condition.healthKey {
                    Text(ConditionLabels.measurement(value, metric: key.metric)).monospacedDigit().foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            stateSymbol(status.state, loading: status.loading)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(ConditionLabels.leaf(condition) + measurementLabel(condition: condition, status: status))
            .accessibilityValue(L.text(status.loading ? "Checking conditions…" : status.state == .met ? "Condition met" : status.state == .unmet ? "Condition not met" : "Condition unknown"))
            .accessibilityIdentifier("conditions.leaf." + condition.id.uuidString)
    }
    private func measurementLabel(condition: AchievementCondition, status: ConditionLeafStatus) -> String {
        guard let value = status.measurement, let key = condition.healthKey else { return "" }
        return ", " + ConditionLabels.measurement(value, metric: key.metric)
    }
}

enum ConditionLabels {
    static func group(_ group: ConditionGroup, index: Int) -> String {
        if let name = group.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        return String(format: L.text("Group %lld"), locale: L.locale, index + 1)
    }
    static func combination(_ value: ConditionCombination) -> String { L.text(value == .all ? "All conditions" : "Any condition") }
    static func window(_ value: HealthWindow) -> String {
        L.text(value == .day ? "Today so far" : value == .week ? "This week so far (Monday start)" : "This month so far")
    }
    static func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
    static func measurement(_ value: Decimal, metric: HealthMetric) -> String {
        let number = Numbers.display(metric == .sleep ? value / 3600 : value, precision: metric == .sleep ? 2 : 0, locale: L.locale)
        return number + " " + L.text(metric == .sleep ? "hours" : "steps")
    }
    static func leaf(_ condition: AchievementCondition) -> String {
        switch condition.payload {
        case .place(let p): return p.name + " · " + L.text(p.relation == .inside ? "Inside" : "Outside") + " · 200 m"
        case .time(let t): return t.startMinute == t.endMinute ? L.text("All day") : clock(t.startMinute) + "–" + clock(t.endMinute)
        case .weekdays(let days):
            if Set(days).count == 7 { return L.text("Every day") }
            return WeekdayOrder.days(starting: L.firstWeekday).filter { days.contains($0) }
                .map { L.locale.calendar.weekdaySymbols[$0 - 1] }.joined(separator: " · ")
        case .steps(let t), .sleep(let t):
            let number = (Numbers.decimal(t.threshold).map { $0.formatted(.number.precision(.fractionLength(0...28)).locale(L.locale)) }) ?? t.threshold
            let key = condition.isSleep ? (t.comparison == .greater ? "More than %@ hours" : "Less than %@ hours")
                : (t.comparison == .greater ? "More than %@ steps" : "Fewer than %@ steps")
            return String(format: L.text(key), locale: L.locale, number) + " · " + window(t.window)
        }
    }
}
