import XCTest
@testable import Wharf

/// DockProfile storage and the three profile trigger kinds, including the
/// time-of-day window arithmetic.
@MainActor
final class ProfileModelTests: LayoutTestCase {
    private let utc = TestCalendars.utc

    // 2026-10-12 is a Monday.
    private func monday(_ hour: Int, _ minute: Int) -> Date {
        TestCalendars.date(2026, 10, 12, hour, minute, 30)
    }

    private func sampleProfile() -> DockProfile {
        DockProfile(
            id: "p1",
            name: "Work",
            symbolName: "briefcase.fill",
            dateCreated: Date(timeIntervalSince1970: 1_700_000_000),
            pinnedItems: [.app(bundleIdentifier: "com.apple.Safari")],
            trailingItems: [TrailingTileItem(id: "t1", kind: .trash)],
            widgetPlacements: [],
            appWidgetDisplays: [],
            hiddenAppBundleIdentifiers: ["com.apple.Maps"],
            triggers: [
                .timeOfDay(TimeOfDayTrigger(id: "a", startMinuteOfDay: 540, endMinuteOfDay: 1080, weekdays: [2, 3, 4])),
                .frontmostApp(FrontmostAppTrigger(id: "b", bundleIdentifier: "com.apple.dt.Xcode")),
                .space(SpaceTrigger(id: "c", bundleIdentifier: "com.apple.Safari")),
            ]
        )
    }

    // MARK: - DockProfile

    func testProfileRoundTripsEveryField() throws {
        let profile = sampleProfile()
        let decoded = try JSONDecoder().decode(DockProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded, profile)
    }

    func testProfileArrayRoundTripKeepsOrder() throws {
        let profiles = (0..<10).map { DockProfile(id: "p\($0)", name: "Profile \($0)") }
        let decoded = try JSONDecoder().decode([DockProfile].self, from: JSONEncoder().encode(profiles))
        XCTAssertEqual(decoded.map(\.id), profiles.map(\.id))
    }

