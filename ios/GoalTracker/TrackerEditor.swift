import SwiftUI
import PhotosUI
import ImageIO

struct TrackerEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var existing: Tracker?
    @State private var name = ""
    @State private var kind = TrackerKind.number
    @State private var unit = ""
    @State private var precision = 3
    @State private var direction = Direction.up
    @State private var goalEnabled = false
    @State private var target = ""
    @State private var due = Date().addingTimeInterval(86400 * 30)
    @State private var period = Period.weekly
    @State private var frequency = 2
    @State private var cardBackground = CardBackground.plot
    @State private var error: String?
    private enum Field: Hashable { case name, unit, target }
    @FocusState private var focusedField: Field?
    @State private var initialized = false
    @State private var keyboard = EditorKeyboardControl()
    var body: some View {
        NavigationStack {
            Form {
                Section(L.text("Tracker")) {
                    TextField(L.text("Name"), text: $name).focused($focusedField, equals: .name).accessibilityIdentifier("tracker.name")
                    VStack(alignment: .leading, spacing: 8) {
                    Picker(L.text("Record type"), selection: $kind) {
                        Text(L.text("Number snapshot")).tag(TrackerKind.number)
                        Text(L.text("Completion record")).tag(TrackerKind.daily)
                    }.accessibilityIdentifier("tracker.kind").disabled(!(existing?.entries.isEmpty ?? true) || !(existing?.rules.isEmpty ?? true))
                    if !(existing?.entries.isEmpty ?? true) || !(existing?.rules.isEmpty ?? true) { Text(L.text("Create a new tracker to change its type or unit.")).font(.caption).foregroundStyle(TrackerColors.secondaryText) }
                    }
                    if kind == .number {
                        TextField(L.text("Unit (optional)"), text: $unit).focused($focusedField, equals: .unit).disabled(!(existing?.entries.isEmpty ?? true) || !(existing?.rules.isEmpty ?? true)).accessibilityIdentifier("tracker.unit")
                        Stepper(L.text("Decimal places") + ": \(precision)", value: $precision, in: 0...8)
                        Picker(L.text("Improvement direction"), selection: $direction) {
                            Text(L.text("Higher is better")).tag(Direction.up); Text(L.text("Lower is better")).tag(Direction.down)
                        }
                    }
                }
                Section(L.text("Goal")) {
                    if existing?.rules.isEmpty ?? true { Toggle(L.text("Set a goal"), isOn: $goalEnabled).accessibilityIdentifier("goal.enabled") }
                    if goalEnabled {
                        if kind == .number {
                            TextField(L.text("Target value"), text: $target).focused($focusedField, equals: .target).keyboardType(.numbersAndPunctuation).accessibilityIdentifier("goal.target")
                            DatePicker(L.text("Deadline"), selection: $due, in: Date()..., displayedComponents: [.date])
                        } else {
                            Picker(L.text("Frequency"), selection: $period) {
                                Text(L.text("Weekly")).tag(Period.weekly); Text(L.text("Monthly")).tag(Period.monthly)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                            Stepper(L.text("Completions") + ": \(frequency)", value: $frequency, in: 1...(period == .weekly ? 7 : 31))
                                .accessibilityIdentifier("goal.frequency")
                            if !(existing?.rules.isEmpty ?? true) { Text(L.text("Changes start with the next full period. Past goals stay unchanged.")).font(.caption).foregroundStyle(TrackerColors.secondaryText) }
                            }
                        }
                    }
                }
                Section(L.text("Card background")) {
                    Picker(L.text("Card background"), selection: $cardBackground) {
                        Text(L.text("Chart")).tag(CardBackground.plot)
                        Text(L.text("Latest photo")).tag(CardBackground.photo)
                        Text(L.text("Location map")).tag(CardBackground.map)
                    }.accessibilityIdentifier("tracker.cardBackground")
                }
                if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("editor.error") } }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(EditorKeyboardDismissal(keyboard: keyboard) { focusedField = nil })
            .navigationTitle(L.text(existing == nil ? "New tracker" : "Edit tracker"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L.text("Cancel")) { endEditing(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(L.text("Save"), action: save).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 120 || unit.count > 30).accessibilityIdentifier("tracker.save") }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button(L.text("Done"), action: endEditing).accessibilityIdentifier("tracker.keyboard.done") }
            }
            .onAppear {
                guard !initialized else { return }; initialized = true
                guard let t = existing else { return }
                name = t.name; kind = t.kind; unit = t.unit; precision = t.precision; direction = t.direction; cardBackground = t.resolvedCardBackground
                if let rule = t.rules.max(by: { $0.effectiveAt < $1.effectiveAt }) {
                    goalEnabled = true; target = rule.target; due = rule.deadline ?? due; period = rule.period; frequency = Int(rule.target) ?? 2
                }
            }
            .onChange(of: kind) { _, _ in endEditing() }
            .onChange(of: period) { _, _ in endEditing(); frequency = min(frequency, period == .weekly ? 7 : 31) }
        }
    }
    private func endEditing() { keyboard.dismiss(); focusedField = nil }
    private func save() {
        endEditing()
        do {
            var t = existing ?? Tracker(name: name, kind: kind)
            t.name = name.trimmingCharacters(in: .whitespacesAndNewlines); t.kind = kind; t.unit = unit; t.precision = precision; t.direction = direction
            t.cardBackground = cardBackground
            if goalEnabled {
                if kind == .number {
                    let value = try Numbers.parse(target, locale: L.locale)
                    let end = t.calendar.date(byAdding: .day, value: 1, to: t.calendar.startOfDay(for: due))!.addingTimeInterval(-0.001)
                    let prior = t.rules.max { $0.effectiveAt < $1.effectiveAt }
                    if prior?.target != value || prior?.deadline != end || prior?.direction != direction {
                        t.rules.append(GoalRule(period: .deadline, target: value, effectiveAt: Date(), deadline: end, direction: direction))
                    }
                } else if t.rules.max(by: { $0.effectiveAt < $1.effectiveAt })?.target != String(frequency) || t.rules.max(by: { $0.effectiveAt < $1.effectiveAt })?.period != period {
                    t.setFrequency(period, target: frequency, now: Date())
                }
            }
            try store.save(t); dismiss()
        } catch { self.error = L.error(error) }
    }
}
