import SwiftUI

struct AchievementConditionEditor: View {
    @Binding var groups: [ConditionGroup]
    @Binding var outerCombination: ConditionCombination
    @Binding var gateSave: Bool
    @State private var expanded: Set<UUID> = []
    @State private var firstGroupID = UUID()
    @Binding var editing: ConditionEditorSelection?
    @Binding var deleting: ConditionGroup?
    @State private var initialized = false

    let healthAccess: HealthConditionAccess
    let onConnectHealth: () -> Void

    var body: some View {
        if healthAccess.needsConnection {
            Section {
                Button(action: onConnectHealth) {
                    Label(L.text("Connect Apple Health for more conditions"), systemImage: "heart.fill")
                        .multilineTextAlignment(.leading).frame(minHeight: 44)
                }.buttonStyle(.borderless).accessibilityIdentifier("conditions.healthSetup")
            }
        }
        if groups.count > 1 {
            Section {
                Picker(L.text("Combine groups"), selection: $outerCombination) {
                    Text(L.text("All groups")).tag(ConditionCombination.all)
                    Text(L.text("Any group")).tag(ConditionCombination.any)
                }.tint(.primary).accessibilityIdentifier("tracker.conditions.outerCombination")
            }
        }
        if groups.isEmpty || (groups.count == 1 && groups[0].conditions.isEmpty) {
            Section { addCondition(groupID: groups.first?.id ?? firstGroupID, count: 0) }
        }
        ForEach(Array(groups.enumerated()).filter { groups.count > 1 || !$0.element.conditions.isEmpty }, id: \.element.id) { index, group in
            Section {
                if groups.count == 1 || flatExpanded { contents(group: group) }
                else {
                    DisclosureGroup(isExpanded: expansion(group.id)) {
                        contents(group: group)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ConditionLabels.group(group, index: index))
                                .accessibilityIdentifier("conditions.editor.group." + group.id.uuidString)
                            Text(ConditionLabels.combination(group.combination) + " · " + String(group.conditions.count))
                                .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                if flatExpanded && groups.count > 1 { Text(ConditionLabels.group(group, index: index)) }
            }
        }.onAppear {
            guard !initialized else { return }; initialized = true
            if let first = groups.first { expanded.insert(first.id) }
        }
        if groups.contains(where: { !$0.conditions.isEmpty }) && groups.count < ConditionGroup.limit {
            Section {
                Button(L.text("Add group")) {
                    let group = ConditionGroup(); groups.append(group); expanded.insert(group.id)
                }.accessibilityIdentifier("conditions.editor.addGroup")
            }
        }
        if groups.contains(where: { !$0.conditions.isEmpty }) {
            Section {
                Toggle(L.text("Require conditions to save a record"), isOn: $gateSave)
                    .disabled(groups.contains { $0.conditions.isEmpty })
                    .accessibilityIdentifier("tracker.conditions.gate")
            } footer: { Text(L.text("Checked against now")) }
        }
    }

    @ViewBuilder private func contents(group: ConditionGroup) -> some View {
        LabeledContent(L.text("Name")) {
            TextField(L.text("Group name (optional)"), text: Binding(
                get: { groups.first { $0.id == group.id }?.name ?? "" },
                set: { value in if let index = groups.firstIndex(where: { $0.id == group.id }) { groups[index].name = value.isEmpty ? nil : value } }
            )).multilineTextAlignment(.trailing).accessibilityIdentifier("conditions.editor.name." + group.id.uuidString)
        }
        if group.conditions.count > 1 {
            Picker(L.text("Combine conditions"), selection: Binding(
                get: { groups.first { $0.id == group.id }?.combination ?? .all },
                set: { value in if let index = groups.firstIndex(where: { $0.id == group.id }) { groups[index].combination = value } }
            )) {
                Text(L.text("All conditions")).tag(ConditionCombination.all)
                Text(L.text("Any condition")).tag(ConditionCombination.any)
            }.tint(.primary).accessibilityIdentifier("conditions.editor.combination." + group.id.uuidString)
        }
        ForEach(group.conditions) { condition in
            Button { editing = ConditionEditorSelection(groupID: group.id, condition: condition, kind: ConditionLeafKind(condition.payload)) } label: {
                Text(ConditionLabels.leaf(condition)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.buttonStyle(.borderless).tint(.primary).accessibilityIdentifier("conditions.editor.leaf." + condition.id.uuidString)
                .swipeActions { Button(L.text("Delete"), role: .destructive) { remove(condition: condition, groupID: group.id) } }
                .contextMenu { Button(L.text("Delete condition"), role: .destructive) { remove(condition: condition, groupID: group.id) } }
                .accessibilityAction(named: L.text("Delete condition")) { remove(condition: condition, groupID: group.id) }
        }
        addCondition(groupID: group.id, count: group.conditions.count)
        if groups.count > 1 {
            Button(L.text("Delete group"), role: .destructive) {
                if group.conditions.isEmpty { delete(group: group) } else { deleting = group }
            }.buttonStyle(.borderless).accessibilityIdentifier("conditions.editor.deleteGroup." + group.id.uuidString)
        }
    }
    @ViewBuilder private func addCondition(groupID: UUID, count: Int) -> some View {
        if count < ConditionGroup.limit {
            Menu {
                ForEach(ConditionLeafKind.available(healthAccess: healthAccess)) { kind in
                    Button(L.text(kind.title)) { editing = ConditionEditorSelection(groupID: groupID, condition: nil, kind: kind) }
                        .accessibilityIdentifier("conditions.editor.add." + kind.rawValue)
                }
            } label: {
                Label(L.text("Add condition"), systemImage: "plus")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
                .buttonStyle(.borderless).accessibilityIdentifier("conditions.editor.addCondition." + groupID.uuidString)
        }
    }
    private func delete(group: ConditionGroup) {
        guard groups.count > 1 else { return }
        groups.removeAll { $0.id == group.id }; expanded.remove(group.id)
        if groups.allSatisfy({ $0.conditions.isEmpty }) { gateSave = false }
    }
    private func remove(condition: AchievementCondition, groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].conditions.removeAll { $0.id == condition.id }
        if groups.allSatisfy({ $0.conditions.isEmpty }) { gateSave = false }
    }
    private func expansion(_ id: UUID) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }
    private var flatExpanded: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--uitesting") && ProcessInfo.processInfo.arguments.contains("--conditions-flat-expanded")
        #else
        false
        #endif
    }
}

struct ConditionEditorSelection: Identifiable {
    let id = UUID()
    let groupID: UUID
    let condition: AchievementCondition?
    let kind: ConditionLeafKind
}
enum ConditionLeafKind: String, Identifiable, CaseIterable {
    case place, time, weekdays, steps, sleep
    var id: String { rawValue }
    static func available(healthAccess: HealthConditionAccess) -> [Self] {
        allCases.filter {
            switch $0 {
            case .steps: healthAccess.steps == .requested
            case .sleep: healthAccess.sleep == .requested
            default: true
            }
        }
    }
    var title: String {
        switch self { case .place: "Place"; case .time: "Time range"; case .weekdays: "Weekdays"; case .steps: "Steps"; case .sleep: "Sleep" }
    }
    init(_ payload: ConditionPayload) {
        switch payload { case .place: self = .place; case .time: self = .time; case .weekdays: self = .weekdays; case .steps: self = .steps; case .sleep: self = .sleep }
    }
}

struct AchievementLeafEditor: View {
    @Environment(\.dismiss) private var dismiss
    let existing: AchievementCondition?
    let kind: ConditionLeafKind
    let onSave: (ConditionPayload) -> Void
    @State private var startMinute = 9 * 60
    @State private var endMinute = 17 * 60
    @State private var weekdays = Set(1...7)
    @State private var comparison = ThresholdComparison.greater
    @State private var threshold = ""
    @State private var window = HealthWindow.day
    @State private var initialized = false
    @State private var error: String?
    @State private var keyboard = EditorKeyboardControl()
    @FocusState private var numberFocused: Bool

