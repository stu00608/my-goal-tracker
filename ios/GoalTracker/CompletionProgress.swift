import SwiftUI
import Charts

@MainActor struct CompletionProgressView<CalendarContent: View>: View {
    let tracker: Tracker
    let now: Date
    private let calendarContent: CalendarContent
    let editGoal: () -> Void
    @State private var presentation = CompletionPresentation.calendar

    init(tracker: Tracker, now: Date, editGoal: @escaping () -> Void, @ViewBuilder calendar: () -> CalendarContent) {
        self.tracker = tracker
        self.now = now
        calendarContent = calendar()
        self.editGoal = editGoal
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                Picker(L.text("Progress view"), selection: $presentation) {
                    ForEach(CompletionPresentation.allCases, id: \.self) { option in
                        Text(L.text(option.title)).tag(option)
                    }
                }.pickerStyle(.segmented).accessibilityIdentifier("completion.view")
                switch presentation {
                case .calendar: calendarContent
                case .barChart: barChart
                case .progressBar: progressBar
                }
                let full = tracker.frequencyHistory(until: now).filter { !$0.3 && $0.0.end <= now }
                if !full.isEmpty {
                    LabeledContent(L.text("Full-period success rate"), value: (Double(full.filter { $0.1 >= $0.2 }.count) / Double(full.count)).formatted(.percent.precision(.fractionLength(0)).locale(L.locale))).monospacedDigit()
                }
            }.padding(.vertical, 8)
        }
        .environment(\.calendar, tracker.calendar)
        .environment(\.timeZone, tracker.calendar.timeZone)
    }

    private var barChart: some View {
        let periods = CompletionProgressData.history(for: tracker, now: now)
        let maximum = periods.map { max($0.count, $0.target ?? 0) }.max() ?? 0
        let step = max(1, Int(ceil(Double(periods.count) / 4)))
        let labels = periods.enumerated().compactMap { index, period in
            index % step == 0 || index == periods.count - 1 ? period.interval.start : nil
        }
        return VStack(alignment: .leading, spacing: 12) {
            if periods.allSatisfy({ $0.count == 0 }) {
                ContentUnavailableView(L.text("No completion records in this period."), systemImage: "calendar")
                    .frame(minHeight: DetailStyle.chartHeight).accessibilityIdentifier("completion.chart")
            } else {
                Chart(periods) { period in
                    BarMark(x: .value(L.text("Period"), period.interval.start), y: .value(L.text("Recorded completions"), period.count))
                        .foregroundStyle(TrackerColors.accent)
                        .annotation(position: .top) {
                            if period.partial && period.count > 0 {
                                Image(systemName: "circle.lefthalf.filled").font(.caption)
                                    .foregroundStyle(.secondary).accessibilityLabel(L.text("Partial period"))
                            }
                        }
                    if let target = period.target {
                        PointMark(x: .value(L.text("Period"), period.interval.start), y: .value(L.text("Target"), target))
                            .symbol(.diamond).symbolSize(45).foregroundStyle(.secondary)
                    }
                }
                .frame(height: DetailStyle.chartHeight)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .chartYScale(domain: 0...max(maximum + 1, 1))
                .chartXAxis {
                    AxisMarks(values: labels) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date, format: Date.FormatStyle(date: .omitted, time: .omitted, locale: L.locale, calendar: tracker.calendar, timeZone: tracker.calendar.timeZone).month(.abbreviated).day())
                            }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L.text("Completion history"))
                .accessibilityIdentifier("completion.chart")
                .accessibilityChildren {
                    ForEach(periods) { period in
                        Text(DetailStyle.date(period.interval.start, calendar: tracker.calendar, now: now))
                        Text(countLabel(period))
                        if period.partial { Text(L.text("Partial period")) }
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { legend(periods) }
                    VStack(alignment: .leading, spacing: 8) { legend(periods) }
                }.font(.caption).foregroundStyle(.secondary)
                if periods.allSatisfy({ $0.target == nil }) {
                    Text(L.text("Weekly recorded completions")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func legend(_ periods: [CompletionPeriodProgress]) -> some View {
        Label(L.text("Recorded completions"), systemImage: "rectangle.fill")
        if periods.contains(where: { $0.target != nil }) { Label(L.text("Target"), systemImage: "diamond.fill") }
        if periods.contains(where: \.partial) { Label(L.text("Partial period"), systemImage: "circle.lefthalf.filled") }
    }

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let period = CompletionProgressData.current(for: tracker, now: now) {
                ProgressView(value: period.fraction) {
                    HStack {
                        Text(L.text(period.period == .weekly ? "This week" : "This month"))
                        Spacer()
                        Text(countLabel(period)).monospacedDigit()
                    }
                }
                .progressViewStyle(.linear)
                .accessibilityLabel(L.text(period.period == .weekly ? "This week" : "This month") + ": " + L.text("Recorded completions"))
                .accessibilityValue(countLabel(period))
                .accessibilityIdentifier("completion.progress")
                HStack {
                    Text(DetailStyle.date(period.interval.start, calendar: tracker.calendar, now: now))
                    Text("–")
                    Text(DetailStyle.date(tracker.calendar.date(byAdding: .day, value: -1, to: period.interval.end) ?? period.interval.start, calendar: tracker.calendar, now: now))
                }.font(.caption).foregroundStyle(.secondary)
                if period.count == 0 { Text(L.text("No completion records in this period.")).foregroundStyle(.secondary) }
            } else {
                Text(L.text("No completion goal")).font(.headline).accessibilityIdentifier("completion.progress")
                Button(L.text("Set a goal"), action: editGoal).accessibilityIdentifier("completion.setGoal")
            }
        }
    }

    private func countLabel(_ period: CompletionPeriodProgress) -> String {
        let count = period.count.formatted(.number.locale(L.locale))
        if let target = period.target { return count + " / " + target.formatted(.number.locale(L.locale)) }
        return count
    }
}

private enum CompletionPresentation: String, CaseIterable {
    case calendar, barChart, progressBar
    var title: String {
        switch self {
        case .calendar: "Calendar"
        case .barChart: "Bar chart"
        case .progressBar: "Progress bar"
        }
    }
}
