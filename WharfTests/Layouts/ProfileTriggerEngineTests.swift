import XCTest
@testable import Wharf

/// Trigger-to-profile resolution (specificity, ties) and the engine's
/// automatic switching, driven with an injected clock and signals.
@MainActor
final class ProfileTriggerEngineTests: LayoutTestCase {
    private let utc = TestCalendars.utc

    private func profile(
        _ id: String,
        created: TimeInterval = 0,
        triggers: [ProfileTrigger] = []
    ) -> DockProfile {
        DockProfile(
            id: id,
            name: id,
            dateCreated: Date(timeIntervalSince1970: created),
            triggers: triggers
        )
    }

    private func time(_ start: Int = 0, _ end: Int = 1439, weekdays: Set<Int> = Set(1...7)) -> ProfileTrigger {
        .timeOfDay(TimeOfDayTrigger(startMinuteOfDay: start, endMinuteOfDay: end, weekdays: weekdays))
    }

    private func app(_ bundle: String) -> ProfileTrigger {
        .frontmostApp(FrontmostAppTrigger(bundleIdentifier: bundle))
    }

    private func space(_ bundle: String) -> ProfileTrigger {
        .space(SpaceTrigger(bundleIdentifier: bundle))
    }

    private let noon = TestCalendars.date(2026, 10, 12, 12, 0, 0) // Monday

    private func best(
        _ profiles: [DockProfile],
        now: Date? = nil,
        frontmost: String? = nil,
        spaceApps: Set<String> = []
    ) -> String? {
        ProfileTriggerEngine.bestMatch(
            profiles: profiles, now: now ?? noon, frontmost: frontmost, spaceApps: spaceApps, calendar: utc
        )?.id
    }

    // MARK: - Resolution

    func testNoProfilesAndNoTriggersMatchNothing() {
        XCTAssertNil(best([]))
        XCTAssertNil(best([profile("a"), profile("b")]))
    }

    func testSingleMatchingTriggerWins() {
        XCTAssertEqual(best([profile("a"), profile("b", triggers: [time()])]), "b")
    }

    func testSpaceBeatsAppBeatsTime() {
        let profiles = [
            profile("time", triggers: [time()]),
            profile("app", triggers: [app("com.a")]),
            profile("space", triggers: [space("com.a")]),
        ]
        XCTAssertEqual(best(profiles, frontmost: "com.a", spaceApps: ["com.a"]), "space")
        XCTAssertEqual(best(profiles, frontmost: "com.a", spaceApps: []), "app")
        XCTAssertEqual(best(profiles, frontmost: nil, spaceApps: []), "time")
    }

    func testListOrderDoesNotChangeTheSpecificityWinner() {
        let a = profile("time", triggers: [time()])
        let b = profile("space", triggers: [space("com.a")])
        XCTAssertEqual(best([a, b], spaceApps: ["com.a"]), "space")
        XCTAssertEqual(best([b, a], spaceApps: ["com.a"]), "space")
    }

    func testTiesGoToTheEarliestCreatedProfile() {
        let profiles = [
            profile("late", created: 300, triggers: [time()]),
            profile("early", created: 100, triggers: [time()]),
            profile("middle", created: 200, triggers: [time()]),
        ]
        XCTAssertEqual(best(profiles), "early")
    }

    func testTiesWithTheSameCreationDateGoToTheFirstListed() {
        let profiles = [
            profile("first", created: 100, triggers: [app("com.a")]),
            profile("second", created: 100, triggers: [app("com.a")]),
        ]
        XCTAssertEqual(best(profiles, frontmost: "com.a"), "first")
        XCTAssertEqual(best(profiles.reversed(), frontmost: "com.a"), "second")
    }

    func testAProfileCountsAtItsMostSpecificMatchingTrigger() {
        let both = profile("both", created: 500, triggers: [time(), space("com.a")])
        let rival = profile("rival", created: 100, triggers: [app("com.a")])
        XCTAssertEqual(best([rival, both], frontmost: "com.a", spaceApps: ["com.a"]), "both")
    }

    func testANonMatchingHighSpecificityTriggerDoesNotHelp() {
        let spaceOnly = profile("space", created: 100, triggers: [space("com.other")])
        let timed = profile("time", created: 900, triggers: [time()])
        XCTAssertEqual(best([spaceOnly, timed], spaceApps: ["com.a"]), "time")
    }

