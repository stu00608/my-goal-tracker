import SwiftUI
import Charts

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var selected = 0
    @State private var todayNavigationID = UUID()
    @State private var settings = false
    @State private var creating = false
    @State private var entryTracker: Tracker?
    var body: some View {
        TimelineView(.everyMinute) { _ in screen(at: Date()) }
    }
    private func screen(at date: Date) -> some View {
        @Bindable var store = store
        return TabView(selection: $selected) {
            NavigationStack { trackerList(today: true, at: date) }.id(todayNavigationID).tabItem { Label(L.text("Today"), systemImage: "checkmark.circle") }.tag(0)
            NavigationStack { trackerList(today: false, at: date) }.tabItem { Label(L.text("Goals"), systemImage: "chart.xyaxis.line") }.tag(1)
        }
        .task(id: store.trackers) {
            do { try await Reminders.sync(store.trackers) }
            catch is CancellationError { }
            catch { store.error = L.error(error) }
        }
        .onOpenURL { url in
            guard url.scheme == "goaltracker", url.host == "today" else { return }
            settings = false; creating = false; entryTracker = nil; selected = 0; todayNavigationID = UUID()
        }
        .sheet(isPresented: $settings) { SettingsView() }
        .sheet(isPresented: $creating) { TrackerEditor() }
        .sheet(item: $entryTracker) { t in EntryEditor(tracker: t, existing: t.entries.first { $0.localDay == t.day(Date()) && t.kind == .daily }) }
        .alert(L.text("Action failed"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button(L.text("OK"), role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
    private func trackerList(today: Bool, at date: Date) -> some View {
        List {
            if store.trackers.filter({ !$0.archived }).isEmpty {
                ContentUnavailableView {
                    Label(L.text("Make room for progress"), systemImage: "leaf")
                } description: { Text(L.text("Track a number or mark a day. Start with one thing that matters to you.")) }
                actions: { Button(L.text("Create a tracker")) { creating = true }.accessibilityIdentifier("empty.create") }
                .listRowBackground(Color.clear)
            }
            ForEach(store.trackers.filter { !$0.archived }) { tracker in
                HStack(spacing: 14) {
                    if today && tracker.kind == .daily {
                        let done = tracker.entries.contains { $0.localDay == tracker.day(date) }
                        Button {
                            store.perform {
                                var copy = store.trackers.first { $0.id == tracker.id } ?? tracker
                                let now = Date()
                                let day = copy.day(now)
                                if copy.entries.contains(where: { $0.localDay == day }) {
                                    if let entry = copy.entries.first(where: { $0.localDay == day }), !entry.note.isEmpty || !entry.photos.isEmpty {
                                        entryTracker = copy; return
                                    }
                                    copy.entries.removeAll { $0.localDay == day }
                                }
                                else { copy.put(Entry(occurredAt: now, localDay: day)) }
                                try store.save(copy)
                            }
                        } label: { Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.title2).frame(minWidth: 44, minHeight: 44) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L.text(done ? "Undo completion" : "Mark complete") + ": " + tracker.name)
                        .accessibilityIdentifier("complete." + tracker.id.uuidString)
                    }
                    NavigationLink { TrackerDetail(id: tracker.id) } label: { TrackerSummary(tracker: tracker, now: date) }
                        .accessibilityIdentifier("tracker." + tracker.id.uuidString)
                    if today && tracker.kind == .number {
                        Button { entryTracker = tracker } label: { Image(systemName: "plus.circle").font(.title2).frame(minWidth: 44, minHeight: 44) }
                            .buttonStyle(.borderless).accessibilityLabel(L.text("Add a snapshot") + ": " + tracker.name)
                            .accessibilityIdentifier("snapshot." + tracker.id.uuidString)
                    }
                }.padding(.vertical, 6)
            }.onMove { indices, destination in
                store.perform {
                    var active = store.trackers.filter { !$0.archived }
                    active.move(fromOffsets: indices, toOffset: destination)
                    try store.replace(active + store.trackers.filter(\.archived))
                }
            }
        }
        .navigationTitle(L.text(today ? "Today" : "Goals"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { settings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel(L.text("Settings")).accessibilityIdentifier("settings.open")
            }
            if !today { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button { creating = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel(L.text("Create a tracker")).accessibilityIdentifier("tracker.create")
            }
        }
    }
}

struct TrackerSummary: View {
    let tracker: Tracker
    var now = Date()
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(tracker.name).font(.headline)
            if tracker.kind == .number {
                if let v = tracker.latest?.value.flatMap(Numbers.decimal) {
                    Text(Numbers.display(v, precision: tracker.precision, locale: L.locale) + (tracker.unit.isEmpty ? "" : " " + tracker.unit)).font(.title3.monospacedDigit()).foregroundStyle(.primary)
                } else { Text(L.text("No snapshots yet")).foregroundStyle(.secondary) }
            } else if let rule = tracker.rule(at: now) {
                Text("\(tracker.count(in: tracker.interval(now, period: rule.period))) / \(rule.target) · " + L.text(rule.period == .weekly ? "This week" : "This month"))
                    .foregroundStyle(.secondary).monospacedDigit().accessibilityIdentifier("progress." + tracker.id.uuidString)
            } else { Text(L.text("Daily completion")).foregroundStyle(.secondary) }
        }.padding(.vertical, 2)
    }
}

import MapKit

@MainActor struct TrackerDetail: View {
    @Environment(AppStore.self) private var store
    let id: UUID
    @State private var editing = false
    @State private var addEntry = false
    @State private var selectedEntry: Entry?
    @State private var range = ChartRange.ninetyDays
    @State private var customStart = Date()
    @State private var customEnd = Date()
    @State private var initializedRange = false
    @State private var month = Date()
    @State private var deleteTracker = false
    private var tracker: Tracker? { store.trackers.first { $0.id == id } }
    var body: some View {
        TimelineView(.everyMinute) { context in
        Group {
            if let t = tracker {
                List {
                    Section { TrackerSummary(tracker: t, now: Date()) }
                    if t.kind == .number { numeric(t, now: context.date) } else { daily(t) }
                    locations(t)
                    if !t.rules.isEmpty {
                        Section(L.text("Goal history")) {
                            ForEach(t.rules.sorted { $0.effectiveAt > $1.effectiveAt }) { rule in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L.text(rule.period == .weekly ? "Weekly" : rule.period == .monthly ? "Monthly" : "Deadline goal") + " · " + rule.target)
                                    Text(rule.effectiveAt, format: .dateTime.year().month().day()).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Section(L.text("Timeline")) {
                        if t.entries.isEmpty { Text(L.text("No records yet")).foregroundStyle(.secondary) }
                        ForEach(t.sortedEntries.reversed()) { e in
                            Button { selectedEntry = e } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        if let v = e.value.flatMap(Numbers.decimal) { Text(Numbers.display(v, precision: t.precision, locale: L.locale)).font(.headline.monospacedDigit()) }
                                        else { Label(L.text("Completed"), systemImage: "checkmark.circle.fill") }
                                        Spacer()
                                        Text(t.kind == .daily ? (t.date(for: e.localDay) ?? e.occurredAt) : e.occurredAt, format: .dateTime.year().month().day()).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if !e.note.isEmpty { Text(e.note).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                                    if !e.photos.isEmpty { Label("\(e.photos.count)", systemImage: "photo").font(.caption) }
                                }.foregroundStyle(.primary)
                            }.accessibilityIdentifier("entry." + e.id.uuidString)
                        }
                    }
                    Section {
                        Button(L.text(t.archived ? "Unarchive" : "Archive")) {
                            store.perform { var next = t; next.archived.toggle(); try store.save(next) }
                        }
                        Button(L.text("Delete tracker"), role: .destructive) { deleteTracker = true }
                    }
                }
                .navigationTitle(t.name).navigationBarTitleDisplayMode(.inline)
                .environment(\.timeZone, t.calendar.timeZone)
                .environment(\.calendar, t.calendar)
                .onAppear {
                    guard !initializedRange else { return }
                    customEnd = t.calendar.startOfDay(for: context.date)
                    customStart = t.calendar.date(byAdding: .day, value: -89, to: customEnd) ?? customEnd
                    initializedRange = true
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(L.text("Add a record")) { addEntry = true }
                            Button(L.text("Edit tracker")) { editing = true }
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityIdentifier("tracker.menu")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { addEntry = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel(L.text(t.kind == .number ? "Add a snapshot" : "Add a completion"))
                            .accessibilityIdentifier("entry.add")
                    }
                }
                .sheet(isPresented: $editing) { TrackerEditor(existing: t) }
                .sheet(isPresented: $addEntry) { EntryEditor(tracker: t) }
                .sheet(item: $selectedEntry) { EntryEditor(tracker: t, existing: $0) }
                .confirmationDialog(L.text("Delete this tracker and all its records?"), isPresented: $deleteTracker, titleVisibility: .visible) {
                    Button(L.text("Delete tracker"), role: .destructive) { store.perform { try store.remove(id) } }
                }
            } else { ContentUnavailableView(L.text("Tracker removed"), systemImage: "archivebox") }
        }
        }
    }
    private func numeric(_ t: Tracker, now: Date) -> some View {
        let snapshot = range.snapshot(for: t, now: now, customStart: customStart, customEnd: customEnd)
        return Section(L.text("Progress")) {
            Picker(L.text("Period"), selection: $range) {
                ForEach(ChartRange.allCases, id: \.self) { period in Text(L.text(period.title)).tag(period) }
            }.pickerStyle(.menu).accessibilityIdentifier("snapshot.period")
            if range == .custom {
                DatePicker(L.text("Start date"), selection: Binding(get: { customStart }, set: {
                    customStart = t.calendar.startOfDay(for: $0)
                    if customEnd < customStart { customEnd = customStart }
                }), in: ...customEnd, displayedComponents: .date)
                .accessibilityIdentifier("snapshot.custom.start")
                DatePicker(L.text("End date"), selection: Binding(get: { customEnd }, set: {
                    customEnd = t.calendar.startOfDay(for: $0)
                    if customStart > customEnd { customStart = customEnd }
                }), in: customStart..., displayedComponents: .date)
                .accessibilityIdentifier("snapshot.custom.end")
            }
            if let snapshot { snapshotChart(snapshot, tracker: t) }
            if let best = t.best { metric("Best", Numbers.display(best, precision: t.precision, locale: L.locale)) }
            if t.sortedEntries.count > 1, let latest = t.latest?.value.flatMap(Numbers.decimal), let previous = t.sortedEntries.dropLast().last?.value.flatMap(Numbers.decimal) {
                metric("Since previous", Numbers.display(latest - previous, precision: t.precision, locale: L.locale))
            }
            if let change = snapshot?.periodChange {
                metric("Period change", Numbers.display(change, precision: t.precision, locale: L.locale))
            }
            if let rule = t.rule(at: Date()), let target = Numbers.decimal(rule.target) {
                metric("Target", Numbers.display(target, precision: t.precision, locale: L.locale))
                if let latest = t.latest?.value.flatMap(Numbers.decimal) { metric("Distance to target", Numbers.display(abs(target - latest), precision: t.precision, locale: L.locale)) }
                if let deadline = rule.deadline { LabeledContent(L.text("Deadline")) { Text(deadline, format: .dateTime.year().month().day()) } }
                Text(L.text(t.achieved(rule) ? "Goal achieved" : "Working toward your goal")).foregroundStyle(t.achieved(rule) ? .teal : .secondary)
            }
        }
    }
    private func snapshotChart(_ snapshot: ChartSnapshot, tracker: Tracker) -> some View {
        let entries = snapshot.numericEntries
        let values = entries.compactMap { $0.value.flatMap(Numbers.decimal).map { NSDecimalNumber(decimal: $0).doubleValue } }
        let low = values.min() ?? 0, high = values.max() ?? 0
        let padding = max((high - low) * 0.1, pow(10, -Double(tracker.precision)), max(abs(low), abs(high)) * 1e-9)
        return Chart(entries) { entry in
            if let value = entry.value.flatMap(Numbers.decimal) {
                if entries.count > 1 {
                    LineMark(x: .value(L.text("Date"), entry.occurredAt), y: .value(L.text("Value"), NSDecimalNumber(decimal: value).doubleValue))
                }
                PointMark(x: .value(L.text("Date"), entry.occurredAt), y: .value(L.text("Value"), NSDecimalNumber(decimal: value).doubleValue)).symbolSize(45)
            }
        }
        .frame(height: 220)
        .chartXScale(domain: snapshot.interval.start...snapshot.interval.end)
        .chartYScale(domain: (low - padding)...(high + padding))
        .chartYAxis(entries.isEmpty ? .hidden : .automatic)
        .overlay {
            if entries.isEmpty {
                Text(L.text("No snapshots in this period")).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { location in
                    guard let frame = proxy.plotFrame,
                          geometry[frame].contains(location),
                          let date: Date = proxy.value(atX: location.x - geometry[frame].origin.x) else { return }
                    selectedEntry = entries.min { abs($0.occurredAt.timeIntervalSince(date)) < abs($1.occurredAt.timeIntervalSince(date)) }
                }
            }
        }
        .accessibilityLabel(L.text("Snapshot chart"))
        .accessibilityIdentifier("snapshot.chart")
        .accessibilityChildren {
            ForEach(entries) { entry in
                Button { selectedEntry = entry } label: {
                    Text(entry.occurredAt, format: .dateTime.year().month().day())
                    if let value = entry.value.flatMap(Numbers.decimal) { Text(Numbers.display(value, precision: tracker.precision, locale: L.locale)) }
                }.accessibilityIdentifier("snapshot.point." + entry.id.uuidString)
            }
        }
    }
    @ViewBuilder private func locations(_ tracker: Tracker) -> some View {
        let entries = tracker.sortedEntries.filter { $0.location?.isValid == true }
        if !entries.isEmpty {
            Section(L.text("Recorded locations")) {
                Map {
                    ForEach(entries) { entry in
                        if let location = entry.location {
                            Annotation(entry.occurredAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: L.locale, calendar: tracker.calendar, timeZone: tracker.calendar.timeZone)), coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)) {
                                Button { selectedEntry = entry } label: {
                                    Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(.white, .teal)
                                        .padding(6).background(.regularMaterial, in: Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(entry.occurredAt, format: .dateTime.year().month().day()))
                                .accessibilityIdentifier("location." + entry.id.uuidString)
                            }
                        }
                    }
                }.frame(height: 240).accessibilityIdentifier("record.map")
            }
        }
    }
    private func metric(_ key: String, _ value: String) -> some View { LabeledContent(L.text(key), value: value).monospacedDigit() }
    private func daily(_ t: Tracker) -> some View {
        let cells = CompletionCalendarCell.month(for: t, containing: month)
        let completed = Set(t.entries.map(\.localDay))
        let history = t.frequencyHistory(until: Date())
        let full = history.filter { !$0.3 && $0.0.end <= Date() }
        return Section(L.text("Completion calendar")) {
            HStack {
                Button { month = t.calendar.date(byAdding: .month, value: -1, to: month)! } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.buttonStyle(.borderless).accessibilityLabel(L.text("Previous month"))
                Spacer(); Text(month, format: .dateTime.year().month(.wide)); Spacer()
                Button { month = t.calendar.date(byAdding: .month, value: 1, to: month)! } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.buttonStyle(.borderless).accessibilityLabel(L.text("Next month"))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 8) {
                ForEach(cells) { cell in
                    switch cell {
                    case .weekday(let index):
                        Text(L.locale.calendar.veryShortStandaloneWeekdaySymbols[(index + 1) % 7]).font(.caption).foregroundStyle(.secondary)
                    case .padding:
                        Color.clear.frame(height: 32).accessibilityHidden(true)
                    case .day(let date, let localDay):
                        let done = completed.contains(localDay)
                        Button {
                            if let entry = t.entries.first(where: { $0.localDay == localDay }) { selectedEntry = entry }
                            else { selectedEntry = Entry(occurredAt: date, localDay: localDay) }
                        } label: {
                            Text("\(t.calendar.component(.day, from: date))").font(.body.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.5).frame(maxWidth: .infinity, minHeight: 44)
                                .background(done ? Color.teal.opacity(0.18) : Color.clear, in: Circle()).foregroundStyle(done ? .teal : .primary)
                        }
                        .buttonStyle(.borderless)
                        .disabled(date > t.calendar.startOfDay(for: Date()))
                        .accessibilityLabel(date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: L.locale, calendar: t.calendar, timeZone: t.calendar.timeZone)) + ": " + L.text(done ? "Completed" : "No record"))
                        .accessibilityIdentifier(cell.id)
                    }
                }
            }
            if let rule = t.rule(at: Date()) {
                let interval = t.interval(Date(), period: rule.period)
                metric(rule.period == .weekly ? "This week" : "This month", "\(t.count(in: interval)) / \(rule.target)")
                if history.last?.3 == true { Text(L.text("Partial period · excluded from success rate")).font(.caption).foregroundStyle(.secondary) }
            }
            if !full.isEmpty {
                metric("Full-period success rate", (Double(full.filter { $0.1 >= $0.2 }.count) / Double(full.count)).formatted(.percent.precision(.fractionLength(0)).locale(L.locale)))
            }
            ForEach(Array(history.suffix(12).enumerated()), id: \.offset) { _, record in
                HStack {
                    Text(record.0.start, format: .dateTime.month().day()).foregroundStyle(.secondary)
                    Spacer(); Text("\(record.1) / \(record.2)").monospacedDigit()
                    if record.3 { Image(systemName: "circle.lefthalf.filled").accessibilityLabel(L.text("Partial period")) }
                }
            }
            Text(L.text("An unmarked date means there is no completion record.")).font(.caption).foregroundStyle(.secondary)
        }
    }
}
