import ApplicationServices
import XCTest
@testable import Wharf

/// Base class for the layout, rule, profile and window bookkeeping tests.
/// Hands out throwaway UserDefaults suites and removes them afterwards, so no
/// test ever reads or writes the real Wharf preferences domain.
@MainActor
class LayoutTestCase: XCTestCase {
    private var suiteNames: [String] = []

    func makeDefaults() -> UserDefaults {
        let name = "WharfTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        suiteNames.append(name)
        return defaults
    }

    override func tearDown() {
        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }
}

// MARK: - Fake windows

/// Windows for tests. Identity in the registry is an `AXUIElement`; creating an
/// application element for a made-up pid is a purely local operation (no
/// Accessibility permission, no IPC), and different pids give elements that
/// are not equal, which is exactly the property the registry relies on.
@MainActor
enum FakeWindows {
    private static var counter: pid_t = 70_000

    static func element() -> AXUIElement {
        counter += 1
        return AXUIElementCreateApplication(counter)
    }

    static func make(
        bundle: String = "com.test.app",
        title: String = "Document",
        frame: CGRect? = CGRect(x: 100, y: 50, width: 800, height: 600),
        minimized: Bool = false,
        pid: pid_t = 4242,
        appName: String = "Test App",
        cgWindowID: CGWindowID? = nil,
        windowNumber: Int? = nil,
        element: AXUIElement? = nil
    ) -> AppWindow {
        AppWindow(
            element: element ?? Self.element(),
            bundleIdentifier: bundle,
            processIdentifier: pid,
            appDisplayName: appName,
            windowTitle: title,
            isMinimized: minimized,
            windowNumber: windowNumber,
            cgWindowID: cgWindowID,
            frame: frame
        )
    }
}

// MARK: - Fake desk

extension LayoutDisplay {
    /// 1440x900 primary display with a 25pt menu bar.
    static let primary = LayoutDisplay(
        uuid: "DISPLAY-A",
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
    )
    /// 1920x1080 display to the right of the primary one.
    static let right = LayoutDisplay(
        uuid: "DISPLAY-B",
        frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055)
    )
}

/// A scripted stand-in for the machine the layout service runs on.
@MainActor
final class FakeDesk {
    var displays: [LayoutDisplay] = [.primary, .right]
    /// Defaults to the first display when nil.
    var mainOverride: LayoutDisplay?
    var windows: [AppWindow] = []
    var running: Set<String> = []
    /// Bundle identifiers that can be launched; others report "not installed".
    var launchable: Set<String> = []
    private(set) var launched: [String] = []
    private(set) var resizeLog: [(window: AppWindow, frame: CGRect)] = []
    var resizeResult: (AppWindow, Int) -> Bool = { _, _ in true }
    var onResize: (() -> Void)?
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var scheduled: [(delay: TimeInterval, work: () -> Void)] = []

    var mainDisplay: LayoutDisplay? { mainOverride ?? displays.first }

    func environment() -> WorkspaceLayoutEnvironment {
        WorkspaceLayoutEnvironment(
            displays: { self.displays },
            mainDisplay: { self.mainDisplay },
            windows: { self.windows },
            resize: { window, frame in
                self.resizeLog.append((window, frame))
                self.onResize?()
                return self.resizeResult(window, self.resizeLog.count)
            },
            runningBundleIdentifiers: { self.running },
            launchApp: { bundleID in
                guard self.launchable.contains(bundleID) else { return false }
                self.launched.append(bundleID)
                return true
            },
            now: { self.clock },
            schedule: { delay, work in self.scheduled.append((delay, work)) }
        )
    }

    /// Runs the oldest scheduled callback, if any. Returns whether one ran.
    @discardableResult
    func runNextScheduled() -> Bool {
        guard !scheduled.isEmpty else { return false }
        let next = scheduled.removeFirst()
        next.work()
        return true
    }

    func clearResizeLog() {
        resizeLog.removeAll()
    }
}

// MARK: - Dates and calendars

enum TestCalendars {
    /// Gregorian calendar pinned to a zone, so the tests do not depend on
    /// where the machine running them happens to be.
    static func gregorian(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    static let utc = gregorian("UTC")
    static let newYork = gregorian("America/New_York")

    static func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0,
        in calendar: Calendar = TestCalendars.utc
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ))!
    }
}

/// Weekday numbers as Calendar reports them (1 = Sunday).
enum Weekday {
    static let sunday = 1
    static let monday = 2
    static let tuesday = 3
    static let wednesday = 4
    static let thursday = 5
    static let friday = 6
    static let saturday = 7
    static let all = Array(1...7)
}

// MARK: - Layout fixtures

func makePlacement(
    bundle: String = "com.test.app",
    title: String = "Document",
    frame: CGRect = CGRect(x: 100, y: 250, width: 800, height: 600),
    display: String? = LayoutDisplay.primary.uuid
) -> WindowPlacement {
    WindowPlacement(bundleIdentifier: bundle, windowTitle: title, frame: frame, displayUUID: display)
}

func makeLayout(
    id: String = UUID().uuidString,
    name: String = "Work",
    placements: [WindowPlacement] = [],
    bundles: [String]? = nil
) -> WorkspaceLayout {
    WorkspaceLayout(
        id: id,
        name: name,
        placements: placements,
        bundleIdentifiers: bundles ?? Array(Set(placements.map(\.bundleIdentifier))).sorted()
    )
}