    func testFrontmostAppNeedsAnExactBundleIdentifier() {
        let profiles = [profile("a", triggers: [app("com.apple.Safari")])]
        XCTAssertEqual(best(profiles, frontmost: "com.apple.Safari"), "a")
        XCTAssertNil(best(profiles, frontmost: "com.apple.safari"))
        XCTAssertNil(best(profiles, frontmost: "com.apple.Safari.helper"))
        XCTAssertNil(best(profiles, frontmost: nil))
        XCTAssertNil(best(profiles, frontmost: ""))
    }

    func testSpaceTriggerMatchesWhenTheAppHasAWindowOnTheSpace() {
        let profiles = [profile("a", triggers: [space("com.a")])]
        XCTAssertEqual(best(profiles, spaceApps: ["com.a", "com.b"]), "a")
        XCTAssertNil(best(profiles, spaceApps: ["com.b"]))
        XCTAssertNil(best(profiles, spaceApps: []))
    }

    func testTimeTriggerOutsideItsWindowDoesNotMatch() {
        let profiles = [profile("work", triggers: [time(9 * 60, 18 * 60)])]
        XCTAssertEqual(best(profiles, now: noon), "work")
        XCTAssertNil(best(profiles, now: TestCalendars.date(2026, 10, 12, 20, 0)))
    }

    func testTimeTriggerRespectsWeekdays() {
        let profiles = [profile("weekend", triggers: [time(0, 1439, weekdays: [Weekday.saturday, Weekday.sunday])])]
        XCTAssertNil(best(profiles, now: noon))
        XCTAssertEqual(best(profiles, now: TestCalendars.date(2026, 10, 17, 12, 0)), "weekend")
    }

    func testEveryTriggerKindEvaluatesIndependently() {
        XCTAssertTrue(ProfileTriggerEngine.trigger(time(), matches: noon, frontmost: nil, spaceApps: [], calendar: utc))
        XCTAssertTrue(ProfileTriggerEngine.trigger(app("a"), matches: noon, frontmost: "a", spaceApps: [], calendar: utc))
        XCTAssertTrue(ProfileTriggerEngine.trigger(space("a"), matches: noon, frontmost: nil, spaceApps: ["a"], calendar: utc))
        XCTAssertFalse(ProfileTriggerEngine.trigger(app("a"), matches: noon, frontmost: nil, spaceApps: ["a"], calendar: utc))
        XCTAssertFalse(ProfileTriggerEngine.trigger(space("a"), matches: noon, frontmost: "a", spaceApps: [], calendar: utc))
    }

    func testResolutionAcrossManyProfilesIsDeterministic() {
        let profiles = (0..<200).map { index in
            profile("p\(index)", created: TimeInterval(1000 - index), triggers: index % 3 == 0 ? [time()] : [])
        }
        let first = best(profiles)
        for _ in 0..<5 { XCTAssertEqual(best(profiles), first) }
        // Earliest created among the matching ones (index % 3 == 0): the highest such index.
        XCTAssertEqual(first, "p198")
    }

    // MARK: - Minute boundary

    func testNextMinuteBoundaryIsTheNextWholeMinute() {
        let cases: [(from: Date, expected: Date)] = [
            (TestCalendars.date(2026, 10, 12, 10, 0, 30), TestCalendars.date(2026, 10, 12, 10, 1, 0)),
            (TestCalendars.date(2026, 10, 12, 10, 0, 59), TestCalendars.date(2026, 10, 12, 10, 1, 0)),
            (TestCalendars.date(2026, 10, 12, 10, 59, 1), TestCalendars.date(2026, 10, 12, 11, 0, 0)),
            (TestCalendars.date(2026, 10, 12, 23, 59, 30), TestCalendars.date(2026, 10, 13, 0, 0, 0)),
        ]
        for item in cases {
            XCTAssertEqual(ProfileTriggerEngine.nextMinuteBoundary(after: item.from, calendar: utc), item.expected)
        }
    }

    func testNextMinuteBoundaryIsStrictlyAfterAnExactBoundary() {
        let boundary = TestCalendars.date(2026, 10, 12, 10, 0, 0)
        XCTAssertEqual(
            ProfileTriggerEngine.nextMinuteBoundary(after: boundary, calendar: utc),
            boundary.addingTimeInterval(60)
        )
    }

