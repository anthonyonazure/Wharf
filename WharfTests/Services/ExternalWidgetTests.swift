import AppKit
import XCTest
@testable import Wharf

// MARK: - Plugin doubles

/// A configurable stand-in for a third-party plugin. It never comes from a
/// loaded bundle, so no foreign code runs.
@objc(WharfTestPlugin)
class TestPlugin: NSObject, DockyWidgetPlugin {
    var identifier = "test.plugin"
    var displayName = "Test Plugin"
    var systemImageName = "star"
    var defaultSpanValue = 2
    var supportedSpanValues = [1, 2, 3]
    var expansionWidthTiles = 3
    var expansionHeightTiles = 2
    var isExpandable = true
    var includesInPalette = true
    var includesInSmartStack = false

    var plainViewCalls: [(CGFloat, Int, Bool, Bool, Bool)] = []

    required override init() { super.init() }

    func makeView(
        cornerRadius: CGFloat,
        renderedSpanValue: Int,
        isWithinStack: Bool,
        isExpanded: Bool,
        isExpandedPreviewOpen: Bool
    ) -> NSView {
        plainViewCalls.append((cornerRadius, renderedSpanValue, isWithinStack, isExpanded, isExpandedPreviewOpen))
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier("plain")
        return view
    }
}

/// Implements the optional metadata and configured-view members.
@objc(WharfTestConfigurablePlugin)
final class TestConfigurablePlugin: TestPlugin {
    var receivedConfiguration: [String: Any]?

    @objc var author: String { "Ada Lovelace" }
    @objc var version: String { "2.4.1" }

    @objc func makeView(
        cornerRadius: CGFloat,
        renderedSpanValue: Int,
        isWithinStack: Bool,
        isExpanded: Bool,
        isExpandedPreviewOpen: Bool,
        configuration: [String: Any]
    ) -> NSView {
        receivedConfiguration = configuration
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier("configured")
        return view
    }
}

// MARK: - Registration and registry

final class ExternalWidgetRegistrationTests: XCTestCase {

    private func register(_ plugin: TestPlugin, settings: [WidgetSettingsField] = []) -> ExternalWidgetRegistration {
        ExternalWidgetRegistration(
            plugin: plugin,
            bundleURL: URL(fileURLWithPath: "/tmp/Fake.dockywidget"),
            settingsSchema: settings
        )
    }

    func testMetadataIsCapturedFromThePlugin() {
        let metadata = register(TestPlugin()).metadata
        XCTAssertEqual(metadata.identifier, "test.plugin")
        XCTAssertEqual(metadata.displayName, "Test Plugin")
        XCTAssertEqual(metadata.systemImageName, "star")
        XCTAssertEqual(metadata.defaultSpan, .two)
        XCTAssertEqual(metadata.supportedSpans, [.one, .two, .three])
        XCTAssertEqual(metadata.expansionExtent, WidgetExpansionExtent(widthTiles: 3, heightTiles: 2))
        XCTAssertTrue(metadata.isExpandable)
        XCTAssertTrue(metadata.includesInPalette)
        XCTAssertFalse(metadata.includesInSmartStack)
    }

    func testMissingOptionalMetadataFallsBackToDefaults() {
        let metadata = register(TestPlugin()).metadata
        XCTAssertEqual(metadata.author, "Unknown")
        XCTAssertEqual(metadata.version, "1.0")
    }

    func testOptionalMetadataIsReadWhenImplemented() {
        let metadata = register(TestConfigurablePlugin()).metadata
        XCTAssertEqual(metadata.author, "Ada Lovelace")
        XCTAssertEqual(metadata.version, "2.4.1")
    }

    func testUnknownDefaultSpanFallsBackToThree() {
        for value in [0, -1, 5, 99, Int.max, Int.min] {
            let plugin = TestPlugin()
            plugin.defaultSpanValue = value
            XCTAssertEqual(register(plugin).metadata.defaultSpan, .three, "span \(value)")
        }
    }

    func testThemeOnlyFourSpanIsAccepted() {
        let plugin = TestPlugin()
        plugin.defaultSpanValue = 4
        XCTAssertEqual(register(plugin).metadata.defaultSpan, .four)
    }

    func testUnsupportedSpansAreDropped() {
        let plugin = TestPlugin()
        plugin.supportedSpanValues = [3, 0, -2, 1, 7, 2, Int.max, 2]
        XCTAssertEqual(register(plugin).metadata.supportedSpans, [.three, .one, .two, .two])
    }

    func testEmptySupportedSpansStayEmpty() {
        let plugin = TestPlugin()
        plugin.supportedSpanValues = []
        XCTAssertTrue(register(plugin).metadata.supportedSpans.isEmpty)
    }