    var body: some View {
        if kind == .place {
            ConditionEditor(existing: existing?.place) { onSave(.place($0)) }
        } else {
            NavigationStack {
                Form {
                    switch kind {
                    case .time: timeFields
                    case .weekdays: weekdayFields
                    case .steps, .sleep: healthFields
                    case .place: EmptyView()
                    }
                }
                .statusToast(message: $error, identifier: "condition.error")
                .scrollDismissesKeyboard(.interactively)
                .background(EditorKeyboardDismissal(keyboard: keyboard, dismiss: { keyboard.dismiss(); numberFocused = false }))
                .navigationTitle(L.text(kind.title)).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L.text("Cancel")) { dismiss() }.accessibilityIdentifier("condition.cancel") }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L.text("Done"), action: save).disabled(kind == .weekdays && weekdays.isEmpty)
                            .accessibilityIdentifier("condition.confirm")
                    }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button(L.text("Done")) { keyboard.dismiss(); numberFocused = false }.accessibilityIdentifier("condition.keyboard.done") }
                }
                .onAppear(perform: load)
            }
        }
    }
    private var timeFields: some View {
        Section {
            DatePicker(L.text("Start time"), selection: clockBinding($startMinute), displayedComponents: .hourAndMinute)
                .accessibilityIdentifier("condition.time.start")
            DatePicker(L.text("End time"), selection: clockBinding($endMinute), displayedComponents: .hourAndMinute)
                .accessibilityIdentifier("condition.time.end")
        } footer: {
            if startMinute == endMinute { Text(L.text("Same start and end means all day.")) }
        }
        .environment(\.timeZone, .gmt)
    }
    private var weekdayFields: some View {
        Section {
            WeekdaySelector(weekdays: $weekdays, identifier: "condition.weekday")
        } footer: { if weekdays.isEmpty { Text(L.text("Choose at least one weekday.")) } }
    }
    private var healthFields: some View {
        Section {
            Picker(L.text("Comparison"), selection: $comparison) {
                Text(L.text("Greater than")).tag(ThresholdComparison.greater)
                Text(L.text("Less than")).tag(ThresholdComparison.less)
            }.tint(.primary).accessibilityIdentifier("condition.health.comparison")
            TextField(L.text(kind == .sleep ? "Sleep hours" : "Step count"), text: $threshold)
                .keyboardType(kind == .sleep ? .decimalPad : .numberPad).monospacedDigit().focused($numberFocused)
                .accessibilityIdentifier("condition.health.threshold")
            Picker(L.text("Calendar period"), selection: $window) {
                ForEach(HealthWindow.allCases, id: \.self) { Text(ConditionLabels.window($0)).tag($0) }
            }.tint(.primary).accessibilityIdentifier("condition.health.window")
        }
    }
    private func clockBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        // A fixed non-DST reference day keeps typed wall-clock minutes independent of this device's timezone.
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let origin = Date(timeIntervalSince1970: 0)
        return Binding(get: { origin.addingTimeInterval(Double(minutes.wrappedValue * 60)) }, set: {
            let parts = calendar.dateComponents([.hour, .minute], from: $0)
            minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }
    private func load() {
        guard !initialized else { return }; initialized = true
        guard let existing else { threshold = kind == .sleep ? "7" : "5000"; return }
        switch existing.payload {
        case .time(let t): startMinute = t.startMinute; endMinute = t.endMinute
        case .weekdays(let days): weekdays = Set(days)
        case .steps(let t), .sleep(let t):
            comparison = t.comparison; window = t.window
            threshold = t.threshold.replacingOccurrences(of: ".", with: L.locale.decimalSeparator ?? ".")
        default: break
        }
    }
    private func save() {
        do {
            let payload: ConditionPayload
            switch kind {
            case .time: payload = .time(TimeCondition(startMinute: startMinute, endMinute: endMinute))
            case .weekdays:
                guard !weekdays.isEmpty else { throw ConditionError("Choose at least one weekday.") }
                payload = .weekdays(weekdays.sorted())
            case .steps, .sleep:
                let text = try Numbers.parse(threshold, locale: L.locale)
                guard let value = Numbers.decimal(text), value >= 0,
                      value <= (kind == .steps ? Decimal(1_000_000_000) : Decimal(744)),
                      kind != .steps || !text.contains(".") else {
                    throw ConditionError("Enter nonnegative whole steps up to 1,000,000,000, or sleep hours up to 744.")
                }
                let health = HealthThreshold(comparison: comparison, threshold: text, window: window)
                payload = kind == .steps ? .steps(health) : .sleep(health)
            case .place: return
            }
            onSave(payload); dismiss()
        } catch { self.error = L.error(error) }
    }
}

