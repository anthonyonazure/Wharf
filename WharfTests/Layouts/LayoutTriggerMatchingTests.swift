import XCTest
@testable import Wharf

/// The pure decisions behind layout rules: does a time-of-day rule match this
/// instant, which calendar event is due, how triggers read in plain English
/// and how they round-trip through storage.
@MainActor
final class LayoutTriggerMatchingTests: LayoutTestCase {
    private let utc = TestCalendars.utc

    private func matches(
        _ hour: Int, _ minute: Int, weekdays: [Int] = [], at date: Date, calendar: Calendar? = nil
    ) -> Bool {
        LayoutTrigger.timeOfDayMatches(
            hour: hour, minute: minute, weekdays: weekdays, now: date, calendar: calendar ?? utc
        )
    }

    // 2026-10-12 is a Monday.
    private func monday(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        TestCalendars.date(2026, 10, 12, hour, minute, second)
    }

    // MARK: - Time of day

    func testMatchesTheExactMinute() {
        XCTAssertTrue(matches(8, 0, at: monday(8, 0)))
        XCTAssertTrue(matches(8, 30, at: monday(8, 30)))
        XCTAssertTrue(matches(17, 45, at: monday(17, 45)))
    }

    func testDoesNotMatchTheNeighbouringMinutes() {
        XCTAssertFalse(matches(8, 0, at: monday(7, 59, 59)))
        XCTAssertFalse(matches(8, 0, at: monday(8, 1, 0)))
        XCTAssertFalse(matches(8, 30, at: monday(8, 29, 59)))
        XCTAssertFalse(matches(8, 30, at: monday(8, 31)))
    }

    func testEverySecondOfTheTargetMinuteMatches() {
        for second in 0..<60 {
            XCTAssertTrue(matches(13, 37, at: monday(13, 37, second)), "second \(second)")
        }
    }

    func testMatchesAtMidnightAndLastMinuteOfTheDay() {
        XCTAssertTrue(matches(0, 0, at: monday(0, 0, 0)))
        XCTAssertTrue(matches(0, 0, at: monday(0, 0, 59)))
        XCTAssertTrue(matches(23, 59, at: monday(23, 59, 59)))
        XCTAssertFalse(matches(0, 0, at: monday(23, 59, 59)))
    }

    func testAMinuteBoundaryTickBelongsToTheNewMinuteOnly() {
        XCTAssertFalse(matches(8, 59, at: monday(9, 0, 0)))
        XCTAssertTrue(matches(9, 0, at: monday(9, 0, 0)))
    }

    func testMidnightTickMovesTheWeekdayToo() {
        // Sunday 23:59:50 -> Monday 00:00:10. A Monday-only 00:00 rule is due
        // only after the roll over.
        let sundayNight = TestCalendars.date(2026, 10, 11, 23, 59, 50)
        let mondayJustAfter = TestCalendars.date(2026, 10, 12, 0, 0, 10)
        XCTAssertFalse(matches(0, 0, weekdays: [Weekday.monday], at: sundayNight))
        XCTAssertTrue(matches(0, 0, weekdays: [Weekday.monday], at: mondayJustAfter))
    }

    func testExactlyOneMinuteOfTheDayMatchesARule() {
        var count = 0
        let start = TestCalendars.date(2026, 10, 12, 0, 0, 0)
        for minute in 0..<1440 {
            let date = start.addingTimeInterval(TimeInterval(minute * 60 + 30))
            if matches(13, 37, at: date) { count += 1 }
        }
        XCTAssertEqual(count, 1)
    }

    func testEveryHourAndMinuteIsReachable() {
        let start = TestCalendars.date(2026, 10, 12, 0, 0, 0)
        for hour in 0..<24 {
            for minute in stride(from: 0, to: 60, by: 7) {
                let date = start.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
                XCTAssertTrue(matches(hour, minute, at: date), "\(hour):\(minute)")
            }
        }
    }

