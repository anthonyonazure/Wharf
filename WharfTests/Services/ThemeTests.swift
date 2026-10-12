import AppKit
import XCTest
@testable import Wharf

// MARK: - Manifest model

final class ThemeManifestTests: XCTestCase {

    private func decode(_ json: String) throws -> ThemeManifest {
        try JSONDecoder().decode(ThemeManifest.self, from: Data(json.utf8))
    }

    private let minimal = #"{"schemaVersion": 1, "id": "demo", "name": "Demo", "appearance": {}}"#

    // MARK: Required and optional fields

    func testMinimalManifestDecodes() throws {
        let manifest = try decode(minimal)
        XCTAssertEqual(manifest.id, "demo")
        XCTAssertEqual(manifest.name, "Demo")
        XCTAssertNil(manifest.author)
        XCTAssertNil(manifest.behavior)
        XCTAssertNil(manifest.layout)
    }

    func testMissingRequiredFieldsAreRejected() {
        for json in [
            #"{"id": "x", "name": "n", "appearance": {}}"#,
            #"{"schemaVersion": 1, "name": "n", "appearance": {}}"#,
            #"{"schemaVersion": 1, "id": "x", "appearance": {}}"#,
            #"{"schemaVersion": 1, "id": "x", "name": "n"}"#,
            #"{}"#,
            #"[]"#,
        ] {
            XCTAssertThrowsError(try decode(json), json)
        }
    }

    func testWrongTypesForRequiredFieldsAreRejected() {
        for json in [
            #"{"schemaVersion": "1", "id": "x", "name": "n", "appearance": {}}"#,
            #"{"schemaVersion": 1, "id": 7, "name": "n", "appearance": {}}"#,
            #"{"schemaVersion": 1, "id": "x", "name": null, "appearance": {}}"#,
            #"{"schemaVersion": 1, "id": "x", "name": "n", "appearance": []}"#,
            #"{"schemaVersion": 1.5, "id": "x", "name": "n", "appearance": {}}"#,
        ] {
            XCTAssertThrowsError(try decode(json), json)
        }
    }

