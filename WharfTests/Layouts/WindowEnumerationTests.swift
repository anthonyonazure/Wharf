import XCTest
@testable import Wharf

/// The pure parts of window enumeration: the time and count bounds added to
/// stop a hostile AX server freezing the dock, element de-duplication, the
/// per-app filters and title handling.
@MainActor
final class WindowEnumerationTests: LayoutTestCase {
    /// A clock that moves forward by a fixed step each time it is read.
    private final class SteppingClock {
        private var nanoseconds: UInt64 = 1_000_000_000
        let stepMilliseconds: UInt64
        private(set) var reads = 0

        init(stepMilliseconds: UInt64) { self.stepMilliseconds = stepMilliseconds }

        func now() -> DispatchTime {
            reads += 1
            let value = nanoseconds
            nanoseconds += stepMilliseconds * 1_000_000
            return DispatchTime(uptimeNanoseconds: value)
        }

        func advance(milliseconds: UInt64) { nanoseconds += milliseconds * 1_000_000 }
    }

    // MARK: - boundedEnumeration

    func testEveryElementIsProcessedWhenTheClockStandsStill() {
        let result = WindowRegistry.boundedEnumeration(
            Array(0..<50), now: { DispatchTime(uptimeNanoseconds: 5_000_000_000) }
        ) { $0 }
        XCTAssertEqual(result, Array(0..<50))
    }

    func testOutputKeepsInputOrderAndDropsNils() {
        let result = WindowRegistry.boundedEnumeration(
            Array(0..<10), now: { DispatchTime(uptimeNanoseconds: 5_000_000_000) }
        ) { $0 % 2 == 0 ? $0 * 10 : nil }
        XCTAssertEqual(result, [0, 20, 40, 60, 80])
    }

    func testEnumerationStopsOnceTheBudgetIsSpent() {
        // Each clock read costs 100 ms against a 750 ms budget. One read sets
        // the deadline, then one per element: elements 1-7 start in time.
        let clock = SteppingClock(stepMilliseconds: 100)
        var processed = 0
        _ = WindowRegistry.boundedEnumeration(
            Array(0..<100), budget: .milliseconds(750), now: clock.now
        ) { _ -> Int? in
            processed += 1
            return processed
        }
        XCTAssertEqual(processed, 7)
    }

    func testASlowElementEatsTheBudgetForTheRest() {
        // Each element's own work (a stalled AX read) takes 400 ms.
        let clock = SteppingClock(stepMilliseconds: 0)
        var processed = 0
        let result = WindowRegistry.boundedEnumeration(
            Array(0..<256), budget: .milliseconds(750), now: clock.now
        ) { element -> Int? in
            processed += 1
            clock.advance(milliseconds: 400)
            return element
        }
        XCTAssertEqual(processed, 2, "0 ms and 400 ms are inside 750 ms; 800 ms is not")
        XCTAssertEqual(result, [0, 1])
    }

    func testWorstCaseStallIsBoundedNotMultiplied() {
        // 256 windows that each stall just under the 1 s per-message timeout.
        let clock = SteppingClock(stepMilliseconds: 0)
        var processed = 0
        _ = WindowRegistry.boundedEnumeration(Array(0..<256), now: clock.now) { _ -> Int? in
            processed += 1
            clock.advance(milliseconds: 990)
            return 1
        }
        XCTAssertLessThanOrEqual(processed, 2)
    }

    func testAnAlreadyExpiredBudgetProcessesNothing() {
        let clock = SteppingClock(stepMilliseconds: 1)
        var processed = 0
        let result = WindowRegistry.boundedEnumeration(
            Array(0..<10), budget: .milliseconds(-1), now: clock.now
        ) { _ -> Int? in
            processed += 1
            return 1
        }
        XCTAssertEqual(processed, 0)
        XCTAssertTrue(result.isEmpty)
    }

    func testTheCountCapIs256() {
        XCTAssertEqual(WindowRegistry.maxWindowsPerApp, 256)
        XCTAssertEqual(WindowRegistry.enumerationBudget, .milliseconds(750))
    }

    func testAtMostTheCapIsProcessed() {
        var processed = 0
        let result = WindowRegistry.boundedEnumeration(
            Array(0..<10_000), now: { DispatchTime(uptimeNanoseconds: 5_000_000_000) }
        ) { element -> Int? in
            processed += 1
            return element
        }
        XCTAssertEqual(processed, 256)
        XCTAssertEqual(result.count, 256)
        XCTAssertEqual(result.last, 255)
    }

    func testExactlyTheCapPassesThrough() {
        let result = WindowRegistry.boundedEnumeration(
            Array(0..<256), now: { DispatchTime(uptimeNanoseconds: 5_000_000_000) }
        ) { $0 }
        XCTAssertEqual(result.count, 256)
    }

    func testEmptyInput() {
        let result = WindowRegistry.boundedEnumeration([Int]()) { $0 }
        XCTAssertTrue(result.isEmpty)
    }

