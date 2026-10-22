import XCTest
@testable import Wharf

/// The system Dock plist (`com.apple.dock`) is writable by any process running
/// as the user, so everything `TileStore` parses out of it is untrusted input.
/// These tests feed it real-shaped and hostile entries and assert it neither
/// traps nor invents data.
@MainActor
final class TileStoreParsingTests: XCTestCase {
    // MARK: - Builders

    private func fileURLString(_ path: String) -> String {
        URL(fileURLWithPath: path).absoluteString
    }

    private func appEntry(
        guid: Any? = nil,
        bundleID: String? = "com.example.app",
        label: String? = "Example",
        urlString: String? = "file:///Applications/Example.app/"
    ) -> [String: Any] {
        var data: [String: Any] = [:]
        if let bundleID { data["bundle-identifier"] = bundleID }
        if let label { data["file-label"] = label }
        if let urlString { data["file-data"] = ["_CFURLString": urlString, "_CFURLStringType": 15] }
        var entry: [String: Any] = ["tile-type": "file-tile", "tile-data": data]
        if let guid { entry["GUID"] = guid }
        return entry
    }

    private func folderEntry(
        guid: Any? = nil,
        label: String? = "Downloads",
        urlString: Any? = "file:///Users/test/Downloads/",
        displayas: Any? = nil,
        showas: Any? = nil
    ) -> [String: Any] {
        var data: [String: Any] = [:]
        if let label { data["file-label"] = label }
        if let urlString { data["file-data"] = ["_CFURLString": urlString, "_CFURLStringType": 15] }
        if let displayas { data["displayas"] = displayas }
        if let showas { data["showas"] = showas }
        var entry: [String: Any] = ["tile-type": "directory-tile", "tile-data": data]
        if let guid { entry["GUID"] = guid }
        return entry
    }

    private func parse(_ entry: [String: Any], fallback: String = "fallback") -> Tile? {
        TileStore.parse(entry: entry, fallbackID: fallback)
    }

    private func appTile(_ tile: Tile?, file: StaticString = #filePath, line: UInt = #line) -> AppTile? {
        guard let tile, case .app(let app) = tile.content else {
            XCTFail("expected an app tile", file: file, line: line)
            return nil
        }
        return app
    }

    private func folderTile(_ tile: Tile?, file: StaticString = #filePath, line: UInt = #line) -> FolderTile? {
        guard let tile, case .folder(let folder) = tile.content else {
            XCTFail("expected a folder tile", file: file, line: line)
            return nil
        }
        return folder
    }

    // MARK: - tile-type dispatch

    func testFileTileParsesToAppTile() {
        let tile = parse(appEntry(guid: NSNumber(value: 42)))
        XCTAssertEqual(tile?.id, "42")
        let app = appTile(tile)
        XCTAssertEqual(app?.bundleIdentifier, "com.example.app")
        XCTAssertEqual(app?.displayName, "Example")
    }

    func testDirectoryTileParsesToFolderTile() {
        let tile = parse(folderEntry(guid: NSNumber(value: 7)))
        XCTAssertEqual(tile?.id, "7")
        let folder = folderTile(tile)
        XCTAssertEqual(folder?.displayName, "Downloads")
        XCTAssertEqual(folder?.url.absoluteString, "file:///Users/test/Downloads/")
    }

    func testSpacerTilesParseToSpacer() {
        for type in ["spacer-tile", "small-spacer-tile"] {
            let tile = parse(["tile-type": type, "GUID": NSNumber(value: 9)])
            XCTAssertEqual(tile, Tile(id: "9", content: .spacer), type)
        }
    }

    func testSpacerTileWithoutTileDataStillParses() {
        XCTAssertEqual(parse(["tile-type": "spacer-tile"]), Tile(id: "fallback", content: .spacer))
    }

    func testUnsupportedTileTypesAreSkipped() {
        let types: [Any] = ["url-tile", "recent-tile", "", " ", "FILE-TILE", "file-tile ", "directory", 7, true, NSNull(), ["file-tile"]]
        for type in types {
            XCTAssertNil(parse(["tile-type": type, "tile-data": [:] as [String: Any]]), "type \(type)")
        }
    }

