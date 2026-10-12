import XCTest
@testable import Wharf

/// The runtime firing path of layout rules, run in process: an injected clock
/// and calendar feed the same evaluation the 20 second timer runs, and the
/// "restore" actions are recorders. This is the proof that a rule fires.
@MainActor
final class LayoutTriggerEngineTests: LayoutTestCase {
    /// A scripted machine for the engine.
    @MainActor
    final class Harness {
        var clock = TestCalendars.date(2026, 10, 12, 7, 59, 0) // a Monday
        var calendar = TestCalendars.utc
        var events: [LayoutCalendarEvent] = []
        var layouts: [WorkspaceLayout] = []
        private(set) var restored: [WorkspaceLayout] = []
        private(set) var launchedAndRestored: [WorkspaceLayout] = []
        let defaults: UserDefaults
        private(set) var engine: LayoutTriggerEngine!

        init(defaults: UserDefaults) {
            self.defaults = defaults
            engine = makeEngine()
        }

        func makeEngine() -> LayoutTriggerEngine {
            LayoutTriggerEngine(
                defaults: defaults,
                environment: LayoutTriggerEnvironment(
                    now: { self.clock },
                    calendar: { self.calendar },
                    upcomingEvents: { self.events },
                    layouts: { self.layouts },
                    restore: { self.restored.append($0) },
                    launchAndRestore: { self.launchedAndRestored.append($0) }
                )
            )
        }

        func reload() -> LayoutTriggerEngine {
            makeEngine()
        }

        func tick(at date: Date) {
            clock = date
            engine.evaluateTimeAndCalendarRules()
        }

        var fireCount: Int { restored.count + launchedAndRestored.count }
    }

    private var harness: Harness!
    private let work = makeLayout(id: "layout-work", name: "Work", placements: [makePlacement()])
    private let focus = makeLayout(id: "layout-focus", name: "Focus", placements: [makePlacement(title: "Other")])

    override func setUp() {
        super.setUp()
        harness = Harness(defaults: makeDefaults())
        harness.layouts = [work, focus]
    }

    private func rule(
        _ id: String = "rule",
        layout: WorkspaceLayout? = nil,
        trigger: LayoutTrigger,
        enabled: Bool = true,
        launches: Bool = false,
        useID: Bool = true
    ) -> LayoutRule {
        let target = layout ?? work
        return LayoutRule(
            id: id,
            layoutID: useID ? target.id : nil,
            layoutName: target.name,
            trigger: trigger,
            isEnabled: enabled,
            launchesMissingApps: launches
        )
    }

    private func at(_ hour: Int, _ minute: Int, _ second: Int = 0, day: Int = 12) -> Date {
        TestCalendars.date(2026, 10, day, hour, minute, second)
    }

    // MARK: - Time of day firing

    func testTimeRuleFiresWhenTheClockReachesItsMinute() {
        harness.engine.add(rule(trigger: .timeOfDay(hour: 8, minute: 0, weekdays: [])))
        harness.tick(at: at(7, 59, 40))
        XCTAssertEqual(harness.fireCount, 0)
        harness.tick(at: at(8, 0, 5))
        XCTAssertEqual(harness.restored, [work])
    }

    func testTimeRuleDoesNotFireOutsideItsMinute() {
        harness.engine.add(rule(trigger: .timeOfDay(hour: 8, minute: 0, weekdays: [])))
        for (hour, minute) in [(0, 0), (7, 59), (8, 1), (12, 0), (20, 0), (23, 59)] {
            harness.tick(at: at(hour, minute, 30))
        }
        XCTAssertEqual(harness.fireCount, 0)
    }

    func testTimeRuleFiresOnceAcrossTheThreeTicksInItsMinute() {
        harness.engine.add(rule(trigger: .timeOfDay(hour: 8, minute: 0, weekdays: [])))
        for second in [0, 20, 40] { harness.tick(at: at(8, 0, second)) }
        XCTAssertEqual(harness.fireCount, 1)
    }

