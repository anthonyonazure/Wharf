import XCTest
@testable import Wharf

/// Short aliases for the preference key and default-value tables.
typealias PrefKeys = DockyPreferences.Keys
typealias PrefDefaults = DockyPreferences.DefaultValues

/// Base class for every DockyPreferences test.
///
/// Each test gets its own throwaway `UserDefaults` suite, removed in `tearDown`,
/// so nothing here can touch `UserDefaults.standard` or the real Wharf domain.
///
/// Two preferences are seeded before any instance is built, because their
/// setters (or their missing-key defaults) reach real machine services:
/// `opensAtLogin` consults the login-item service, and `hidesSystemDock` hides or
/// restores the real system Dock. Seeding them keeps the reset functions and the
/// init path from ever calling those services. Tests must never assign either
/// property, nor `windowPosition` while `hidesSystemDock` is true (it moves the
/// real Dock).
class DockyPreferencesTestCase: XCTestCase {
    private(set) var suiteName: String = ""
    private(set) var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "WharfTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: PrefKeys.opensAtLogin)
        defaults.set(true, forKey: PrefKeys.hidesSystemDock)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// Builds preferences over the throwaway suite with every outward side
    /// effect (profile mirroring, login item sync) switched off.
    func makePrefs() -> DockyPreferences {
        let prefs = DockyPreferences(defaults: defaults)
        prefs.isApplyingProfile = true
        prefs.isSyncingOpenAtLoginPreference = true
        return prefs
    }

    /// Writes raw values into the suite, then builds fresh preferences from them.
    func makePrefs(seeding values: [String: Any]) -> DockyPreferences {
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
        return makePrefs()
    }

    func makePrefs(seeding value: Any, forKey key: String) -> DockyPreferences {
        makePrefs(seeding: [key: value])
    }

    /// Re-reads everything from the suite, as a relaunch would.
    func reload() -> DockyPreferences {
        makePrefs()
    }

    func encoded<T: Encodable>(_ value: T) -> Data {
        guard let data = try? JSONEncoder().encode(value) else {
            XCTFail("encode failed for \(T.self)")
            return Data()
        }
        return data
    }

    func json(_ text: String) -> Data {
        Data(text.utf8)
    }

    /// A temporary directory removed at teardown.
    func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WharfTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