    func testUnknownKeysAreIgnoredForForwardCompatibility() throws {
        let manifest = try decode(#"{"schemaVersion": 9, "id": "x", "name": "n", "appearance": {"future": {"a": 1}}, "newTopLevel": [1, 2]}"#)
        XCTAssertEqual(manifest.schemaVersion, 9)
    }

    func testOptionalMetadataFieldsDecode() throws {
        let manifest = try decode(#"{"schemaVersion": 1, "id": "x", "name": "n", "author": "A", "version": "1.2.3", "description": "d", "appearance": {}}"#)
        XCTAssertEqual(manifest.author, "A")
        XCTAssertEqual(manifest.version, "1.2.3")
        XCTAssertEqual(manifest.description, "d")
    }

    func testManifestRoundTripsThroughJSON() throws {
        let original = ThemeManifest(
            schemaVersion: 1, id: "round.trip", name: "Round Trip", author: "A", version: "1", description: "d",
            appearance: ThemeAppearance(
                disablesGlassLook: true,
                tile: ThemeTile(clipShape: "circle", verticalPadding: 4, spacing: 2, iconPadding: 1),
                window: ThemeWindow(cornerRadius: 8, backgroundImage: "assets/b.png", tintColor: ThemeColor(r: 0.1, g: 0.2, b: 0.3)),
                indicators: ThemeIndicators(shape: "dot", offset: -2, scale: 1.5),
                iconShadow: ThemeShadow(color: ThemeColor(name: "black"), radius: 3, opacity: 0.5)
            ),
            behavior: ThemeBehavior(windowAxisSizing: "fullAxis", tileSize: 48, largeSize: 96, magnification: true, showsActivePinnedSeparator: false),
            layout: ThemeLayout(insertions: [ThemeLayoutInsertion(kind: "spacer", after: "divider:trailing", before: nil, span: nil)])
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(ThemeManifest.self, from: data), original)
    }

    func testEncodingIsStableWithSortedKeys() throws {
        let manifest = try decode(minimal)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(manifest), try encoder.encode(manifest))
    }

    // MARK: Hostile numeric values

    func testNegativeAndHugeSizesDecodeAsGiven() throws {
        // The model does not clamp; this pins that decoding preserves values
        // so the consuming layer is the one place that must bound them.
        let manifest = try decode("""
        {"schemaVersion": 1, "id": "x", "name": "n", "appearance": {
          "tile": {"verticalPadding": -50, "spacing": 1e308, "iconPadding": -1e308},
          "window": {"cornerRadius": -1, "tintOpacity": 7, "borderWidth": 1e300}
        }, "behavior": {"tileSize": -10, "largeSize": 1e12}}
        """)
        XCTAssertEqual(manifest.appearance.tile?.verticalPadding, -50)
        XCTAssertEqual(manifest.appearance.tile?.spacing, 1e308)
        XCTAssertEqual(manifest.appearance.window?.tintOpacity, 7)
        XCTAssertEqual(manifest.behavior?.tileSize, -10)
        XCTAssertEqual(manifest.behavior?.largeSize, 1e12)
    }

    func testNonFiniteLiteralsCannotEnterThroughJSON() {
        for literal in ["NaN", "Infinity", "-Infinity", "nan", "inf"] {
            let json = #"{"schemaVersion": 1, "id": "x", "name": "n", "appearance": {"window": {"cornerRadius": \#(literal)}}}"#
            XCTAssertThrowsError(try decode(json), literal)
        }
    }

    func testStringWhereNumberExpectedIsRejected() {
        for json in [
            #"{"schemaVersion": 1, "id": "x", "name": "n", "appearance": {"window": {"cornerRadius": "12"}}}"#,
            #"{"schemaVersion": 1, "id": "x", "name": "n", "appearance": {"tile": {"spacing": true}}}"#,
            #"{"schemaVersion": 1, "id": "x", "name": "n", "appearance": {"tile": {"spacing": [1]}}}"#,
        ] {
            XCTAssertThrowsError(try decode(json), json)
        }
    }

    func testNullOptionalValuesAreTreatedAsAbsent() throws {
        let manifest = try decode(#"{"schemaVersion": 1, "id": "x", "name": "n", "appearance": {"window": null, "tile": {"spacing": null}}}"#)
        XCTAssertNil(manifest.appearance.window)
        XCTAssertNil(manifest.appearance.tile?.spacing)
    }

    // MARK: Asset paths are strings only

    func testAssetPathsAreCarriedVerbatim() throws {
        // Decoding performs no path validation; resolution must.
        let manifest = try decode("""
        {"schemaVersion": 1, "id": "x", "name": "n", "appearance": {"window": {"backgroundImage": "../../../etc/passwd"},
          "indicators": {"image": "/etc/hosts", "divider": {"left": "assets/../../x", "right": "", "center": "file:///etc/passwd"}}}}
        """)
        XCTAssertEqual(manifest.appearance.window?.backgroundImage, "../../../etc/passwd")
        XCTAssertEqual(manifest.appearance.indicators?.image, "/etc/hosts")
        XCTAssertEqual(manifest.appearance.indicators?.divider?.left, "assets/../../x")
        XCTAssertEqual(manifest.appearance.indicators?.divider?.right, "")
        XCTAssertEqual(manifest.appearance.indicators?.divider?.center, "file:///etc/passwd")
    }

    // MARK: Layout insertions

    func testLayoutInsertionsDecode() throws {
        let manifest = try decode("""
        {"schemaVersion": 1, "id": "x", "name": "n", "appearance": {}, "layout": {"insertions": [
          {"kind": "flexibleSpacer", "after": "divider:trailing"},
          {"kind": "search", "before": "com.apple.Safari", "span": 4},
          {"kind": "weather", "after": "a", "before": "b", "span": 99}
        ]}}
        """)
        let insertions = try XCTUnwrap(manifest.layout?.insertions)
        XCTAssertEqual(insertions.count, 3)
        XCTAssertEqual(insertions[0].after, "divider:trailing")
        XCTAssertNil(insertions[0].before)
        XCTAssertEqual(insertions[1].span, 4)
        XCTAssertEqual(insertions[2].after, "a")
        XCTAssertEqual(insertions[2].before, "b", "both anchors decode; the resolver decides that `after` wins")
        XCTAssertEqual(insertions[2].span, 99, "out-of-range spans decode and are the resolver's to reject")
    }

    func testInsertionWithoutKindIsRejected() {
        let json = #"{"schemaVersion": 1, "id": "x", "name": "n", "appearance": {}, "layout": {"insertions": [{"after": "a"}]}}"#
        XCTAssertThrowsError(try decode(json))
    }

    func testEmptyInsertionList() throws {
        let manifest = try decode(#"{"schemaVersion": 1, "id": "x", "name": "n", "appearance": {}, "layout": {"insertions": []}}"#)
        XCTAssertEqual(manifest.layout?.insertions?.count, 0)
    }

    func testHugeInsertionListDecodes() throws {
        let items = Array(repeating: #"{"kind": "spacer", "after": "divider:trailing"}"#, count: 5_000).joined(separator: ",")
        let manifest = try decode(#"{"schemaVersion": 1, "id": "x", "name": "n", "appearance": {}, "layout": {"insertions": [\#(items)]}}"#)
        XCTAssertEqual(manifest.layout?.insertions?.count, 5_000)
    }

    func testInsertionAnchorsMayBeUnicodeAndLong() throws {
        let anchor = String(repeating: "é", count: 4_000)
        let json = #"{"schemaVersion": 1, "id": "x", "name": "n", "appearance": {}, "layout": {"insertions": [{"kind": "spacer", "after": "\#(anchor)"}]}}"#
        XCTAssertEqual(try decode(json).layout?.insertions?.first?.after, anchor)
    }

    // MARK: Colors

    func testComponentColorResolvesToDeviceRGB() throws {
        let color = try XCTUnwrap(ThemeColor(r: 0.25, g: 0.5, b: 0.75).nsColor)
        XCTAssertEqual(color.redComponent, 0.25, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 0.5, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 0.75, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 1)
    }

    func testPartialComponentsResolveToNothing() {
        XCTAssertNil(ThemeColor(r: 1, g: 0, b: nil).nsColor)
        XCTAssertNil(ThemeColor(r: nil, g: nil, b: nil).nsColor)
        XCTAssertNil(ThemeColor(r: 1).dockColor)
    }

    func testNamedColorsResolveCaseInsensitively() {
        for name in [
            "accent", "TINT", "controlAccent", "label", "SecondaryLabel", "tertiaryLabel", "quaternaryLabel",
            "systemBlue", "systemRed", "systemGreen", "systemYellow", "systemOrange", "systemPurple",
            "systemPink", "systemTeal", "systemIndigo", "systemMint", "systemBrown", "systemGray",
            "white", "black", "clear", "WHITE",
        ] {
            XCTAssertNotNil(ThemeColor.resolveNamedColor(name), name)
        }
    }

    func testUnknownColorNamesResolveToNothing() {
        for name in ["", "blurple", "red", " white", "white ", "#ff0000", "rgb(1,2,3)", "../../x", "🔥"] {
            XCTAssertNil(ThemeColor.resolveNamedColor(name), name.debugDescription)
        }
    }

    func testNamedColorWinsOverComponents() throws {
        let color = ThemeColor(r: 1, g: 0, b: 0, name: "black")
        XCTAssertEqual(try XCTUnwrap(color.nsColor).usingColorSpace(.deviceRGB)?.redComponent ?? 1, 0, accuracy: 0.001)
    }

    func testUnknownNameFallsBackToComponents() throws {
        let color = ThemeColor(r: 0.5, g: 0.5, b: 0.5, name: "blurple")
        XCTAssertNotNil(color.nsColor)
    }

    func testOutOfRangeComponentsDoNotTrap() {
        for value in [-5.0, 5.0, 1e308, -1e308] {
            _ = ThemeColor(r: value, g: value, b: value).nsColor
            _ = ThemeColor(r: value, g: value, b: value).dockColor
        }
    }
}

// MARK: - Bundled themes ship intact

final class BundledThemeTests: XCTestCase {

    private var themesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BundledThemes", isDirectory: true)
    }

    private func themeDirectories() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: themesRoot, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func strings(in value: Any) -> [String] {
        switch value {
        case let string as String: return [string]
        case let array as [Any]: return array.flatMap(strings(in:))
        case let dict as [String: Any]: return dict.values.flatMap(strings(in:))
        default: return []
        }
    }

    func testThereAreBundledThemes() throws {
        XCTAssertFalse(try themeDirectories().isEmpty)
    }

    func testEveryBundledManifestDecodes() throws {
        for directory in try themeDirectories() {
            let data = try Data(contentsOf: directory.appendingPathComponent("theme.json"))
            XCTAssertNoThrow(try JSONDecoder().decode(ThemeManifest.self, from: data), directory.lastPathComponent)
        }
    }

    func testBundledIdsAreValidAndMatchTheirFolders() throws {
        for directory in try themeDirectories() {
            let data = try Data(contentsOf: directory.appendingPathComponent("theme.json"))
            let manifest = try JSONDecoder().decode(ThemeManifest.self, from: data)
            XCTAssertTrue(ThemeManager.isValidThemeID(manifest.id), manifest.id)
            XCTAssertEqual(manifest.id, directory.lastPathComponent)
        }
    }

    func testBundledIdsAreUnique() throws {
        var seen = Set<String>()
        for directory in try themeDirectories() {
            let data = try Data(contentsOf: directory.appendingPathComponent("theme.json"))
            let manifest = try JSONDecoder().decode(ThemeManifest.self, from: data)
            XCTAssertTrue(seen.insert(manifest.id).inserted, "duplicate id \(manifest.id)")
        }
    }

    func testBundledAssetReferencesExistAndStayInsideTheTheme() throws {
        for directory in try themeDirectories() {
            let data = try Data(contentsOf: directory.appendingPathComponent("theme.json"))
            let object = try JSONSerialization.jsonObject(with: data)
            for text in strings(in: object) where text.hasPrefix("assets/") {
                XCTAssertFalse(text.contains(".."), "\(directory.lastPathComponent): \(text)")
                let file = directory.appendingPathComponent(text)
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "\(directory.lastPathComponent): \(text) is missing")
            }
        }
    }
}

// MARK: - Manager

@MainActor
final class ThemeManagerTests: XCTestCase {

    private struct Harness {
        let manager: ThemeManager
        let themes: URL
        let bundled: URL
        let defaults: UserDefaults
    }

    private func makeHarness(seedDefaults: [String: Any] = [:]) throws -> Harness {
        let root = try makeScratchDirectory("themes")
        let themes = root.appendingPathComponent("Themes", isDirectory: true)
        let bundled = root.appendingPathComponent("Bundled", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        let defaults = makeIsolatedDefaults()
        for (key, value) in seedDefaults { defaults.set(value, forKey: key) }
        let manager = ThemeManager(defaults: defaults, themesDirectory: themes, bundledThemesDirectory: bundled)
        return Harness(manager: manager, themes: themes, bundled: bundled, defaults: defaults)
    }

    @discardableResult
    private func installTheme(
        id: String,
        folder: String? = nil,
        in directory: URL,
        json: String? = nil,
        assets: [String: Data] = [:]
    ) throws -> URL {
        let url = directory.appendingPathComponent(folder ?? id, isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let body = json ?? #"{"schemaVersion": 1, "id": "\#(id)", "name": "Theme \#(id)", "appearance": {}}"#
        try Data(body.utf8).write(to: url.appendingPathComponent("theme.json"))
        for (name, data) in assets {
            try data.write(to: url.appendingPathComponent(name))
        }
        return url
    }

    private func zip(_ entries: [ZIPFixture.Entry], named name: String = "theme.dockytheme") throws -> URL {
        let directory = try makeScratchDirectory("zip")
        let url = directory.appendingPathComponent(name)
        try ZIPFixture.archive(entries).write(to: url)
        return url
    }

    private func manifestEntry(id: String, prefix: String = "") -> ZIPFixture.Entry {
        .init(name: "\(prefix)theme.json", contents: Data(#"{"schemaVersion": 1, "id": "\#(id)", "name": "N", "appearance": {}}"#.utf8))
    }

    // MARK: Identifier validation

    func testValidThemeIDs() {
        for id in ["demo", "My-Theme_2", "com.example.theme", "A", "a.b-c_d", "1", String(repeating: "a", count: 128)] {
            XCTAssertTrue(ThemeManager.isValidThemeID(id), id)
        }
    }

    func testInvalidThemeIDs() {
        let invalid = [
            "", ".", "..", ".hidden", "../evil", "a/b", "a\\b", "a b", "tab\there", "new\nline", "é", "テーマ", "a:b",
            "a*b", "a?b", "a<b", "~root", "$HOME", "a%2Fb", "a\u{0}b", String(repeating: "a", count: 129), "emoji🙂",
        ]
        for id in invalid {
            XCTAssertFalse(ThemeManager.isValidThemeID(id), id.debugDescription)
        }
    }

    func testIdThatIsOnlyDotsAfterTheFirstCharacterIsStillAccepted() {
        // "a.." has no separator and no leading dot, so it is a legal folder name.
        XCTAssertTrue(ThemeManager.isValidThemeID("a.."))
    }

    func testIDValidationCountsCharactersNotBytes() {
        // 128 valid ASCII characters pass; the limit is on Character count.
        XCTAssertTrue(ThemeManager.isValidThemeID(String(repeating: "z", count: 128)))
        XCTAssertFalse(ThemeManager.isValidThemeID(String(repeating: "z", count: 129)))
    }

    // MARK: Slugify

    func testSlugify() {
        let cases: [(String, String?)] = [
            ("My Theme", "my-theme"),
            ("  Padded  ", "padded"),
            ("Already-Slug", "already-slug"),
            ("Multiple   Spaces", "multiple-spaces"),
            ("Tab\tSeparated", "tab-separated"),
            ("Symbols!@#$%", "symbols"),
            ("a.b_c", "a.b_c"),
            ("--leading", "leading"),
            ("trailing--", "trailing"),
            ("._weird_.", "weird"),
            ("UPPER", "upper"),
            ("日本語", nil),
            ("", nil),
            ("!!!", nil),
            ("   ", nil),
            ("a - b", "a--b"),
            ("Café Au Lait", "caf-au-lait"),
            ("../../etc", "etc"),
            ("a/b\\c", "abc"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(ThemeManager.slugify(input), expected, input.debugDescription)
        }
    }

    func testSlugifyAlwaysProducesAValidIDOrNil() {
        let inputs = [
            "My Theme", "x", "../a", " . ", "Ünïcödé", "a" + String(repeating: "b", count: 300), "😀😀", "a\u{0}b", "-_.", "a.b.c",
        ]
        for input in inputs {
            if let slug = ThemeManager.slugify(input) {
                // Length is bounded separately by isValidThemeID at import time.
                XCTAssertFalse(slug.hasPrefix("."), slug)
                XCTAssertFalse(slug.contains("/"), slug)
                XCTAssertFalse(slug.isEmpty)
            }
        }
    }

    func testSlugifyOfVeryLongNameIsRejectedByValidation() throws {
        let slug = try XCTUnwrap(ThemeManager.slugify(String(repeating: "x", count: 500)))
        XCTAssertEqual(slug.count, 500)
        XCTAssertFalse(ThemeManager.isValidThemeID(slug), "export rejects it via isValidThemeID")
    }

    // MARK: Scanning

    func testStartsEmpty() throws {
        let h = try makeHarness()
        XCTAssertTrue(h.manager.installedThemes.isEmpty)
        XCTAssertNil(h.manager.activeThemeID)
        XCTAssertNil(h.manager.activeManifest)
        XCTAssertNil(h.manager.activeBundleURL)
    }

    func testThemesDirectoryIsCreatedOnInit() throws {
        let h = try makeHarness()
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.themes.path))
        XCTAssertEqual(h.manager.themesDirectoryURL, h.themes)
    }

    func testRefreshFindsUserThemes() throws {
        let h = try makeHarness()
        try installTheme(id: "alpha", in: h.themes)
        try installTheme(id: "beta", in: h.themes)
        h.manager.refreshInstalled()
        XCTAssertEqual(Set(h.manager.installedThemes.keys), ["alpha", "beta"])
        XCTAssertEqual(h.manager.installedThemes["alpha"]?.isBundled, false)
    }

    func testBundledThemesAreFlagged() throws {
        let h = try makeHarness()
        try installTheme(id: "builtin", in: h.bundled)
        h.manager.refreshInstalled()
        XCTAssertEqual(h.manager.installedThemes["builtin"]?.isBundled, true)
    }

    func testUserThemeOverridesBundledThemeWithSameID() throws {
        let h = try makeHarness()
        try installTheme(id: "shared", in: h.bundled, json: #"{"schemaVersion": 1, "id": "shared", "name": "Bundled", "appearance": {}}"#)
        try installTheme(id: "shared", in: h.themes, json: #"{"schemaVersion": 1, "id": "shared", "name": "User", "appearance": {}}"#)
        h.manager.refreshInstalled()
        XCTAssertEqual(h.manager.installedThemes["shared"]?.manifest.name, "User")
        XCTAssertEqual(h.manager.installedThemes["shared"]?.isBundled, false)
    }

    func testManifestIDWinsOverFolderName() throws {
        let h = try makeHarness()
        try installTheme(id: "real-id", folder: "renamed-folder", in: h.themes)
        h.manager.refreshInstalled()
        XCTAssertNotNil(h.manager.installedThemes["real-id"])
        XCTAssertNil(h.manager.installedThemes["renamed-folder"])
    }

    func testTwoFoldersWithTheSameIDCollapseToOneEntry() throws {
        let h = try makeHarness()
        try installTheme(id: "twin", folder: "one", in: h.themes)
        try installTheme(id: "twin", folder: "two", in: h.themes)
        h.manager.refreshInstalled()
        XCTAssertEqual(h.manager.installedThemes.count, 1)
    }

    func testCorruptAndIncompleteThemesAreSkipped() throws {
        let h = try makeHarness()
        try installTheme(id: "good", in: h.themes)
        try installTheme(id: "bad", in: h.themes, json: "{ not json")
        try installTheme(id: "empty", in: h.themes, json: "")
        try installTheme(id: "partial", in: h.themes, json: #"{"schemaVersion": 1, "id": "partial"}"#)
        try FileManager.default.createDirectory(at: h.themes.appendingPathComponent("no-manifest"), withIntermediateDirectories: true)
        try Data("stray".utf8).write(to: h.themes.appendingPathComponent("loose-file.json"))
        h.manager.refreshInstalled()
        XCTAssertEqual(Set(h.manager.installedThemes.keys), ["good"])
    }

    func testHiddenThemeFoldersAreSkipped() throws {
        let h = try makeHarness()
        try installTheme(id: "hidden", folder: ".hidden", in: h.themes)
        h.manager.refreshInstalled()
        XCTAssertTrue(h.manager.installedThemes.isEmpty)
    }

    func testManifestWithPathLikeIDIsStillIndexedByDictionaryKeyOnly() throws {
        // Scanning does not validate ids (import does). The id is only ever a
        // dictionary key here, never joined to a path.
        let h = try makeHarness()
        try installTheme(id: "x", folder: "weird", in: h.themes, json: #"{"schemaVersion": 1, "id": "../../escape", "name": "N", "appearance": {}}"#)
        h.manager.refreshInstalled()
        XCTAssertEqual(h.manager.installedThemes["../../escape"]?.bundleURL.lastPathComponent, "weird")
    }

    func testDeleteOfThemeWithPathLikeIDOnlyRemovesItsOwnFolder() throws {
        let h = try makeHarness()
        let sentinel = h.themes.deletingLastPathComponent().appendingPathComponent("sentinel.txt")
        try Data("keep".utf8).write(to: sentinel)
        try installTheme(id: "x", folder: "weird", in: h.themes, json: #"{"schemaVersion": 1, "id": "../sentinel.txt", "name": "N", "appearance": {}}"#)
        h.manager.refreshInstalled()
        try h.manager.deleteTheme(id: "../sentinel.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.themes.appendingPathComponent("weird").path))
    }

    func testLargeNumberOfThemesScansQuickly() throws {
        let h = try makeHarness()
        for index in 0..<200 { try installTheme(id: "t\(index)", in: h.themes) }
        let start = Date()
        h.manager.refreshInstalled()
        XCTAssertEqual(h.manager.installedThemes.count, 200)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    // MARK: Activation

    func testActivationPersistsAndResolves() throws {
        let h = try makeHarness()
        try installTheme(id: "alpha", in: h.themes)
        h.manager.refreshInstalled()
        h.manager.setActive("alpha")
        XCTAssertEqual(h.manager.activeThemeID, "alpha")
        XCTAssertEqual(h.manager.activeManifest?.name, "Theme alpha")
        XCTAssertEqual(h.manager.activeBundleURL?.lastPathComponent, "alpha")
        XCTAssertEqual(h.defaults.string(forKey: "docky.activeThemeID"), "alpha")
    }

    func testActivatingUnknownThemeIsIgnored() throws {
        let h = try makeHarness()
        h.manager.setActive("ghost")
        XCTAssertNil(h.manager.activeThemeID)
        XCTAssertNil(h.defaults.string(forKey: "docky.activeThemeID"))
    }

    func testClearActiveRemovesPersistedValue() throws {
        let h = try makeHarness()
        try installTheme(id: "alpha", in: h.themes)
        h.manager.refreshInstalled()
        h.manager.setActive("alpha")
        h.manager.clearActive()
        XCTAssertNil(h.manager.activeThemeID)
        XCTAssertNil(h.defaults.string(forKey: "docky.activeThemeID"))
        h.manager.clearActive()
        XCTAssertNil(h.manager.activeThemeID)
    }

    func testPersistedActiveThemeIsRestoredOnInit() throws {
        let root = try makeScratchDirectory("restore")
        let themes = root.appendingPathComponent("Themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        try installTheme(id: "kept", in: themes)
        let defaults = makeIsolatedDefaults()
        defaults.set("kept", forKey: "docky.activeThemeID")
        let manager = ThemeManager(defaults: defaults, themesDirectory: themes, bundledThemesDirectory: nil)
        XCTAssertEqual(manager.activeThemeID, "kept")
        XCTAssertNotNil(manager.activeManifest)
    }

    func testStaleActiveIDIsForgottenOnInit() throws {
        let h = try makeHarness(seedDefaults: ["docky.activeThemeID": "vanished"])
        XCTAssertNil(h.manager.activeThemeID)
        XCTAssertNil(h.defaults.string(forKey: "docky.activeThemeID"))
    }

    func testActiveThemeIsClearedWhenItsFolderDisappears() throws {
        let h = try makeHarness()
        let url = try installTheme(id: "alpha", in: h.themes)
        h.manager.refreshInstalled()
        h.manager.setActive("alpha")
        try FileManager.default.removeItem(at: url)
        h.manager.refreshInstalled()
        XCTAssertNil(h.manager.activeThemeID)
    }

    func testSwitchingActiveThemes() throws {
        let h = try makeHarness()
        try installTheme(id: "a", in: h.themes)
        try installTheme(id: "b", in: h.themes)
        h.manager.refreshInstalled()
        h.manager.setActive("a")
        h.manager.setActive("b")
        XCTAssertEqual(h.manager.activeThemeID, "b")
        XCTAssertEqual(h.defaults.string(forKey: "docky.activeThemeID"), "b")
    }

    // MARK: Delete

    func testDeleteRemovesUserTheme() throws {
        let h = try makeHarness()
        let url = try installTheme(id: "alpha", in: h.themes)
        h.manager.refreshInstalled()
        try h.manager.deleteTheme(id: "alpha")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(h.manager.installedThemes["alpha"])
    }

    func testDeleteIgnoresBundledThemes() throws {
        let h = try makeHarness()
        let url = try installTheme(id: "builtin", in: h.bundled)
        h.manager.refreshInstalled()
        try h.manager.deleteTheme(id: "builtin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(h.manager.installedThemes["builtin"])
    }

    func testDeleteOfUnknownThemeIsANoOp() throws {
        let h = try makeHarness()
        XCTAssertNoThrow(try h.manager.deleteTheme(id: "ghost"))
    }

    func testDeletingTheActiveThemeClearsActivation() throws {
        let h = try makeHarness()
        try installTheme(id: "alpha", in: h.themes)
        h.manager.refreshInstalled()
        h.manager.setActive("alpha")
        try h.manager.deleteTheme(id: "alpha")
        XCTAssertNil(h.manager.activeThemeID)
    }

    func testDeletingUserOverrideFallsBackToBundledAndKeepsActivation() throws {
        let h = try makeHarness()
        try installTheme(id: "shared", in: h.bundled)
        try installTheme(id: "shared", in: h.themes)
        h.manager.refreshInstalled()
        h.manager.setActive("shared")
        try h.manager.deleteTheme(id: "shared")
        XCTAssertEqual(h.manager.activeThemeID, "shared")
        XCTAssertEqual(h.manager.installedThemes["shared"]?.isBundled, true)
    }

    // MARK: Asset resolution

    func testAssetResolvesInsideTheActiveBundle() throws {
        let h = try makeHarness()
        try installTheme(id: "alpha", in: h.themes, assets: ["assets/bg.png": ImageFixtures.png(width: 4, height: 4)])
        h.manager.refreshInstalled()
        h.manager.setActive("alpha")
        XCTAssertEqual(h.manager.activeAssetURL("assets/bg.png")?.lastPathComponent, "bg.png")
    }

    func testAssetLookupNeedsAnActiveTheme() throws {
        let h = try makeHarness()
        XCTAssertNil(h.manager.activeAssetURL("assets/bg.png"))
    }

    func testMissingNilAndEmptyAssetPathsResolveToNil() throws {
        let h = try makeHarness()
        try installTheme(id: "alpha", in: h.themes)
        h.manager.refreshInstalled()
        h.manager.setActive("alpha")
        XCTAssertNil(h.manager.activeAssetURL(nil))
        XCTAssertNil(h.manager.activeAssetURL(""))
        XCTAssertNil(h.manager.activeAssetURL("assets/missing.png"))
    }

    func testAssetPathMayNotEscapeTheThemeBundle() throws {
        expectKnownBug("activeAssetURL appends the manifest string to the bundle URL and checks only that the file exists, so '../' and absolute paths resolve to files outside the theme. A hostile theme can make Wharf read any image-shaped file the user can read.")
        let h = try makeHarness()
        let outside = h.themes.deletingLastPathComponent().appendingPathComponent("outside.png")
        try ImageFixtures.png(width: 4, height: 4).write(to: outside)
        try installTheme(id: "alpha", in: h.themes)
        h.manager.refreshInstalled()
        h.manager.setActive("alpha")
        XCTAssertNil(h.manager.activeAssetURL("../../outside.png"))
        XCTAssertNil(h.manager.activeAssetURL(outside.path))
    }

    func testAbsoluteAssetPathIsRelativeToTheBundleNotTheFilesystem() throws {
        // appending(path:) treats "/x" as a child of the bundle, not the root.
        let h = try makeHarness()
        try installTheme(id: "alpha", in: h.themes)
        h.manager.refreshInstalled()
        h.manager.setActive("alpha")
        XCTAssertNil(h.manager.activeAssetURL("/etc/hosts"))
    }

    func testAssetSymlinkPointingOutsideIsFollowed() throws {
        // Current behavior, recorded as a finding alongside the traversal
        // case above: a symlink inside a theme is followed without checks.
        let h = try makeHarness()
        let outside = try makeScratchDirectory("outside").appendingPathComponent("secret.png")
        try ImageFixtures.png(width: 4, height: 4).write(to: outside)
        let url = try installTheme(id: "alpha", in: h.themes)
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("assets/link.png"), withDestinationURL: outside)
        h.manager.refreshInstalled()
        h.manager.setActive("alpha")
        XCTAssertNotNil(h.manager.activeAssetURL("assets/link.png"))
    }

    func testPerAppIconLookupByConvention() throws {
        let h = try makeHarness()
        try installTheme(
            id: "alpha", in: h.themes,
            assets: [
                "assets/com.apple.Safari.png": ImageFixtures.png(width: 4, height: 4),
                "assets/com.example.photo.jpg": ImageFixtures.jpeg(width: 4, height: 4),
                "assets/background.png": ImageFixtures.png(width: 4, height: 4),
                "assets/com.example.bad.gif": Data("gif".utf8),
            ]
        )
        h.manager.refreshInstalled()
        h.manager.setActive("alpha")
        XCTAssertEqual(h.manager.activeAppIconURL(forBundleIdentifier: "com.apple.Safari")?.lastPathComponent, "com.apple.Safari.png")
        XCTAssertEqual(h.manager.activeAppIconURL(forBundleIdentifier: "com.example.photo")?.lastPathComponent, "com.example.photo.jpg")
        XCTAssertNil(h.manager.activeAppIconURL(forBundleIdentifier: "com.example.bad"))
        XCTAssertNil(h.manager.activeAppIconURL(forBundleIdentifier: "com.apple.Mail"))
        XCTAssertNil(h.manager.activeAppIconURL(forBundleIdentifier: ""))
        XCTAssertEqual(Set(h.manager.activeAppIconBundleIDs()), ["com.apple.Safari", "com.example.photo"])
    }

    func testPerAppIconLookupWithoutActiveThemeIsEmpty() throws {
        let h = try makeHarness()
        XCTAssertNil(h.manager.activeAppIconURL(forBundleIdentifier: "com.apple.Safari"))
        XCTAssertTrue(h.manager.activeAppIconBundleIDs().isEmpty)
    }

    func testPerAppIconBundleIdentifierCannotTraverse() throws {
        expectKnownBug("activeAppIconURL joins the caller's bundle identifier into a path without sanitizing it, so '../' in an identifier reads outside assets/. Identifiers come from installed apps, so exploitation needs a malicious app.")
        let h = try makeHarness()
        let url = try installTheme(id: "alpha", in: h.themes)
        try ImageFixtures.png(width: 4, height: 4).write(to: url.appendingPathComponent("cover.png"))
        h.manager.refreshInstalled()
        h.manager.setActive("alpha")
        XCTAssertNil(h.manager.activeAppIconURL(forBundleIdentifier: "../cover"))
    }

    func testCoverImageLookup() throws {
        let h = try makeHarness()
        let url = try installTheme(id: "alpha", in: h.themes)
        h.manager.refreshInstalled()
        let theme = try XCTUnwrap(h.manager.installedThemes["alpha"])
        XCTAssertNil(theme.coverImageURL)
        try ImageFixtures.jpeg(width: 4, height: 4).write(to: url.appendingPathComponent("cover_image.jpg"))
        XCTAssertEqual(theme.coverImageURL?.lastPathComponent, "cover_image.jpg")
        try ImageFixtures.png(width: 4, height: 4).write(to: url.appendingPathComponent("cover_image.png"))
        XCTAssertEqual(theme.coverImageURL?.lastPathComponent, "cover_image.png", "png has priority")
    }

    // MARK: Import

    func testImportInstallsThemeFromFlatArchive() throws {
        let h = try makeHarness()
        let archive = try zip([manifestEntry(id: "imported"), .init(name: "assets/bg.png", contents: ImageFixtures.png(width: 4, height: 4))])
        let manifest = try h.manager.importTheme(from: archive)
        XCTAssertEqual(manifest.id, "imported")
        XCTAssertNotNil(h.manager.installedThemes["imported"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.themes.appendingPathComponent("imported/assets/bg.png").path))
    }

    func testImportAcceptsASingleWrappingFolder() throws {
        let h = try makeHarness()
        let archive = try zip([manifestEntry(id: "wrapped", prefix: "Wrapper/")])
        XCTAssertEqual(try h.manager.importTheme(from: archive).id, "wrapped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.themes.appendingPathComponent("wrapped/theme.json").path))
    }

    func testImportWithoutManifestIsRejected() throws {
        let h = try makeHarness()
        let archive = try zip([.init(name: "readme.txt", contents: Data("hi".utf8))])
        XCTAssertThrowsError(try h.manager.importTheme(from: archive)) { error in
            guard case ThemeImportError.missingManifest = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testImportWithTwoTopLevelFoldersIsRejected() throws {
        let h = try makeHarness()
        let archive = try zip([manifestEntry(id: "a", prefix: "One/"), manifestEntry(id: "b", prefix: "Two/")])
        XCTAssertThrowsError(try h.manager.importTheme(from: archive)) { error in
            guard case ThemeImportError.missingManifest = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testImportWithInvalidManifestIsRejected() throws {
        let h = try makeHarness()
        let archive = try zip([.init(name: "theme.json", contents: Data("{ nope".utf8))])
        XCTAssertThrowsError(try h.manager.importTheme(from: archive)) { error in
            guard case ThemeImportError.invalidManifest = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testImportRejectsUnsafeIdentifiers() throws {
        let h = try makeHarness()
        let ids = ["../evil", "..", ".", ".hidden", "a/b", "", "with space", String(repeating: "a", count: 129), "ünï"]
        for id in ids {
            let archive = try zip([manifestEntry(id: id.replacingOccurrences(of: "\"", with: ""))])
            XCTAssertThrowsError(try h.manager.importTheme(from: archive), id.debugDescription) { error in
                guard case ThemeImportError.invalidID = error else { return XCTFail("wrong error \(error) for \(id)") }
            }
        }
        // Nothing but the themes directory itself may exist afterwards.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: h.themes.path)
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
    }

    func testImportRejectsNonArchive() throws {
        let h = try makeHarness()
        let directory = try makeScratchDirectory("notzip")
        let file = directory.appendingPathComponent("fake.dockytheme")
        try Data("this is not a zip".utf8).write(to: file)
        XCTAssertThrowsError(try h.manager.importTheme(from: file)) { error in
            guard case ThemeImportError.extractionFailed = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testImportOfMissingFileFails() throws {
        let h = try makeHarness()
        let missing = try makeScratchDirectory("missing").appendingPathComponent("nope.dockytheme")
        XCTAssertThrowsError(try h.manager.importTheme(from: missing))
    }

    func testImportReplacesExistingInstallAndKeepsActivation() throws {
        let h = try makeHarness()
        try installTheme(id: "same", in: h.themes, assets: ["assets/old.png": ImageFixtures.png(width: 4, height: 4)])
        h.manager.refreshInstalled()
        h.manager.setActive("same")

        let archive = try zip([manifestEntry(id: "same"), .init(name: "assets/new.png", contents: ImageFixtures.png(width: 4, height: 4))])
        _ = try h.manager.importTheme(from: archive)

        XCTAssertEqual(h.manager.activeThemeID, "same")
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.themes.appendingPathComponent("same/assets/old.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.themes.appendingPathComponent("same/assets/new.png").path))
    }

    func testImportDoesNotDisturbAnotherActiveTheme() throws {
        let h = try makeHarness()
        try installTheme(id: "current", in: h.themes)
        h.manager.refreshInstalled()
        h.manager.setActive("current")
        _ = try h.manager.importTheme(from: try zip([manifestEntry(id: "other")]))
        XCTAssertEqual(h.manager.activeThemeID, "current")
    }

    func testImportCleansItsTemporaryExtraction() throws {
        let h = try makeHarness()
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
            .filter { $0.hasPrefix("docky-theme-import-") }
        _ = try h.manager.importTheme(from: try zip([manifestEntry(id: "tidy")]))
        _ = try? h.manager.importTheme(from: try zip([manifestEntry(id: "../bad")]))
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
            .filter { $0.hasPrefix("docky-theme-import-") }
        XCTAssertTrue(after.subtracting(before).isEmpty, "temporary extraction directories must be removed")
    }

    func testImportedArchiveEntriesCannotEscapeTheExtractionDirectory() throws {
        let h = try makeHarness()
        let marker = "wharf-theme-slip-\(UUID().uuidString).txt"
        let archive = try zip([
            .init(name: "../\(marker)", contents: Data("escaped".utf8)),
            .init(name: "../../\(marker)", contents: Data("escaped".utf8)),
            manifestEntry(id: "slip"),
        ])
        _ = try? h.manager.importTheme(from: archive)
        let tmp = FileManager.default.temporaryDirectory
        for escape in [tmp.appendingPathComponent(marker), tmp.deletingLastPathComponent().appendingPathComponent(marker)] {
            let exists = FileManager.default.fileExists(atPath: escape.path)
            if exists { try? FileManager.default.removeItem(at: escape) }
            XCTAssertFalse(exists, "entry escaped to \(escape.path)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.themes.deletingLastPathComponent().appendingPathComponent(marker).path))
    }

    func testImportedSymlinkEntriesAreInertForInstallAndScan() throws {
        let h = try makeHarness()
        let archive = try zip([
            manifestEntry(id: "linky"),
            .init(name: "assets/hosts", contents: Data("/etc/hosts".utf8), unixMode: 0o120755),
        ])
        XCTAssertNoThrow(try h.manager.importTheme(from: archive))
        XCTAssertNotNil(h.manager.installedThemes["linky"])
    }

    // MARK: Export guards

    func testExportRejectsNamesThatSlugifyToNothing() throws {
        let h = try makeHarness()
        let destination = try makeScratchDirectory("export").appendingPathComponent("out.dockytheme")
        for name in ["", "   ", "!!!", "日本語", "\n"] {
            XCTAssertThrowsError(try h.manager.exportCurrentAppearance(name: name, to: destination), name.debugDescription) { error in
                guard case ThemeExportError.invalidName = error else { return XCTFail("wrong error \(error)") }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testExportRejectsOverlongNames() throws {
        let h = try makeHarness()
        let destination = try makeScratchDirectory("export").appendingPathComponent("out.dockytheme")
        XCTAssertThrowsError(try h.manager.exportCurrentAppearance(name: String(repeating: "x", count: 200), to: destination))
    }

    func testErrorDescriptionsAreReadable() {
        XCTAssertTrue(ThemeImportError.missingManifest.errorDescription?.contains("theme.json") == true)
        XCTAssertTrue(ThemeImportError.invalidID("../x").errorDescription?.contains("../x") == true)
        XCTAssertTrue(ThemeImportError.extractionFailed(status: 2, stderr: "boom\n").errorDescription?.contains("boom") == true)
        XCTAssertTrue(ThemeExportError.invalidName("Q").errorDescription?.contains("Q") == true)
        XCTAssertTrue(ThemeExportError.archiveFailed(status: 1, stderr: "").errorDescription?.contains("exit 1") == true)
    }
}