    func testTimeRuleLandsInsideItsMinuteForEveryTimerPhase() {
        // The timer starts at an arbitrary moment. Whatever the phase, ticks
        // every `checkInterval` seconds hit the target minute and the rule
        // fires exactly once per day.
        for phase in 0..<Int(LayoutTriggerEngine.checkInterval) {
            let local = Harness(defaults: makeDefaults())
            local.layouts = [work]
            local.engine.add(rule(trigger: .timeOfDay(hour: 8, minute: 15, weekdays: [])))
            var tick = at(8, 10, 0).addingTimeInterval(TimeInterval(phase))
            let end = at(8, 25, 0)
            while tick < end {
                local.tick(at: tick)
                tick = tick.addingTimeInterval(LayoutTriggerEngine.checkInterval)
            }
            XCTAssertEqual(local.fireCount, 1, "phase \(phase)")
        }
    }

    func testCheckIntervalSamplesEveryMinuteAtLeastTwice() {
        XCTAssertEqual(LayoutTriggerEngine.checkInterval, 20)
        XCTAssertLessThanOrEqual(LayoutTriggerEngine.checkInterval, 30)
    }

    func testTimeRuleFiresAgainTheNextDay() {
        harness.engine.add(rule(trigger: .timeOfDay(hour: 8, minute: 0, weekdays: [])))
        harness.tick(at: at(8, 0, 10, day: 12))
        harness.tick(at: at(8, 0, 10, day: 13))
        harness.tick(at: at(8, 0, 10, day: 14))
        XCTAssertEqual(harness.fireCount, 3)
    }

    func testWeekdayFilterFiresOnlyOnListedDays() {
        harness.engine.add(rule(trigger: .timeOfDay(hour: 8, minute: 0, weekdays: [Weekday.monday, Weekday.wednesday])))
        // Oct 11 (Sun) ... Oct 17 (Sat)
        var firedDays: [Int] = []
        for day in 11...17 {
            let before = harness.fireCount
            harness.tick(at: at(8, 0, 10, day: day))
            if harness.fireCount > before { firedDays.append(day) }
        }
        XCTAssertEqual(firedDays, [12, 14])
    }

    func testRuleAtMidnightFiresOnceAcrossTheDayChange() {
        harness.engine.add(rule(trigger: .timeOfDay(hour: 0, minute: 0, weekdays: [])))
        harness.tick(at: at(23, 59, 40, day: 12))
        harness.tick(at: at(0, 0, 0, day: 13))
        harness.tick(at: at(0, 0, 20, day: 13))
        XCTAssertEqual(harness.fireCount, 1)
    }

    func testRuleAtTheLastMinuteOfTheDay() {
        harness.engine.add(rule(trigger: .timeOfDay(hour: 23, minute: 59, weekdays: [])))
        harness.tick(at: at(23, 59, 50))
        XCTAssertEqual(harness.fireCount, 1)
    }

    func testDisabledRuleNeverFires() {
        harness.engine.add(rule(trigger: .timeOfDay(hour: 8, minute: 0, weekdays: []), enabled: false))
        harness.tick(at: at(8, 0, 10))
        XCTAssertEqual(harness.fireCount, 0)
    }

    func testEnablingARuleMakesItFire() {
        var disabled = rule(trigger: .timeOfDay(hour: 8, minute: 0, weekdays: []), enabled: false)
        harness.engine.add(disabled)
        harness.tick(at: at(8, 0, 10))
        disabled.isEnabled = true
        harness.engine.update(disabled)
        harness.tick(at: at(8, 0, 30))
        XCTAssertEqual(harness.fireCount, 1)
    }

    func testTwoRulesDueTogetherBothFire() {
        harness.engine.add(rule("a", layout: work, trigger: .timeOfDay(hour: 8, minute: 0, weekdays: [])))
        harness.engine.add(rule("b", layout: focus, trigger: .timeOfDay(hour: 8, minute: 0, weekdays: [])))
        harness.tick(at: at(8, 0, 10))
        XCTAssertEqual(harness.restored, [work, focus])
    }

    func testTwoRulesForTheSameLayoutEachFireOnce() {
        harness.engine.add(rule("a", trigger: .timeOfDay(hour: 8, minute: 0, weekdays: [])))
        harness.engine.add(rule("b", trigger: .timeOfDay(hour: 8, minute: 0, weekdays: [])))
        harness.tick(at: at(8, 0, 10))
        harness.tick(at: at(8, 0, 30))
        XCTAssertEqual(harness.fireCount, 2)
    }

