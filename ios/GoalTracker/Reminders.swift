import SwiftUI
import UserNotifications
import CoreLocation
import Observation
import UIKit

// This edits a tracker draft, including a tracker that has never been persisted.
struct ReminderScheduleEditor: View {
    @Binding var reminder: Reminder?
    @State private var enabled = false
    @State private var time = Date()
    @State private var weekdays = Set(1...7)
    @State private var initialized = false
    var body: some View {
        Form {
            Section {
                Toggle(L.text("Enable reminders"), isOn: $enabled).accessibilityIdentifier("reminder.enabled")
                if enabled {
                    DatePicker(L.text("Time"), selection: $time, displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("reminder.time")
                    WeekdaySelector(weekdays: $weekdays, identifier: "reminder.weekday")
                    if weekdays.isEmpty {
                        Text(L.text("Choose at least one weekday.")).foregroundStyle(.red)
                    }
                }
            } footer: {
                Text(L.text("Deadline goals also get a reminder on their due date."))
            }
        }
        .navigationTitle(L.text("Time and weekdays")).navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !initialized else { return }; initialized = true
            if let reminder {
                enabled = true; weekdays = Set(reminder.weekdays)
                time = Calendar.current.date(bySettingHour: reminder.hour, minute: reminder.minute, second: 0, of: Date()) ?? Date()
            }
        }
        .onChange(of: enabled) { _, _ in update() }
        .onChange(of: time) { _, _ in update() }
        .onChange(of: weekdays) { _, _ in update() }
    }
    private func update() {
        guard initialized else { return }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        reminder = enabled ? Reminder(hour: parts.hour ?? 0, minute: parts.minute ?? 0, weekdays: weekdays.sorted()) : nil
    }
}