    func testOutOfRangeHoursAndMinutesNeverMatch() {
        let start = TestCalendars.date(2026, 10, 12, 0, 0, 0)
        let bad: [(Int, Int)] = [(24, 0), (25, 0), (-1, 0), (0, 60), (0, -1), (99, 99), (Int.max, 0), (0, Int.min)]
        for (hour, minute) in bad {
            for step in 0..<1440 where step % 17 == 0 {
                XCTAssertFalse(matches(hour, minute, at: start.addingTimeInterval(TimeInterval(step * 60))))
            }
        }
    }

    func testEmptyWeekdayListMeansEveryDay() {
        for day in 0..<7 {
            let date = TestCalendars.date(2026, 10, 11 + day, 8, 0)
            XCTAssertTrue(matches(8, 0, weekdays: [], at: date), "day offset \(day)")
        }
    }

    func testWeekdayFilterMatchesOnlyListedDays() {
        let weekdays = [Weekday.monday, Weekday.wednesday, Weekday.friday]
        for day in 0..<7 {
            let date = TestCalendars.date(2026, 10, 11 + day, 8, 0) // Sunday ... Saturday
            let weekday = utc.component(.weekday, from: date)
            XCTAssertEqual(matches(8, 0, weekdays: weekdays, at: date), weekdays.contains(weekday), "weekday \(weekday)")
        }
    }

    func testWeekdayNumberingStartsAtSunday() {
        let sunday = TestCalendars.date(2026, 10, 11, 8, 0)
        let saturday = TestCalendars.date(2026, 10, 17, 8, 0)
        XCTAssertTrue(matches(8, 0, weekdays: [1], at: sunday))
        XCTAssertFalse(matches(8, 0, weekdays: [1], at: saturday))
        XCTAssertTrue(matches(8, 0, weekdays: [7], at: saturday))
    }

    func testInvalidWeekdayNumbersNeverMatchAnything() {
        for day in 0..<7 {
            let date = TestCalendars.date(2026, 10, 11 + day, 8, 0)
            XCTAssertFalse(matches(8, 0, weekdays: [0, 8, -1, 100], at: date))
        }
    }

    func testValidWeekdayAmongInvalidOnesStillMatches() {
        XCTAssertTrue(matches(8, 0, weekdays: [0, 99, Weekday.monday], at: monday(8, 0)))
    }

    func testCalendarFirstWeekdayDoesNotChangeNumbering() {
        var calendar = TestCalendars.utc
        calendar.firstWeekday = 2
        XCTAssertTrue(matches(8, 0, weekdays: [Weekday.monday], at: monday(8, 0), calendar: calendar))
        XCTAssertFalse(matches(8, 0, weekdays: [Weekday.sunday], at: monday(8, 0), calendar: calendar))
    }

    func testTheCalendarTimeZoneDecidesWhatTheWallClockSays() {
        // 12:00 UTC is 08:00 in New York (EDT) on 2026-10-12.
        let instant = TestCalendars.date(2026, 10, 12, 12, 0)
        XCTAssertTrue(matches(12, 0, at: instant, calendar: TestCalendars.utc))
        XCTAssertFalse(matches(8, 0, at: instant, calendar: TestCalendars.utc))
        XCTAssertTrue(matches(8, 0, at: instant, calendar: TestCalendars.newYork))
    }

    func testTheWeekdayIsTakenInTheCalendarTimeZoneToo() {
        // 02:00 UTC Monday is still Sunday evening in New York.
        let instant = TestCalendars.date(2026, 10, 12, 2, 0)
        XCTAssertTrue(matches(2, 0, weekdays: [Weekday.monday], at: instant, calendar: TestCalendars.utc))
        XCTAssertTrue(matches(22, 0, weekdays: [Weekday.sunday], at: instant, calendar: TestCalendars.newYork))
        XCTAssertFalse(matches(22, 0, weekdays: [Weekday.monday], at: instant, calendar: TestCalendars.newYork))
    }