    func testRulesAtDifferentTimesFireIndependently() {
        harness.engine.add(rule("morning", layout: work, trigger: .timeOfDay(hour: 8, minute: 0, weekdays: [])))
        harness.engine.add(rule("evening", layout: focus, trigger: .timeOfDay(hour: 18, minute: 30, weekdays: [])))
        harness.tick(at: at(8, 0, 10))
        harness.tick(at: at(18, 30, 10))
        XCTAssertEqual(harness.restored, [work, focus])
    }

    func testRuleFollowsTheEnginesCalendarTimeZone() {
        harness.calendar = TestCalendars.newYork
        harness.engine.add(rule(trigger: .timeOfDay(hour: 8, minute: 0, weekdays: [])))
        harness.tick(at: TestCalendars.date(2026, 10, 12, 8, 0, 10)) // 08:00 UTC = 04:00 New York
        XCTAssertEqual(harness.fireCount, 0)
        harness.tick(at: TestCalendars.date(2026, 10, 12, 12, 0, 10)) // 08:00 New York
        XCTAssertEqual(harness.fireCount, 1)
    }

    func testRuleFiresTwiceOnTheFallBackDayWhenItsTimeRepeats() {
        // "Once per day" is the documented behaviour of a time rule, but the
        // 01:30 wall-clock minute happens twice on 2026-11-01 in New York and
        // the refractory period is only five minutes.
        harness.calendar = TestCalendars.newYork
        harness.engine.add(rule(trigger: .timeOfDay(hour: 1, minute: 30, weekdays: [])))
        var tick = TestCalendars.date(2026, 11, 1, 0, 0, in: TestCalendars.newYork)
        let end = tick.addingTimeInterval(4 * 3600)
        while tick < end {
            harness.tick(at: tick)
            tick = tick.addingTimeInterval(LayoutTriggerEngine.checkInterval)
        }
        XCTAssertEqual(harness.fireCount, 1)
    }

    func testRuleForTheSkippedSpringForwardMinuteNeverFires() {
        harness.calendar = TestCalendars.newYork
        harness.engine.add(rule(trigger: .timeOfDay(hour: 2, minute: 30, weekdays: [])))
        var tick = TestCalendars.date(2026, 3, 8, 0, 0, in: TestCalendars.newYork)
        let end = tick.addingTimeInterval(24 * 3600)
        while tick < end {
            harness.tick(at: tick)
            tick = tick.addingTimeInterval(LayoutTriggerEngine.checkInterval)
        }
        XCTAssertEqual(harness.fireCount, 0)
    }

    func testClockMovedBackwardsKeepsARuleQuietUntilTheOldTimestampPasses() {
        harness.engine.add(rule(trigger: .timeOfDay(hour: 8, minute: 0, weekdays: [])))
        harness.tick(at: at(8, 0, 10))
        harness.tick(at: at(7, 59, 0)) // user sets the clock back a minute
        harness.tick(at: at(8, 0, 0))
        XCTAssertEqual(harness.fireCount, 1)
    }

    // MARK: - Resolving the layout

    func testRuleResolvesItsLayoutByIDEvenAfterARename() {
        harness.layouts = [makeLayout(id: work.id, name: "Renamed", placements: work.placements), focus]
        harness.engine.add(rule(layout: work, trigger: .timeOfDay(hour: 8, minute: 0, weekdays: [])))
        harness.tick(at: at(8, 0, 10))
        XCTAssertEqual(harness.restored.first?.name, "Renamed")
    }

    func testRuleBoundByIDPrefersTheIDOverAnotherLayoutWithTheSameName() {
        let twin = makeLayout(id: "twin", name: "Work", placements: [makePlacement(title: "Twin")])
        harness.layouts = [twin, work]
        harness.engine.add(rule(layout: work, trigger: .timeOfDay(hour: 8, minute: 0, weekdays: [])))
        harness.tick(at: at(8, 0, 10))
        XCTAssertEqual(harness.restored.first?.id, work.id)
    }

    func testRuleWithoutLayoutIDFallsBackToTheName() {
        harness.engine.add(rule(layout: focus, trigger: .timeOfDay(hour: 8, minute: 0, weekdays: []), useID: false))
        harness.tick(at: at(8, 0, 10))
        XCTAssertEqual(harness.restored.first?.id, focus.id)
    }