/// Calendar identifiers stay Sunday=1; the display order follows the user's preference.
struct WeekdaySelector: View {
    @Binding var weekdays: Set<Int>
    let identifier: String
    var body: some View {
        HStack(spacing: 4) {
            ForEach(WeekdayOrder.days(starting: L.firstWeekday), id: \.self) { day in
                let selected = weekdays.contains(day)
                Toggle(isOn: Binding(get: { weekdays.contains(day) }, set: {
                    if $0 { weekdays.insert(day) } else { weekdays.remove(day) }
                })) {
                    Text(L.locale.calendar.veryShortStandaloneWeekdaySymbols[day - 1])
                        .font(.body.weight(.medium)).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity).frame(minWidth: 44, minHeight: 44)
                        .foregroundStyle(selected ? Color(uiColor: .systemBackground) : .primary)
                        .background(selected ? TrackerColors.accent : .clear, in: Circle())
                        .overlay { Circle().strokeBorder(selected ? .clear : Color.secondary, lineWidth: 1) }
                }.toggleStyle(.button).buttonStyle(.plain)
                    .accessibilityLabel(L.locale.calendar.weekdaySymbols[day - 1])
                    .accessibilityIdentifier(identifier + ".\(day)")
            }
        }.accessibilityElement(children: .contain)
    }
}