    func testExpansionExtentIsAtLeastOneTile() {
        let cases: [(Int, Int, Int, Int)] = [
            (0, 0, 1, 1), (-4, 3, 1, 3), (2, -9, 2, 1), (Int.min, Int.min, 1, 1), (5, 6, 5, 6),
        ]
        for (w, h, expectedW, expectedH) in cases {
            let plugin = TestPlugin()
            plugin.expansionWidthTiles = w
            plugin.expansionHeightTiles = h
            let extent = register(plugin).metadata.expansionExtent
            XCTAssertEqual(extent.widthTiles, expectedW)
            XCTAssertEqual(extent.heightTiles, expectedH)
        }
    }

    func testHugeExpansionExtentIsStoredWithoutTrapping() {
        let plugin = TestPlugin()
        plugin.expansionWidthTiles = Int.max
        plugin.expansionHeightTiles = Int.max
        let extent = register(plugin).metadata.expansionExtent
        XCTAssertEqual(extent.widthTiles, Int.max)
    }

    func testSettingsSchemaIsCarriedThrough() {
        let field = WidgetSettingsField(id: "unit", label: "Unit", type: .text)
        XCTAssertEqual(register(TestPlugin(), settings: [field]).metadata.settingsSchema, [field])
    }

    func testBundleURLIsRetained() {
        XCTAssertEqual(register(TestPlugin()).bundleURL.lastPathComponent, "Fake.dockywidget")
    }

    func testViewFallsBackToPlainFactoryWithoutConfiguredVariant() {
        let plugin = TestPlugin()
        let registration = register(plugin)
        let view = registration.view(
            cornerRadius: 12, renderedSpan: .two, isWithinStack: true, isExpanded: false, isExpandedPreviewOpen: true,
            settings: ["unit": .string("C")]
        )
        XCTAssertEqual(view.identifier?.rawValue, "plain")
        XCTAssertEqual(plugin.plainViewCalls.count, 1)
        XCTAssertEqual(plugin.plainViewCalls[0].0, 12)
        XCTAssertEqual(plugin.plainViewCalls[0].1, 2)
        XCTAssertTrue(plugin.plainViewCalls[0].2)
        XCTAssertFalse(plugin.plainViewCalls[0].3)
        XCTAssertTrue(plugin.plainViewCalls[0].4)
    }

    func testViewPrefersConfiguredVariantAndPassesCocoaSettings() {
        let plugin = TestConfigurablePlugin()
        let registration = register(plugin)
        let view = registration.view(
            cornerRadius: 4, renderedSpan: .three, isWithinStack: false, isExpanded: true, isExpandedPreviewOpen: false,
            settings: [
                "name": .string("home"),
                "count": .number(3),
                "on": .bool(true),
                "tags": .stringList(["a", "b"]),
            ]
        )
        XCTAssertEqual(view.identifier?.rawValue, "configured")
        let configuration = plugin.receivedConfiguration
        XCTAssertEqual(configuration?["name"] as? String, "home")
        XCTAssertEqual(configuration?["count"] as? Double, 3)
        XCTAssertEqual(configuration?["on"] as? Bool, true)
        XCTAssertEqual(configuration?["tags"] as? [String], ["a", "b"])
        XCTAssertTrue(plugin.plainViewCalls.isEmpty)
    }

    func testViewWithEmptySettingsPassesEmptyConfiguration() {
        let plugin = TestConfigurablePlugin()
        _ = register(plugin).view(
            cornerRadius: 0, renderedSpan: .one, isWithinStack: false, isExpanded: false, isExpandedPreviewOpen: false
        )
        XCTAssertEqual(plugin.receivedConfiguration?.count, 0)
    }
}

final class ExternalWidgetRegistryTests: XCTestCase {

    private func registration(_ identifier: String, name: String = "N") -> ExternalWidgetRegistration {
        let plugin = TestPlugin()
        plugin.identifier = identifier
        plugin.displayName = name
        return ExternalWidgetRegistration(plugin: plugin, bundleURL: URL(fileURLWithPath: "/tmp/\(name).dockywidget"))
    }

    func testRegisteredWidgetIsFound() {
        let registry = ExternalWidgetRegistry()
        registry.register(registration("a"))
        XCTAssertEqual(registry.metadata(for: "a")?.identifier, "a")
        XCTAssertNotNil(registry.registration(for: "a"))
        XCTAssertEqual(registry.registrations.count, 1)
    }

    func testUnknownIdentifierIsNil() {
        let registry = ExternalWidgetRegistry()
        XCTAssertNil(registry.metadata(for: "nope"))
        XCTAssertNil(registry.registration(for: ""))
    }