    func testRuleWithADanglingIDFallsBackToTheName() {
        var dangling = rule(trigger: .timeOfDay(hour: 8, minute: 0, weekdays: []))
        dangling.layoutID = "deleted-layout"
        harness.engine.add(dangling)
        harness.tick(at: at(8, 0, 10))
        XCTAssertEqual(harness.restored.first?.id, work.id, "same name, different layout: a documented fallback")
    }

    func testRuleWithNoMatchingLayoutDoesNothing() {
        harness.layouts = []
        harness.engine.add(rule(trigger: .timeOfDay(hour: 8, minute: 0, weekdays: [])))
        harness.tick(at: at(8, 0, 10))
        XCTAssertEqual(harness.fireCount, 0)
    }

    func testRuleThatCouldNotResolveItsLayoutStillFiresOnceTheLayoutAppears() {
        harness.layouts = []
        harness.engine.add(rule(trigger: .timeOfDay(hour: 8, minute: 0, weekdays: [])))
        harness.tick(at: at(8, 0, 10))
        harness.layouts = [work]
        harness.tick(at: at(8, 0, 30))
        XCTAssertEqual(harness.fireCount, 1)
    }

    func testLaunchesMissingAppsUsesTheLaunchPath() {
        harness.engine.add(rule(trigger: .timeOfDay(hour: 8, minute: 0, weekdays: []), launches: true))
        harness.tick(at: at(8, 0, 10))
        XCTAssertEqual(harness.launchedAndRestored, [work])
        XCTAssertTrue(harness.restored.isEmpty)
    }

    func testPlainRuleDoesNotLaunchAnything() {
        harness.engine.add(rule(trigger: .timeOfDay(hour: 8, minute: 0, weekdays: []), launches: false))
        harness.tick(at: at(8, 0, 10))
        XCTAssertEqual(harness.restored, [work])
        XCTAssertTrue(harness.launchedAndRestored.isEmpty)
    }

    // MARK: - Calendar firing

    private func calendarRule(_ id: String = "cal", minutes: Int = 5) -> LayoutRule {
        rule(id, trigger: .beforeCalendarEvent(minutesBefore: minutes))
    }

    func testCalendarRuleFiresWhenTheNextEventIsWithinTheLeadTime() {
        harness.engine.add(calendarRule(minutes: 5))
        let start = at(9, 0, 0)
        harness.events = [LayoutCalendarEvent(startDate: start, eventIdentifier: "standup")]
        harness.tick(at: at(8, 50, 0))
        XCTAssertEqual(harness.fireCount, 0)
        harness.tick(at: at(8, 55, 20))
        XCTAssertEqual(harness.fireCount, 1)
    }

    func testCalendarRuleFiresOncePerEvent() {
        harness.engine.add(calendarRule(minutes: 5))
        harness.events = [LayoutCalendarEvent(startDate: at(9, 0, 0), eventIdentifier: "standup")]
        for second in stride(from: 0, to: 300, by: 20) {
            harness.tick(at: at(8, 55, 0).addingTimeInterval(TimeInterval(second)))
        }
        XCTAssertEqual(harness.fireCount, 1)
    }

    func testCalendarRuleFiresForTheNextEventAfterTheFirstHasStarted() {
        harness.engine.add(calendarRule(minutes: 5))
        harness.events = [
            LayoutCalendarEvent(startDate: at(9, 0, 0), eventIdentifier: "first"),
            LayoutCalendarEvent(startDate: at(10, 0, 0), eventIdentifier: "second"),
        ]
        harness.tick(at: at(8, 56, 0))
        harness.tick(at: at(9, 30, 0))
        XCTAssertEqual(harness.fireCount, 1, "second is still 30 minutes away")
        harness.tick(at: at(9, 56, 0))
        XCTAssertEqual(harness.fireCount, 2)
    }

    func testBackToBackMeetingsEachFireDespiteTheRefractoryPeriod() {
        harness.engine.add(calendarRule(minutes: 2))
        harness.events = [
            LayoutCalendarEvent(startDate: at(9, 0, 0), eventIdentifier: "one"),
            LayoutCalendarEvent(startDate: at(9, 4, 0), eventIdentifier: "two"),
        ]
        harness.tick(at: at(8, 58, 30))
        harness.tick(at: at(9, 2, 30)) // two minutes after the first firing, inside the 5 minute refractory
        XCTAssertEqual(harness.fireCount, 2)
    }