    func testTheSpringForwardGapNeverMatchesAnInvalidWallClockTime() {
        // 2026-03-08 in New York: 02:00 jumps to 03:00, so 02:30 never exists.
        let ny = TestCalendars.newYork
        var hits = 0
        var cursor = TestCalendars.date(2026, 3, 8, 0, 0, in: ny)
        let end = TestCalendars.date(2026, 3, 9, 0, 0, in: ny)
        while cursor < end {
            if matches(2, 30, at: cursor, calendar: ny) { hits += 1 }
            cursor = cursor.addingTimeInterval(20)
        }
        XCTAssertEqual(hits, 0)
    }

    func testTheRuleAfterTheSpringForwardGapStillMatches() {
        let ny = TestCalendars.newYork
        let instant = TestCalendars.date(2026, 3, 8, 3, 30, in: ny)
        XCTAssertTrue(matches(3, 30, at: instant, calendar: ny))
    }

    func testTheFallBackHourMatchesTwice() {
        // 2026-11-01 in New York: 01:00-01:59 happens twice (EDT then EST).
        let ny = TestCalendars.newYork
        var firstPass = TestCalendars.date(2026, 11, 1, 0, 0, in: ny)
        var minutesMatching = 0
        let end = firstPass.addingTimeInterval(4 * 3600)
        while firstPass < end {
            if matches(1, 30, at: firstPass, calendar: ny) { minutesMatching += 1 }
            firstPass = firstPass.addingTimeInterval(60)
        }
        XCTAssertEqual(minutesMatching, 2, "the wall clock reads 01:30 once per pass")
    }