    func testCustomCapIsHonoured() {
        let result = WindowRegistry.boundedEnumeration(
            Array(0..<100), maxElements: 3, now: { DispatchTime(uptimeNanoseconds: 5_000_000_000) }
        ) { $0 }
        XCTAssertEqual(result, [0, 1, 2])
    }

    func testEnumerationOfAHugeListIsFast() {
        let started = Date()
        _ = WindowRegistry.boundedEnumeration(Array(0..<1_000_000)) { $0 }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "the cap must be applied before any per-element work")
    }

    // MARK: - collectWindows

    private let steady: () -> DispatchTime = { DispatchTime(uptimeNanoseconds: 5_000_000_000) }

    private func collect(
        _ elements: [AXUIElement],
        isWindow: @escaping (AXUIElement) -> Bool = { _ in true },
        make: ((AXUIElement) -> AppWindow?)? = nil,
        keep: @escaping (AppWindow, AXUIElement) -> Bool = { _, _ in true },
        maxElements: Int = WindowRegistry.maxWindowsPerApp
    ) -> [AppWindow] {
        WindowRegistry.collectWindows(
            from: elements, isWindow: isWindow, makeWindow: make ?? { FakeWindows.make(element: $0) }, keep: keep,
            maxElements: maxElements, now: steady
        )
    }

    func testDistinctWindowElementsAreAllKeptInOrder() {
        let elements = (0..<5).map { _ in FakeWindows.element() }
        let result = collect(elements, make: { FakeWindows.make(title: "w", element: $0) })
        XCTAssertEqual(result.count, 5)
        for (window, element) in zip(result, elements) {
            XCTAssertTrue(CFEqual(window.element, element))
        }
    }

    func testTheSameElementListedTwiceYieldsOneWindow() {
        let element = FakeWindows.element()
        let other = FakeWindows.element()
        let result = collect([element, other, element, element])
        XCTAssertEqual(result.count, 2)
    }

    func testDuplicatesAreSkippedBeforeAnyWorkIsDoneForThem() {
        let element = FakeWindows.element()
        var built = 0
        _ = collect([element, element, element], make: {
            built += 1
            return FakeWindows.make(element: $0)
        })
        XCTAssertEqual(built, 1)
    }

    func testNonWindowRolesAreSkipped() {
        let window = FakeWindows.element()
        let sheet = FakeWindows.element()
        let result = collect([sheet, window], isWindow: { CFEqual($0, window) })
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(CFEqual(result[0].element, window))
    }

    func testElementsThatCannotBeBuiltAreSkipped() {
        let bad = FakeWindows.element()
        let good = FakeWindows.element()
        let result = collect([bad, good], make: { CFEqual($0, bad) ? nil : FakeWindows.make(element: $0) })
        XCTAssertEqual(result.count, 1)
    }

    func testTheAppFilterCanRejectAWindow() {
        let hidden = FakeWindows.element()
        let shown = FakeWindows.element()
        let result = collect([hidden, shown], keep: { _, element in !CFEqual(element, hidden) })
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(CFEqual(result[0].element, shown))
    }

    func testARejectedElementIsNotRetriedWhenListedAgain() {
        let element = FakeWindows.element()
        var keepCalls = 0
        let result = collect([element, element], keep: { _, _ in
            keepCalls += 1
            return false
        })
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(keepCalls, 1)
    }

    func testPipelineAppliesTheCountCap() {
        let elements = (0..<400).map { _ in FakeWindows.element() }
        XCTAssertEqual(collect(elements).count, 256)
    }

    func testPipelineAppliesTheTimeBudget() {
        let clock = SteppingClock(stepMilliseconds: 100)
        let elements = (0..<50).map { _ in FakeWindows.element() }
        let result = WindowRegistry.collectWindows(
            from: elements,
            isWindow: { _ in true },
            makeWindow: { FakeWindows.make(element: $0) },
            keep: { _, _ in true },
            budget: .milliseconds(750),
            now: clock.now
        )
        XCTAssertEqual(result.count, 7)
    }

    func testDuplicatesBeyondTheCapAreNeverSeen() {
        let first = FakeWindows.element()
        let elements = [first] + (0..<300).map { _ in FakeWindows.element() }
        let result = collect(elements + [first])
        XCTAssertEqual(result.count, 256)
    }

    // MARK: - Titles

    func testTitleIsTrimmed() {
        XCTAssertEqual(WindowRegistry.resolvedTitle(raw: "  Report.docx \n", appDisplayName: "Word"), "Report.docx")
    }

    func testMissingOrBlankTitlesFallBackToTheAppName() {
        for raw in [nil, "", "   ", "\n\t", "\u{00A0}"] as [String?] {
            XCTAssertEqual(WindowRegistry.resolvedTitle(raw: raw, appDisplayName: "Word"), "Word", "\(String(describing: raw))")
        }
    }

    func testInnerWhitespaceAndUnicodeAreKept() {
        XCTAssertEqual(WindowRegistry.resolvedTitle(raw: "A  B\u{1F600}", appDisplayName: "X"), "A  B\u{1F600}")
    }

    func testVeryLongTitlesPassThrough() {
        let long = String(repeating: "t", count: 100_000)
        XCTAssertEqual(WindowRegistry.resolvedTitle(raw: long, appDisplayName: "X").count, 100_000)
    }

    func testEmptyAppNameWithEmptyTitleStaysEmpty() {
        XCTAssertEqual(WindowRegistry.resolvedTitle(raw: nil, appDisplayName: ""), "")
    }

    // MARK: - Per-app filters

    private func passes(
        _ bundle: String,
        title: String = "Window",
        app: String = "App",
        frame: CGRect? = CGRect(x: 0, y: 0, width: 800, height: 600),
        subrole: String? = nil
    ) -> Bool {
        WindowRegistry.passesAppDiscriminator(
            bundleID: bundle, windowTitle: title, appDisplayName: app, frame: frame, subrole: { subrole }
        )
    }

    func testOrdinaryAppsPassUntouched() {
        XCTAssertTrue(passes("com.apple.Safari"))
        XCTAssertTrue(passes("com.apple.Safari", title: "", frame: nil))
        XCTAssertTrue(passes("com.example.tiny", frame: CGRect(x: 0, y: 0, width: 1, height: 1)))
    }

    func testSteamOverlayShadowsAreDropped() {
        XCTAssertFalse(passes("com.valvesoftware.steam", title: "", app: "Steam"))
        XCTAssertFalse(passes("com.valvesoftware.steam", title: "   ", app: "Steam"))
        XCTAssertFalse(passes("com.valvesoftware.steam", title: "Steam", app: "Steam"))
        XCTAssertTrue(passes("com.valvesoftware.steam", title: "Library", app: "Steam"))
    }

    func testFirefoxThinPanelsAreDroppedButRealWindowsKept() {
        XCTAssertFalse(passes("org.mozilla.firefox", frame: CGRect(x: 0, y: 0, width: 900, height: 299)))
        XCTAssertTrue(passes("org.mozilla.firefox", frame: CGRect(x: 0, y: 0, width: 900, height: 300)))
        XCTAssertTrue(passes("org.mozilla.firefox", frame: nil))
    }

    func testTheMozillaPrefixCoversSiblingApps() {
        XCTAssertFalse(passes("org.mozilla.thunderbird", frame: CGRect(x: 0, y: 0, width: 900, height: 100)))
        XCTAssertFalse(passes("org.mozilla.nightly", frame: CGRect(x: 0, y: 0, width: 900, height: 100)))
        XCTAssertTrue(passes("org.mozillafoo", frame: CGRect(x: 0, y: 0, width: 900, height: 100)))
    }

    func testJetBrainsFloatingHelpersAreDropped() {
        XCTAssertFalse(passes("com.jetbrains.intellij", subrole: "AXFloatingWindow"))
        XCTAssertFalse(passes("com.jetbrains.pycharm", subrole: "AXSystemFloatingWindow"))
        XCTAssertTrue(passes("com.jetbrains.intellij", subrole: "AXStandardWindow"))
        XCTAssertTrue(passes("com.jetbrains.intellij", subrole: nil))
    }

    func testTheSubroleIsOnlyReadForJetBrainsApps() {
        var reads = 0
        for bundle in ["com.apple.Safari", "com.valvesoftware.steam", "org.mozilla.firefox"] {
            _ = WindowRegistry.passesAppDiscriminator(
                bundleID: bundle, windowTitle: "w", appDisplayName: "a", frame: nil,
                subrole: { reads += 1; return nil }
            )
        }
        XCTAssertEqual(reads, 0)
        _ = WindowRegistry.passesAppDiscriminator(
            bundleID: "com.jetbrains.x", windowTitle: "w", appDisplayName: "a", frame: nil,
            subrole: { reads += 1; return nil }
        )
        XCTAssertEqual(reads, 1)
    }

    func testFiltersDoNotLeakAcrossApps() {
        XCTAssertTrue(passes("com.apple.Safari", frame: CGRect(x: 0, y: 0, width: 900, height: 100), subrole: "AXFloatingWindow"))
        XCTAssertTrue(passes("com.example.app", title: "", app: "App"))
    }

    func testBundleLookalikesAreNotFiltered() {
        XCTAssertTrue(passes("com.valvesoftware.steamvr", title: "", app: "x"))
        XCTAssertTrue(passes("jetbrains.com.thing", subrole: "AXFloatingWindow"))
        XCTAssertTrue(passes("", title: ""))
    }

    func testSizeGateTreatsNaNAsBigEnough() {
        // NaN comparisons are false, so a NaN dimension is not "below the minimum".
        XCTAssertFalse(WindowRegistry.isBelowMinimumTrackedSize(CGSize(width: CGFloat.nan, height: CGFloat.nan)))
    }
}
