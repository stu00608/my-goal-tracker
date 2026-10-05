import SwiftUI

struct ConditionStatusView: View {
    @Environment(\.scenePhase) private var scenePhase
    let tracker: Tracker
    @State private var facts = ConditionFacts()
    @State private var request: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var error: String?

    var body: some View {
        if tracker.requiresConditionGate {
            TimelineView(.everyMinute) { context in
                let snapshot = RecordConditions.status(tracker: tracker, now: context.date, facts: facts)
                VStack(alignment: .leading, spacing: 14) {
                    statusRow(title: L.text("Overall result"), state: snapshot.state, loading: snapshot.loading)
                        .font(.headline).accessibilityIdentifier("conditions.overall")
                    Text(L.text(tracker.resolvedOuterCombination == .all ? "All groups" : "Any group"))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(tracker.resolvedConditionGroups.enumerated()), id: \.element.id) { index, group in
                        if let result = snapshot.groups.first(where: { $0.id == group.id }) {
                            VStack(alignment: .leading, spacing: 8) {
                                statusRow(title: ConditionLabels.group(group, index: index), state: result.state, loading: result.loading)
                                    .font(.subheadline.weight(.semibold)).accessibilityIdentifier("conditions.group." + group.id.uuidString)
                                Text(ConditionLabels.combination(group.combination)).font(.caption).foregroundStyle(.secondary)
                                ForEach(group.conditions) { condition in
                                    if let leaf = result.leaves.first(where: { $0.id == condition.id }) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            statusRow(title: ConditionLabels.leaf(condition), state: leaf.state, loading: leaf.loading)
                                            if let detail = leaf.detail {
                                                Text(L.text(detail)).font(.caption).foregroundStyle(.secondary)
                                            }
                                            if let value = leaf.measurement, let key = condition.healthKey {
                                                Text(ConditionLabels.measurement(value, metric: key.metric))
                                                    .font(.caption).foregroundStyle(.secondary)
                                                if let date = leaf.measuredAt {
                                                    Text(String(format: L.text("Read at %@"), locale: L.locale,
                                                        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened,
                                                            locale: L.locale, calendar: tracker.calendar, timeZone: tracker.calendar.timeZone))))
                                                        .font(.caption).foregroundStyle(.secondary)
                                                }
                                            }
                                        }.accessibilityElement(children: .combine)
                                            .accessibilityIdentifier("conditions.leaf." + condition.id.uuidString)
                                    }
                                }
                            }
                        }
                    }
                    Text(L.text("Conditions use the current time, even for a backdated record."))
                        .font(.caption).foregroundStyle(.secondary)
                    if tracker.resolvedConditionGroups.flatMap(\.conditions).contains(where: \.isHealth) {
                        Text(L.text("Based on readable Apple Health data so far in this calendar period. Sleep is clipped to the period, not grouped by wake-up."))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(L.text("Connect Apple Health")) { refresh(connect: true) }
                            .buttonStyle(.borderless).disabled(request != nil).accessibilityIdentifier("conditions.connectHealth")
                    }
                    if !tracker.resolvedConditions.isEmpty {
                        Button(L.text("Check current location")) { refresh(location: true) }
                            .buttonStyle(.borderless).disabled(request != nil).accessibilityIdentifier("conditions.checkLocation")
                    }
                    Button(L.text("Refresh conditions")) { refresh(allHealth: true) }
                        .buttonStyle(.borderless).disabled(request != nil).accessibilityIdentifier("conditions.refresh")
                    if let error { Text(error).font(.callout).foregroundStyle(.red).accessibilityIdentifier("conditions.error") }
                }.padding(.vertical, 4)
            }
            .onAppear { refresh() }
            .onChange(of: ConditionPlan.signature(tracker)) { _, _ in facts = ConditionFacts(); refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { facts = ConditionFacts(); refresh() }
                else { stop() }
            }
            .onDisappear { stop() }
        }
    }
    @ViewBuilder private func statusRow(title: String, state: ConditionState, loading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            if loading { ProgressView(L.text("Checking conditions…")) }
            else {
                Label(L.text(state == .met ? "Conditions met" : state == .unmet ? "Conditions not met" : "Cannot determine yet"),
                    systemImage: state == .met ? "checkmark.circle" : state == .unmet ? "xmark.circle" : "questionmark.circle")
                    .font(.caption).foregroundStyle(state == .unmet ? Color.red : Color.secondary)
            }
        }.accessibilityElement(children: .combine)
    }
    private func stop() {
        generation = UUID(); request?.cancel(); request = nil
        facts.loadingPlaces = false; facts.loadingHealth = []
    }
    private func refresh(connect: Bool = false, location: Bool = false, allHealth: Bool = false) {
        stop(); error = nil
        let token = generation
        let source = tracker
        if let fixture = RecordConditions.previewFixture(tracker: source) { facts = fixture; return }
        let needed = allHealth || connect ? source.resolvedConditionGroups.flatMap(\.conditions)
            : ConditionEvaluation.neededLeaves(tracker: source, facts: facts, now: Date())
        let keys = Set(needed.compactMap(\.healthKey))
        facts.loadingHealth = keys
        facts.loadingPlaces = location
        request = Task {
            var checkingLocation = false
            defer {
                if generation == token { request = nil; facts.loadingHealth = []; facts.loadingPlaces = false }
            }
            do {
                if connect { try await HealthConditions.shared.connect(tracker: source) }
                let health = try await HealthConditions.shared.read(keys: keys, tracker: source, now: Date())
                try Task.checkCancellation()
                guard generation == token else { return }
                facts.health.merge(health) { _, fresh in fresh }
                if location {
                    checkingLocation = true
                    let fix = try await RecordConditions.checkLocation(tracker: source)
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    facts.fix = fix; facts.locationIssue = nil
                } else if ConditionEvaluation.canVerifyWithLocation(tracker: source, facts: facts, now: Date()) {
                    checkingLocation = true
                    facts.loadingPlaces = true
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
                self.error = L.error(error)
            }
        }
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
            return WeekdayOrder.days(starting: L.firstWeekday).filter { days.contains($0) }
                .map { L.locale.calendar.weekdaySymbols[$0 - 1] }.joined(separator: " · ")
        case .steps(let t), .sleep(let t):
            let title = L.text(condition.isSleep ? "Sleep" : "Steps")
            let number = t.threshold.replacingOccurrences(of: ".", with: L.locale.decimalSeparator ?? ".")
            return title + " " + (t.comparison == .greater ? "> " : "< ") + number
                + (condition.isSleep ? " " + L.text("hours") : "") + " · " + window(t.window)
        }
    }
}
