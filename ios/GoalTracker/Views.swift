import SwiftUI
import Charts
import MapKit

struct RootView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("homeLayout") private var homeLayout = "grid"
    @AppStorage("recordLocationByDefault", store: L.defaults) private var recordLocationByDefault = false
    @State private var selected = 0
    @State private var todayNavigationID = UUID()
    @State private var editMode = EditMode.inactive
    @State private var goalsNavigationID = UUID()
    @State private var creating = false
    @State private var entryTracker: Tracker?
    var body: some View {
        TimelineView(.everyMinute) { _ in screen(at: Date()) }
    }
    private func screen(at date: Date) -> some View {
        TabView(selection: $selected) {
            NavigationStack { trackerList(today: true, at: date) }.id(todayNavigationID).tabItem { Label(L.text("Today"), systemImage: "checkmark.circle") }.tag(0)
            NavigationStack { trackerList(today: false, at: date) }.id(goalsNavigationID).tabItem { Label(L.text("Goals"), systemImage: "chart.xyaxis.line") }.tag(1)
            SettingsView().tabItem { Label(L.text("Settings"), systemImage: "gearshape") }.tag(2)
        }
        .environment(\.editMode, $editMode)
        .task(id: store.trackers) {
            do { try await Reminders.sync(store.trackers) }
            catch is CancellationError { }
            catch { store.error = L.error(error) }
        }
        .onOpenURL { url in
            guard url.scheme == "goaltracker", url.host == "today" || url.host == "record" else { return }
            creating = false; entryTracker = nil; selected = 0; editMode = .inactive; todayNavigationID = UUID(); goalsNavigationID = UUID()
            if url.host == "record", url.pathComponents.count == 2,
               let id = UUID(uuidString: url.pathComponents[1]) {
                entryTracker = store.trackers.first { $0.id == id && !$0.archived }
            }
        }
        .sheet(isPresented: $creating) { TrackerEditor() }
        .sheet(item: $entryTracker) { t in EntryEditor(tracker: t, existing: t.entries.first { $0.localDay == t.day(Date()) && t.kind == .daily }) }
        .alert(L.text("Action failed"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button(L.text("OK"), role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
    private func trackerList(today: Bool, at date: Date) -> some View {
        let active = store.trackers.filter { !$0.archived }
        return Group {
            if today && homeLayout != "list" && !active.isEmpty {
                DashboardView(trackers: store.trackers, now: date,
                              onRecord: { entryTracker = $0 }, onReorder: reorder)
            } else {
                List {
                    if active.isEmpty {
                        ContentUnavailableView {
                            Label(L.text("Make room for progress"), systemImage: "leaf")
                        } description: { Text(L.text("Track a number or mark a day. Start with one thing that matters to you.")) }
                        actions: { Button(L.text("Create a tracker")) { creating = true }.accessibilityIdentifier("empty.create") }
                        .listRowBackground(Color.clear)
                    }
                    ForEach(active) { tracker in
                        HStack(spacing: 14) {
                            if today {
                                Button { entryTracker = tracker } label: {
                                    TrackerSummary(tracker: tracker, now: date).frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.borderless).accessibilityIdentifier("tracker." + tracker.id.uuidString)
                            } else {
                                NavigationLink { TrackerDetail(id: tracker.id) } label: { TrackerSummary(tracker: tracker, now: date) }
                                    .accessibilityIdentifier("tracker." + tracker.id.uuidString)
                            }
                            if today && tracker.kind == .daily {
                                let done = tracker.entries.contains { $0.localDay == tracker.day(date) }
                                Button {
                                    store.perform {
                                        var copy = store.trackers.first { $0.id == tracker.id } ?? tracker
                                        let now = Date(), day = copy.day(now)
                                        if let entry = copy.entries.first(where: { $0.localDay == day }) {
                                            if !entry.note.isEmpty || !entry.photos.isEmpty || entry.location != nil { entryTracker = copy; return }
                                            copy.entries.removeAll { $0.localDay == day }
                                        } else {
                                            if recordLocationByDefault || copy.requiresLocationGate { entryTracker = copy; return }
                                            copy.put(Entry(occurredAt: now, localDay: day))
                                        }
                                        try store.save(copy)
                                    }
                                } label: { Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.title2).frame(minWidth: 44, minHeight: 44) }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(L.text(done ? "Undo completion" : "Mark complete") + ": " + tracker.name)
                                .accessibilityIdentifier("complete." + tracker.id.uuidString)
                            }
                            if today && tracker.kind == .number {
                                Button { entryTracker = tracker } label: { Image(systemName: "plus.circle").font(.title2).frame(minWidth: 44, minHeight: 44) }
                                    .buttonStyle(.borderless).accessibilityLabel(L.text("Add a snapshot") + ": " + tracker.name)
                                    .accessibilityIdentifier("snapshot." + tracker.id.uuidString)
                            }
                        }.padding(.vertical, 6)
                        .modifier(TrackerReorderInteraction(enabled: today, id: tracker.id, active: active, onReorder: reorder))
                    }.onMove { indices, destination in
                        store.perform {
                            var reordered = active
                            reordered.move(fromOffsets: indices, toOffset: destination)
                            try store.replace(reordered + store.trackers.filter(\.archived))
                        }
                    }
                }
            }
        }
        .environment(\.editMode, today ? .constant(.inactive) : $editMode)
        .navigationTitle(L.text(today ? "Today" : "Goals"))
        .toolbar {
            if !today && !active.isEmpty { ToolbarItem(placement: .topBarTrailing) {
                Button(L.text(editMode.isEditing ? "Done" : "Edit")) {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }.accessibilityIdentifier("home.edit")
            } }
            ToolbarItem(placement: .topBarTrailing) {
                Button { creating = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel(L.text("Create a tracker")).accessibilityIdentifier("tracker.create")
            }
        }
    }
    private func reorder(_ source: UUID, _ target: UUID) {
        store.perform {
            var active = store.trackers.filter { !$0.archived }
            guard source != target, let from = active.firstIndex(where: { $0.id == source }),
                  let to = active.firstIndex(where: { $0.id == target }) else { return }
            let tracker = active.remove(at: from); active.insert(tracker, at: to)
            try store.replace(active + store.trackers.filter(\.archived))
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
                if let v = tracker.resolvedEntries.last(where: { $0.occurredAt <= now })?.value.flatMap(Numbers.decimal) {
                    Text(Numbers.display(v, precision: tracker.precision, locale: L.locale) + (tracker.unit.isEmpty ? "" : " " + tracker.unit)).font(.title3.monospacedDigit()).foregroundStyle(.primary)
                } else { Text(L.text("No snapshots yet")).foregroundStyle(TrackerColors.secondaryText) }
            } else if let rule = tracker.rule(at: now) {
                Text("\(tracker.count(in: tracker.interval(now, period: rule.period))) / \(rule.target) · " + L.text(rule.period == .weekly ? "This week" : "This month"))
                    .foregroundStyle(TrackerColors.secondaryText).monospacedDigit().accessibilityIdentifier("progress." + tracker.id.uuidString)
            } else { Text(L.text("Completion record")).foregroundStyle(TrackerColors.secondaryText) }
        }.padding(.vertical, 2)
    }
}

@MainActor struct TrackerDetail: View {
    @Environment(AppStore.self) private var store
    let id: UUID
    @State private var editing = false
    @State private var addEntry = false
    @State private var selectedEntry: Entry?
    @State private var numericView = "Chart"
    @State private var photoPreview: TrackerPhotoPreview?
    @State private var range = ChartRange.ninetyDays
    @State private var customStart = Date()
    @State private var customEnd = Date()
    @State private var initializedRange = false
    @State private var month = Date()
    @State private var deleteTracker = false
    private var tracker: Tracker? { store.trackers.first { $0.id == id } }
    var body: some View {
        TimelineView(.everyMinute) { _ in
        let now = Date()
        Group {
            if let t = tracker {
                List {
                    Section { TrackerSummary(tracker: t, now: now) }
                    content(t)
                    if t.kind == .number { numeric(t, now: now) }
                    else { CompletionProgressView(tracker: t, now: now) { daily(t) } }
                    locations(t)
                    if !t.rules.isEmpty {
                        Section(L.text("Goal history")) {
                            ForEach(t.rules.sorted { $0.effectiveAt > $1.effectiveAt }) { rule in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L.text(rule.period == .weekly ? "Weekly" : rule.period == .monthly ? "Monthly" : "Deadline goal") + " · " + rule.target)
                                    Text(rule.effectiveAt, format: .dateTime.year().month().day()).font(.caption).foregroundStyle(TrackerColors.secondaryText)
                                }
                            }
                        }
                    }
                    Section(L.text("Timeline")) {
                        if t.entries.isEmpty { Text(L.text("No records yet")).foregroundStyle(TrackerColors.secondaryText) }
                        ForEach(t.resolvedEntries.reversed()) { e in
                            Button { selectedEntry = e } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        if let v = e.value.flatMap(Numbers.decimal) { Text(Numbers.display(v, precision: t.precision, locale: L.locale)).font(.headline.monospacedDigit()) }
                                        else { Label(L.text("Completed"), systemImage: "checkmark.circle.fill") }
                                        Spacer()
                                        Text(t.kind == .daily ? (t.date(for: e.localDay) ?? e.occurredAt) : e.occurredAt, format: .dateTime.year().month().day()).font(.caption).foregroundStyle(TrackerColors.secondaryText)
                                    }
                                    if let change = e.change.flatMap(Numbers.decimal) {
                                        Text(L.text("Change amount") + " " + (change >= 0 ? "+" : "") + Numbers.display(change, precision: t.precision, locale: L.locale))
                                            .font(.subheadline.monospacedDigit()).foregroundStyle(TrackerColors.secondaryText)
                                        Text(L.text("Calculated value after this change")).font(.caption).foregroundStyle(TrackerColors.secondaryText)
                                    }
                                    if !e.note.isEmpty { Text(e.note).font(.subheadline).foregroundStyle(TrackerColors.secondaryText).lineLimit(2) }
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
                    customEnd = t.calendar.startOfDay(for: now)
                    customStart = t.calendar.date(byAdding: .day, value: -89, to: customEnd) ?? customEnd
                    initializedRange = true
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
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
                .sheet(item: $selectedEntry) { selection in
                    EntryEditor(tracker: t, existing: t.entries.first { $0.id == selection.id } ?? selection)
                }
                .fullScreenCover(item: $photoPreview) { PhotoViewer(photos: $0.photos, initialIndex: $0.index) }
                .confirmationDialog(L.text("Delete this tracker and all its records?"), isPresented: $deleteTracker, titleVisibility: .visible) {
                    Button(L.text("Delete tracker"), role: .destructive) { store.perform { try store.remove(id) } }
                }
            } else { ContentUnavailableView(L.text("Tracker removed"), systemImage: "archivebox") }
        }
        }
    }
    @ViewBuilder private func content(_ t: Tracker) -> some View {
        if t.description?.isEmpty == false || validatedWebsite(t.website) != nil {
            Section {
                if let description = t.description, !description.isEmpty {
                    Text(description).textSelection(.enabled).accessibilityIdentifier("tracker.description")
                }
                if let url = validatedWebsite(t.website) {
                    Link(destination: url) { Label(L.text("Website"), systemImage: "arrow.up.right.square") }
                        .accessibilityIdentifier("tracker.website")
                }
            }
        }
        if let photos = t.photos, !photos.isEmpty {
            Section(L.text("Tracker photos")) {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(photos.indices, id: \.self) { index in
                            Button { photoPreview = TrackerPhotoPreview(photos: photos, index: index) } label: {
                                if let image = UIImage(data: photos[index]) {
                                    Image(uiImage: image).resizable().scaledToFill().frame(width: 104, height: 104)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                            }.buttonStyle(.plain)
                                .accessibilityLabel(String(format: L.text("Photo %lld of %lld"), locale: L.locale, Int64(index + 1), Int64(photos.count)))
                                .accessibilityIdentifier("tracker.photo.\(index)")
                        }
                    }
                }.accessibilityIdentifier("tracker.photoGallery")
            }
        }
    }
    private func validatedWebsite(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false else { return nil }
        return url
    }
    private func numeric(_ t: Tracker, now: Date) -> some View {
        let snapshot = range.snapshot(for: t, now: now, customStart: customStart, customEnd: customEnd)
        let entries = t.resolvedEntries.filter { $0.occurredAt <= now }
        let values = entries.compactMap { $0.value.flatMap(Numbers.decimal) }
        let latest = entries.last?.value.flatMap(Numbers.decimal)
        return Section(L.text("Progress")) {
            Picker(L.text("Numeric view"), selection: $numericView) {
                Text(L.text("Chart")).tag("Chart")
                Text(L.text("Goal progress")).tag("Goal progress")
            }.pickerStyle(.segmented).accessibilityIdentifier("snapshot.view")
            if numericView == "Goal progress" {
                if let progress = GoalProgress.current(for: t, now: now) {
                    VStack(spacing: 12) {
                        GoalProgressRing(fraction: progress.fraction).frame(width: 144, height: 144)
                        Text(progress.fraction.formatted(.percent.precision(.fractionLength(0)).locale(L.locale)))
                            .font(.title2.monospacedDigit())
                        Text(L.text("Baseline to target") + ": " + formatted(progress.baseline, tracker: t) + " → " + formatted(progress.target, tracker: t))
                            .font(.caption).foregroundStyle(TrackerColors.secondaryText).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 12).accessibilityIdentifier("snapshot.progress")
                } else { Text(L.text("Set a deadline goal and record a baseline to see goal progress.")).foregroundStyle(TrackerColors.secondaryText) }
            } else {
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
            }
            if let best = t.direction == .up ? values.max() : values.min() { metric("Best", Numbers.display(best, precision: t.precision, locale: L.locale)) }
            if entries.count > 1, let latest, let previous = entries.dropLast().last?.value.flatMap(Numbers.decimal) {
                metric("Since previous", Numbers.display(latest - previous, precision: t.precision, locale: L.locale))
            }
            if let change = snapshot?.periodChange {
                metric("Period change", Numbers.display(change, precision: t.precision, locale: L.locale))
            }
            if let rule = t.rule(at: now), let target = Numbers.decimal(rule.target) {
                metric("Target", Numbers.display(target, precision: t.precision, locale: L.locale))
                if let latest { metric("Distance to target", Numbers.display(abs(target - latest), precision: t.precision, locale: L.locale)) }
                if let deadline = rule.deadline { LabeledContent(L.text("Deadline")) { Text(deadline, format: .dateTime.year().month().day()) } }
                let achieved = GoalProgress.current(for: t, now: now)?.achieved == true
                Text(L.text(achieved ? "Goal achieved" : "Working toward your goal")).foregroundStyle(achieved ? TrackerColors.accent : TrackerColors.secondaryText)
            }
        }
    }
    private func formatted(_ value: String, tracker: Tracker) -> String {
        Numbers.decimal(value).map { Numbers.display($0, precision: tracker.precision, locale: L.locale) } ?? value
    }
    private func snapshotChart(_ snapshot: ChartSnapshot, tracker: Tracker) -> some View {
        let entries = snapshot.numericEntries
        let points = entries.compactMap { entry in entry.value.map { CardPlotPoint(date: entry.occurredAt, value: $0) } }
        let carried = snapshot.carries.flatMap { [$0.start, $0.end] }
        let target = tracker.rule(at: Date()).map { CardPlotPoint(date: snapshot.interval.start, value: $0.target) }
        let domain = CardPlotScale.domain(points: points + carried + [target].compactMap { $0 }, precision: tracker.precision,
                                          lower: tracker.axisLower, upper: tracker.axisUpper)
        let clipped = points.compactMap(\.plottedValue).filter { !domain.contains($0) }.count
        return VStack(alignment: .leading, spacing: 8) {
        Chart {
        ForEach(entries) { entry in
            if let value = entry.value.flatMap(Numbers.decimal) {
                if entries.count > 1 {
                    LineMark(x: .value(L.text("Date"), entry.occurredAt), y: .value(L.text("Value"), NSDecimalNumber(decimal: value).doubleValue), series: .value("Series", "actual"))
                }
                PointMark(x: .value(L.text("Date"), entry.occurredAt), y: .value(L.text("Value"), NSDecimalNumber(decimal: value).doubleValue)).symbolSize(45)
            }
        }
        ForEach(snapshot.carries) { segment in
            ForEach([segment.start, segment.end], id: \.date) { point in
                if let value = point.plottedValue {
                    LineMark(x: .value(L.text("Date"), point.date), y: .value(L.text("Value"), value), series: .value("Series", segment.id))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                }
            }
        }
        }
        .frame(height: 220)
        .chartXScale(domain: snapshot.interval.start...snapshot.interval.end)
        .chartYScale(domain: domain)
        .chartYAxis(entries.isEmpty && carried.isEmpty ? .hidden : .automatic)
        .chartPlotStyle { $0.clipped() }.chartLegend(.hidden)
        .overlay {
            if entries.isEmpty && carried.isEmpty {
                Text(L.text("No snapshots in this period")).foregroundStyle(TrackerColors.secondaryText).multilineTextAlignment(.center).padding()
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { location in
                    guard let frame = proxy.plotFrame, geometry[frame].contains(location) else { return }
                    let point = CGPoint(x: location.x - geometry[frame].origin.x, y: location.y - geometry[frame].origin.y)
                    let hits = entries.compactMap { entry -> (Entry, Double)? in
                        guard let value = entry.value.flatMap(Numbers.decimal), domain.contains(NSDecimalNumber(decimal: value).doubleValue),
                              let x = proxy.position(forX: entry.occurredAt), let y = proxy.position(forY: NSDecimalNumber(decimal: value).doubleValue) else { return nil }
                        return (entry, hypot(point.x - x, point.y - y))
                    }
                    if let hit = hits.min(by: { $0.1 < $1.1 }), hit.1 <= 26 { selectedEntry = hit.0 }
                }
            }
        }
        .accessibilityElement(children: .contain)
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
        if !carried.isEmpty, let date = snapshot.lastRecordedAt {
            (Text(L.text("Last recorded")) + Text(" ") + Text(date, format: .dateTime.year().month().day()))
                .font(.caption).foregroundStyle(TrackerColors.secondaryText).accessibilityIdentifier("snapshot.lastRecorded")
        }
        if clipped > 0 {
            Text(String(format: L.text("%lld records outside the chart bounds. Values are preserved in the timeline."), locale: L.locale, Int64(clipped)))
                .font(.caption).foregroundStyle(TrackerColors.secondaryText).accessibilityIdentifier("snapshot.clipped")
        } else if carried.compactMap(\.plottedValue).contains(where: { !domain.contains($0) }) {
            Text(L.text("Last recorded value is outside chart bounds."))
                .font(.caption).foregroundStyle(TrackerColors.secondaryText).accessibilityIdentifier("snapshot.clipped")
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
                                    Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(.white, TrackerColors.accent)
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
            VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { month = t.calendar.date(byAdding: .month, value: -1, to: month)! } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.buttonStyle(.borderless).accessibilityLabel(L.text("Previous month"))
                Spacer(); Text(month, format: .dateTime.year().month(.wide)); Spacer()
                Button { month = t.calendar.date(byAdding: .month, value: 1, to: month)! } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.buttonStyle(.borderless).accessibilityLabel(L.text("Next month"))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 8) {
                ForEach(cells) { cell in
                    switch cell {
                    case .weekday(let index):
                        Text(L.locale.calendar.veryShortStandaloneWeekdaySymbols[(index + 1) % 7]).font(.caption).foregroundStyle(TrackerColors.secondaryText)
                    case .padding:
                        Color.clear.frame(height: 32).accessibilityHidden(true)
                    case .day(let date, let localDay):
                        let done = completed.contains(localDay)
                        Button {
                            if let entry = t.entries.first(where: { $0.localDay == localDay }) { selectedEntry = entry }
                            else { selectedEntry = Entry(occurredAt: date, localDay: localDay) }
                        } label: {
                            Text("\(t.calendar.component(.day, from: date))").font(.body.monospacedDigit())
                                .dynamicTypeSize(...DynamicTypeSize.accessibility1).lineLimit(1).minimumScaleFactor(0.5).frame(maxWidth: .infinity, minHeight: 44)
                                .background(done ? TrackerColors.accent.opacity(0.18) : Color.clear, in: Circle()).foregroundStyle(done ? TrackerColors.accent : .primary)
                        }
                        .buttonStyle(.borderless)
                        .disabled(date > t.calendar.startOfDay(for: Date()))
                        .accessibilityLabel(date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: L.locale, calendar: t.calendar, timeZone: t.calendar.timeZone)) + ": " + L.text(done ? "Completed" : "No record"))
                        .accessibilityIdentifier(cell.id)
                    }
                }
            }
            Text(L.text("An unmarked date means there is no completion record.")).font(.caption).foregroundStyle(TrackerColors.secondaryText)
            }
            if let rule = t.rule(at: Date()) {
                VStack(alignment: .leading, spacing: 8) {
                let interval = t.interval(Date(), period: rule.period)
                metric(rule.period == .weekly ? "This week" : "This month", "\(t.count(in: interval)) / \(rule.target)")
                if history.last?.3 == true { Text(L.text("Partial period · excluded from success rate")).font(.caption).foregroundStyle(TrackerColors.secondaryText) }
                }
            }
            if !full.isEmpty {
                metric("Full-period success rate", (Double(full.filter { $0.1 >= $0.2 }.count) / Double(full.count)).formatted(.percent.precision(.fractionLength(0)).locale(L.locale)))
            }
            ForEach(Array(history.suffix(12).enumerated()), id: \.offset) { _, record in
                HStack {
                    Text(record.0.start, format: .dateTime.month().day()).foregroundStyle(TrackerColors.secondaryText)
                    Spacer(); Text("\(record.1) / \(record.2)").monospacedDigit()
                    if record.3 { Image(systemName: "circle.lefthalf.filled").accessibilityLabel(L.text("Partial period")) }
                }
            }
        }
    }
}

private struct TrackerPhotoPreview: Identifiable {
    let id = UUID()
    let photos: [Data]
    let index: Int
}
