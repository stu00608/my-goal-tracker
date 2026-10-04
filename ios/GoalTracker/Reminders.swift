import SwiftUI
import UserNotifications
import CoreLocation

struct ReminderEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let tracker: Tracker
    @State private var enabled = false
    @State private var time = Date()
    @State private var weekdays = Set(1...7)
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        Form {
            Toggle(L.text("Enable reminders"), isOn: $enabled)
            if enabled {
                Section {
                DatePicker(L.text("Time"), selection: $time, displayedComponents: .hourAndMinute)
                ForEach(1...7, id: \.self) { day in
                    Toggle(L.locale.calendar.weekdaySymbols[day - 1], isOn: Binding(get: { weekdays.contains(day) }, set: { if $0 { weekdays.insert(day) } else { weekdays.remove(day) } }))
                }
                } footer: {
                    Text(L.text("Deadline goals also get a reminder on their due date.")).font(.caption).foregroundStyle(TrackerColors.secondaryText)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle(tracker.name)
            .toolbar { Button(L.text("Save")) {
                Task {
                    busy = true; defer { busy = false }
                    do {
                        if enabled {
                            guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) else { error = L.text("Notifications are disabled. You can enable them in iPhone Settings."); return }
                        }
                        var t = store.trackers.first { $0.id == tracker.id } ?? tracker
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                        t.reminder = enabled ? Reminder(hour: parts.hour!, minute: parts.minute!, weekdays: weekdays.sorted()) : nil
                        let candidate = store.trackers.map { $0.id == t.id ? t : $0 }
                        _ = try Reminders.requests(candidate)
                        try store.save(t); try await Reminders.sync(store.trackers); dismiss()
                    } catch { self.error = L.error(error) }
                }
            }.disabled(busy || (enabled && weekdays.isEmpty)) }
            .onAppear {
                if let r = tracker.reminder {
                    enabled = true; weekdays = Set(r.weekdays)
                    time = Calendar.current.date(bySettingHour: r.hour, minute: r.minute, second: 0, of: Date())!
                }
            }
    }
}

@MainActor enum Reminders {
    static func requests(_ trackers: [Tracker], now: Date = Date()) throws -> [UNNotificationRequest] {
        var result: [UNNotificationRequest] = []
        for t in trackers where !t.archived {
            guard let r = t.reminder else { continue }
            for day in r.weekdays {
                var parts = DateComponents(); parts.timeZone = t.calendar.timeZone; parts.weekday = day; parts.hour = r.hour; parts.minute = r.minute
                let content = UNMutableNotificationContent(); content.title = t.name; content.body = L.text(t.kind == .daily ? "A moment to record your day." : "Any progress to capture?"); content.sound = .default
                result.append(UNNotificationRequest(identifier: t.id.uuidString + ".\(day)", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)))
            }
            if let rule = t.rule(at: now), let due = rule.deadline, !t.achieved(rule) {
                var parts = t.calendar.dateComponents([.year, .month, .day], from: due)
                parts.timeZone = t.calendar.timeZone; parts.hour = r.hour; parts.minute = r.minute
                if let date = t.calendar.date(from: parts), date > now {
                    let content = UNMutableNotificationContent(); content.title = t.name; content.body = L.text("Your goal's deadline is today."); content.sound = .default
                    result.append(UNNotificationRequest(identifier: t.id.uuidString + ".deadline", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
                }
            }
        }
        guard result.count <= 60 else { throw DataError.tooManyReminders }
        return result
    }
    static func sync(_ trackers: [Tracker]) async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        try Task.checkCancellation()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let planned = try requests(trackers)
        let old = await center.pendingNotificationRequests()
        for request in planned { try Task.checkCancellation(); try await center.add(request) }
        try Task.checkCancellation()
        let identifiers = Set(planned.map(\.identifier))
        center.removePendingNotificationRequests(withIdentifiers: old.filter { !identifiers.contains($0.identifier) }.map(\.identifier))
    }
}