    func testDuplicateIdentifierKeepsFirstRegistration() {
        let registry = ExternalWidgetRegistry()
        registry.register(registration("dup", name: "First"))
        registry.register(registration("dup", name: "Second"))
        XCTAssertEqual(registry.registrations.count, 1)
        XCTAssertEqual(registry.metadata(for: "dup")?.displayName, "First")
    }

    func testIdentifiersAreCaseSensitive() {
        let registry = ExternalWidgetRegistry()
        registry.register(registration("Widget"))
        registry.register(registration("widget"))
        XCTAssertEqual(registry.registrations.count, 2)
    }

    func testRegistrationOrderIsPreserved() {
        let registry = ExternalWidgetRegistry()
        for id in ["c", "a", "b"] { registry.register(registration(id)) }
        XCTAssertEqual(registry.registrations.map(\.metadata.identifier), ["c", "a", "b"])
    }

    func testIsolatedRegistriesDoNotShareState() {
        let one = ExternalWidgetRegistry()
        let two = ExternalWidgetRegistry()
        one.register(registration("only-in-one"))
        XCTAssertNil(two.metadata(for: "only-in-one"))
    }

    func testHostileIdentifiersAreStoredVerbatimAndLookedUpExactly() {
        let registry = ExternalWidgetRegistry()
        let hostile = ["../../etc/passwd", "a/b", "", " ", "🔥", String(repeating: "x", count: 10_000), "x\u{0}y", "a b\nc"]
        for id in hostile { registry.register(registration(id)) }
        for id in hostile { XCTAssertEqual(registry.metadata(for: id)?.identifier, id) }
        XCTAssertEqual(registry.registrations.count, hostile.count)
    }

