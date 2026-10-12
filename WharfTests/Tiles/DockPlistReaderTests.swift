import XCTest
@testable import Wharf

/// `DockPlistReader.read(domain:)` goes through CFPreferences, so these tests
/// point it at a scratch preferences file addressed by absolute path in a
/// temporary directory. The real `com.apple.dock` domain is never written.
/// (File-format handling, binary vs XML and truncated files, is covered by
/// `DockEditorServiceTests`, which parses plist files directly.)
@MainActor
final class DockPlistReaderTests: XCTestCase {
    private var directory: URL!
    private var domain: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WharfDockReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // An absolute path is a valid CFPreferences application id; it maps
        // to "<path>.plist".
        domain = directory.appendingPathComponent("scratch").path
    }

    override func tearDownWithError() throws {
        CFPreferencesAppSynchronize(domain as CFString)
        try? FileManager.default.removeItem(at: directory)
    }

    private func set(_ key: String, _ value: Any?) {
        CFPreferencesSetValue(
            key as CFString,
            value as CFPropertyList?,
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesAppSynchronize(domain as CFString)
    }

    func testSystemDockDomainName() {
        XCTAssertEqual(DockPlistReader.systemDockDomain, "com.apple.dock")
    }

    func testKeyListIsUniqueAndIncludesTheTileSections() {
        XCTAssertEqual(Set(DockPlistReader.keys).count, DockPlistReader.keys.count)
        XCTAssertTrue(DockPlistReader.keys.contains("persistent-apps"))
        XCTAssertTrue(DockPlistReader.keys.contains("persistent-others"))
        XCTAssertTrue(DockPlistReader.keys.contains("tilesize"))
    }

    func testEmptyDomainReadsAsNil() {
        XCTAssertNil(DockPlistReader.read(domain: domain))
    }

    func testKnownKeysAreReturned() throws {
        set("orientation", "left")
        set("tilesize", 52)
        set("autohide", true)
        let values = try XCTUnwrap(DockPlistReader.read(domain: domain))
        XCTAssertEqual(values["orientation"] as? String, "left")
        XCTAssertEqual(values["tilesize"] as? Int, 52)
        XCTAssertEqual(values["autohide"] as? Bool, true)
        XCTAssertEqual(values.count, 3)
    }

    func testUnrelatedKeysAreNotReturned() throws {
        set("orientation", "bottom")
        set("not-a-dock-key", "secret")
        set("wvous-tl-corner", 2)
        let values = try XCTUnwrap(DockPlistReader.read(domain: domain))
        XCTAssertEqual(Set(values.keys), ["orientation"])
    }

    func testOnlyUnrelatedKeysReadAsNil() {
        set("not-a-dock-key", "x")
        XCTAssertNil(DockPlistReader.read(domain: domain))
    }

    func testPersistentSectionsRoundTrip() throws {
        let apps: [[String: Any]] = [
            ["GUID": 1, "tile-type": "file-tile", "tile-data": ["file-label": "A", "bundle-identifier": "a"]],
            ["GUID": 2, "tile-type": "spacer-tile"],
        ]
        set("persistent-apps", apps)
        set("persistent-others", [[String: Any]]())
        let values = try XCTUnwrap(DockPlistReader.read(domain: domain))
        let readApps = try XCTUnwrap(values["persistent-apps"] as? [[String: Any]])
        XCTAssertEqual(readApps.count, 2)
        XCTAssertEqual((values["persistent-others"] as? [Any])?.count, 0)
    }

    func testReaderDoesNotValidateValueTypes() throws {
        // The reader is a transport. Callers (TileStore) cast and discard.
        set("persistent-apps", "not an array")
        let values = try XCTUnwrap(DockPlistReader.read(domain: domain))
        XCTAssertEqual(values["persistent-apps"] as? String, "not an array")
        XCTAssertEqual(TileStore.parsedTiles(from: values, section: "persistent-apps"), [])
    }

    func testLargeSectionsAreReadWhole() throws {
        let apps: [[String: Any]] = (0..<10_000).map { ["GUID": $0, "tile-type": "spacer-tile"] }
        set("persistent-apps", apps)
        let values = try XCTUnwrap(DockPlistReader.read(domain: domain))
        XCTAssertEqual((values["persistent-apps"] as? [[String: Any]])?.count, 10_000)
    }

    func testRemovingAKeyRemovesItFromTheRead() throws {
        set("orientation", "left")
        set("tilesize", 40)
        set("orientation", nil)
        let values = try XCTUnwrap(DockPlistReader.read(domain: domain))
        XCTAssertEqual(Set(values.keys), ["tilesize"])
    }
}