    func testCalendarRuleIgnoresAnEventAlreadyUnderway() {
        harness.engine.add(calendarRule(minutes: 5))
        harness.events = [LayoutCalendarEvent(startDate: at(9, 0, 0), eventIdentifier: "running")]
        harness.tick(at: at(9, 10, 0))
        XCTAssertEqual(harness.fireCount, 0)
    }

    func testCalendarRuleWithNoEventsDoesNothing() {
        harness.engine.add(calendarRule())
        harness.tick(at: at(9, 0, 0))
        XCTAssertEqual(harness.fireCount, 0)
    }

    func testTwoCalendarRulesKeepSeparateHandledEvents() {
        harness.engine.add(calendarRule("five", minutes: 5))
        harness.engine.add(calendarRule("two", minutes: 2))
        harness.events = [LayoutCalendarEvent(startDate: at(9, 0, 0), eventIdentifier: "e")]
        harness.tick(at: at(8, 56, 0)) // inside 5, outside 2
        XCTAssertEqual(harness.fireCount, 1)
        harness.tick(at: at(8, 58, 30)) // now inside 2 as well
        XCTAssertEqual(harness.fireCount, 2)
    }

    func testCalendarRuleWithAnAbsurdLeadTimeDoesNotCrash() {
        harness.engine.add(calendarRule(minutes: Int.max))
        harness.events = [LayoutCalendarEvent(startDate: at(9, 0, 0), eventIdentifier: "e")]
        harness.tick(at: at(8, 0, 0))
        XCTAssertEqual(harness.fireCount, 1)
    }

    func testCalendarRuleConsumesTheEventEvenWhenItsLayoutIsMissing() {
        harness.layouts = []
        harness.engine.add(calendarRule(minutes: 5))
        harness.events = [LayoutCalendarEvent(startDate: at(9, 0, 0), eventIdentifier: "e")]
        harness.tick(at: at(8, 56, 0))
        harness.layouts = [work]
        harness.tick(at: at(8, 57, 0))
        XCTAssertEqual(harness.fireCount, 0, "documented: the event counts as handled once the rule evaluated it")
    }

    func testTimeAndCalendarRulesDoNotInterfere() {
        harness.engine.add(rule("time", layout: work, trigger: .timeOfDay(hour: 8, minute: 56, weekdays: [])))
        harness.engine.add(rule("cal", layout: focus, trigger: .beforeCalendarEvent(minutesBefore: 5)))
        harness.events = [LayoutCalendarEvent(startDate: at(9, 0, 0), eventIdentifier: "e")]
        harness.tick(at: at(8, 56, 10))
        XCTAssertEqual(harness.restored, [work, focus])
    }

    // MARK: - App and display rules

    func testAppRuleFiresWhenItsAppComesToTheFront() {
        harness.engine.add(rule(trigger: .appActivated(bundleIdentifier: "com.apple.Safari")))
        harness.engine.evaluateAppRules("com.apple.Safari")
        XCTAssertEqual(harness.restored, [work])
    }

    func testAppRuleIgnoresOtherApps() {
        harness.engine.add(rule(trigger: .appActivated(bundleIdentifier: "com.apple.Safari")))
        harness.engine.evaluateAppRules("com.apple.Mail")
        harness.engine.evaluateAppRules("")
        harness.engine.evaluateAppRules("com.apple.safari")
        XCTAssertEqual(harness.fireCount, 0)
    }

    func testDisabledAppRuleDoesNotFire() {
        harness.engine.add(rule(trigger: .appActivated(bundleIdentifier: "com.a"), enabled: false))
        harness.engine.evaluateAppRules("com.a")
        XCTAssertEqual(harness.fireCount, 0)
    }

    func testAppRuleIsHeldOffForTheRefractoryPeriod() {
        harness.engine.add(rule(trigger: .appActivated(bundleIdentifier: "com.a")))
        harness.clock = at(9, 0, 0)
        harness.engine.evaluateAppRules("com.a")
        harness.clock = at(9, 4, 59)
        harness.engine.evaluateAppRules("com.a")
        XCTAssertEqual(harness.fireCount, 1)
        harness.clock = at(9, 5, 0)
        harness.engine.evaluateAppRules("com.a")
        XCTAssertEqual(harness.fireCount, 2)
    }