@MainActor enum Reminders {
    static var enabled: Bool { globalEnabled(L.defaults) }
    static func globalEnabled(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: "remindersEnabled") as? Bool ?? true }
    static let conditionPrefix = "goalooker.condition."
    private static var revision = 0

    static func conditionIdentifier(_ id: UUID) -> String { conditionPrefix + id.uuidString }
    static func owns(_ identifier: String) -> Bool {
        if identifier.hasPrefix(conditionPrefix) {
            return UUID(uuidString: String(identifier.dropFirst(conditionPrefix.count))) != nil
        }
        let components = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2, UUID(uuidString: String(components[0])) != nil else { return false }
        return components[1] == "deadline" || (Int(components[1]).map { (1...7).contains($0) && String($0) == components[1] } ?? false)
    }
    static func requests(_ trackers: [Tracker], now: Date = Date(), enabled: Bool = true) throws -> [UNNotificationRequest] {
        guard enabled else { return [] }
        var result: [UNNotificationRequest] = []
        for t in trackers where !t.archived {
            guard let r = t.reminder else { continue }
            guard (0...23).contains(r.hour), (0...59).contains(r.minute), !r.weekdays.isEmpty,
                  Set(r.weekdays).count == r.weekdays.count, r.weekdays.allSatisfy({ (1...7).contains($0) }) else { throw DataError.invalidBackup }
            for day in r.weekdays {
                var parts = DateComponents(); parts.timeZone = t.calendar.timeZone; parts.weekday = day; parts.hour = r.hour; parts.minute = r.minute
                result.append(UNNotificationRequest(identifier: t.id.uuidString + ".\(day)",
                    content: content(t, body: t.kind == .daily ? "A moment to record your day." : "Any progress to capture?"),
                    trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)))
            }
            if let rule = t.rule(at: now), let due = rule.deadline, t.achievement(for: rule, now: now) == nil {
                var parts = t.calendar.dateComponents([.year, .month, .day], from: due)
                parts.timeZone = t.calendar.timeZone; parts.hour = r.hour; parts.minute = r.minute
                if let date = t.calendar.date(from: parts), date > now {
                    result.append(UNNotificationRequest(identifier: t.id.uuidString + ".deadline",
                        content: content(t, body: "Your goal's deadline is today."),
                        trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
                }
            }
        }
        guard result.count <= 60 else { throw DataError.tooManyReminders }
        return result
    }
    static func content(_ tracker: Tracker, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = tracker.name; content.body = L.text(body); content.sound = .default
        content.userInfo = ["url": "goaltracker://record/" + tracker.id.uuidString]
        return content
    }
    // Reserve one pending slot for each condition tracker; global OFF never bypasses validation.
    static func validate(_ trackers: [Tracker], now: Date = Date()) throws {
        _ = try ConditionPlan.centers(trackers)
        let time = try requests(trackers, now: now)
        guard time.count + ConditionPlan.eligible(trackers).count <= 60 else { throw DataError.tooManyReminders }
    }
    static func hasCapacity(planned: Int, pending: [String], adding identifier: String) -> Bool {
        let others = pending.filter { $0 != identifier }
        let conditions = others.filter { $0.hasPrefix(conditionPrefix) && owns($0) }.count
        let foreign = others.filter { !owns($0) }.count
        return foreign + max(planned + conditions, others.filter(owns).count) + 1 <= 60
    }
    static func sync(_ trackers: [Tracker], requestPermission: Bool = false) async throws {
        revision += 1; let token = revision
        let center = UNUserNotificationCenter.current()
        if !enabled {
            let pending = await center.pendingNotificationRequests()
            guard revision == token, !enabled else { return }
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter(owns))
            let delivered = await center.deliveredNotifications()
            guard revision == token, !enabled else { return }
            center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }.filter(owns))
            try await ConditionReminders.shared.sync(trackers: trackers, enabled: false)
            return
        }
        try validate(trackers)
        if requestPermission && trackers.contains(where: { !$0.archived && ($0.reminder != nil || $0.remindWhenMet == true) }) {
            guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else {
                throw ConditionError("Notifications are disabled. You can enable them in iPhone Settings.")
            }
        }
        let settings = await center.notificationSettings()
        try Task.checkCancellation()
        guard revision == token, enabled else { return }
        let authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        let planned = authorized ? try requests(trackers) : []
        let old = await center.pendingNotificationRequests()
        guard revision == token, enabled else { return }
        let conditionIDs = Set(ConditionPlan.eligible(trackers).map { conditionIdentifier($0.id) })
        let desiredIDs = Set(planned.map(\.identifier)).union(authorized ? conditionIDs : [])
        let unknownCount = old.filter { !owns($0.identifier) }.count
        guard unknownCount + planned.count + (authorized ? conditionIDs.count : 0) <= 60 else { throw DataError.tooManyReminders }
        for request in planned {
            try Task.checkCancellation()
            guard revision == token, enabled else { return }
            try await center.add(request)
        }
        guard revision == token, enabled else { return }
        center.removePendingNotificationRequests(withIdentifiers: old.map(\.identifier).filter { owns($0) && !desiredIDs.contains($0) })
        let delivered = await center.deliveredNotifications()
        guard revision == token, enabled else { return }
        center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }.filter { owns($0) && !desiredIDs.contains($0) })
        try await ConditionReminders.shared.sync(trackers: trackers, enabled: true, notificationsAuthorized: authorized)
    }
}