    func testHugeAndDistantDatesDoNotTrap() {
        for date in [Date.distantPast, Date.distantFuture, Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: -1e12)] {
            _ = matches(8, 0, weekdays: [1, 2], at: date)
        }
    }

    // MARK: - Calendar rules

    private func event(_ id: String, in seconds: TimeInterval, from now: Date) -> LayoutCalendarEvent {
        LayoutCalendarEvent(startDate: now.addingTimeInterval(seconds), eventIdentifier: id)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func due(
        minutesBefore: Int, events: [LayoutCalendarEvent], handled: String? = nil
    ) -> LayoutCalendarEvent? {
        LayoutTrigger.calendarEventDue(minutesBefore: minutesBefore, now: now, events: events, handledEventID: handled)
    }

    func testEventInsideTheWindowIsDue() {
        XCTAssertEqual(due(minutesBefore: 5, events: [event("a", in: 240, from: now)])?.eventIdentifier, "a")
    }

    func testEventExactlyAtTheEdgeOfTheWindowIsDue() {
        XCTAssertNotNil(due(minutesBefore: 5, events: [event("a", in: 300, from: now)]))
    }

    func testEventJustOutsideTheWindowIsNotDue() {
        XCTAssertNil(due(minutesBefore: 5, events: [event("a", in: 300.5, from: now)]))
        XCTAssertNil(due(minutesBefore: 5, events: [event("a", in: 3600, from: now)]))
    }

    func testEventStartingThisInstantIsNotDue() {
        XCTAssertNil(due(minutesBefore: 5, events: [event("a", in: 0, from: now)]))
    }

    func testEventAlreadyUnderwayIsSkippedInFavourOfTheNextOne() {
        let events = [event("running", in: -600, from: now), event("next", in: 120, from: now)]
        XCTAssertEqual(due(minutesBefore: 5, events: events)?.eventIdentifier, "next")
    }

    func testOnlyEventsInTheFutureCount() {
        XCTAssertNil(due(minutesBefore: 5, events: [event("old", in: -60, from: now)]))
    }

    func testAlreadyHandledEventIsNotDueAgain() {
        let events = [event("a", in: 120, from: now)]
        XCTAssertNil(due(minutesBefore: 5, events: events, handled: "a"))
        XCTAssertNotNil(due(minutesBefore: 5, events: events, handled: "other"))
    }

    func testNoEventsMeansNothingIsDue() {
        XCTAssertNil(due(minutesBefore: 5, events: []))
    }

    func testZeroOrNegativeLeadTimeIsNeverDue() {
        let events = [event("a", in: 1, from: now)]
        XCTAssertNil(due(minutesBefore: 0, events: events))
        XCTAssertNil(due(minutesBefore: -5, events: events))
    }

    func testHugeLeadTimeDoesNotTrap() {
        // Int.max * 60 used to overflow and crash the app on a persisted rule.
        let events = [event("a", in: 120, from: now)]
        for minutes in [Int.max, Int.max / 2, Int.max / 59, 1 << 62] {
            XCTAssertNotNil(due(minutesBefore: minutes, events: events), "\(minutes)")
        }
    }

    func testOnlyTheFirstUpcomingEventIsConsidered() {
        // A rule looks at the next event only; a later event inside the window
        // is not due while an earlier one is outside it.
        let events = [event("far", in: 4000, from: now), event("near", in: 60, from: now)]
        XCTAssertNil(due(minutesBefore: 5, events: events))
    }

    func testBandCatchesAnEventAtAnyTickPhase() {
        // The engine ticks every 20s, so for any phase there is a tick
        // inside the last `minutesBefore` minutes before the event.
        let minutesBefore = 2
        for phase in 0..<20 {
            var hit = false
            var tick = TimeInterval(phase)
            while tick < 600 {
                let eventStart = now.addingTimeInterval(600)
                let when = now.addingTimeInterval(tick)
                let result = LayoutTrigger.calendarEventDue(
                    minutesBefore: minutesBefore,
                    now: when,
                    events: [LayoutCalendarEvent(startDate: eventStart, eventIdentifier: "e")],
                    handledEventID: nil
                )
                if result != nil { hit = true }
                tick += 20
            }
            XCTAssertTrue(hit, "phase \(phase)")
        }
    }

    // MARK: - Plain English

    func testDescriptionForTimeOfDayEveryDay() {
        XCTAssertEqual(LayoutTrigger.timeOfDay(hour: 8, minute: 0, weekdays: []).describedInPlainEnglish, "Every day at 08:00")
    }

    func testDescriptionZeroPadsTheTime() {
        XCTAssertEqual(LayoutTrigger.timeOfDay(hour: 7, minute: 5, weekdays: []).describedInPlainEnglish, "Every day at 07:05")
    }

    func testDescriptionListsWeekdayNames() {
        let text = LayoutTrigger.timeOfDay(hour: 9, minute: 15, weekdays: [2, 3]).describedInPlainEnglish
        let symbols = Calendar.current.shortWeekdaySymbols
        XCTAssertEqual(text, "At 09:15 on \(symbols[1]), \(symbols[2])")
    }

    func testDescriptionDropsInvalidWeekdayNumbers() {
        let text = LayoutTrigger.timeOfDay(hour: 9, minute: 15, weekdays: [0, 8, 2]).describedInPlainEnglish
        XCTAssertTrue(text.hasSuffix(Calendar.current.shortWeekdaySymbols[1]))
    }

    func testDescriptionForCalendarAppAndDisplayTriggers() {
        XCTAssertEqual(LayoutTrigger.beforeCalendarEvent(minutesBefore: 10).describedInPlainEnglish, "10 minutes before a calendar event")
        XCTAssertEqual(LayoutTrigger.appActivated(bundleIdentifier: "com.apple.Safari").describedInPlainEnglish, "When com.apple.Safari comes to the front")
        XCTAssertEqual(LayoutTrigger.displayConfigurationChanged.describedInPlainEnglish, "When a display is connected or disconnected")
    }

    func testDescriptionOfOutOfRangeTimesDoesNotTrap() {
        for (hour, minute) in [(99, 99), (-5, -5), (Int.max, Int.min)] {
            _ = LayoutTrigger.timeOfDay(hour: hour, minute: minute, weekdays: [Int.max, Int.min]).describedInPlainEnglish
        }
    }

    // MARK: - Codable

    private let sampleTriggers: [LayoutTrigger] = [
        .timeOfDay(hour: 8, minute: 30, weekdays: [2, 3, 4]),
        .timeOfDay(hour: 0, minute: 0, weekdays: []),
        .beforeCalendarEvent(minutesBefore: 5),
        .appActivated(bundleIdentifier: "com.apple.Safari"),
        .displayConfigurationChanged,
    ]

    func testEveryTriggerKindRoundTrips() throws {
        for trigger in sampleTriggers {
            let data = try JSONEncoder().encode(trigger)
            XCTAssertEqual(try JSONDecoder().decode(LayoutTrigger.self, from: data), trigger)
        }
    }

    func testRuleRoundTripsWithAndWithoutLayoutID() throws {
        for id in [nil, "layout-1"] as [String?] {
            let rule = LayoutRule(
                id: "r", layoutID: id, layoutName: "Work",
                trigger: .beforeCalendarEvent(minutesBefore: 3), isEnabled: true, launchesMissingApps: false
            )
            XCTAssertEqual(try JSONDecoder().decode(LayoutRule.self, from: JSONEncoder().encode(rule)), rule)
        }
    }

    func testRuleSavedBeforeLayoutIDExistedStillLoads() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LayoutRule(
            id: "r", layoutID: "x", layoutName: "Work",
            trigger: .displayConfigurationChanged, isEnabled: true, launchesMissingApps: true
        ))) as! [String: Any]
        json.removeValue(forKey: "layoutID")
        let data = try JSONSerialization.data(withJSONObject: json)
        let rule = try JSONDecoder().decode(LayoutRule.self, from: data)
        XCTAssertNil(rule.layoutID)
        XCTAssertEqual(rule.layoutName, "Work")
    }

    func testUnknownTriggerKindFailsToDecode() {
        let blob = #"{"id":"r","layoutName":"Work","trigger":{"onSunrise":{}},"isEnabled":true,"launchesMissingApps":false}"#
        XCTAssertThrowsError(try JSONDecoder().decode(LayoutRule.self, from: Data(blob.utf8)))
    }

    func testTriggerWithMissingAssociatedValuesFailsToDecode() {
        let blobs = [
            #"{"timeOfDay":{"hour":8}}"#,
            #"{"beforeCalendarEvent":{}}"#,
            #"{"appActivated":{}}"#,
            #"{}"#,
        ]
        for blob in blobs {
            XCTAssertThrowsError(try JSONDecoder().decode(LayoutTrigger.self, from: Data(blob.utf8)), blob)
        }
    }

    func testRuleMissingRequiredFieldsFailsToDecode() throws {
        let rule = LayoutRule(id: "r", layoutID: nil, layoutName: "W", trigger: .displayConfigurationChanged, isEnabled: true, launchesMissingApps: true)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as! [String: Any]
        for key in ["id", "layoutName", "trigger", "isEnabled", "launchesMissingApps"] {
            var broken = json
            broken.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: broken)
            XCTAssertThrowsError(try JSONDecoder().decode(LayoutRule.self, from: data), key)
        }
    }

    func testHugeWeekdayListRoundTrips() throws {
        let trigger = LayoutTrigger.timeOfDay(hour: 8, minute: 0, weekdays: Array(repeating: 2, count: 20_000))
        let decoded = try JSONDecoder().decode(LayoutTrigger.self, from: JSONEncoder().encode(trigger))
        XCTAssertEqual(decoded, trigger)
        XCTAssertTrue(matches(8, 0, weekdays: Array(repeating: 2, count: 20_000), at: monday(8, 0)))
    }

    func testTriggerEqualityDistinguishesPayloads() {
        XCTAssertNotEqual(LayoutTrigger.timeOfDay(hour: 8, minute: 0, weekdays: []), .timeOfDay(hour: 8, minute: 1, weekdays: []))
        XCTAssertNotEqual(LayoutTrigger.timeOfDay(hour: 8, minute: 0, weekdays: [1]), .timeOfDay(hour: 8, minute: 0, weekdays: [2]))
        XCTAssertNotEqual(LayoutTrigger.appActivated(bundleIdentifier: "a"), .appActivated(bundleIdentifier: "b"))
        XCTAssertEqual(LayoutTrigger.displayConfigurationChanged, .displayConfigurationChanged)
    }
}