    func testNextMinuteBoundaryIsNeverMoreThanAMinuteAway() {
        var date = TestCalendars.date(2026, 10, 12, 10, 0, 0)
        for _ in 0..<180 {
            let next = ProfileTriggerEngine.nextMinuteBoundary(after: date, calendar: utc)
            XCTAssertGreaterThan(next, date)
            XCTAssertLessThanOrEqual(next.timeIntervalSince(date), 60)
            date = date.addingTimeInterval(7)
        }
    }

    func testNextMinuteBoundaryHandlesDaylightSavingDays() {
        let ny = TestCalendars.newYork
        for start in [TestCalendars.date(2026, 3, 8, 1, 59, 30, in: ny), TestCalendars.date(2026, 11, 1, 1, 59, 30, in: ny)] {
            let next = ProfileTriggerEngine.nextMinuteBoundary(after: start, calendar: ny)
            XCTAssertGreaterThan(next, start)
            XCTAssertLessThanOrEqual(next.timeIntervalSince(start), 60)
        }
    }

    // MARK: - Automatic switching

    private struct Rig {
        let engine: ProfileTriggerEngine
        let service: ProfileService
        let prefs: DockyPreferences
    }

    private var clock = Date()

    private func makeRig(_ profiles: [DockProfile], active: String? = nil) throws -> Rig {
        let defaults = makeDefaults()
        defaults.set(try JSONEncoder().encode(profiles), forKey: ProfileService.Keys.profiles)
        if let active { defaults.set(active, forKey: ProfileService.Keys.activeProfileID) }
        let prefs = DockyPreferences(defaults: makeDefaults())
        let service = ProfileService(defaults: defaults, preferences: { prefs })
        prefs.profileMirrorTarget = service
        clock = noon
        let engine = ProfileTriggerEngine(profileService: service, now: { self.clock }, calendar: TestCalendars.utc)
        return Rig(engine: engine, service: service, prefs: prefs)
    }

    func testEvaluateSwitchesToTheMatchingProfile() throws {
        let rig = try makeRig([profile("a"), profile("b", triggers: [time()])], active: "a")
        rig.engine.evaluate()
        XCTAssertEqual(rig.service.activeProfileID, "b")
        XCTAssertEqual(rig.engine.lastAutoActivatedProfileID, "b")
    }

    func testEvaluateDoesNothingWhenNothingMatches() throws {
        let rig = try makeRig([profile("a"), profile("b", triggers: [app("com.a")])], active: "a")
        rig.engine.evaluate()
        XCTAssertEqual(rig.service.activeProfileID, "a")
        XCTAssertNil(rig.engine.lastAutoActivatedProfileID)
    }

    func testEvaluateDoesNothingWhenTheMatchIsAlreadyActive() throws {
        let rig = try makeRig([profile("a", triggers: [time()]), profile("b")], active: "a")
        rig.engine.evaluate()
        XCTAssertEqual(rig.service.activeProfileID, "a")
        XCTAssertNil(rig.engine.lastAutoActivatedProfileID, "no switch happened, so nothing was auto-activated")
    }

    func testEvaluateReactsToTheFrontmostApp() throws {
        let rig = try makeRig([profile("home"), profile("dev", triggers: [app("com.apple.dt.Xcode")])], active: "home")
        rig.engine.evaluate()
        XCTAssertEqual(rig.service.activeProfileID, "home")
        rig.engine.currentFrontmostBundleID = "com.apple.dt.Xcode"
        rig.engine.evaluate()
        XCTAssertEqual(rig.service.activeProfileID, "dev")
    }

    func testEvaluateReactsToTheSpace() throws {
        let rig = try makeRig([profile("home"), profile("video", triggers: [space("com.apple.QuickTimePlayerX")])], active: "home")
        rig.engine.currentSpaceApps = ["com.apple.QuickTimePlayerX"]
        rig.engine.evaluate()
        XCTAssertEqual(rig.service.activeProfileID, "video")
    }

