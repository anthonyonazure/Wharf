//
//  LayoutTriggerEngine.swift
//  Wharf
//
//  Layouts that fire on their own.
//
//  A saved layout still costs a decision and a click. The value only compounds
//  when the desk rearranges itself because the day moved on: the work layout at
//  08:00 on weekdays, the meeting layout when a calendar event is about to
//  start, the research layout when the browser comes forward.
//
//  Deliberately rule-based rather than learned. A rule the user wrote is
//  predictable and can be turned off; a model guessing at window arrangements
//  is neither, and a wrong guess scatters a working desk.
//

import AppKit
import Combine

enum LayoutTrigger: Codable, Equatable {
    /// Fires once per day at a wall-clock time, on the listed weekdays
    /// (1 = Sunday, matching Calendar's numbering).
    case timeOfDay(hour: Int, minute: Int, weekdays: [Int])
    /// Fires when a calendar event is about to start.
    case beforeCalendarEvent(minutesBefore: Int)
    /// Fires when a given app becomes frontmost.
    case appActivated(bundleIdentifier: String)
    /// Fires when a display is connected or disconnected.
    case displayConfigurationChanged

    var describedInPlainEnglish: String {
        switch self {
        case let .timeOfDay(hour, minute, weekdays):
            let time = String(format: "%02d:%02d", hour, minute)
            return weekdays.isEmpty ? "Every day at \(time)" : "At \(time) on \(weekdayNames(weekdays))"
        case let .beforeCalendarEvent(minutes):
            return "\(minutes) minutes before a calendar event"
        case let .appActivated(bundleIdentifier):
            return "When \(bundleIdentifier) comes to the front"
        case .displayConfigurationChanged:
            return "When a display is connected or disconnected"
        }
    }

    private func weekdayNames(_ weekdays: [Int]) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        return weekdays.compactMap { index in
            (1...7).contains(index) ? symbols[index - 1] : nil
        }.joined(separator: ", ")
    }
}

struct LayoutRule: Codable, Equatable, Identifiable {
    var id: String
    /// Bound by id, not name. Names are user-editable and not unique, so a
    /// rename or a second layout called "Work" would silently point the rule
    /// at a different arrangement. Optional for rules saved before this field
    /// existed, which still fall back to the name.
    var layoutID: String?
    var layoutName: String
    var trigger: LayoutTrigger
    var isEnabled: Bool
    /// Whether to launch the layout's missing apps before placing windows.
    var launchesMissingApps: Bool
}

@MainActor
final class LayoutTriggerEngine: ObservableObject {
    static let shared = LayoutTriggerEngine()

    @Published private(set) var rules: [LayoutRule] = []

    /// The last time each rule fired, so a rule cannot fire repeatedly while
    /// its condition stays true. A time-of-day rule is true for a whole
    /// minute; without this the desk would rearrange itself dozens of times.
    private var lastFired: [String: Date] = [:]

    /// Calendar events each rule has already handled. The refractory period
    /// alone is time-based, so back-to-back meetings could each land inside one
    /// window and only the first would fire — or a long window could fire twice
    /// for the same meeting. Keyed by rule id to the event identifier.
    private var handledEventByRule: [String: String] = [:]

    private var cancellables: Set<AnyCancellable> = []
    private var timer: Timer?
    private let defaultsKey = "wharf.layoutRules"

    /// Minimum gap between firings of the same rule.
    private let refractoryPeriod: TimeInterval = 5 * 60

    private init() {
        load()
    }

    func start() {
        // Idempotent: a second call would otherwise stack another timer and
        // another set of subscriptions, and every rule would fire twice.
        guard timer == nil else { return }

        let checkTimer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluateTimeAndCalendarRules() }
        }
        RunLoop.main.add(checkTimer, forMode: .common)
        timer = checkTimer

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier }
            .sink { [weak self] bundleID in self?.evaluateAppRules(bundleID) }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            // Displays settle noisily; wait for the dust before rearranging.
            .debounce(for: .seconds(3), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluateDisplayRules() }
            .store(in: &cancellables)
    }

    // MARK: - Rule management

    func add(_ rule: LayoutRule) {
        rules.append(rule)
        save()
    }

    func update(_ rule: LayoutRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        save()
    }

    func delete(_ rule: LayoutRule) {
        rules.removeAll { $0.id == rule.id }
        save()
    }

    // MARK: - Evaluation

    private func evaluateTimeAndCalendarRules() {
        let now = Date()
        let components = Calendar.current.dateComponents([.hour, .minute, .weekday], from: now)

        for rule in rules where rule.isEnabled {
            switch rule.trigger {
            case let .timeOfDay(hour, minute, weekdays):
                guard components.hour == hour, components.minute == minute else { continue }
                if !weekdays.isEmpty, let weekday = components.weekday, !weekdays.contains(weekday) { continue }
                fire(rule)

            case let .beforeCalendarEvent(minutesBefore):
                // First event that has not started. `nextEvent` can be the
                // meeting currently in progress, in which case a rule for the
                // one after it would never fire.
                guard let event = CalendarService.shared.upcomingEvents
                    .first(where: { $0.startDate > now }) else { continue }
                let secondsAway = event.startDate.timeIntervalSince(now)
                let windowStart = TimeInterval(minutesBefore * 60)
                // A band, not an instant: the check runs every 20 seconds and
                // would step straight over an exact-second comparison.
                guard secondsAway > 0, secondsAway <= windowStart else { continue }
                guard handledEventByRule[rule.id] != event.eventIdentifier else { continue }
                handledEventByRule[rule.id] = event.eventIdentifier
                fire(rule, bypassRefractory: true)

            default:
                continue
            }
        }
    }

    private func evaluateAppRules(_ bundleIdentifier: String) {
        for rule in rules where rule.isEnabled {
            guard case let .appActivated(target) = rule.trigger, target == bundleIdentifier else { continue }
            fire(rule)
        }
    }

    private func evaluateDisplayRules() {
        for rule in rules where rule.isEnabled {
            guard case .displayConfigurationChanged = rule.trigger else { continue }
            fire(rule)
        }
    }

    private func fire(_ rule: LayoutRule, bypassRefractory: Bool = false) {
        if !bypassRefractory,
           let last = lastFired[rule.id],
           Date().timeIntervalSince(last) < refractoryPeriod { return }
        let layouts = WorkspaceLayoutService.shared.layouts
        let resolved = rule.layoutID.flatMap { id in layouts.first { $0.id == id } }
            ?? layouts.first { $0.name == rule.layoutName }
        guard let layout = resolved else { return }

        lastFired[rule.id] = Date()

        guard rule.launchesMissingApps else {
            WorkspaceLayoutService.shared.restore(layout)
            return
        }
        WorkspaceLayoutService.shared.launchAndRestore(layout)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([LayoutRule].self, from: data) else { return }
        rules = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