    func testMissingTileTypeIsSkipped() {
        XCTAssertNil(parse([:]))
        XCTAssertNil(parse(["tile-data": ["file-label": "x"]]))
        XCTAssertNil(parse(["GUID": NSNumber(value: 1)]))
    }

    func testUrlTileIsSkippedEvenWithAFileURL() {
        let entry: [String: Any] = [
            "tile-type": "url-tile",
            "tile-data": ["label": "Apple", "url": ["_CFURLString": "https://apple.com", "_CFURLStringType": 15]],
        ]
        XCTAssertNil(parse(entry))
    }

    // MARK: - GUID handling

    func testGuidBecomesTheTileID() {
        let values: [(Any, String)] = [
            (NSNumber(value: 1), "1"),
            (NSNumber(value: 0), "0"),
            (NSNumber(value: -5), "-5"),
            (NSNumber(value: Int64.max), "9223372036854775807"),
            (NSNumber(value: Int64.min), "-9223372036854775808"),
            (NSNumber(value: UInt64.max), "18446744073709551615"),
            (NSNumber(value: 1.5), "1.5"),
            (NSNumber(value: true), "1"),
            (4_294_967_295 as Int, "4294967295"),
        ]
        for (guid, expected) in values {
            XCTAssertEqual(parse(["tile-type": "spacer-tile", "GUID": guid])?.id, expected, "guid \(guid)")
        }
    }

    func testNonNumericGuidFallsBackToTheFallbackID() {
        let values: [Any] = ["123", "", "abc", NSNull(), [1, 2], ["a": 1], Data([1, 2, 3]), Date(timeIntervalSince1970: 0)]
        for guid in values {
            XCTAssertEqual(
                parse(["tile-type": "spacer-tile", "GUID": guid], fallback: "fb")?.id,
                "fb",
                "guid \(guid)"
            )
        }
    }

    func testMissingGuidFallsBackToTheFallbackID() {
        XCTAssertEqual(parse(["tile-type": "spacer-tile"], fallback: "persistent-apps:3:spacer-tile")?.id, "persistent-apps:3:spacer-tile")
    }

    func testHugeGuidDoesNotTrap() {
        let tile = parse(["tile-type": "spacer-tile", "GUID": NSDecimalNumber(string: "999999999999999999999999999999")])
        XCTAssertNotNil(tile)
        XCTAssertFalse(tile?.id.isEmpty ?? true)
    }

