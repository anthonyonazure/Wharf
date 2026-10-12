import XCTest
@testable import Wharf

/// `DockEditorService` rewrites the system Dock plist. Every test points it at
/// a scratch file through `init(dockPlistURL:)`, which also keeps it from
/// restarting the real Dock or touching the process-wide `TileStore`.
@MainActor
final class DockEditorServiceTests: XCTestCase {
    private var directory: URL!
    private var plistURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WharfDockEditorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        plistURL = directory.appendingPathComponent("com.apple.dock.plist")
    }

    override func tearDownWithError() throws {
        // Directory may have been made read-only by a test.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func appEntry(guid: Any? = nil, bundleID: String, label: String? = nil) -> [String: Any] {
        var entry: [String: Any] = [
            "tile-type": "file-tile",
            "tile-data": [
                "bundle-identifier": bundleID,
                "file-label": label ?? bundleID,
                "file-data": ["_CFURLString": "file:///Applications/\(bundleID).app/", "_CFURLStringType": 15],
            ] as [String: Any],
        ]
        if let guid { entry["GUID"] = guid }
        return entry
    }

    @discardableResult
    private func write(
        apps: [[String: Any]]?,
        others: [[String: Any]]? = nil,
        extra: [String: Any] = [:],
        format: PropertyListSerialization.PropertyListFormat = .binary
    ) throws -> Data {
        var plist = extra
        if let apps { plist["persistent-apps"] = apps }
        if let others { plist["persistent-others"] = others }
        return try writeRaw(plist, format: format)
    }

    @discardableResult
    private func writeRaw(_ object: Any, format: PropertyListSerialization.PropertyListFormat = .binary) throws -> Data {
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: format, options: 0)
        try data.write(to: plistURL)
        return data
    }

    private func readPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: plistURL)
        return try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
    }

    private func readApps() throws -> [[String: Any]] {
        try XCTUnwrap(try readPlist()["persistent-apps"] as? [[String: Any]])
    }

    private func bundleIDs(_ entries: [[String: Any]]) -> [String] {
        entries.compactMap { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String }
    }

    private func guids(_ entries: [[String: Any]]) -> [String] {
        entries.compactMap { ($0["GUID"] as? NSNumber)?.stringValue }
    }

    private func fileBytes() throws -> Data { try Data(contentsOf: plistURL) }

    private func format(of data: Data) throws -> PropertyListSerialization.PropertyListFormat {
        var format = PropertyListSerialization.PropertyListFormat.binary
        _ = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        return format
    }

    private func editor() -> DockEditorService { DockEditorService(dockPlistURL: plistURL) }

    private func directoryContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    // MARK: - setPinnedApp: refusals

    func testFinderCanNeverBeUnpinned() throws {
        let original = try write(apps: [appEntry(guid: 1, bundleID: "com.apple.finder"), appEntry(guid: 2, bundleID: "a")])
        XCTAssertFalse(editor().setPinnedApp(bundleIdentifier: "com.apple.finder", pinned: false))
        XCTAssertFalse(editor().removePinnedApp(bundleIdentifier: "com.apple.finder"))
        XCTAssertEqual(try fileBytes(), original)
    }

    func testFinderCanNeverBePinned() throws {
        let original = try write(apps: [], extra: ["recent-apps": [appEntry(bundleID: "com.apple.finder")]])
        XCTAssertFalse(editor().setPinnedApp(bundleIdentifier: "com.apple.finder", pinned: true))
        XCTAssertEqual(try fileBytes(), original)
    }

    func testEmptyBundleIdentifierIsRefusedWithoutOpeningTheFile() {
        // The plist does not exist: if the guard were missing the call would
        // still return false, so also assert no file was created.
        XCTAssertFalse(editor().setPinnedApp(bundleIdentifier: "", pinned: true))
        XCTAssertFalse(editor().setPinnedApp(bundleIdentifier: "", pinned: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL.path))
    }

    func testEmptyBundleIdentifierDoesNotMatchEntriesWithoutOne() throws {
        let entry: [String: Any] = ["GUID": 1, "tile-type": "spacer-tile"]
        let original = try write(apps: [entry])
        XCTAssertFalse(editor().setPinnedApp(bundleIdentifier: "", pinned: false))
        XCTAssertEqual(try fileBytes(), original)
    }

    // MARK: - setPinnedApp: remove

    func testRemoveDeletesOnlyTheMatchingEntryAndKeepsOrder() throws {
        try write(apps: [
            appEntry(guid: 1, bundleID: "a"), appEntry(guid: 2, bundleID: "b"), appEntry(guid: 3, bundleID: "c"),
        ])
        XCTAssertTrue(editor().setPinnedApp(bundleIdentifier: "b", pinned: false))
        let apps = try readApps()
        XCTAssertEqual(bundleIDs(apps), ["a", "c"])
        XCTAssertEqual(guids(apps), ["1", "3"])
    }

    func testRemoveOfUnpinnedAppReturnsFalseAndLeavesFileUntouched() throws {
        let original = try write(apps: [appEntry(guid: 1, bundleID: "a")])
        XCTAssertFalse(editor().setPinnedApp(bundleIdentifier: "zzz", pinned: false))
        XCTAssertEqual(try fileBytes(), original)
    }

    func testRemoveTakesOnlyTheFirstOfDuplicateBundleIdentifiers() throws {
        try write(apps: [
            appEntry(guid: 1, bundleID: "dup"), appEntry(guid: 2, bundleID: "x"), appEntry(guid: 3, bundleID: "dup"),
        ])
        XCTAssertTrue(editor().setPinnedApp(bundleIdentifier: "dup", pinned: false))
        XCTAssertEqual(guids(try readApps()), ["2", "3"])
    }

    func testRemoveWithDuplicateGuidsDoesNotTrap() throws {
        try write(apps: [
            appEntry(guid: 9, bundleID: "a"), appEntry(guid: 9, bundleID: "b"), appEntry(guid: 9, bundleID: "c"),
        ])
        XCTAssertTrue(editor().setPinnedApp(bundleIdentifier: "b", pinned: false))
        XCTAssertEqual(bundleIDs(try readApps()), ["a", "c"])
    }

    func testRemoveByRealBundleURLWhenEntryHasNoBundleIdentifier() throws {
        let path = "/System/Applications/Calculator.app"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "Calculator.app not installed")
        let entry: [String: Any] = [
            "GUID": 5, "tile-type": "file-tile",
            "tile-data": ["file-data": ["_CFURLString": URL(fileURLWithPath: path).absoluteString]],
        ]
        try write(apps: [entry, appEntry(guid: 6, bundleID: "keep")])
        XCTAssertTrue(editor().setPinnedApp(bundleIdentifier: "com.apple.calculator", pinned: false))
        XCTAssertEqual(guids(try readApps()), ["6"])
    }

    func testEntryWithNonFileURLDoesNotRaiseDuringLookup() throws {
        // Regression: Bundle(url:) raises for a non-file URL, and entries are
        // scanned for every pin/unpin.
        let hostile: [String: Any] = [
            "GUID": 1, "tile-type": "file-tile",
            "tile-data": ["file-data": ["_CFURLString": "https://example.com/Evil.app"]],
        ]
        let original = try write(apps: [hostile, appEntry(guid: 2, bundleID: "a")])
        XCTAssertFalse(editor().setPinnedApp(bundleIdentifier: "com.example.nope", pinned: false))
        XCTAssertEqual(try fileBytes(), original)
        XCTAssertTrue(editor().setPinnedApp(bundleIdentifier: "a", pinned: false))
        XCTAssertEqual(guids(try readApps()), ["1"])
    }

    func testRemoveSurvivesEntriesOfEveryHostileShape() throws {
        let hostile: [[String: Any]] = [
            [:],
            ["tile-type": 5],
            ["tile-type": "file-tile", "tile-data": "x"],
            ["tile-type": "file-tile", "tile-data": ["bundle-identifier": 7, "file-data": ["_CFURLString": 9]]],
            ["tile-type": "file-tile", "tile-data": ["file-data": ["_CFURLString": ""]]],
            ["tile-type": "file-tile", "tile-data": ["file-data": ["_CFURLString": "file:///a/../../b"]]],
            ["tile-type": "file-tile", "tile-data": ["file-data": ["_CFURLString": "file:///with space/\u{00E9}.app"]]],
            appEntry(guid: 100, bundleID: "target"),
        ]
        try write(apps: hostile)
        XCTAssertTrue(editor().setPinnedApp(bundleIdentifier: "target", pinned: false))
        XCTAssertEqual(try readApps().count, hostile.count - 1)
    }

    // MARK: - setPinnedApp: add

    func testPinCopiesTheRecentAppEntryWithAFreshGuid() throws {
        let recent = appEntry(guid: 424_242, bundleID: "com.example.recent", label: "Recent App")
        try write(
            apps: [appEntry(guid: 1, bundleID: "a")],
            extra: ["recent-apps": [recent]]
        )
        XCTAssertTrue(editor().setPinnedApp(bundleIdentifier: "com.example.recent", pinned: true))
        let apps = try readApps()
        XCTAssertEqual(bundleIDs(apps), ["a", "com.example.recent"])
        let added = try XCTUnwrap(apps.last)
        let guid = try XCTUnwrap((added["GUID"] as? NSNumber)?.int64Value)
        XCTAssertTrue((1...Int64(UInt32.max)).contains(guid))
        XCTAssertNotEqual(guid, 424_242, "a pinned copy must not reuse the recent entry's GUID")
        let data = try XCTUnwrap(added["tile-data"] as? [String: Any])
        XCTAssertEqual(data["file-label"] as? String, "Recent App")
    }

    func testPinOfAnAlreadyPinnedAppIsRefused() throws {
        let original = try write(
            apps: [appEntry(guid: 1, bundleID: "a")],
            extra: ["recent-apps": [appEntry(bundleID: "a")]]
        )
        XCTAssertFalse(editor().setPinnedApp(bundleIdentifier: "a", pinned: true))
        XCTAssertEqual(try fileBytes(), original)
    }

    func testPinOfAnUnknownAppIsRefused() throws {
        let original = try write(apps: [appEntry(guid: 1, bundleID: "a")])
        XCTAssertFalse(editor().setPinnedApp(bundleIdentifier: "no.such.app.\(UUID().uuidString)", pinned: true))
        XCTAssertEqual(try fileBytes(), original)
    }

    func testRepeatedPinOnlyAddsOnce() throws {
        try write(apps: [], extra: ["recent-apps": [appEntry(bundleID: "r")]])
        XCTAssertTrue(editor().setPinnedApp(bundleIdentifier: "r", pinned: true))
        XCTAssertFalse(editor().setPinnedApp(bundleIdentifier: "r", pinned: true))
        XCTAssertEqual(bundleIDs(try readApps()), ["r"])
    }

    func testPinThenUnpinRoundTrips() throws {
        try write(apps: [appEntry(guid: 1, bundleID: "a")], extra: ["recent-apps": [appEntry(bundleID: "r")]])
        XCTAssertTrue(editor().setPinnedApp(bundleIdentifier: "r", pinned: true))
        XCTAssertTrue(editor().setPinnedApp(bundleIdentifier: "r", pinned: false))
        XCTAssertEqual(bundleIDs(try readApps()), ["a"])
    }

    // MARK: - Structure of the plist

    func testMissingPersistentAppsIsRefused() throws {
        let original = try write(apps: nil, extra: ["tilesize": 48])
        XCTAssertFalse(editor().setPinnedApp(bundleIdentifier: "a", pinned: false))
        XCTAssertFalse(editor().setPinnedItemOrder(ids: ["1"]))
        XCTAssertEqual(try fileBytes(), original)
    }

    func testWrongTypedPersistentAppsIsRefused() throws {
        for value in ["a string", 5, ["x", "y"], ["k": "v"]] as [Any] {
            let original = try writeRaw(["persistent-apps": value])
            XCTAssertFalse(editor().setPinnedApp(bundleIdentifier: "a", pinned: false), "\(value)")
            XCTAssertFalse(editor().setPinnedItemOrder(ids: ["1"]), "\(value)")
            XCTAssertEqual(try fileBytes(), original)
        }
    }

    func testOtherKeysAndSectionsSurviveARewrite() throws {
        let others: [[String: Any]] = [["GUID": 50, "tile-type": "directory-tile", "tile-data": ["file-label": "Downloads"]]]
        try write(
            apps: [appEntry(guid: 1, bundleID: "a"), appEntry(guid: 2, bundleID: "b")],
            others: others,
            extra: [
                "tilesize": 64, "autohide": true, "orientation": "left",
                "nested": ["deep": ["list": [1, 2, 3]]],
                "blob": Data([0, 1, 2, 255]),
                "stamp": Date(timeIntervalSince1970: 1_000_000),
            ]
        )
        XCTAssertTrue(editor().setPinnedApp(bundleIdentifier: "a", pinned: false))
        let plist = try readPlist()
        XCTAssertEqual(plist["tilesize"] as? Int, 64)
        XCTAssertEqual(plist["autohide"] as? Bool, true)
        XCTAssertEqual(plist["orientation"] as? String, "left")
        XCTAssertEqual((plist["nested"] as? NSDictionary), ["deep": ["list": [1, 2, 3]]] as NSDictionary)
        XCTAssertEqual(plist["blob"] as? Data, Data([0, 1, 2, 255]))
        XCTAssertEqual(plist["stamp"] as? Date, Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual((plist["persistent-others"] as? [[String: Any]])?.count, 1)
    }

    func testBinaryFormatIsPreserved() throws {
        try write(apps: [appEntry(guid: 1, bundleID: "a"), appEntry(guid: 2, bundleID: "b")], format: .binary)
        XCTAssertTrue(editor().setPinnedApp(bundleIdentifier: "a", pinned: false))
        let data = try fileBytes()
        XCTAssertEqual(String(decoding: data.prefix(6), as: UTF8.self), "bplist")
        XCTAssertEqual(try format(of: data), .binary)
    }

    func testXMLFormatIsPreserved() throws {
        try write(apps: [appEntry(guid: 1, bundleID: "a"), appEntry(guid: 2, bundleID: "b")], format: .xml)
        XCTAssertTrue(editor().setPinnedApp(bundleIdentifier: "a", pinned: false))
        let data = try fileBytes()
        XCTAssertTrue(String(decoding: data.prefix(5), as: UTF8.self).hasPrefix("<?xml"))
        XCTAssertEqual(try format(of: data), .xml)
    }

    func testXMLFormatIsPreservedOnReorder() throws {
        try write(apps: [appEntry(guid: 1, bundleID: "a"), appEntry(guid: 2, bundleID: "b")], format: .xml)
        XCTAssertTrue(editor().setPinnedItemOrder(ids: ["2", "1"]))
        XCTAssertEqual(try format(of: try fileBytes()), .xml)
    }

    // MARK: - Unreadable input

    func testMissingPlistReturnsFalseAndCreatesNothing() throws {
        XCTAssertFalse(editor().setPinnedApp(bundleIdentifier: "a", pinned: false))
        XCTAssertFalse(editor().setPinnedApp(bundleIdentifier: "a", pinned: true))
        XCTAssertFalse(editor().setPinnedItemOrder(ids: ["1", "2"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL.path))
        XCTAssertEqual(try directoryContents(), [])
    }

    func testUnreadableContentsAreRefusedAndLeftByteIdentical() throws {
        let valid = try PropertyListSerialization.data(
            fromPropertyList: ["persistent-apps": [appEntry(guid: 1, bundleID: "a")]], format: .binary, options: 0
        )
        let samples: [(String, Data)] = [
            ("empty", Data()),
            ("one byte", Data([0x62])),
            ("garbage", Data((0..<256).map { UInt8($0) })),
            ("truncated binary", valid.prefix(valid.count / 2)),
            ("header only", Data("bplist00".utf8)),
            ("truncated xml", Data("<?xml version=\"1.0\"?><plist><dict><key>persistent-apps</key><array>".utf8)),
            ("json", Data(#"{"persistent-apps": []}"#.utf8)),
            ("array top level", try PropertyListSerialization.data(fromPropertyList: [1, 2, 3], format: .binary, options: 0)),
            ("string top level", try PropertyListSerialization.data(fromPropertyList: "text", format: .xml, options: 0)),
        ]
        for (name, bytes) in samples {
            try bytes.write(to: plistURL)
            XCTAssertFalse(editor().setPinnedApp(bundleIdentifier: "a", pinned: false), name)
            XCTAssertFalse(editor().setPinnedItemOrder(ids: ["1"]), name)
            XCTAssertEqual(try fileBytes(), bytes, "\(name) must be left byte-identical")
        }
    }

    func testDirectoryInPlaceOfPlistIsRefused() throws {
        try FileManager.default.createDirectory(at: plistURL, withIntermediateDirectories: false)
        XCTAssertFalse(editor().setPinnedApp(bundleIdentifier: "a", pinned: false))
        XCTAssertFalse(editor().setPinnedItemOrder(ids: ["1"]))
    }

    // MARK: - Atomic write

    func testSuccessfulWriteLeavesNoTemporaryFilesBehind() throws {
        try write(apps: [appEntry(guid: 1, bundleID: "a"), appEntry(guid: 2, bundleID: "b")])
        XCTAssertTrue(editor().setPinnedApp(bundleIdentifier: "a", pinned: false))
        XCTAssertEqual(try directoryContents(), ["com.apple.dock.plist"])
    }

    func testFailedWriteInReadOnlyDirectoryLeavesOriginalIntactAndNoPartialFile() throws {
        let original = try write(apps: [appEntry(guid: 1, bundleID: "a"), appEntry(guid: 2, bundleID: "b")])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: directory.path), "directory is still writable (running as root?)")
        XCTAssertFalse(editor().setPinnedApp(bundleIdentifier: "a", pinned: false))
        XCTAssertFalse(editor().setPinnedItemOrder(ids: ["2", "1"]))
        XCTAssertEqual(try fileBytes(), original)
        XCTAssertEqual(try directoryContents(), ["com.apple.dock.plist"])
    }

    func testWriteReplacesTheFileInPlaceWithoutChangingItsLocation() throws {
        try write(apps: [appEntry(guid: 1, bundleID: "a"), appEntry(guid: 2, bundleID: "b")])
        XCTAssertTrue(editor().setPinnedApp(bundleIdentifier: "b", pinned: false))
        XCTAssertEqual(try directoryContents(), ["com.apple.dock.plist"])
        XCTAssertEqual(bundleIDs(try readApps()), ["a"])
    }

    // MARK: - setPinnedItemOrder

    func testEmptyOrderIsRefused() throws {
        let original = try write(apps: [appEntry(guid: 1, bundleID: "a")])
        XCTAssertFalse(editor().setPinnedItemOrder(ids: []))
        XCTAssertEqual(try fileBytes(), original)
    }

    func testReorderAppliesAValidPermutation() throws {
        try write(apps: [
            appEntry(guid: 1, bundleID: "a"), appEntry(guid: 2, bundleID: "b"), appEntry(guid: 3, bundleID: "c"),
        ])
        XCTAssertTrue(editor().setPinnedItemOrder(ids: ["3", "1", "2"]))
        XCTAssertEqual(bundleIDs(try readApps()), ["c", "a", "b"])
    }

    func testReorderToTheSameOrderSucceedsAndKeepsEntries() throws {
        try write(apps: [appEntry(guid: 1, bundleID: "a"), appEntry(guid: 2, bundleID: "b")])
        XCTAssertTrue(editor().setPinnedItemOrder(ids: ["1", "2"]))
        XCTAssertEqual(bundleIDs(try readApps()), ["a", "b"])
    }

    func testReorderOfASingleEntry() throws {
        try write(apps: [appEntry(guid: 7, bundleID: "only")])
        XCTAssertTrue(editor().setPinnedItemOrder(ids: ["7"]))
        XCTAssertEqual(bundleIDs(try readApps()), ["only"])
    }

    func testReorderKeepsEveryEntryIntactNotJustTheBundleID() throws {
        let entries = [appEntry(guid: 1, bundleID: "a", label: "A label"), appEntry(guid: 2, bundleID: "b", label: "B label")]
        try write(apps: entries)
        XCTAssertTrue(editor().setPinnedItemOrder(ids: ["2", "1"]))
        let apps = try readApps()
        XCTAssertEqual(apps.map { NSDictionary(dictionary: $0) }, [NSDictionary(dictionary: entries[1]), NSDictionary(dictionary: entries[0])])
    }

    func testReorderWithTooFewIDsIsRefused() throws {
        let original = try write(apps: [appEntry(guid: 1, bundleID: "a"), appEntry(guid: 2, bundleID: "b")])
        XCTAssertFalse(editor().setPinnedItemOrder(ids: ["1"]))
        XCTAssertEqual(try fileBytes(), original)
    }

    func testReorderWithTooManyIDsIsRefused() throws {
        let original = try write(apps: [appEntry(guid: 1, bundleID: "a"), appEntry(guid: 2, bundleID: "b")])
        XCTAssertFalse(editor().setPinnedItemOrder(ids: ["1", "2", "3"]))
        XCTAssertEqual(try fileBytes(), original)
    }

    func testReorderWithUnknownIDIsRefused() throws {
        let original = try write(apps: [appEntry(guid: 1, bundleID: "a"), appEntry(guid: 2, bundleID: "b")])
        XCTAssertFalse(editor().setPinnedItemOrder(ids: ["1", "999"]))
        XCTAssertFalse(editor().setPinnedItemOrder(ids: ["", ""]))
        XCTAssertFalse(editor().setPinnedItemOrder(ids: ["1", ""]))
        XCTAssertEqual(try fileBytes(), original)
    }

    func testReorderWithIDsInTheWrongNamespaceIsRefused() throws {
        // Wharf's own tile ids are prefixed ("pinned:..."); the editor takes
        // raw plist ids and must not guess.
        let original = try write(apps: [appEntry(guid: 1, bundleID: "a"), appEntry(guid: 2, bundleID: "b")])
        XCTAssertFalse(editor().setPinnedItemOrder(ids: ["pinned:1", "pinned:2"]))
        XCTAssertEqual(try fileBytes(), original)
    }

    func testReorderWithRepeatedIDsMustNotDropAnApp() throws {
        // Two distinct apps, request names app 1 twice. A correct editor
        // refuses (or preserves both); silently writing [a, a] loses app b
        // from the user's real Dock.
        let original = try write(apps: [appEntry(guid: 1, bundleID: "a"), appEntry(guid: 2, bundleID: "b")])
        XCTAssertFalse(editor().setPinnedItemOrder(ids: ["1", "1"]))
        XCTAssertEqual(try fileBytes(), original)
        XCTAssertEqual(Set(bundleIDs(try readApps())), ["a", "b"])
    }

    func testReorderWithDuplicateGuidsInThePlistDoesNotTrap() throws {
        // Regression for the launch crash: duplicate GUIDs in persistent-apps.
        try write(apps: [
            appEntry(guid: 5, bundleID: "a"), appEntry(guid: 5, bundleID: "b"), appEntry(guid: 6, bundleID: "c"),
        ])
        let result = editor().setPinnedItemOrder(ids: ["6", "5", "5"])
        // Whatever it decides, the file must still be a readable plist.
        XCTAssertNoThrow(try readApps())
        _ = result
    }

    func testReorderWithDuplicateGuidsMustNotLoseEntries() throws {
        try write(apps: [
            appEntry(guid: 5, bundleID: "a"), appEntry(guid: 5, bundleID: "b"), appEntry(guid: 6, bundleID: "c"),
        ])
        XCTAssertTrue(editor().setPinnedItemOrder(ids: ["6", "5", "5"]))
        XCTAssertEqual(bundleIDs(try readApps()), ["c", "a", "b"])
    }

    func testReorderFirstWinsForDuplicateGuids() throws {
        try write(apps: [
            appEntry(guid: 5, bundleID: "first"), appEntry(guid: 5, bundleID: "second"), appEntry(guid: 6, bundleID: "other"),
        ])
        // The call may refuse an ambiguous request; if it applies one, the
        // first entry with a shared GUID is the one that is looked up.
        if editor().setPinnedItemOrder(ids: ["6", "5", "5"]) {
            XCTAssertEqual(bundleIDs(try readApps()).first, "other")
            XCTAssertEqual(bundleIDs(try readApps()).dropFirst().first, "first")
        }
    }

    func testReorderOfAllIdenticalGuidsDoesNotTrap() throws {
        let entries = (0..<50).map { appEntry(guid: 1, bundleID: "app\($0)") }
        try write(apps: entries)
        _ = editor().setPinnedItemOrder(ids: Array(repeating: "1", count: 50))
        XCTAssertNoThrow(try readApps())
    }

    func testReorderOfEntriesWithoutGuidUsesSignatureIDs() throws {
        let entries = [appEntry(bundleID: "a"), appEntry(bundleID: "b"), appEntry(bundleID: "c")]
        try write(apps: entries)
        let service = editor()
        let ids = entries.enumerated().map { service.pinnedItemID(in: $1, at: $0) }
        XCTAssertEqual(Set(ids).count, 3)
        XCTAssertTrue(service.setPinnedItemOrder(ids: [ids[2], ids[0], ids[1]]))
        XCTAssertEqual(bundleIDs(try readApps()), ["c", "a", "b"])
    }

    func testReorderOfIdenticalEntriesWithoutGuidStaysDistinctByIndex() throws {
        let entries = [appEntry(bundleID: "same"), appEntry(bundleID: "same"), appEntry(bundleID: "same")]
        try write(apps: entries)
        let service = editor()
        let ids = entries.enumerated().map { service.pinnedItemID(in: $1, at: $0) }
        XCTAssertEqual(Set(ids).count, 3, "the index keeps otherwise identical entries apart")
        XCTAssertTrue(service.setPinnedItemOrder(ids: ids.reversed()))
    }

    func testReorderWithMixedGuidAndGuidlessEntries() throws {
        let entries = [appEntry(guid: 10, bundleID: "a"), appEntry(bundleID: "b"), appEntry(guid: 30, bundleID: "c")]
        try write(apps: entries)
        let service = editor()
        let ids = entries.enumerated().map { service.pinnedItemID(in: $1, at: $0) }
        XCTAssertTrue(service.setPinnedItemOrder(ids: [ids[1], ids[2], ids[0]]))
        XCTAssertEqual(bundleIDs(try readApps()), ["b", "c", "a"])
    }

    func testReorderWithExtremeGuidValues() throws {
        let entries = [
            appEntry(guid: NSNumber(value: Int64.max), bundleID: "max"),
            appEntry(guid: NSNumber(value: Int64.min), bundleID: "min"),
            appEntry(guid: NSNumber(value: 0), bundleID: "zero"),
            appEntry(guid: NSNumber(value: -1), bundleID: "neg"),
        ]
        try write(apps: entries)
        XCTAssertTrue(editor().setPinnedItemOrder(ids: [
            "-1", "0", "-9223372036854775808", "9223372036854775807",
        ]))
        XCTAssertEqual(bundleIDs(try readApps()), ["neg", "zero", "min", "max"])
    }

    func testReorderLeavesOtherSectionsAlone() throws {
        let others: [[String: Any]] = [["GUID": 99, "tile-type": "directory-tile", "tile-data": ["file-label": "D"]]]
        try write(apps: [appEntry(guid: 1, bundleID: "a"), appEntry(guid: 2, bundleID: "b")], others: others, extra: ["tilesize": 40])
        XCTAssertTrue(editor().setPinnedItemOrder(ids: ["2", "1"]))
        let plist = try readPlist()
        XCTAssertEqual(plist["tilesize"] as? Int, 40)
        XCTAssertEqual(guids(try XCTUnwrap(plist["persistent-others"] as? [[String: Any]])), ["99"])
    }

    func testReorderOfAThousandEntries() throws {
        let entries = (0..<1_000).map { appEntry(guid: $0 + 1, bundleID: "app\($0)") }
        try write(apps: entries)
        let ids = (1...1_000).reversed().map(String.init)
        XCTAssertTrue(editor().setPinnedItemOrder(ids: ids))
        let after = bundleIDs(try readApps())
        XCTAssertEqual(after.first, "app999")
        XCTAssertEqual(after.last, "app0")
        XCTAssertEqual(Set(after).count, 1_000)
    }

    func testReorderOfTenThousandEntriesWithAllDistinctGuids() throws {
        let entries = (0..<10_000).map { appEntry(guid: $0, bundleID: "a\($0)") }
        try write(apps: entries, format: .binary)
        let ids = entries.indices.map(String.init)
        XCTAssertTrue(editor().setPinnedItemOrder(ids: ids.reversed()))
        XCTAssertEqual(try readApps().count, 10_000)
    }

    // MARK: - pinnedItemID rules

    func testPinnedItemIDPrefersTheGuid() {
        let id = editor().pinnedItemID(in: ["GUID": NSNumber(value: 12_345), "tile-type": "file-tile"], at: 4)
        XCTAssertEqual(id, "12345")
    }

    func testPinnedItemIDIgnoresNonNumericGuid() {
        let id = editor().pinnedItemID(in: ["GUID": "12345", "tile-type": "spacer-tile"], at: 2)
        XCTAssertEqual(id, "persistent-apps:2:spacer-tile")
    }

    func testPinnedItemIDSignatureOrderAndEscaping() {
        let entry = appEntry(bundleID: "com.a:b", label: "My: App")
        let id = editor().pinnedItemID(in: entry, at: 1)
        XCTAssertEqual(id, "persistent-apps:1:file-tile:com.a_b:file_///Applications/com.a_b.app/:My_ App")
    }

    func testPinnedItemIDForEmptyEntry() {
        XCTAssertEqual(editor().pinnedItemID(in: [:], at: 0), "persistent-apps:0:unknown")
    }

    func testPinnedItemIDEscapesColonsInAllFields() {
        let entry: [String: Any] = [
            "tile-type": "file-tile",
            "tile-data": [
                "bundle-identifier": "x:y",
                "file-label": "p:q",
                "file-data": ["_CFURLString": "u:v"],
            ] as [String: Any],
        ]
        XCTAssertEqual(editor().pinnedItemID(in: entry, at: 3), "persistent-apps:3:file-tile:x_y:u_v:p_q")
    }

    func testPinnedItemIDChangesWithIndex() {
        let entry = appEntry(bundleID: "a")
        XCTAssertNotEqual(editor().pinnedItemID(in: entry, at: 0), editor().pinnedItemID(in: entry, at: 1))
    }

    func testPinnedItemIDToleratesWrongTypes() {
        let entries: [[String: Any]] = [
            ["tile-type": 1, "tile-data": 2],
            ["tile-type": "file-tile", "tile-data": ["file-data": 3, "bundle-identifier": [1], "file-label": 4]],
        ]
        for (index, entry) in entries.enumerated() {
            XCTAssertTrue(editor().pinnedItemID(in: entry, at: index).hasPrefix("persistent-apps:\(index):"))
        }
    }

    func testPinnedAppBundleIdentifierPrefersExplicitIdentifier() {
        let entry: [String: Any] = [
            "tile-data": ["bundle-identifier": "explicit", "file-data": ["_CFURLString": "file:///System/Applications/Calculator.app"]],
        ]
        XCTAssertEqual(editor().pinnedAppBundleIdentifier(in: entry), "explicit")
    }

    func testPinnedAppBundleIdentifierOfEntryWithoutDataIsNil() {
        XCTAssertNil(editor().pinnedAppBundleIdentifier(in: [:]))
        XCTAssertNil(editor().pinnedAppBundleIdentifier(in: ["tile-data": "x"]))
        XCTAssertNil(editor().pinnedAppBundleIdentifier(in: ["tile-data": ["file-data": ["_CFURLString": 5]]]))
    }

    func testPinnedAppBundleIdentifierIgnoresNonFileURLs() {
        let entry: [String: Any] = ["tile-data": ["file-data": ["_CFURLString": "https://example.com/X.app"]]]
        XCTAssertNil(editor().pinnedAppBundleIdentifier(in: entry))
    }
}
