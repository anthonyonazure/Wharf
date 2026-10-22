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

/// The calendar fields a rule looks at.
struct LayoutCalendarEvent: Equatable {
    var startDate: Date
    var eventIdentifier: String
}

/// Everything the engine reads from or does to the running system. The live
/// value uses the wall clock, the calendar service and the layout service;
/// tests inject a clock, an event list and recorders so the whole firing path
/// runs in process.
struct LayoutTriggerEnvironment {
    var now: () -> Date
    var calendar: () -> Calendar
    /// Upcoming events in start order, including one already in progress.
    var upcomingEvents: () -> [LayoutCalendarEvent]
    var layouts: () -> [WorkspaceLayout]
    var restore: (WorkspaceLayout) -> Void
    var launchAndRestore: (WorkspaceLayout) -> Void

    static let live = LayoutTriggerEnvironment(
        now: { Date() },
        calendar: { Calendar.current },
        upcomingEvents: {
            CalendarService.shared.upcomingEvents.map {
                LayoutCalendarEvent(startDate: $0.startDate, eventIdentifier: $0.eventIdentifier)
            }
        },
        layouts: { WorkspaceLayoutService.shared.layouts },
        restore: { WorkspaceLayoutService.shared.restore($0) },
        launchAndRestore: { WorkspaceLayoutService.shared.launchAndRestore($0) }
    )
}

extension LayoutTrigger {
    /// Whether a time-of-day rule is due at `now`: the wall clock reads the
    /// rule's hour and minute, and (when weekdays are listed) today is one of
    /// them. The whole minute matches, which is why the engine needs a
    /// refractory period.
    static func timeOfDayMatches(
        hour: Int,
        minute: Int,
        weekdays: [Int],
        now: Date,
        calendar: Calendar
    ) -> Bool {
        let components = calendar.dateComponents([.hour, .minute, .weekday], from: now)
        guard components.hour == hour, components.minute == minute else { return false }
        if !weekdays.isEmpty, let weekday = components.weekday, !weekdays.contains(weekday) { return false }
        return true
    }

    /// The event a calendar rule should fire for, if any: the first event that
    /// has not started, when it starts within `minutesBefore` minutes and this
    /// rule has not already handled it.
    static func calendarEventDue(
        minutesBefore: Int,
        now: Date,
        events: [LayoutCalendarEvent],
        handledEventID: String?
    ) -> LayoutCalendarEvent? {
        // First event that has not started. `nextEvent` can be the
        // meeting currently in progress, in which case a rule for the
        // one after it would never fire.
        guard let event = events.first(where: { $0.startDate > now }) else { return nil }
        let secondsAway = event.startDate.timeIntervalSince(now)
        let windowStart = TimeInterval(minutesBefore) * 60
        // A band, not an instant: the check runs every 20 seconds and
        // would step straight over an exact-second comparison.
        guard secondsAway > 0, secondsAway <= windowStart else { return nil }
        guard handledEventID != event.eventIdentifier else { return nil }
        return event
    }
}

@MainActor
final class LayoutTriggerEngine: ObservableObject {
    static let shared = LayoutTriggerEngine()

    /// How often the time and calendar rules are checked. Must stay well under
    /// 60 seconds so every wall-clock minute is sampled at least once.
    static let checkInterval: TimeInterval = 20

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

    /// The calendar day and minute-of-day each time-of-day rule last fired
    /// for. On the fall-back DST day the same wall-clock minute happens twice,
    /// more than the refractory period apart; this keeps "once per day".
    private var lastFiredSlot: [String: TimeOfDaySlot] = [:]

    private struct TimeOfDaySlot: Equatable {
        var year: Int?
        var month: Int?
        var day: Int?
        var minuteOfDay: Int
    }

    private var cancellables: Set<AnyCancellable> = []
    private var timer: Timer?
    static let defaultsKey = "wharf.layoutRules"
    private let defaults: UserDefaults
    private let environment: LayoutTriggerEnvironment

    /// Minimum gap between firings of the same rule.
    let refractoryPeriod: TimeInterval = 5 * 60

    /// `defaults` and `environment` are injectable so tests run against a
    /// throwaway suite, a fake clock and recorded actions.
    init(defaults: UserDefaults = .standard, environment: LayoutTriggerEnvironment = .live) {
        self.defaults = defaults
        self.environment = environment
        load()
    }

    var isRunning: Bool { timer != nil }

    func start() {
        // Idempotent: a second call would otherwise stack another timer and
        // another set of subscriptions, and every rule would fire twice.
        guard timer == nil else { return }

        let checkTimer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
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

    func stop() {
        timer?.invalidate()
        timer = nil
        cancellables.removeAll()
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

    /// One timer tick: fires every enabled time-of-day and calendar rule that
    /// is due right now.
    func evaluateTimeAndCalendarRules() {
        let now = environment.now()
        let calendar = environment.calendar()

        for rule in rules where rule.isEnabled {
            switch rule.trigger {
            case let .timeOfDay(hour, minute, weekdays):
                guard LayoutTrigger.timeOfDayMatches(
                    hour: hour, minute: minute, weekdays: weekdays, now: now, calendar: calendar
                ) else { continue }
                let day = calendar.dateComponents([.year, .month, .day], from: now)
                let slot = TimeOfDaySlot(
                    year: day.year, month: day.month, day: day.day, minuteOfDay: hour * 60 + minute
                )
                guard lastFiredSlot[rule.id] != slot else { continue }
                if fire(rule) { lastFiredSlot[rule.id] = slot }

            case let .beforeCalendarEvent(minutesBefore):
                guard let event = LayoutTrigger.calendarEventDue(
                    minutesBefore: minutesBefore,
                    now: now,
                    events: environment.upcomingEvents(),
                    handledEventID: handledEventByRule[rule.id]
                ) else { continue }
                handledEventByRule[rule.id] = event.eventIdentifier
                fire(rule, bypassRefractory: true)

            default:
                continue
            }
        }
    }

    func evaluateAppRules(_ bundleIdentifier: String) {
        for rule in rules where rule.isEnabled {
            guard case let .appActivated(target) = rule.trigger, target == bundleIdentifier else { continue }
            fire(rule)
        }
    }

    func evaluateDisplayRules() {
        for rule in rules where rule.isEnabled {
            guard case .displayConfigurationChanged = rule.trigger else { continue }
            fire(rule)
        }
    }

    @discardableResult
    private func fire(_ rule: LayoutRule, bypassRefractory: Bool = false) -> Bool {
        if !bypassRefractory,
           let last = lastFired[rule.id],
           environment.now().timeIntervalSince(last) < refractoryPeriod { return false }
        let layouts = environment.layouts()
        let resolved = rule.layoutID.flatMap { id in layouts.first { $0.id == id } }
            ?? layouts.first { $0.name == rule.layoutName }
        guard let layout = resolved else { return false }

        lastFired[rule.id] = environment.now()

        guard rule.launchesMissingApps else {
            environment.restore(layout)
            return true
        }
        environment.launchAndRestore(layout)
        return true
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([LayoutRule].self, from: data) else { return }
        rules = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
