import SwiftUI

struct AchievementConditionEditor: View {
    @Binding var groups: [ConditionGroup]
    @Binding var outerCombination: ConditionCombination
    @Binding var gateSave: Bool
    @State private var expanded: Set<UUID> = []
    @Binding var editing: ConditionEditorSelection?
    @Binding var deleting: ConditionGroup?
    @State private var initialized = false

    var body: some View {
        Section {
            Toggle(L.text("Require conditions to save a record"), isOn: $gateSave)
                .disabled(groups.isEmpty || groups.contains { $0.conditions.isEmpty })
                .accessibilityIdentifier("tracker.conditions.gate")
            Picker(L.text("Combine groups"), selection: $outerCombination) {
                Text(L.text("All groups")).tag(ConditionCombination.all)
                Text(L.text("Any group")).tag(ConditionCombination.any)
            }.disabled(groups.count <= 1).accessibilityIdentifier("tracker.conditions.outerCombination")
        } header: { Text(L.text("Achievement conditions")) } footer: {
            Text(L.text("New records and changes to a record’s number or date check the current conditions. Notes and photos can still be edited."))
        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            if groups.isEmpty { groups = [ConditionGroup()] }
            if let first = groups.first { expanded.insert(first.id) }
        }
        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
            Section {
                if flatExpanded { contents(group: group) }
                else {
                    DisclosureGroup(isExpanded: expansion(group.id)) {
                        contents(group: group)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ConditionLabels.group(group, index: index))
                                .accessibilityIdentifier("conditions.editor.group." + group.id.uuidString)
                            Text(ConditionLabels.combination(group.combination) + " · " + String(group.conditions.count))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                if flatExpanded { Text(ConditionLabels.group(group, index: index)) }
            }
        }
        Section {
            Button(L.text("Add group")) {
                guard groups.count < ConditionGroup.limit else { return }
                let group = ConditionGroup(); groups.append(group); expanded.insert(group.id)
            }.disabled(groups.count >= ConditionGroup.limit).accessibilityIdentifier("conditions.editor.addGroup")
        } footer: { Text(L.text("Up to 10 groups, with up to 10 conditions in each group.")) }

    }
    @ViewBuilder private func contents(group: ConditionGroup) -> some View {
        LabeledContent(L.text("Name")) {
            TextField(L.text("Group name (optional)"), text: Binding(
                get: { groups.first { $0.id == group.id }?.name ?? "" },
                set: { value in if let index = groups.firstIndex(where: { $0.id == group.id }) { groups[index].name = value.isEmpty ? nil : value } }
            )).multilineTextAlignment(.trailing).accessibilityIdentifier("conditions.editor.name." + group.id.uuidString)
        }
        Picker(L.text("Combine conditions"), selection: Binding(
            get: { groups.first { $0.id == group.id }?.combination ?? .all },
            set: { value in if let index = groups.firstIndex(where: { $0.id == group.id }) { groups[index].combination = value } }
        )) {
            Text(L.text("All conditions")).tag(ConditionCombination.all)
            Text(L.text("Any condition")).tag(ConditionCombination.any)
        }.disabled(group.conditions.count <= 1).accessibilityIdentifier("conditions.editor.combination." + group.id.uuidString)
        ForEach(group.conditions) { condition in
            Button { editing = ConditionEditorSelection(groupID: group.id, condition: condition, kind: ConditionLeafKind(condition.payload)) } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(ConditionLabels.leaf(condition)).foregroundStyle(Color.primary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }.frame(minHeight: 44)
            }.buttonStyle(.borderless).accessibilityIdentifier("conditions.editor.leaf." + condition.id.uuidString)
                .swipeActions { Button(L.text("Delete"), role: .destructive) { remove(condition: condition, groupID: group.id) } }
                .contextMenu { Button(L.text("Delete condition"), role: .destructive) { remove(condition: condition, groupID: group.id) } }
                .accessibilityAction(named: L.text("Delete condition")) { remove(condition: condition, groupID: group.id) }
        }
        if group.conditions.isEmpty {
            Text(L.text("Add at least one condition to this group.")).font(.caption).foregroundStyle(.secondary)
        }
        Menu {
            ForEach(ConditionLeafKind.allCases) { kind in
                Button(L.text(kind.title)) { editing = ConditionEditorSelection(groupID: group.id, condition: nil, kind: kind) }
                    .accessibilityIdentifier("conditions.editor.add." + kind.rawValue)
            }
        } label: { Label(L.text("Add condition"), systemImage: "plus") }
            .buttonStyle(.borderless)
            .disabled(group.conditions.count >= ConditionGroup.limit).accessibilityIdentifier("conditions.editor.addCondition." + group.id.uuidString)
        Button(L.text("Delete group"), role: .destructive) {
            guard groups.count > 1 else { return }
            if group.conditions.isEmpty { delete(group: group) } else { deleting = group }
        }.buttonStyle(.borderless).disabled(groups.count <= 1).accessibilityIdentifier("conditions.editor.deleteGroup." + group.id.uuidString)
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
            Text(L.text(startMinute == endMinute ? "Same start and end means all day." : "Includes both selected minutes. Overnight ranges use the current weekday."))
        }
        .environment(\.timeZone, .gmt)
    }
    private var weekdayFields: some View {
        Section {
            HStack(spacing: 0) {
                ForEach(WeekdayOrder.days(starting: L.firstWeekday), id: \.self) { day in
                    Button {
                        if weekdays.contains(day) { weekdays.remove(day) } else { weekdays.insert(day) }
                    } label: {
                        Text(L.locale.calendar.veryShortStandaloneWeekdaySymbols[day - 1])
                            .font(.body.weight(.medium)).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .lineLimit(1).minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .foregroundStyle(weekdays.contains(day) ? Color(uiColor: .systemBackground) : Color.primary)
                            .background(weekdays.contains(day) ? TrackerColors.accent : .clear, in: Circle())
                            .overlay { Circle().strokeBorder(weekdays.contains(day) ? .clear : Color.secondary, lineWidth: 1) }
                    }.buttonStyle(.borderless)
                        .accessibilityLabel(L.locale.calendar.weekdaySymbols[day - 1])
                        .accessibilityValue(L.text(weekdays.contains(day) ? "On" : "Off"))
                        .accessibilityAddTraits(weekdays.contains(day) ? .isSelected : [])
                        .accessibilityIdentifier("condition.weekday.\(day)")
                }
            }
            .accessibilityElement(children: .contain)
        } footer: { if weekdays.isEmpty { Text(L.text("Choose at least one weekday.")) } }
    }
    private var healthFields: some View {
        Section {
            Picker(L.text("Comparison"), selection: $comparison) {
                Text(L.text("Greater than")).tag(ThresholdComparison.greater)
                Text(L.text("Less than")).tag(ThresholdComparison.less)
            }.accessibilityIdentifier("condition.health.comparison")
            TextField(L.text(kind == .sleep ? "Sleep hours" : "Step count"), text: $threshold)
                .keyboardType(kind == .sleep ? .decimalPad : .numberPad).focused($numberFocused)
                .accessibilityIdentifier("condition.health.threshold")
            Picker(L.text("Calendar period"), selection: $window) {
                ForEach(HealthWindow.allCases, id: \.self) { Text(ConditionLabels.window($0)).tag($0) }
            }.accessibilityIdentifier("condition.health.window")
            HealthConnectionView(keys: [HealthFactKey(metric: kind == .sleep ? .sleep : .steps, window: window)], onFailure: { error = $0 })
        } footer: {
            Text(L.text("Strict comparison: equality does not meet the condition. Uses readable Apple Health data from the calendar period’s start through now."))
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