    func testManyRegistrationsStayFast() {
        let registry = ExternalWidgetRegistry()
        let start = Date()
        for index in 0..<2_000 { registry.register(registration("id-\(index)")) }
        XCTAssertEqual(registry.registrations.count, 2_000)
        XCTAssertNotNil(registry.registration(for: "id-1999"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}

// MARK: - Settings manifest

final class ExternalWidgetSettingsManifestTests: XCTestCase {

    private func parse(_ json: String) -> [WidgetSettingsField] {
        ExternalWidgetSettingsManifest.parse(Data(json.utf8))
    }

    func testParsesEveryFieldType() {
        let fields = parse("""
        {"fields": [
          {"id": "name", "type": "text", "label": "Name", "default": "Home"},
          {"id": "size", "type": "number", "label": "Size", "default": 4.5},
          {"id": "on", "type": "toggle", "label": "On", "default": true},
          {"id": "mode", "type": "select", "label": "Mode", "default": "a",
           "options": [{"value": "a", "label": "Alpha"}, {"value": "b"}]}
        ]}
        """)
        XCTAssertEqual(fields.count, 4)
        XCTAssertEqual(fields[0], WidgetSettingsField(id: "name", label: "Name", type: .text, defaultValue: .string("Home")))
        XCTAssertEqual(fields[1].defaultValue, .number(4.5))
        XCTAssertEqual(fields[2].defaultValue, .bool(true))
        XCTAssertEqual(fields[3].options, [
            WidgetSettingsField.Option(value: "a", label: "Alpha"),
            WidgetSettingsField.Option(value: "b", label: "b"),
        ])
    }

    func testLabelDefaultsToId() {
        let fields = parse(#"{"fields": [{"id": "unit", "type": "text"}]}"#)
        XCTAssertEqual(fields.first?.label, "unit")
        XCTAssertNil(fields.first?.defaultValue)
    }

    func testNonStringLabelFallsBackToId() {
        let fields = parse(#"{"fields": [{"id": "unit", "type": "text", "label": 42}]}"#)
        XCTAssertEqual(fields.first?.label, "unit")
    }

    func testRootThatIsNotAnObjectYieldsNoFields() {
        for json in ["[]", "null", "42", "\"fields\"", "true", "[{\"fields\": []}]"] {
            XCTAssertTrue(parse(json).isEmpty, json)
        }
    }

    func testMalformedJSONYieldsNoFields() {
        for json in ["", "{", "{\"fields\": [", "{'fields': []}", "\u{FEFF}{\"fields\": []}x", "{\"fields\": [,]}"] {
            XCTAssertTrue(parse(json).isEmpty, json)
        }
    }

    func testBinaryGarbageYieldsNoFields() {
        XCTAssertTrue(ExternalWidgetSettingsManifest.parse(Data([0x00, 0xFF, 0xFE, 0x7B, 0x80])).isEmpty)
    }

    func testFieldsKeyOfWrongTypeYieldsNoFields() {
        for json in [#"{"fields": {}}"#, #"{"fields": "x"}"#, #"{"fields": null}"#, #"{"fields": [1, 2]}"#, #"{}"#] {
            XCTAssertTrue(parse(json).isEmpty, json)
        }
    }

    func testInvalidEntriesAreSkippedNotFatal() {
        let fields = parse("""
        {"fields": [
          {"type": "text"},
          {"id": "", "type": "text"},
          {"id": 7, "type": "text"},
          {"id": "bad-type", "type": "slider"},
          {"id": "no-type"},
          {"id": "good", "type": "text"}
        ]}
        """)
        XCTAssertEqual(fields.map(\.id), ["good"])
    }

    func testOneNonObjectEntryKeepsTheOtherFields() {
        expectKnownBug("`as? [[String: Any]]` is all or nothing, so a single non-object element (a string, null, a number) discards every field, although the per-field parser is clearly meant to skip bad entries and keep the rest.")
        let fields = parse(#"{"fields": [{"id": "a", "type": "text"}, "oops", null, {"id": "b", "type": "text"}]}"#)
        XCTAssertEqual(fields.map(\.id), ["a", "b"])
    }

    func testOneNonObjectOptionKeepsTheOtherOptions() {
        expectKnownBug("Same all-or-nothing cast for select options: one stray element makes options nil.")
        let fields = parse(#"{"fields": [{"id": "m", "type": "select", "options": [{"value": "a"}, "stray", {"value": "b"}]}]}"#)
        XCTAssertEqual(fields.first?.options?.map(\.value), ["a", "b"])
    }

    func testDefaultOfWrongTypeIsDropped() {
        let fields = parse("""
        {"fields": [
          {"id": "t", "type": "text", "default": 5},
          {"id": "n", "type": "number", "default": "5"},
          {"id": "s", "type": "select", "default": false}
        ]}
        """)
        XCTAssertEqual(fields.count, 3)
        for field in fields { XCTAssertNil(field.defaultValue, field.id) }
    }

    func testToggleDefaultAcceptsIntegers() {
        let fields = parse(#"{"fields": [{"id": "a", "type": "toggle", "default": 1}, {"id": "b", "type": "toggle", "default": 0}]}"#)
        XCTAssertEqual(fields[0].defaultValue, .bool(true))
        XCTAssertEqual(fields[1].defaultValue, .bool(false))
    }

    func testToggleDefaultOfStringIsDropped() {
        XCTAssertNil(parse(#"{"fields": [{"id": "a", "type": "toggle", "default": "yes"}]}"#).first?.defaultValue)
    }

    func testNumberDefaultOfBooleanIsCoercedToNumber() {
        // Current behavior: JSON true is an NSNumber, so it becomes 1.0.
        let value = parse(#"{"fields": [{"id": "a", "type": "number", "default": true}]}"#).first?.defaultValue
        XCTAssertEqual(value, .number(1))
    }

    func testExtremeNumbersAreKeptFinite() {
        let fields = parse(#"{"fields": [{"id": "a", "type": "number", "default": 1e308}, {"id": "b", "type": "number", "default": -1e308}]}"#)
        XCTAssertEqual(fields[0].defaultValue, .number(1e308))
        XCTAssertEqual(fields[1].defaultValue, .number(-1e308))
    }

    func testSelectOptionsWithoutStringValueAreSkipped() {
        let fields = parse("""
        {"fields": [{"id": "m", "type": "select", "options": [
          {"value": 1, "label": "One"}, {"label": "Orphan"}, {"value": "ok", "label": 9}
        ]}]}
        """)
        XCTAssertEqual(fields.first?.options, [WidgetSettingsField.Option(value: "ok", label: "ok")])
    }

    func testOptionsAreIgnoredForNonSelectFields() {
        let fields = parse(#"{"fields": [{"id": "t", "type": "text", "options": [{"value": "x"}]}]}"#)
        XCTAssertNil(fields.first?.options)
    }

    func testSelectWithoutOptionsHasNilOptions() {
        XCTAssertNil(parse(#"{"fields": [{"id": "s", "type": "select"}]}"#).first?.options)
    }

    func testUnicodeIdsAndLabelsSurvive() {
        let fields = parse(#"{"fields": [{"id": "温度", "type": "text", "label": "🌡️ Température"}]}"#)
        XCTAssertEqual(fields.first?.id, "温度")
        XCTAssertEqual(fields.first?.label, "🌡️ Température")
    }

    func testIdsAreNotSanitized() {
        // Ids are opaque keys into the settings dictionary; traversal-looking
        // text is harmless there, and pinned so a change is deliberate.
        let fields = parse(#"{"fields": [{"id": "../../x", "type": "text"}]}"#)
        XCTAssertEqual(fields.first?.id, "../../x")
    }

    func testTenThousandFieldsParseQuickly() {
        let entries = (0..<10_000).map { #"{"id": "f\#($0)", "type": "toggle", "default": false}"# }
        let start = Date()
        let fields = parse(#"{"fields": [\#(entries.joined(separator: ","))]}"#)
        XCTAssertEqual(fields.count, 10_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testDeeplyNestedExtraStructureDoesNotCrash() {
        let depth = 500
        let nested = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        _ = parse(#"{"fields": [{"id": "a", "type": "text", "junk": \#(nested)}]}"#)
    }

    func testDuplicateFieldIdsAreCollapsed() {
        expectKnownBug("Duplicate field ids pass through unchanged. They are the Identifiable id and the settings dictionary key, so the second field shadows the first in the UI and storage.")
        let fields = parse("""
        {"fields": [{"id": "dup", "type": "text"}, {"id": "dup", "type": "toggle"}, {"id": "dup", "type": "number"}]}
        """)
        XCTAssertEqual(Set(fields.map(\.id)).count, fields.count)
    }

    // MARK: Loading from a bundle

    private func makeBundle(in directory: URL, name: String = "W.dockywidget", settings: Data?) throws -> Bundle {
        let root = directory.appendingPathComponent(name, isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "test.\(UUID().uuidString)", "CFBundleName": "W"]
        try (plist as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        if let settings {
            try settings.write(to: resources.appendingPathComponent("settings.json"))
        }
        return try XCTUnwrap(Bundle(url: root))
    }

    func testLoadReadsSettingsJSONFromBundleResources() throws {
        let dir = try makeScratchDirectory("manifest")
        let bundle = try makeBundle(in: dir, settings: Data(#"{"fields": [{"id": "a", "type": "text"}]}"#.utf8))
        XCTAssertEqual(ExternalWidgetSettingsManifest.load(from: bundle).map(\.id), ["a"])
    }

    func testLoadWithoutSettingsFileIsEmpty() throws {
        let dir = try makeScratchDirectory("manifest")
        let bundle = try makeBundle(in: dir, settings: nil)
        XCTAssertTrue(ExternalWidgetSettingsManifest.load(from: bundle).isEmpty)
    }

    func testLoadWithCorruptSettingsFileIsEmpty() throws {
        let dir = try makeScratchDirectory("manifest")
        let bundle = try makeBundle(in: dir, settings: Data("{{{{".utf8))
        XCTAssertTrue(ExternalWidgetSettingsManifest.load(from: bundle).isEmpty)
    }

    func testLoadWithZeroByteSettingsFileIsEmpty() throws {
        let dir = try makeScratchDirectory("manifest")
        let bundle = try makeBundle(in: dir, settings: Data())
        XCTAssertTrue(ExternalWidgetSettingsManifest.load(from: bundle).isEmpty)
    }

    func testLoadWhenSettingsPathIsADirectoryIsEmpty() throws {
        let dir = try makeScratchDirectory("manifest")
        let bundle = try makeBundle(in: dir, settings: nil)
        let asDirectory = bundle.bundleURL.appendingPathComponent("Contents/Resources/settings.json", isDirectory: true)
        try FileManager.default.createDirectory(at: asDirectory, withIntermediateDirectories: true)
        XCTAssertTrue(ExternalWidgetSettingsManifest.load(from: bundle).isEmpty)
    }

    func testOversizeManifestIsRejected() throws {
        expectKnownBug("The settings manifest is read and parsed with no size limit, so a hostile bundle can make launch read and parse an arbitrarily large file. 5 MB here stands in for 'far larger than any real manifest'.")
        let dir = try makeScratchDirectory("manifest")
        let filler = String(repeating: "{\"id\": \"f\", \"type\": \"text\"},", count: 200_000)
        let json = "{\"fields\": [\(filler){\"id\": \"last\", \"type\": \"text\"}]}"
        XCTAssertGreaterThan(json.utf8.count, 5_000_000)
        let bundle = try makeBundle(in: dir, settings: Data(json.utf8))
        XCTAssertTrue(ExternalWidgetSettingsManifest.load(from: bundle).isEmpty)
    }
}

// MARK: - Loader

@MainActor
final class ExternalWidgetLoaderTests: XCTestCase {

    private func makeLoader() throws -> (ExternalWidgetLoader, URL) {
        let root = try makeScratchDirectory("loader")
        let widgets = root.appendingPathComponent("Widgets", isDirectory: true)
        return (ExternalWidgetLoader(widgetsDirectory: widgets), widgets)
    }

    /// A directory that looks like a widget bundle. `executable` bytes, when
    /// given, are written where Info.plist says the binary lives. They are
    /// never valid Mach-O, so loading them cannot run code.
    @discardableResult
    private func makeFakeBundle(
        at url: URL,
        executableName: String? = nil,
        executableBytes: Data? = nil,
        principalClass: String? = nil
    ) throws -> URL {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": "test.\(UUID().uuidString)", "CFBundleName": "Fake"]
        if let executableName { plist["CFBundleExecutable"] = executableName }
        if let principalClass { plist["NSPrincipalClass"] = principalClass }
        try (plist as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        if let executableName, let executableBytes {
            let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try executableBytes.write(to: macOS.appendingPathComponent(executableName))
        }
        return url
    }

    // MARK: Constants

    func testBundleExtensionIsDockywidget() {
        XCTAssertEqual(ExternalWidgetLoader.bundleExtension, "dockywidget")
    }

    func testDefaultWidgetsDirectoryIsUnderApplicationSupportWharf() {
        let url = ExternalWidgetLoader.widgetsDirectoryURL()
        XCTAssertTrue(url.path.hasSuffix("/Wharf/Widgets"))
        XCTAssertTrue(url.path.contains("Application Support"))
    }

    func testEveryFailureHasAHumanReadableReason() {
        let all: [ExternalWidgetLoader.LoadFailure] = [
            .bundleNotOpenable, .missingExecutable, .loadCallFailed, .missingPrincipalClass, .notConformingToProtocol,
        ]
        for failure in all {
            XCTAssertFalse(failure.localizedReason.isEmpty)
            XCTAssertTrue(failure.localizedReason.hasSuffix("."))
        }
        XCTAssertEqual(Set(all.map(\.localizedReason)).count, all.count, "reasons are distinct")
    }

    // MARK: Directory scan

    func testInstalledBundleURLsCreatesTheDirectoryAndStartsEmpty() throws {
        let (loader, widgets) = try makeLoader()
        XCTAssertFalse(FileManager.default.fileExists(atPath: widgets.path))
        XCTAssertTrue(loader.installedBundleURLs().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: widgets.path))
    }

    func testScanKeepsOnlyDockywidgetBundles() throws {
        let (loader, widgets) = try makeLoader()
        try FileManager.default.createDirectory(at: widgets, withIntermediateDirectories: true)
        for name in ["A.dockywidget", "B.bundle", "C.dockywidget.bak", "D.DOCKYWIDGET", "notes.txt", "E"] {
            try makeFakeBundle(at: widgets.appendingPathComponent(name))
        }
        let names = loader.installedBundleURLs().map(\.lastPathComponent)
        XCTAssertEqual(names, ["A.dockywidget"])
    }

    func testScanSkipsHiddenEntries() throws {
        let (loader, widgets) = try makeLoader()
        try FileManager.default.createDirectory(at: widgets, withIntermediateDirectories: true)
        try makeFakeBundle(at: widgets.appendingPathComponent(".Hidden.dockywidget"))
        try makeFakeBundle(at: widgets.appendingPathComponent("Shown.dockywidget"))
        XCTAssertEqual(loader.installedBundleURLs().map(\.lastPathComponent), ["Shown.dockywidget"])
    }

    func testScanDoesNotDescendIntoSubdirectories() throws {
        let (loader, widgets) = try makeLoader()
        let nested = widgets.appendingPathComponent("group", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try makeFakeBundle(at: nested.appendingPathComponent("Deep.dockywidget"))
        XCTAssertTrue(loader.installedBundleURLs().isEmpty)
    }

    func testSymlinkedBundleIsListedAsIs() throws {
        // Current behavior, recorded as a finding: a symlink named
        // *.dockywidget is treated as an installed bundle even though its
        // target lives anywhere on disk. Library validation, not the scan,
        // is what stops unsigned code from loading.
        let (loader, widgets) = try makeLoader()
        try FileManager.default.createDirectory(at: widgets, withIntermediateDirectories: true)
        let outside = try makeScratchDirectory("outside")
        let target = try makeFakeBundle(at: outside.appendingPathComponent("Real.dockywidget"))
        let link = widgets.appendingPathComponent("Linked.dockywidget")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(loader.installedBundleURLs().map(\.lastPathComponent), ["Linked.dockywidget"])
    }

    func testManyJunkEntriesAreScannedQuickly() throws {
        let (loader, widgets) = try makeLoader()
        try FileManager.default.createDirectory(at: widgets, withIntermediateDirectories: true)
        for index in 0..<300 {
            let url = widgets.appendingPathComponent("w\(index).dockywidget", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let start = Date()
        XCTAssertEqual(loader.installedBundleURLs().count, 300)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    // MARK: Install and uninstall

    func testInstallCopiesBundleIntoWidgetsDirectory() throws {
        let (loader, widgets) = try makeLoader()
        let source = try makeScratchDirectory("src")
        let bundle = try makeFakeBundle(at: source.appendingPathComponent("Clock.dockywidget"))
        let installed = try loader.installBundle(from: bundle)
        XCTAssertEqual(installed.deletingLastPathComponent().standardizedFileURL.path, widgets.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("Contents/Info.plist").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path), "the source is copied, not moved")
    }

    func testInstallReplacesAnExistingBundleOfTheSameName() throws {
        let (loader, _) = try makeLoader()
        let source = try makeScratchDirectory("src")
        let first = try makeFakeBundle(at: source.appendingPathComponent("Clock.dockywidget"))
        let installed = try loader.installBundle(from: first)
        try Data("marker".utf8).write(to: installed.appendingPathComponent("old.txt"))

        let second = try makeScratchDirectory("src2").appendingPathComponent("Clock.dockywidget")
        try makeFakeBundle(at: second)
        _ = try loader.installBundle(from: second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.appendingPathComponent("old.txt").path))
    }

    func testInstallOfMissingSourceThrowsAndLeavesDirectoryIntact() throws {
        let (loader, widgets) = try makeLoader()
        let source = try makeScratchDirectory("src").appendingPathComponent("Ghost.dockywidget")
        XCTAssertThrowsError(try loader.installBundle(from: source))
        XCTAssertTrue(loader.installedBundleURLs().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: widgets.path))
    }

    func testInstallPreservesTheQuarantineAttribute() throws {
        // Audit run-1: the quarantine flag must survive installation so
        // Gatekeeper still sees the bundle's origin.
        let (loader, _) = try makeLoader()
        let source = try makeScratchDirectory("src")
        let bundle = try makeFakeBundle(at: source.appendingPathComponent("Q.dockywidget"))
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        let value = Array("0081;00000000;Safari;".utf8)
        let status = setxattr(plist.path, "com.apple.quarantine", value, value.count, 0, 0)
        try XCTSkipIf(status != 0, "filesystem rejected the quarantine attribute")

        let installed = try loader.installBundle(from: bundle)
        let copied = installed.appendingPathComponent("Contents/Info.plist")
        XCTAssertGreaterThan(getxattr(copied.path, "com.apple.quarantine", nil, 0, 0, 0), 0)
    }

    func testInstallRefusesNamesThatAreNotPlainBundleNames() throws {
        expectKnownBug("installBundle trusts sourceURL.lastPathComponent. A source URL ending in '..' makes the destination the Widgets directory's parent, which is then removed before the copy. No extension or component validation exists.")
        let root = try makeScratchDirectory("traversal")
        let widgets = root.appendingPathComponent("App Support/Wharf/Widgets", isDirectory: true)
        let loader = ExternalWidgetLoader(widgetsDirectory: widgets)
        let precious = root.appendingPathComponent("App Support/Wharf/precious.txt")
        try FileManager.default.createDirectory(at: widgets, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: precious)

        let source = URL(fileURLWithPath: root.path + "/src/..")
        XCTAssertThrowsError(try loader.installBundle(from: source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: precious.path), "nothing outside Widgets may be touched")
    }

    func testInstallAcceptsAnyExtensionToday() throws {
        // Current behavior: nothing checks that the source is a .dockywidget,
        // so a stray file is copied in (it is never loaded, since the scan
        // filters by extension).
        let (loader, _) = try makeLoader()
        let source = try makeScratchDirectory("src")
        let file = source.appendingPathComponent("readme.txt")
        try Data("hi".utf8).write(to: file)
        let installed = try loader.installBundle(from: file)
        XCTAssertEqual(installed.lastPathComponent, "readme.txt")
        XCTAssertTrue(loader.installedBundleURLs().isEmpty)
    }

    func testUninstallRemovesTheBundle() throws {
        let (loader, _) = try makeLoader()
        let source = try makeScratchDirectory("src")
        let bundle = try makeFakeBundle(at: source.appendingPathComponent("Gone.dockywidget"))
        let installed = try loader.installBundle(from: bundle)
        try loader.uninstallBundle(at: installed)
        XCTAssertTrue(loader.installedBundleURLs().isEmpty)
    }

    func testUninstallOfMissingBundleThrows() throws {
        let (loader, widgets) = try makeLoader()
        XCTAssertThrowsError(try loader.uninstallBundle(at: widgets.appendingPathComponent("Nope.dockywidget")))
    }

    func testUninstallStaysInsideTheWidgetsDirectory() throws {
        expectKnownBug("uninstallBundle removes whatever URL it is handed, with no check that it sits inside the Widgets directory.")
        let (loader, _) = try makeLoader()
        let outside = try makeScratchDirectory("outside")
        let victim = outside.appendingPathComponent("important.txt")
        try Data("x".utf8).write(to: victim)
        XCTAssertThrowsError(try loader.uninstallBundle(at: victim))
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
    }

    // MARK: Load failures (no foreign code can run)

    func testNonexistentBundleIsNotOpenable() throws {
        let (loader, widgets) = try makeLoader()
        let url = widgets.appendingPathComponent("Absent.dockywidget")
        loader.loadBundle(at: url)
        XCTAssertEqual(loader.loadFailures[url.standardizedFileURL], .bundleNotOpenable)
    }

    func testBundleWithoutBinaryFailsToLoad() throws {
        let (loader, widgets) = try makeLoader()
        let url = try makeFakeBundle(at: widgets.appendingPathComponent("NoBinary.dockywidget"))
        loader.loadBundle(at: url)
        let failure = try XCTUnwrap(loader.loadFailures[url.standardizedFileURL])
        XCTAssertTrue([.missingExecutable, .loadCallFailed].contains(failure), "got \(failure)")
    }

    func testBundleWhoseDeclaredBinaryIsMissingFailsToLoad() throws {
        let (loader, widgets) = try makeLoader()
        let url = try makeFakeBundle(at: widgets.appendingPathComponent("Declared.dockywidget"), executableName: "Declared")
        loader.loadBundle(at: url)
        let failure = try XCTUnwrap(loader.loadFailures[url.standardizedFileURL])
        XCTAssertTrue([.missingExecutable, .loadCallFailed].contains(failure), "got \(failure)")
    }

    func testBundleWithGarbageBinaryIsRejectedByTheLoader() throws {
        let (loader, widgets) = try makeLoader()
        let url = try makeFakeBundle(
            at: widgets.appendingPathComponent("Garbage.dockywidget"),
            executableName: "Garbage",
            executableBytes: Data("this is not Mach-O".utf8),
            principalClass: "Garbage.Plugin"
        )
        loader.loadBundle(at: url)
        XCTAssertEqual(loader.loadFailures[url.standardizedFileURL], .loadCallFailed)
        XCTAssertNil(ExternalWidgetRegistry.shared.registration(for: "Garbage"))
    }

    func testBundleWithEmptyBinaryIsRejectedByTheLoader() throws {
        let (loader, widgets) = try makeLoader()
        let url = try makeFakeBundle(
            at: widgets.appendingPathComponent("Empty.dockywidget"),
            executableName: "Empty",
            executableBytes: Data()
        )
        loader.loadBundle(at: url)
        XCTAssertNotNil(loader.loadFailures[url.standardizedFileURL])
    }

    func testTruncatedMachOHeaderIsRejected() throws {
        let (loader, widgets) = try makeLoader()
        // A Mach-O 64-bit magic number followed by nothing useful.
        let header = Data([0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01])
        let url = try makeFakeBundle(
            at: widgets.appendingPathComponent("Stub.dockywidget"),
            executableName: "Stub",
            executableBytes: header
        )
        loader.loadBundle(at: url)
        XCTAssertEqual(loader.loadFailures[url.standardizedFileURL], .loadCallFailed)
    }

    func testDiscoveryRecordsFailuresPerBundleAndKeepsGoing() throws {
        let (loader, widgets) = try makeLoader()
        try FileManager.default.createDirectory(at: widgets, withIntermediateDirectories: true)
        for name in ["One.dockywidget", "Two.dockywidget", "Three.dockywidget"] {
            try makeFakeBundle(
                at: widgets.appendingPathComponent(name),
                executableName: "bin",
                executableBytes: Data("junk".utf8)
            )
        }
        loader.discoverAndLoad()
        XCTAssertTrue(loader.hasDiscovered)
        XCTAssertEqual(loader.loadFailures.count, 3)
    }

    func testDiscoveryIsIdempotent() throws {
        let (loader, widgets) = try makeLoader()
        loader.discoverAndLoad()
        try makeFakeBundle(
            at: widgets.appendingPathComponent("Late.dockywidget"),
            executableName: "bin",
            executableBytes: Data("junk".utf8)
        )
        loader.discoverAndLoad()
        XCTAssertTrue(loader.loadFailures.isEmpty, "the second call must not rescan")
    }

    func testFreshLoaderHasNotDiscoveredAnything() throws {
        let (loader, _) = try makeLoader()
        XCTAssertFalse(loader.hasDiscovered)
        XCTAssertTrue(loader.loadFailures.isEmpty)
    }
}