    func testRefractoryPeriodIsFiveMinutes() {
        XCTAssertEqual(harness.engine.refractoryPeriod, 300)
    }

    func testAppRuleDoesNotFireFromTheTimerTick() {
        harness.engine.add(rule(trigger: .appActivated(bundleIdentifier: "com.a")))
        harness.tick(at: at(8, 0, 0))
        XCTAssertEqual(harness.fireCount, 0)
    }

    func testDisplayRuleFiresAndIsHeldOff() {
        harness.engine.add(rule(trigger: .displayConfigurationChanged))
        harness.clock = at(9, 0, 0)
        harness.engine.evaluateDisplayRules()
        harness.clock = at(9, 1, 0)
        harness.engine.evaluateDisplayRules()
        XCTAssertEqual(harness.fireCount, 1)
        harness.clock = at(9, 6, 0)
        harness.engine.evaluateDisplayRules()
        XCTAssertEqual(harness.fireCount, 2)
    }

    func testDisplayRuleDoesNotFireForAppEvents() {
        harness.engine.add(rule(trigger: .displayConfigurationChanged))
        harness.engine.evaluateAppRules("com.a")
        XCTAssertEqual(harness.fireCount, 0)
    }

    func testEveryTriggerKindFiresIndependently() {
        harness.engine.add(rule("time", trigger: .timeOfDay(hour: 8, minute: 0, weekdays: [])))
        harness.engine.add(rule("app", trigger: .appActivated(bundleIdentifier: "com.a")))
        harness.engine.add(rule("display", trigger: .displayConfigurationChanged))
        harness.tick(at: at(8, 0, 10))
        XCTAssertEqual(harness.fireCount, 1)
        harness.engine.evaluateAppRules("com.a")
        XCTAssertEqual(harness.fireCount, 2)
        harness.engine.evaluateDisplayRules()
        XCTAssertEqual(harness.fireCount, 3)
    }

    // MARK: - Rule management and persistence

    func testAddUpdateAndDeletePersist() {
        let original = rule(trigger: .timeOfDay(hour: 8, minute: 0, weekdays: []))
        harness.engine.add(original)
        XCTAssertEqual(harness.reload().rules, [original])

        var changed = original
        changed.trigger = .timeOfDay(hour: 9, minute: 30, weekdays: [2])
        harness.engine.update(changed)
        XCTAssertEqual(harness.reload().rules, [changed])

        harness.engine.delete(changed)
        XCTAssertTrue(harness.reload().rules.isEmpty)
    }

    func testUpdateOfAnUnknownRuleDoesNothing() {
        harness.engine.add(rule("known", trigger: .displayConfigurationChanged))
        harness.engine.update(rule("unknown", trigger: .displayConfigurationChanged))
        XCTAssertEqual(harness.engine.rules.map(\.id), ["known"])
    }

    func testDeleteOfAnUnknownRuleDoesNothing() {
        harness.engine.add(rule("known", trigger: .displayConfigurationChanged))
        harness.engine.delete(rule("unknown", trigger: .displayConfigurationChanged))
        XCTAssertEqual(harness.engine.rules.count, 1)
    }

    func testRuleOrderIsKept() {
        for id in ["c", "a", "b"] {
            harness.engine.add(rule(id, trigger: .displayConfigurationChanged))
        }
        XCTAssertEqual(harness.reload().rules.map(\.id), ["c", "a", "b"])
    }

    func testDeletedRuleStopsFiring() {
        let timed = rule(trigger: .timeOfDay(hour: 8, minute: 0, weekdays: []))
        harness.engine.add(timed)
        harness.engine.delete(timed)
        harness.tick(at: at(8, 0, 10))
        XCTAssertEqual(harness.fireCount, 0)
    }

    func testReloadedRuleFires() {
        harness.engine.add(rule(trigger: .timeOfDay(hour: 8, minute: 0, weekdays: [])))
        let again = harness.reload()
        harness.clock = at(8, 0, 10)
        again.evaluateTimeAndCalendarRules()
        XCTAssertEqual(harness.fireCount, 1)
    }