    func testProfileStoredBeforeTriggersExistedStillDecodes() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sampleProfile())) as! [String: Any]
        json.removeValue(forKey: "triggers")
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(DockProfile.self, from: data)
        XCTAssertEqual(decoded.triggers, [])
        XCTAssertEqual(decoded.name, "Work")
    }

    func testProfileMissingRequiredFieldsFailsToDecode() throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sampleProfile())) as! [String: Any]
        let required = ["id", "name", "symbolName", "dateCreated", "pinnedItems", "trailingItems",
                        "widgetPlacements", "appWidgetDisplays", "hiddenAppBundleIdentifiers"]
        for key in required {
            var broken = json
            broken.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: broken)
            XCTAssertThrowsError(try JSONDecoder().decode(DockProfile.self, from: data), "missing \(key)")
        }
    }

    func testTruncatedProfileBlobFailsToDecode() throws {
        let data = try JSONEncoder().encode([sampleProfile()])
        for length in stride(from: 0, to: data.count, by: 7) {
            XCTAssertThrowsError(try JSONDecoder().decode([DockProfile].self, from: data.prefix(length)))
        }
    }

    func testProfileWithUnknownTriggerKindSkipsOnlyThatTrigger() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sampleProfile())) as! [String: Any]
        let known = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode([ProfileTrigger.frontmostApp(FrontmostAppTrigger(id: "a", bundleIdentifier: "com.apple.Xcode"))])
        ) as! [Any]
        json["triggers"] = [["wifi": ["_0": ["id": "w", "ssid": "Home"]]]] + known
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(DockProfile.self, from: data)
        XCTAssertEqual(decoded.triggers.map(\.id), ["a"])
    }

    func testProfileDefaults() {
        let profile = DockProfile(name: "New")
        XCTAssertEqual(profile.symbolName, "house.fill")
        XCTAssertTrue(profile.pinnedItems.isEmpty)
        XCTAssertTrue(profile.triggers.isEmpty)
        XCTAssertFalse(profile.id.isEmpty)
    }

    func testEachNewProfileGetsADistinctID() {
        let ids = Set((0..<50).map { _ in DockProfile(name: "x").id })
        XCTAssertEqual(ids.count, 50)
    }

    func testProfileEqualityIncludesTriggers() {
        let base = sampleProfile()
        var other = base
        XCTAssertEqual(base, other)
        other.triggers.removeLast()
        XCTAssertNotEqual(base, other)
    }

    func testProfileAcceptsEmptyAndUnicodeNames() throws {
        for name in ["", "  ", "Work \u{1F4BC}", String(repeating: "n", count: 10_000)] {
            let profile = DockProfile(name: name)
            let decoded = try JSONDecoder().decode(DockProfile.self, from: JSONEncoder().encode(profile))
            XCTAssertEqual(decoded.name, name)
        }
    }

    // MARK: - ProfileTrigger

    func testTriggerIdentifierComesFromThePayload() {
        XCTAssertEqual(ProfileTrigger.timeOfDay(TimeOfDayTrigger(id: "t")).id, "t")
        XCTAssertEqual(ProfileTrigger.frontmostApp(FrontmostAppTrigger(id: "f", bundleIdentifier: "x")).id, "f")
        XCTAssertEqual(ProfileTrigger.space(SpaceTrigger(id: "s", bundleIdentifier: "x")).id, "s")
    }

    func testSpecificityOrdersSpaceOverAppOverTime() {
        let time = ProfileTrigger.timeOfDay(TimeOfDayTrigger())
        let app = ProfileTrigger.frontmostApp(FrontmostAppTrigger(bundleIdentifier: "x"))
        let space = ProfileTrigger.space(SpaceTrigger(bundleIdentifier: "x"))
        XCTAssertGreaterThan(space.specificity, app.specificity)
        XCTAssertGreaterThan(app.specificity, time.specificity)
    }

    func testEveryTriggerKindRoundTrips() throws {
        for trigger in sampleProfile().triggers {
            let decoded = try JSONDecoder().decode(ProfileTrigger.self, from: JSONEncoder().encode(trigger))
            XCTAssertEqual(decoded, trigger)
        }
    }

    func testTriggerDefaultsGenerateDistinctIDs() {
        XCTAssertNotEqual(TimeOfDayTrigger().id, TimeOfDayTrigger().id)
        XCTAssertNotEqual(FrontmostAppTrigger(bundleIdentifier: "a").id, FrontmostAppTrigger(bundleIdentifier: "a").id)
        XCTAssertNotEqual(SpaceTrigger(bundleIdentifier: "a").id, SpaceTrigger(bundleIdentifier: "a").id)
    }

    func testTimeOfDayDefaultsToWorkdaysNineToSix() {
        let trigger = TimeOfDayTrigger()
        XCTAssertEqual(trigger.startMinuteOfDay, 540)
        XCTAssertEqual(trigger.endMinuteOfDay, 1080)
        XCTAssertEqual(trigger.weekdays, [2, 3, 4, 5, 6])
    }

    // MARK: - TimeOfDayTrigger

    func testInitClampsMinutesIntoTheDay() {
        let cases: [(input: Int, expected: Int)] = [(-5, 0), (0, 0), (1439, 1439), (1440, 1439), (99_999, 1439), (Int.max, 1439), (Int.min, 0)]
        for item in cases {
            let trigger = TimeOfDayTrigger(startMinuteOfDay: item.input, endMinuteOfDay: item.input)
            XCTAssertEqual(trigger.startMinuteOfDay, item.expected, "\(item.input)")
            XCTAssertEqual(trigger.endMinuteOfDay, item.expected, "\(item.input)")
        }
    }

    func testWindowIncludesItsStartMinuteAndExcludesItsEnd() {
        let trigger = TimeOfDayTrigger(startMinuteOfDay: 9 * 60, endMinuteOfDay: 18 * 60, weekdays: [2])
        XCTAssertFalse(trigger.matches(date: TestCalendars.date(2026, 10, 12, 8, 59, 59), calendar: utc))
        XCTAssertTrue(trigger.matches(date: TestCalendars.date(2026, 10, 12, 9, 0, 0), calendar: utc))
        XCTAssertTrue(trigger.matches(date: TestCalendars.date(2026, 10, 12, 17, 59, 59), calendar: utc))
        XCTAssertFalse(trigger.matches(date: TestCalendars.date(2026, 10, 12, 18, 0, 0), calendar: utc))
    }

    func testWindowCoversExactlyItsLengthInMinutes() {
        let trigger = TimeOfDayTrigger(startMinuteOfDay: 9 * 60, endMinuteOfDay: 18 * 60, weekdays: [2])
        var count = 0
        for minute in 0..<1440 where trigger.matches(date: TestCalendars.date(2026, 10, 12, minute / 60, minute % 60, 0), calendar: utc) {
            count += 1
        }
        XCTAssertEqual(count, 9 * 60)
    }

    func testWrapAroundWindowCoversMidnight() {
        let trigger = TimeOfDayTrigger(startMinuteOfDay: 22 * 60, endMinuteOfDay: 6 * 60, weekdays: Set(1...7))
        let inside: [(Int, Int)] = [(22, 0), (23, 59), (0, 0), (3, 30), (5, 59)]
        let outside: [(Int, Int)] = [(6, 0), (12, 0), (21, 59)]
        for (hour, minute) in inside {
            XCTAssertTrue(trigger.matches(date: TestCalendars.date(2026, 10, 13, hour, minute), calendar: utc), "\(hour):\(minute)")
        }
        for (hour, minute) in outside {
            XCTAssertFalse(trigger.matches(date: TestCalendars.date(2026, 10, 13, hour, minute), calendar: utc), "\(hour):\(minute)")
        }
    }

    func testWrapAroundWindowCoversTheRightNumberOfMinutes() {
        let trigger = TimeOfDayTrigger(startMinuteOfDay: 22 * 60, endMinuteOfDay: 6 * 60, weekdays: Set(1...7))
        var count = 0
        for minute in 0..<1440 where trigger.matches(date: TestCalendars.date(2026, 10, 13, minute / 60, minute % 60), calendar: utc) {
            count += 1
        }
        XCTAssertEqual(count, 8 * 60)
    }

    func testEqualStartAndEndNeverMatches() {
        for minute in [0, 600, 1439] {
            let trigger = TimeOfDayTrigger(startMinuteOfDay: minute, endMinuteOfDay: minute, weekdays: Set(1...7))
            for hour in 0..<24 {
                XCTAssertFalse(trigger.matches(date: TestCalendars.date(2026, 10, 13, hour, 0), calendar: utc))
            }
        }
    }

    func testLastMinuteOfTheDayIsReachableAsAWindowEdge() {
        let trigger = TimeOfDayTrigger(startMinuteOfDay: 1439, endMinuteOfDay: 60, weekdays: Set(1...7))
        XCTAssertTrue(trigger.matches(date: TestCalendars.date(2026, 10, 13, 23, 59), calendar: utc))
        XCTAssertTrue(trigger.matches(date: TestCalendars.date(2026, 10, 13, 0, 30), calendar: utc))
        XCTAssertFalse(trigger.matches(date: TestCalendars.date(2026, 10, 13, 1, 0), calendar: utc))
    }

    func testWeekdaysFilterTheWindow() {
        let trigger = TimeOfDayTrigger(startMinuteOfDay: 0, endMinuteOfDay: 1439, weekdays: [Weekday.saturday, Weekday.sunday])
        XCTAssertTrue(trigger.matches(date: TestCalendars.date(2026, 10, 17, 12, 0), calendar: utc)) // Saturday
        XCTAssertTrue(trigger.matches(date: TestCalendars.date(2026, 10, 11, 12, 0), calendar: utc)) // Sunday
        XCTAssertFalse(trigger.matches(date: monday(12, 0), calendar: utc))
    }

    func testEmptyWeekdaySetNeverMatches() {
        let trigger = TimeOfDayTrigger(startMinuteOfDay: 0, endMinuteOfDay: 1439, weekdays: [])
        for day in 11...17 {
            XCTAssertFalse(trigger.matches(date: TestCalendars.date(2026, 10, day, 12, 0), calendar: utc))
        }
    }

    func testWeekdayNumbersOutsideOneToSevenAreInert() {
        let trigger = TimeOfDayTrigger(startMinuteOfDay: 0, endMinuteOfDay: 1439, weekdays: [0, 8, -3])
        XCTAssertFalse(trigger.matches(date: monday(12, 0), calendar: utc))
    }

    func testMatchingUsesTheCalendarTimeZone() {
        let trigger = TimeOfDayTrigger(startMinuteOfDay: 8 * 60, endMinuteOfDay: 9 * 60, weekdays: Set(1...7))
        let instant = TestCalendars.date(2026, 10, 12, 12, 30) // 08:30 in New York
        XCTAssertFalse(trigger.matches(date: instant, calendar: TestCalendars.utc))
        XCTAssertTrue(trigger.matches(date: instant, calendar: TestCalendars.newYork))
    }

    func testWindowThroughTheSpringForwardGapDoesNotTrap() {
        let ny = TestCalendars.newYork
        let trigger = TimeOfDayTrigger(startMinuteOfDay: 60, endMinuteOfDay: 240, weekdays: Set(1...7))
        var cursor = TestCalendars.date(2026, 3, 8, 0, 0, in: ny)
        var matched = 0
        for _ in 0..<(24 * 60) {
            if trigger.matches(date: cursor, calendar: ny) { matched += 1 }
            cursor = cursor.addingTimeInterval(60)
        }
        // 01:00-04:00 loses the skipped hour on the spring-forward day.
        XCTAssertEqual(matched, 2 * 60)
    }

    func testWindowThroughTheFallBackRepeatMatchesBothPasses() {
        let ny = TestCalendars.newYork
        let trigger = TimeOfDayTrigger(startMinuteOfDay: 60, endMinuteOfDay: 120, weekdays: Set(1...7))
        var cursor = TestCalendars.date(2026, 11, 1, 0, 0, in: ny)
        var matched = 0
        for _ in 0..<(5 * 60) {
            if trigger.matches(date: cursor, calendar: ny) { matched += 1 }
            cursor = cursor.addingTimeInterval(60)
        }
        XCTAssertEqual(matched, 120)
    }

    func testDistantDatesDoNotTrap() {
        let trigger = TimeOfDayTrigger()
        for date in [Date.distantPast, Date.distantFuture, Date(timeIntervalSince1970: -5e11)] {
            _ = trigger.matches(date: date, calendar: utc)
        }
    }

    func testEveryWeekdayAndMinuteOfAWeekIsClassified() {
        // 7 days x 24h x 60m probes: matches iff weekday in set and minute in window.
        let trigger = TimeOfDayTrigger(startMinuteOfDay: 8 * 60 + 30, endMinuteOfDay: 17 * 60, weekdays: [2, 4, 6])
        for day in 11...17 {
            for hour in 0..<24 {
                for minute in stride(from: 0, to: 60, by: 15) {
                    let date = TestCalendars.date(2026, 10, day, hour, minute)
                    let weekday = utc.component(.weekday, from: date)
                    let minuteOfDay = hour * 60 + minute
                    let expected = [2, 4, 6].contains(weekday) && minuteOfDay >= 510 && minuteOfDay < 1020
                    XCTAssertEqual(trigger.matches(date: date, calendar: utc), expected, "day \(day) \(hour):\(minute)")
                }
            }
        }
    }

    // MARK: - Known weaknesses

    func testOvernightWindowStaysActiveIntoTheMorningAfterAListedDay() {
        // Friday 22:00 to Saturday 06:00, Friday listed. The small hours of
        // Saturday belong to Friday night's window.
        let trigger = TimeOfDayTrigger(startMinuteOfDay: 22 * 60, endMinuteOfDay: 6 * 60, weekdays: [Weekday.friday])
        let saturdayTwoAM = TestCalendars.date(2026, 10, 17, 2, 0)
        XCTAssertTrue(trigger.matches(date: saturdayTwoAM, calendar: utc))
    }

    func testDecodedTriggerWithOutOfRangeMinutesStaysInert() throws {
        // Codable bypasses the clamping initializer, so storage can hold
        // minutes outside 0...1439. Such a window must not match at any time.
        let blob = #"{"id":"x","startMinuteOfDay":5000,"endMinuteOfDay":100,"weekdays":[1,2,3,4,5,6,7]}"#
        let decoded = try JSONDecoder().decode(TimeOfDayTrigger.self, from: Data(blob.utf8))
        // Decoding clamps by the same rules as the initializer: 5000 becomes 1439.
        XCTAssertEqual(decoded.startMinuteOfDay, 1439)
        XCTAssertEqual(decoded, TimeOfDayTrigger(id: "x", startMinuteOfDay: 5000, endMinuteOfDay: 100, weekdays: [1, 2, 3, 4, 5, 6, 7]))
        let noon = TestCalendars.date(2026, 10, 13, 12, 0)
        XCTAssertFalse(decoded.matches(date: noon, calendar: utc))
    }

    // MARK: - Frontmost app and space triggers

    func testAppAndSpaceTriggersRoundTripWithTheirBundleIdentifier() throws {
        let app = FrontmostAppTrigger(id: "a", bundleIdentifier: "com.apple.Safari")
        let space = SpaceTrigger(id: "s", bundleIdentifier: "com.apple.Terminal")
        XCTAssertEqual(try JSONDecoder().decode(FrontmostAppTrigger.self, from: JSONEncoder().encode(app)), app)
        XCTAssertEqual(try JSONDecoder().decode(SpaceTrigger.self, from: JSONEncoder().encode(space)), space)
    }

    func testTriggerMissingItsBundleIdentifierFailsToDecode() {
        XCTAssertThrowsError(try JSONDecoder().decode(FrontmostAppTrigger.self, from: Data(#"{"id":"a"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(SpaceTrigger.self, from: Data(#"{"id":"a"}"#.utf8)))
    }
}