    func testEvaluateAppliesTheProfilesDockToPreferences() throws {
        var dev = profile("dev", triggers: [time()])
        dev.pinnedItems = [.app(bundleIdentifier: "com.dev")]
        let rig = try makeRig([profile("home"), dev], active: "home")
        rig.engine.evaluate()
        XCTAssertEqual(rig.prefs.pinnedItems.map(\.bundleIdentifier), ["com.dev"])
    }

    func testAManualSwitchIsNotFoughtBack() throws {
        let rig = try makeRig([
            profile("home"),
            profile("work", triggers: [time()]),
            profile("gaming"),
        ], active: "home")
        rig.engine.evaluate()
        XCTAssertEqual(rig.service.activeProfileID, "work")

        rig.service.setActiveProfile(id: "gaming") // the user's own pick
        rig.engine.evaluate()
        XCTAssertEqual(rig.service.activeProfileID, "gaming")
    }

    func testEngineResumesWhenTheUserReturnsToTheAutoProfile() throws {
        let rig = try makeRig([
            profile("home"),
            profile("work", created: 1, triggers: [app("com.a")]),
            profile("gaming"),
            profile("other", created: 2, triggers: [app("com.b")]),
        ], active: "home")
        rig.engine.currentFrontmostBundleID = "com.a"
        rig.engine.evaluate()
        XCTAssertEqual(rig.service.activeProfileID, "work")
        rig.service.setActiveProfile(id: "gaming")
        rig.engine.evaluate()
        XCTAssertEqual(rig.service.activeProfileID, "gaming")

        // The user flips back to the auto-activated profile, then the signal changes.
        rig.service.setActiveProfile(id: "work")
        rig.engine.currentFrontmostBundleID = nil
        rig.engine.evaluate()
        XCTAssertEqual(rig.service.activeProfileID, "work", "nothing matches, so nothing reverts")

        rig.engine.currentFrontmostBundleID = "com.b"
        rig.engine.evaluate()
        XCTAssertEqual(rig.service.activeProfileID, "other")
    }

    func testTimeWindowEndingDoesNotRevertToTheDefaultProfile() throws {
        let rig = try makeRig([profile("home"), profile("work", triggers: [time(9 * 60, 18 * 60)])], active: "home")
        clock = TestCalendars.date(2026, 10, 12, 10, 0)
        rig.engine.evaluate()
        XCTAssertEqual(rig.service.activeProfileID, "work")
        clock = TestCalendars.date(2026, 10, 12, 20, 0)
        rig.engine.evaluate()
        XCTAssertEqual(rig.service.activeProfileID, "work", "documented: nothing switches back when the window closes")
    }

    func testHigherSpecificityAutoSwitchesFromAnAutoProfile() throws {
        let rig = try makeRig([
            profile("home"),
            profile("timed", triggers: [time()]),
            profile("app", triggers: [app("com.a")]),
        ], active: "home")
        rig.engine.evaluate()
        XCTAssertEqual(rig.service.activeProfileID, "timed")
        rig.engine.currentFrontmostBundleID = "com.a"
        rig.engine.evaluate()
        XCTAssertEqual(rig.service.activeProfileID, "app")
    }

    func testFirstEvaluationMayLeaveAManuallyChosenProfile() throws {
        // Before the engine has ever switched, there is no override to
        // protect, so a matching trigger wins over the persisted choice.
        let rig = try makeRig([profile("manual"), profile("auto", triggers: [time()])], active: "manual")
        rig.engine.evaluate()
        XCTAssertEqual(rig.service.activeProfileID, "auto")
    }

    func testEvaluateWithEveryProfileMatchingPicksTheEarliestCreated() throws {
        let rig = try makeRig([
            profile("c", created: 3, triggers: [time()]),
            profile("a", created: 1, triggers: [time()]),
            profile("b", created: 2, triggers: [time()]),
        ], active: "c")
        rig.engine.evaluate()
        XCTAssertEqual(rig.service.activeProfileID, "a")
    }

    func testEvaluateOnAnEmptyTriggerSetIsInert() throws {
        let rig = try makeRig([profile("only")], active: "only")
        for _ in 0..<10 { rig.engine.evaluate() }
        XCTAssertEqual(rig.service.activeProfileID, "only")
    }

    func testStopWithoutStartIsSafe() throws {
        let rig = try makeRig([profile("a")], active: "a")
        rig.engine.stop()
        rig.engine.stop()
    }
}