@MainActor @Observable final class ConditionReminders: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = ConditionReminders()
    static let monitorName = "GoalookerConditions"
    private(set) var authorization = CLAuthorizationStatus.notDetermined
    private(set) var precise = true
    private(set) var failureKey: String?
    @ObservationIgnored private var manager: CLLocationManager?
    // Type erasure keeps the iOS 18 service object out of iOS 17 stored-property availability.
    @ObservationIgnored private var serviceSession: Any?
    @ObservationIgnored private var requestAlwaysAfterWhenInUse = false
    @ObservationIgnored private var monitorTask: Task<CLMonitor, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var eventGeneration = UUID()
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var trackers: [Tracker] = []
    @ObservationIgnored private var active = false
    @ObservationIgnored private var notificationsAuthorized = false
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var configurationSignature = ""
    @ObservationIgnored private var history: [String: ConditionTransition] = [:]
    private let historyKey = "goalooker.condition.transitions"

    private override init() {
        super.init()
        if let data = L.defaults.data(forKey: historyKey),
           let saved = try? JSONDecoder().decode([String: ConditionTransition].self, from: data) { history = saved }
    }
    var availabilityKey: String? {
        if !Reminders.enabled { return "All reminders are off in Settings. Your tracker choices are kept." }
        if authorization != .authorizedAlways {
            return "Location reminders are inactive. Allow Always location access in iPhone Settings for background reminders."
        }
        if !precise { return "Location reminders are inactive while Precise Location is off." }
        return failureKey
    }
    func start() {
        guard bootstrapTask == nil else { return }
        if Reminders.enabled && !history.isEmpty {
            // Retake an outstanding background session before loading the Ledger or awaiting notifications.
            // This temporary manager has no delegate and never starts GPS or asks for authorization.
            let permission = CLLocationManager()
            if permission.authorizationStatus == .authorizedAlways && permission.accuracyAuthorization == .fullAccuracy {
                updateServiceSession(active: true)
            }
        }
        bootstrapTask = Task {
            do {
                // Start before SwiftUI scene construction, including a location-triggered background launch.
                var url: URL?
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--uitesting") {
                    url = URL.applicationSupportDirectory.appendingPathComponent("UITests/test.store")
                }
                #endif
                let store = try AppStore(url: url)
                try await Reminders.sync(store.trackers)
            } catch {
                updateServiceSession(active: false)
                failureKey = (error as? ConditionError)?.key ?? "Could not configure location reminders. Open the app to try again."
            }
        }
    }
    // Call only from explicit condition reminder ON / Save. Configuration itself never asks.
    func requestAuthorization() {
        let manager = locationManager()
        requestAlwaysAfterWhenInUse = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: requestAlwaysAfterWhenInUse = false; manager.requestAlwaysAuthorization()
        default: requestAlwaysAfterWhenInUse = false
        }
    }
    private func locationManager() -> CLLocationManager {
        if let manager { return manager }
        let manager = CLLocationManager(); self.manager = manager
        manager.delegate = self
        authorization = manager.authorizationStatus; precise = manager.accuracyAuthorization == .fullAccuracy
        return manager
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus; precise = manager.accuracyAuthorization == .fullAccuracy
        if requestAlwaysAfterWhenInUse && authorization != .notDetermined {
            requestAlwaysAfterWhenInUse = false
            if authorization == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
        }
        Task {
            do { try await sync(trackers: trackers, enabled: Reminders.enabled, notificationsAuthorized: notificationsAuthorized) }
            catch { failureKey = (error as? ConditionError)?.key ?? "Could not configure location reminders. Open the app to try again." }
        }
    }
    private func monitor() async -> CLMonitor {
        if let monitorTask { return await monitorTask.value }
        let task = Task { await CLMonitor(Self.monitorName) }
        monitorTask = task
        return await task.value
    }
    private func updateServiceSession(active: Bool) {
        if #available(iOS 18.0, *) {
            if active && serviceSession == nil {
                // Only already-granted Always authorization reaches this path; configuration cannot prompt.
                serviceSession = CLServiceSession(authorization: .always)
            } else if !active {
                (serviceSession as? CLServiceSession)?.invalidate()
                serviceSession = nil
            }
        }
    }
    func sync(trackers: [Tracker], enabled: Bool, notificationsAuthorized: Bool = false) async throws {
        self.trackers = trackers
        self.notificationsAuthorized = notificationsAuthorized
        let eligible = ConditionPlan.eligible(trackers)
        let centers = enabled ? try ConditionPlan.centers(trackers) : []
        let allowed = enabled && notificationsAuthorized && !eligible.isEmpty
        let manager = allowed ? locationManager() : self.manager
        let canMonitor = allowed && manager?.authorizationStatus == .authorizedAlways && manager?.accuracyAuthorization == .fullAccuracy
        updateServiceSession(active: canMonitor)
        let config = "\(enabled):\(notificationsAuthorized):\(canMonitor):" + eligible.map { $0.id.uuidString + ":" + ConditionPlan.signature($0) }.sorted().joined(separator: "|")
        // Metadata/record saves do not restart monitoring or discard an in-flight native event.
        guard config != configurationSignature || (canMonitor && eventsTask == nil) else { return }
        configurationSignature = config
        revision += 1; let token = revision
        let wasActive = active; active = canMonitor
        let ids = Set(eligible.map { $0.id.uuidString })
        history = history.filter { ids.contains($0.key) }
        if !canMonitor {
            for key in history.keys { history[key]?.reset() }
            persist()
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            guard revision == token else { return }
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(Reminders.conditionPrefix) && Reminders.owns($0) })
            let delivered = await center.deliveredNotifications()
            guard revision == token else { return }
            center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }.filter { $0.hasPrefix(Reminders.conditionPrefix) && Reminders.owns($0) })
        } else if !wasActive {
            // Saved history survives process restart. OFF/permission loss explicitly resets aggregate above.
            for t in eligible where history[t.id.uuidString]?.signature != ConditionPlan.signature(t) {
                history[t.id.uuidString] = ConditionTransition(signature: ConditionPlan.signature(t))
            }
        }
        // The named native monitor persists across processes. Reconcile it even on inactive cold launch.
        let monitor = await monitor()
        guard revision == token else { return }
        let desired = canMonitor ? Set(centers.map(\.identifier)) : []
        for id in await monitor.identifiers where !desired.contains(id) {
            guard revision == token else { return }
            await monitor.remove(id)
        }
        if !canMonitor {
            eventGeneration = UUID()
            eventsTask?.cancel(); eventsTask = nil
            return
        }
        let existing = Set(await monitor.identifiers)
        for center in centers where !existing.contains(center.identifier) {
            guard revision == token else { return }
            await monitor.add(CLMonitor.CircularGeographicCondition(center: center.coordinate, radius: PlaceCondition.radius), identifier: center.identifier)
        }
        guard revision == token else { return }
        failureKey = nil
        // Prime only new configurations here. Warm aggregate history must await the native event.
        await evaluate(monitor: monitor, event: nil, primeOnly: true)
        guard revision == token else { return }
        if eventsTask == nil {
            let generation = UUID(); eventGeneration = generation
            eventsTask = Task { [weak self] in
                defer { if self?.eventGeneration == generation { self?.eventsTask = nil } }
                do {
                    for try await event in await monitor.events {
                        guard let self, !Task.isCancelled else { return }
                        await self.evaluate(monitor: monitor, event: event, primeOnly: false)
                    }
                } catch {
                    self?.failureKey = "Could not configure location reminders. Open the app to try again."
                }
            }
        }
    }
    private func evaluate(monitor: CLMonitor, event: CLMonitor.Event?, primeOnly: Bool) async {
        guard active, Reminders.enabled else { return }
        let token = revision
        for t in ConditionPlan.eligible(trackers) {
            if let event, !t.resolvedConditions.contains(where: { ConditionCenter($0.location).identifier == event.identifier }) { continue }
            let signature = ConditionPlan.signature(t)
            let key = t.id.uuidString
            var transition = history[key] ?? ConditionTransition(signature: signature)
            if primeOnly && transition.signature == signature && transition.aggregate != nil { continue }
            var native: [String: ConditionRegionFact] = [:]
            let places = t.resolvedConditionGroups.flatMap(\.conditions).filter { $0.place != nil }
            for id in Set(places.compactMap { $0.place.map { ConditionCenter($0.location).identifier } }) {
                let last = event?.identifier == id ? event : await monitor.record(for: id)?.lastEvent
                if let last {
                    let inside: ConditionState = eventUsable(last) ? (last.state == .satisfied ? .met : .unmet) : .unknown
                    native[id] = ConditionRegionFact(inside: inside, date: last.date)
                }
            }
            guard revision == token, active, Reminders.enabled else { return }
            // Time and weekday leaves use the live clock after the monitor awaits, never the event's date.
            let now = Date()
            let facts = ConditionPlan.facts(t, regions: native, now: now)
            // Every initial relevant native state must be known before ANY or ALL can prime.
            let aggregate = ConditionEvaluation.status(tracker: t, facts: facts, now: now).state
            let shouldNotify = transition.observe(aggregate, signature: signature, now: now,
                initialStatesKnown: !facts.places.values.contains(.unknown))
            history[key] = transition
            // Only a fresh delivered native event may trigger, never a cached startup snapshot.
            if !primeOnly, let event, ConditionPlan.mayNotify(transition: shouldNotify,
                eventState: eventUsable(event) ? .met : .unknown, eventDate: event.date, now: now,
                enabled: Reminders.enabled, authorized: active) {
                let center = UNUserNotificationCenter.current()
                let settings = await center.notificationSettings()
                let pending = await center.pendingNotificationRequests()
                guard revision == token, active, Reminders.enabled,
                      settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { continue }
                let deliveryTime = Date()
                let deliveryFacts = ConditionPlan.facts(t, regions: native, now: deliveryTime)
                guard ConditionEvaluation.status(tracker: t, facts: deliveryFacts, now: deliveryTime).state == .met,
                      ConditionPlan.mayNotify(transition: shouldNotify, eventState: eventUsable(event) ? .met : .unknown,
                        eventDate: event.date, now: deliveryTime, enabled: Reminders.enabled, authorized: active) else { continue }
                let identifier = Reminders.conditionIdentifier(t.id)
                let plannedCount = (try? Reminders.requests(trackers).count) ?? 60
                guard Reminders.hasCapacity(planned: plannedCount, pending: pending.map(\.identifier), adding: identifier) else { continue }
                do {
                    try await center.add(UNNotificationRequest(identifier: identifier,
                        content: Reminders.content(t, body: "Your achievement conditions are met. A moment to record?"), trigger: nil))
                    guard revision == token, active, Reminders.enabled else {
                        center.removePendingNotificationRequests(withIdentifiers: [identifier])
                        center.removeDeliveredNotifications(withIdentifiers: [identifier]); continue
                    }
                    history[key]?.delivered(at: deliveryTime)
                } catch {
                    failureKey = "Could not deliver the location reminder. Check notification settings."
                }
            }
        }
        persist()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(history) { L.defaults.set(data, forKey: historyKey) }
    }
    private func eventUsable(_ event: CLMonitor.Event) -> Bool {
        guard event.state == .satisfied || event.state == .unsatisfied else { return false }
        if #available(iOS 18.0, *), event.authorizationDenied || event.authorizationDeniedGlobally || event.authorizationRestricted || event.accuracyLimited || event.conditionUnsupported || event.conditionLimitExceeded || event.persistenceUnavailable || event.insufficientlyInUse || event.serviceSessionRequired || event.authorizationRequestInProgress { return false }
        return true
    }
}

@MainActor final class GoalookerAppDelegate: UIResponder, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        ConditionReminders.shared.start()
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard Reminders.owns(response.notification.request.identifier),
              let string = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: string), url.scheme == "goaltracker", url.host == "record",
              UUID(uuidString: url.lastPathComponent) != nil else { return }
        await UIApplication.shared.open(url)
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        !Reminders.owns(notification.request.identifier) || Reminders.enabled ? [.banner, .sound] : []
    }
}