    func testNaNAndInfiniteGuidsDoNotTrap() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertNotNil(parse(["tile-type": "spacer-tile", "GUID": NSNumber(value: value)]))
        }
    }

    // MARK: - App tile details

    func testAppLabelDefaultsToUnknown() {
        XCTAssertEqual(appTile(parse(appEntry(label: nil)))?.displayName, "Unknown")
    }

    func testAppWithoutBundleIDOrURLGetsAnEmptyBundleIdentifier() {
        let app = appTile(parse(appEntry(bundleID: nil, urlString: nil)))
        XCTAssertEqual(app?.bundleIdentifier, "")
    }

    func testExplicitBundleIDWinsOverURLInference() {
        let app = appTile(parse(appEntry(bundleID: "com.explicit", urlString: fileURLString("/System/Applications/Calculator.app"))))
        XCTAssertEqual(app?.bundleIdentifier, "com.explicit")
    }

    func testBundleIDIsInferredFromTheAppURL() throws {
        let path = "/System/Applications/Calculator.app"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "Calculator.app not installed")
        let app = appTile(parse(appEntry(bundleID: nil, urlString: fileURLString(path))))
        XCTAssertEqual(app?.bundleIdentifier, "com.apple.calculator")
    }

    func testNonStringBundleIDFallsBackToURLInference() throws {
        let path = "/System/Applications/Calculator.app"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "Calculator.app not installed")
        let entry: [String: Any] = [
            "tile-type": "file-tile",
            "tile-data": [
                "bundle-identifier": 42,
                "file-data": ["_CFURLString": fileURLString(path)],
            ],
        ]
        XCTAssertEqual(appTile(parse(entry))?.bundleIdentifier, "com.apple.calculator")
    }

    func testEmptyStringBundleIDIsKeptAsIs() {
        // An explicit empty string is still a String, so no inference happens.
        XCTAssertEqual(appTile(parse(appEntry(bundleID: "", urlString: nil)))?.bundleIdentifier, "")
    }

    func testFileTileWithWrongTypedTileDataStillYieldsAnEmptyApp() {
        let entry: [String: Any] = ["tile-type": "file-tile", "tile-data": "not a dictionary"]
        let app = appTile(parse(entry))
        XCTAssertEqual(app?.displayName, "Unknown")
        XCTAssertEqual(app?.bundleIdentifier, "")
    }

    func testFileTileWithWrongTypedFileDataAndLabel() {
        let entry: [String: Any] = [
            "tile-type": "file-tile",
            "tile-data": ["file-data": ["not", "a", "dict"], "file-label": 99, "bundle-identifier": ["x"]],
        ]
        let app = appTile(parse(entry))
        XCTAssertEqual(app?.displayName, "Unknown")
        XCTAssertEqual(app?.bundleIdentifier, "")
    }

    func testFileTileWithNonStringURLString() {
        for value in [42, true, ["x"], NSNull()] as [Any] {
            let entry: [String: Any] = [
                "tile-type": "file-tile",
                "tile-data": ["file-data": ["_CFURLString": value]],
            ]
            XCTAssertEqual(appTile(parse(entry))?.bundleIdentifier, "", "value \(value)")
        }
    }

    func testHostileURLStringsNeverTrapAndNeverInventABundleID() {
        let urls = [
            "",
            " ",
            "not a url",
            "http://example.com/Evil.app",
            "https://example.com",
            "ftp://x/y",
            "javascript:alert(1)",
            "file:///Applications/../../../../etc/passwd",
            "file:///Applications/Nonexistent%20App.app/",
            "file:///Applications/Non existent.app/",
            "file:///Applications/\u{00E9}\u{0301}\u{4E2D}\u{6587}.app/",
            "file:///Applications/\u{202E}gpj.app/",
            "file://" + String(repeating: "a", count: 100_000),
            "\u{0000}",
            "file:///%00",
            "file:///%",
            "%%%",
            "//",
            "file:",
        ]
        for url in urls {
            let tile = parse(appEntry(bundleID: nil, urlString: url))
            XCTAssertNotNil(tile, "url \(url.prefix(40))")
            if let app = appTile(tile) {
                XCTAssertEqual(app.bundleIdentifier, "", "url \(url.prefix(40))")
            }
        }
    }

    func testNonFileURLInAFileTileDoesNotRaiseFromBundleLookup() {
        // Regression: Bundle(url:) raises NSInvalidArgumentException for a
        // non-file URL, which crashed Wharf when a hostile plist entry had no
        // bundle-identifier and an http(s) _CFURLString.
        let entry = appEntry(bundleID: nil, label: "Evil", urlString: "https://example.com/Evil.app")
        let app = appTile(parse(entry))
        XCTAssertEqual(app?.bundleIdentifier, "")
        XCTAssertEqual(app?.displayName, "Evil")
        XCTAssertNil(TileStore.inferBundleIdentifier(from: URL(string: "https://example.com/Evil.app")))
    }

    func testVeryLongLabelAndBundleIDDoNotTrap() {
        let long = String(repeating: "x", count: 1_000_000)
        let app = appTile(parse(appEntry(bundleID: long, label: long)))
        XCTAssertEqual(app?.displayName.count, 1_000_000)
        XCTAssertEqual(app?.bundleIdentifier.count, 1_000_000)
    }

    func testUnicodeLabelIsPreserved() {
        let label = "\u{1F9ED} Caf\u{00E9} \u{4E2D}\u{6587} \u{202E}rtl"
        XCTAssertEqual(appTile(parse(appEntry(label: label)))?.displayName, label)
    }

    // MARK: - Folder tile details

    func testFolderLabelDefaultsToFolder() {
        XCTAssertEqual(folderTile(parse(folderEntry(label: nil)))?.displayName, "Folder")
    }

    func testFolderWithoutFileDataIsSkipped() {
        let entry: [String: Any] = ["tile-type": "directory-tile", "tile-data": ["file-label": "x"]]
        XCTAssertNil(parse(entry))
        XCTAssertNil(parse(["tile-type": "directory-tile"]))
    }

    func testFolderWithNonStringURLIsSkipped() {
        for value in [42, true, ["x"], NSNull()] as [Any] {
            XCTAssertNil(parse(folderEntry(urlString: value)), "value \(value)")
        }
    }

    func testFolderWithEmptyURLStringIsSkipped() {
        XCTAssertNil(parse(folderEntry(urlString: "")))
    }

    func testFolderURLWithSpacesAndUnicodeParsesWithoutTrapping() {
        let urls = [
            "file:///Users/test/My%20Folder/",
            "file:///Users/test/My Folder/",
            "file:///Users/test/\u{00E9}\u{4E2D}/",
            "file:///Users/test/../../etc/",
        ]
        for url in urls {
            // Either skipped or parsed; the contract is "never traps".
            _ = parse(folderEntry(urlString: url))
        }
    }

    func testFolderURLWithDotDotIsKeptVerbatimNotResolved() {
        let folder = folderTile(parse(folderEntry(urlString: "file:///Users/test/../../etc/")))
        XCTAssertEqual(folder?.url.absoluteString, "file:///Users/test/../../etc/")
    }

    func testFolderURLNeedNotBeAFileURL() {
        // Parsing does not validate scheme. Documented so a future validation
        // change is a deliberate one.
        let folder = folderTile(parse(folderEntry(urlString: "https://example.com/dir/")))
        XCTAssertEqual(folder?.url.scheme, "https")
    }

    func testFolderDisplayAsMapping() {
        let cases: [(Any?, FolderTileDisplayMode)] = [
            (nil, .contents),
            (NSNumber(value: 0), .contents),
            (NSNumber(value: 1), .folder),
            (NSNumber(value: 2), .contents),
            (NSNumber(value: -1), .contents),
            (NSNumber(value: 1.0), .folder),
            (NSNumber(value: 1.9), .folder),
            (NSNumber(value: true), .folder),
            ("1", .contents),
            ([1], .contents),
            (NSNull(), .contents),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(TileStore.parseFolderDisplayMode(from: raw), expected, "raw \(String(describing: raw))")
        }
    }

    func testFolderShowAsMapping() {
        let cases: [(Any?, FolderTileContentViewMode)] = [
            (nil, .grid),
            (NSNumber(value: 0), .grid),
            (NSNumber(value: 1), .grid),
            (NSNumber(value: 2), .grid),
            (NSNumber(value: 3), .list),
            (NSNumber(value: 4), .grid),
            (NSNumber(value: -3), .grid),
            (NSNumber(value: Int.max), .grid),
            ("3", .grid),
            (NSNull(), .grid),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(TileStore.parseFolderContentViewMode(from: raw), expected, "raw \(String(describing: raw))")
        }
    }

    func testFolderModesFlowThroughParse() {
        let folder = folderTile(parse(folderEntry(displayas: NSNumber(value: 1), showas: NSNumber(value: 3))))
        XCTAssertEqual(folder?.displayMode, .folder)
        XCTAssertEqual(folder?.contentViewMode, .list)
        XCTAssertEqual(folder?.sortMode, .dateAdded)
    }

    // MARK: - inferBundleIdentifier

    func testInferBundleIdentifierFromNilURL() {
        XCTAssertNil(TileStore.inferBundleIdentifier(from: nil))
    }

    func testInferBundleIdentifierFromMissingPath() {
        XCTAssertNil(TileStore.inferBundleIdentifier(from: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).app")))
    }

    func testInferBundleIdentifierFromPlainDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(TileStore.inferBundleIdentifier(from: dir))
    }

    func testInferBundleIdentifierFromRegularFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertNil(TileStore.inferBundleIdentifier(from: file))
    }

    func testInferBundleIdentifierFromRealBundle() throws {
        let url = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "Calculator.app not installed")
        XCTAssertEqual(TileStore.inferBundleIdentifier(from: url), "com.apple.calculator")
    }

    func testInferBundleIdentifierFromSyntheticBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundle = root.appendingPathComponent("Synthetic.app")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info: [String: Any] = ["CFBundleIdentifier": "com.test.synthetic", "CFBundlePackageType": "APPL"]
        try (info as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        XCTAssertEqual(TileStore.inferBundleIdentifier(from: bundle), "com.test.synthetic")
    }

    // MARK: - fallbackTileID

    func testFallbackIDWithFullSignature() {
        let entry = appEntry(bundleID: "com.example.app", label: "Example", urlString: "file:///Applications/Example.app/")
        XCTAssertEqual(
            TileStore.fallbackTileID(for: entry, at: 3, section: "persistent-apps"),
            "persistent-apps:3:file-tile:com.example.app:file_///Applications/Example.app/:Example"
        )
    }

    func testFallbackIDEscapesColonsInEveryField() {
        let entry = appEntry(bundleID: "a:b", label: "c:d", urlString: "e:f")
        XCTAssertEqual(
            TileStore.fallbackTileID(for: entry, at: 0, section: "s"),
            "s:0:file-tile:a_b:e_f:c_d"
        )
    }

    func testFallbackIDForEmptyEntryUsesUnknownType() {
        XCTAssertEqual(TileStore.fallbackTileID(for: [:], at: 5, section: "persistent-others"), "persistent-others:5:unknown")
    }

    func testFallbackIDForSpacerUsesTypeOnly() {
        XCTAssertEqual(
            TileStore.fallbackTileID(for: ["tile-type": "spacer-tile"], at: 2, section: "persistent-apps"),
            "persistent-apps:2:spacer-tile"
        )
    }

    func testFallbackIDDiffersByIndexForIdenticalEntries() {
        let entry = appEntry()
        let a = TileStore.fallbackTileID(for: entry, at: 0, section: "persistent-apps")
        let b = TileStore.fallbackTileID(for: entry, at: 1, section: "persistent-apps")
        XCTAssertNotEqual(a, b)
    }

    func testFallbackIDDiffersBySection() {
        let entry = appEntry()
        XCTAssertNotEqual(
            TileStore.fallbackTileID(for: entry, at: 0, section: "persistent-apps"),
            TileStore.fallbackTileID(for: entry, at: 0, section: "persistent-others")
        )
    }

    func testFallbackIDToleratesWrongTypes() {
        let entries: [[String: Any]] = [
            ["tile-type": 5],
            ["tile-type": "file-tile", "tile-data": "x"],
            ["tile-type": "file-tile", "tile-data": ["file-data": 5, "bundle-identifier": 5, "file-label": 5]],
            ["tile-type": "file-tile", "tile-data": ["file-data": ["_CFURLString": 5]]],
        ]
        for (index, entry) in entries.enumerated() {
            let id = TileStore.fallbackTileID(for: entry, at: index, section: "persistent-apps")
            XCTAssertTrue(id.hasPrefix("persistent-apps:\(index):"), id)
        }
    }

    func testFallbackIDForNegativeAndHugeIndex() {
        XCTAssertEqual(TileStore.fallbackTileID(for: [:], at: -1, section: "s"), "s:-1:unknown")
        XCTAssertEqual(TileStore.fallbackTileID(for: [:], at: Int.max, section: "s"), "s:\(Int.max):unknown")
    }

    // MARK: - parsedTiles (section pipeline)

    func testParsedTilesPreservesOrderAndSkipsUnsupported() {
        let plist: [String: Any] = [
            "persistent-apps": [
                appEntry(guid: NSNumber(value: 1), bundleID: "a"),
                ["tile-type": "url-tile"],
                ["tile-type": "spacer-tile", "GUID": NSNumber(value: 2)],
                appEntry(guid: NSNumber(value: 3), bundleID: "c"),
            ],
        ]
        let tiles = TileStore.parsedTiles(from: plist, section: "persistent-apps")
        XCTAssertEqual(tiles.map(\.id), ["1", "2", "3"])
    }

    func testParsedTilesFromMissingSectionIsEmpty() {
        XCTAssertEqual(TileStore.parsedTiles(from: [:], section: "persistent-apps"), [])
    }

    func testParsedTilesFromEmptyArrayIsEmpty() {
        XCTAssertEqual(TileStore.parsedTiles(from: ["persistent-apps": [[String: Any]]()], section: "persistent-apps"), [])
    }

    func testParsedTilesFromWrongTypedSectionIsEmpty() {
        let wrong: [Any] = ["str", 5, ["a": 1], [1, 2, 3], NSNull(), Data()]
        for value in wrong {
            XCTAssertEqual(TileStore.parsedTiles(from: ["persistent-apps": value], section: "persistent-apps"), [], "value \(value)")
        }
    }

    func testParsedTilesWithOneNonDictionaryElementReadsAsEmpty() {
        // The cast is all-or-nothing: a single hostile element hides the whole
        // section rather than only itself. Documented current behavior.
        let plist: [String: Any] = [
            "persistent-apps": [appEntry(guid: NSNumber(value: 1)), "garbage", appEntry(guid: NSNumber(value: 2))] as [Any],
        ]
        XCTAssertEqual(TileStore.parsedTiles(from: plist, section: "persistent-apps"), [])
    }

    func testParsedTilesUsesIndexBasedFallbackWhenGuidsAreMissing() {
        let plist: [String: Any] = [
            "persistent-others": [
                folderEntry(guid: nil, label: "A", urlString: "file:///a/"),
                folderEntry(guid: nil, label: "A", urlString: "file:///a/"),
            ],
        ]
        let tiles = TileStore.parsedTiles(from: plist, section: "persistent-others")
        XCTAssertEqual(tiles.count, 2)
        XCTAssertNotEqual(tiles[0].id, tiles[1].id, "identical entries must still get distinct fallback IDs")
    }

    func testParsedTilesKeepsDuplicateGuidsAndDownstreamDictionaryKeepsTheFirst() {
        // Regression: duplicate GUIDs in persistent-apps / persistent-others
        // crashed Wharf on every launch (Dictionary(uniqueKeysWithValues:)).
        let plist: [String: Any] = [
            "persistent-apps": [
                appEntry(guid: NSNumber(value: 77), bundleID: "first", label: "First"),
                appEntry(guid: NSNumber(value: 77), bundleID: "second", label: "Second"),
                appEntry(guid: NSNumber(value: 77), bundleID: "third", label: "Third"),
            ],
            "persistent-others": [
                folderEntry(guid: NSNumber(value: 5), label: "One", urlString: "file:///one/"),
                folderEntry(guid: NSNumber(value: 5), label: "Two", urlString: "file:///two/"),
            ],
        ]
        for section in ["persistent-apps", "persistent-others"] {
            let tiles = TileStore.parsedTiles(from: plist, section: section)
            XCTAssertGreaterThan(tiles.count, 1)
            let byID = DataIntegrityReporter.makeDictionary(tiles.map { ($0.id, $0) }, site: "test.\(section)")
            XCTAssertEqual(byID.count, 1)
            XCTAssertEqual(byID.values.first, tiles.first)
        }
    }

    func testParsedTilesHandlesTenThousandEntries() {
        let entries: [[String: Any]] = (0..<10_000).map { index in
            appEntry(guid: NSNumber(value: index), bundleID: "com.example.app\(index)", label: "App \(index)", urlString: nil)
        }
        let tiles = TileStore.parsedTiles(from: ["persistent-apps": entries], section: "persistent-apps")
        XCTAssertEqual(tiles.count, 10_000)
        XCTAssertEqual(tiles.first?.id, "0")
        XCTAssertEqual(tiles.last?.id, "9999")
    }

    func testParsedTilesHandlesTenThousandDuplicateGuids() {
        let entries: [[String: Any]] = (0..<10_000).map { index in
            appEntry(guid: NSNumber(value: 1), bundleID: "com.example.app\(index)", urlString: nil)
        }
        let tiles = TileStore.parsedTiles(from: ["persistent-apps": entries], section: "persistent-apps")
        XCTAssertEqual(tiles.count, 10_000)
        let byID = DataIntegrityReporter.makeDictionary(tiles.map { ($0.id, $0) }, site: "test.10k")
        XCTAssertEqual(byID.count, 1)
        XCTAssertEqual(appTile(byID["1"])?.bundleIdentifier, "com.example.app0")
    }

    func testParsedTilesDoesNotTrapOnMixedHostileEntries() {
        let hostile: [[String: Any]] = [
            [:],
            ["tile-type": NSNull()],
            ["tile-type": "file-tile", "GUID": NSNumber(value: UInt64.max), "tile-data": [:] as [String: Any]],
            ["tile-type": "directory-tile", "tile-data": ["file-data": ["_CFURLString": "file:///a/../b/"]]],
            ["tile-type": "spacer-tile", "GUID": -1],
            ["tile-type": "file-tile", "GUID": "abc", "tile-data": ["file-label": ""]],
        ]
        let tiles = TileStore.parsedTiles(from: ["persistent-apps": hostile], section: "persistent-apps")
        XCTAssertEqual(tiles.count, 4)
    }

    // MARK: - Reorder helper (shared by pinned and trailing reorder)

    func testReorderedFollowsRequestedOrder() {
        let tiles = ["a", "b", "c"].map { Tile(id: $0, content: .spacer) }
        let result = TileStore.reordered(tiles, by: ["c", "a", "b"], site: "t") { $0.id }
        XCTAssertEqual(result.map(\.id), ["c", "a", "b"])
    }

    func testReorderedSkipsUnknownIDs() {
        let tiles = ["a", "b"].map { Tile(id: $0, content: .spacer) }
        let result = TileStore.reordered(tiles, by: ["a", "zzz", "b"], site: "t") { $0.id }
        XCTAssertEqual(result.map(\.id), ["a", "b"])
    }

    func testReorderedWithDuplicateElementIDsHandsThemOutInOrderAndDoesNotTrap() {
        let tiles = [
            Tile(id: "dup", content: .spacer),
            Tile(id: "dup", content: .divider),
            Tile(id: "x", content: .trash),
        ]
        let result = TileStore.reordered(tiles, by: ["x", "dup"], site: "t") { $0.id }
        XCTAssertEqual(result, [tiles[2], tiles[0]])
        let both = TileStore.reordered(tiles, by: ["dup", "x", "dup"], site: "t") { $0.id }
        XCTAssertEqual(both, [tiles[0], tiles[2], tiles[1]])
    }

    func testReorderedWithEmptyInputs() {
        XCTAssertEqual(TileStore.reordered([Tile](), by: ["a"], site: "t") { $0.id }, [])
        XCTAssertEqual(TileStore.reordered([Tile(id: "a", content: .spacer)], by: [], site: "t") { $0.id }, [])
    }

    func testReorderedWithRepeatedRequestIDsUsesEachElementOnce() {
        // A repeated request id cannot yield the element twice, so the result
        // is shorter than the input and callers refuse it on the count check.
        let tiles = ["a", "b"].map { Tile(id: $0, content: .spacer) }
        let result = TileStore.reordered(tiles, by: ["a", "a"], site: "t") { $0.id }
        XCTAssertEqual(result.map(\.id), ["a"])
    }
}