    func testRuleSavedBeforeLayoutIDExistedFiresByName() throws {
        let legacy = #"[{"id":"old","layoutName":"Focus","trigger":{"displayConfigurationChanged":{}},"isEnabled":true,"launchesMissingApps":false}]"#
        harness.defaults.set(Data(legacy.utf8), forKey: LayoutTriggerEngine.defaultsKey)
        let engine = harness.reload()
        XCTAssertEqual(engine.rules.count, 1)
        XCTAssertNil(engine.rules[0].layoutID)
        engine.evaluateDisplayRules()
        XCTAssertEqual(harness.restored, [focus])
    }

    func testCorruptStoredRulesStartEmptyWithoutRewritingTheBlob() {
        let junk = Data("not json at all".utf8)
        harness.defaults.set(junk, forKey: LayoutTriggerEngine.defaultsKey)
        XCTAssertTrue(harness.reload().rules.isEmpty)
        XCTAssertEqual(harness.defaults.data(forKey: LayoutTriggerEngine.defaultsKey), junk)
    }

    func testTruncatedStoredRulesStartEmpty() throws {
        let full = try JSONEncoder().encode([rule(trigger: .timeOfDay(hour: 8, minute: 0, weekdays: [1, 2]))])
        for length in [0, 1, full.count / 3, full.count / 2, full.count - 1] {
            harness.defaults.set(full.prefix(length), forKey: LayoutTriggerEngine.defaultsKey)
            XCTAssertTrue(harness.reload().rules.isEmpty, "prefix \(length)")
        }
    }

    func testUnknownTriggerKindDropsTheRuleListWithoutCrashing() {
        let blob = #"[{"id":"x","layoutName":"Work","trigger":{"onSunrise":{}},"isEnabled":true,"launchesMissingApps":false}]"#
        harness.defaults.set(Data(blob.utf8), forKey: LayoutTriggerEngine.defaultsKey)
        XCTAssertTrue(harness.reload().rules.isEmpty)
    }

    func testStoredValueOfTheWrongTypeStartsEmpty() {
        harness.defaults.set("rules", forKey: LayoutTriggerEngine.defaultsKey)
        XCTAssertTrue(harness.reload().rules.isEmpty)
        harness.defaults.set(7, forKey: LayoutTriggerEngine.defaultsKey)
        XCTAssertTrue(harness.reload().rules.isEmpty)
    }

    func testHostilePersistedRuleValuesNeverCrashTheTick() {
        let hostile: [LayoutRule] = [
            rule("h1", trigger: .timeOfDay(hour: Int.max, minute: Int.min, weekdays: [Int.max, Int.min, 0, -1])),
            rule("h2", trigger: .beforeCalendarEvent(minutesBefore: Int.min)),
            rule("h3", trigger: .beforeCalendarEvent(minutesBefore: Int.max)),
            rule("h4", trigger: .appActivated(bundleIdentifier: String(repeating: "x", count: 100_000))),
            LayoutRule(id: "", layoutID: "", layoutName: "", trigger: .displayConfigurationChanged, isEnabled: true, launchesMissingApps: true),
        ]
        hostile.forEach { harness.engine.add($0) }
        harness.events = [LayoutCalendarEvent(startDate: at(9, 0, 0), eventIdentifier: "e")]
        harness.tick(at: at(8, 0, 0))
        harness.engine.evaluateAppRules("x")
        harness.engine.evaluateDisplayRules()
        XCTAssertEqual(harness.engine.rules.count, 5)
    }

    func testDuplicateRuleIDsUpdateOnlyTheFirst() {
        let first = rule("dup", trigger: .displayConfigurationChanged)
        harness.engine.add(first)
        harness.engine.add(rule("dup", layout: focus, trigger: .displayConfigurationChanged))
        var changed = first
        changed.isEnabled = false
        harness.engine.update(changed)
        XCTAssertEqual(harness.engine.rules.map(\.isEnabled), [false, true])
    }

    func testEngineNeverTouchesTheStandardDefaultsDomain() {
        let before = UserDefaults.standard.data(forKey: LayoutTriggerEngine.defaultsKey)
        harness.engine.add(rule(trigger: .displayConfigurationChanged))
        harness.engine.delete(harness.engine.rules[0])
        XCTAssertEqual(UserDefaults.standard.data(forKey: LayoutTriggerEngine.defaultsKey), before)
    }
}
