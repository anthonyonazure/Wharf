import XCTest
@testable import Wharf

/// App, Trash and folder icon overrides: persistence, duplicate handling and the
/// "does the icon file exist" resolution.
///
/// Regression area for the September audit: these setters used
/// `Dictionary(uniqueKeysWithValues:)`, which traps on a duplicate key, and the
/// stored list is attacker-writable. They now go through
/// `DataIntegrityReporter.makeDictionary`, which keeps the first entry.
final class IconOverrideTests: DockyPreferencesTestCase {

    // MARK: DataIntegrityReporter.makeDictionary

    func testMakeDictionaryKeepsTheFirstValueForDuplicateKeys() {
        let result = DataIntegrityReporter.makeDictionary(
            [("a", 1), ("b", 2), ("a", 3), ("a", 4), ("b", 5)],
            site: "test"
        )
        XCTAssertEqual(result, ["a": 1, "b": 2])
    }

    func testMakeDictionaryHandlesEmptyAndUniqueInput() {
        XCTAssertEqual(DataIntegrityReporter.makeDictionary([(String, Int)](), site: "test"), [:])
        XCTAssertEqual(DataIntegrityReporter.makeDictionary([("x", 1), ("y", 2)], site: "test"), ["x": 1, "y": 2])
    }

    func testMakeDictionaryHandlesTenThousandDuplicates() {
        let pairs = (0..<10_000).map { ("same", $0) }
        let result = DataIntegrityReporter.makeDictionary(pairs, site: "test")
        XCTAssertEqual(result, ["same": 0])
    }

    // MARK: App icon overrides

    private func seedAppOverrides(_ overrides: [AppIconOverride]) {
        defaults.set(encoded(overrides), forKey: PrefKeys.appIconOverrides)
    }

    func testAppOverridesDefaultToEmpty() {
        let prefs = makePrefs()
        XCTAssertEqual(prefs.appIconOverrides, [])
        XCTAssertNil(prefs.appIconOverride(forBundleIdentifier: "com.x"))
        XCTAssertEqual(prefs.appIconOverridePadding(forBundleIdentifier: "com.x"), 0)
    }

    func testSetAppOverridePersistsAndSurvivesReload() {
        let prefs = makePrefs()
        prefs.setAppIconOverride(bundleIdentifier: "com.a", iconPath: "/icons/a.png", paddingFraction: 0.15)
        let reloaded = reload()
        XCTAssertEqual(reloaded.appIconOverride(forBundleIdentifier: "com.a")?.iconPath, "/icons/a.png")
        XCTAssertEqual(reloaded.appIconOverridePadding(forBundleIdentifier: "com.a"), 0.15, accuracy: 1e-9)
    }

    func testSetAppOverrideIgnoresEmptyIdentifierOrPath() {
        let prefs = makePrefs()
        prefs.setAppIconOverride(bundleIdentifier: "", iconPath: "/x.png")
        prefs.setAppIconOverride(bundleIdentifier: "com.a", iconPath: "")
        XCTAssertEqual(prefs.appIconOverrides, [])
        XCTAssertNil(defaults.object(forKey: PrefKeys.appIconOverrides))
    }

    func testSetAppOverrideKeepsListSortedCaseInsensitively() {
        let prefs = makePrefs()
        for id in ["com.zeta", "com.Alpha", "com.beta", "COM.gamma"] {
            prefs.setAppIconOverride(bundleIdentifier: id, iconPath: "/i/\(id).png")
        }
        XCTAssertEqual(prefs.appIconOverrides.map(\.bundleIdentifier), ["com.Alpha", "com.beta", "COM.gamma", "com.zeta"])
    }

    func testSetAppOverrideReplacesExistingEntry() {
        let prefs = makePrefs()
        prefs.setAppIconOverride(bundleIdentifier: "com.a", iconPath: "/old.png")
        prefs.setAppIconOverride(bundleIdentifier: "com.a", iconPath: "/new.png", paddingFraction: 0.3)
        XCTAssertEqual(prefs.appIconOverrides.count, 1)
        XCTAssertEqual(prefs.appIconOverrides.first?.iconPath, "/new.png")
        XCTAssertEqual(prefs.appIconOverrides.first?.paddingFraction, 0.3)
    }

    func testSetAppOverrideWithDuplicateStoredEntriesDoesNotTrapAndKeepsFirst() {
        seedAppOverrides([
            AppIconOverride(bundleIdentifier: "com.dup", iconPath: "/first.png"),
            AppIconOverride(bundleIdentifier: "com.dup", iconPath: "/second.png"),
            AppIconOverride(bundleIdentifier: "com.other", iconPath: "/other.png"),
        ])
        let prefs = makePrefs()
        XCTAssertEqual(prefs.appIconOverrides.count, 3, "load keeps duplicates as stored")
        XCTAssertEqual(prefs.appIconOverride(forBundleIdentifier: "com.dup")?.iconPath, "/first.png")

        prefs.setAppIconOverride(bundleIdentifier: "com.new", iconPath: "/new.png")

        XCTAssertEqual(prefs.appIconOverrides.map(\.bundleIdentifier), ["com.dup", "com.new", "com.other"])
        XCTAssertEqual(prefs.appIconOverride(forBundleIdentifier: "com.dup")?.iconPath, "/first.png")
    }

    func testSetAppOverrideForTheDuplicatedIdentifierCollapsesToTheNewValue() {
        seedAppOverrides([
            AppIconOverride(bundleIdentifier: "com.dup", iconPath: "/first.png"),
            AppIconOverride(bundleIdentifier: "com.dup", iconPath: "/second.png"),
        ])
        let prefs = makePrefs()
        prefs.setAppIconOverride(bundleIdentifier: "com.dup", iconPath: "/fresh.png")
        XCTAssertEqual(prefs.appIconOverrides, [AppIconOverride(bundleIdentifier: "com.dup", iconPath: "/fresh.png")])
    }

    func testSetAppOverrideWithHugeDuplicateListDoesNotTrap() {
        seedAppOverrides((0..<2_000).map { AppIconOverride(bundleIdentifier: "com.same", iconPath: "/\($0).png") })
        let prefs = makePrefs()
        prefs.setAppIconOverride(bundleIdentifier: "com.other", iconPath: "/o.png")
        XCTAssertEqual(prefs.appIconOverrides.count, 2)
        XCTAssertEqual(prefs.appIconOverride(forBundleIdentifier: "com.same")?.iconPath, "/0.png")
    }

    func testBundleIdentifiersDifferingOnlyByCaseAreDistinct() {
        let prefs = makePrefs()
        prefs.setAppIconOverride(bundleIdentifier: "com.App", iconPath: "/1.png")
        prefs.setAppIconOverride(bundleIdentifier: "com.app", iconPath: "/2.png")
        XCTAssertEqual(prefs.appIconOverrides.count, 2)
        XCTAssertEqual(prefs.appIconOverride(forBundleIdentifier: "com.App")?.iconPath, "/1.png")
        XCTAssertEqual(prefs.appIconOverride(forBundleIdentifier: "com.app")?.iconPath, "/2.png")
    }

    func testAppOverrideAcceptsHostileButWellFormedStrings() {
        let prefs = makePrefs()
        let identifiers = [String(repeating: "a", count: 10_000), "\u{1F642}.app", "with space", "tab\there", "nul\0byte"]
        for (index, id) in identifiers.enumerated() {
            prefs.setAppIconOverride(bundleIdentifier: id, iconPath: "/i/\(index).png")
        }
        XCTAssertEqual(prefs.appIconOverrides.count, identifiers.count)
        XCTAssertEqual(reload().appIconOverrides.count, identifiers.count)
    }

    func testAppPaddingFractionUpdatesOnlyExistingOverrides() {
        let prefs = makePrefs()
        prefs.setAppIconPaddingFraction(bundleIdentifier: "com.none", paddingFraction: 0.2)
        XCTAssertEqual(prefs.appIconOverrides, [])

        prefs.setAppIconOverride(bundleIdentifier: "com.a", iconPath: "/a.png")
        prefs.setAppIconPaddingFraction(bundleIdentifier: "com.a", paddingFraction: 0.25)
        XCTAssertEqual(prefs.appIconOverridePadding(forBundleIdentifier: "com.a"), 0.25, accuracy: 1e-9)
        XCTAssertEqual(prefs.appIconOverride(forBundleIdentifier: "com.a")?.iconPath, "/a.png")

        prefs.setAppIconPaddingFraction(bundleIdentifier: "com.a", paddingFraction: nil)
        XCTAssertEqual(prefs.appIconOverridePadding(forBundleIdentifier: "com.a"), 0)
    }

    func testRemoveAppOverrideRemovesEveryDuplicate() {
        seedAppOverrides([
            AppIconOverride(bundleIdentifier: "com.dup", iconPath: "/1.png"),
            AppIconOverride(bundleIdentifier: "com.dup", iconPath: "/2.png"),
            AppIconOverride(bundleIdentifier: "com.keep", iconPath: "/k.png"),
        ])
        let prefs = makePrefs()
        prefs.removeAppIconOverride(bundleIdentifier: "com.dup")
        XCTAssertEqual(prefs.appIconOverrides.map(\.bundleIdentifier), ["com.keep"])
        XCTAssertEqual(reload().appIconOverrides.map(\.bundleIdentifier), ["com.keep"])
    }

    func testRemovingTheLastAppOverridePersistsAnEmptyList() {
        let prefs = makePrefs()
        prefs.setAppIconOverride(bundleIdentifier: "com.a", iconPath: "/a.png")
        prefs.removeAppIconOverride(bundleIdentifier: "com.a")
        XCTAssertEqual(reload().appIconOverrides, [])
    }

    func testRemovingAMissingAppOverrideIsANoOp() {
        let prefs = makePrefs()
        prefs.removeAppIconOverride(bundleIdentifier: "com.never")
        XCTAssertNil(defaults.object(forKey: PrefKeys.appIconOverrides))
    }

    func testManySequentialAppOverridesStayConsistent() {
        let prefs = makePrefs()
        for index in 0..<150 {
            prefs.setAppIconOverride(bundleIdentifier: "com.app.\(index % 50)", iconPath: "/\(index).png")
        }
        XCTAssertEqual(prefs.appIconOverrides.count, 50)
        XCTAssertEqual(prefs.appIconOverride(forBundleIdentifier: "com.app.7")?.iconPath, "/107.png")
    }

    func testEffectiveAppOverrideURLReturnsExistingFile() throws {
        let directory = makeTempDirectory()
        let icon = directory.appendingPathComponent("icon.png")
        try Data([0x89, 0x50]).write(to: icon)
        let prefs = makePrefs()
        prefs.setAppIconOverride(bundleIdentifier: "com.a", iconPath: icon.path)
        XCTAssertEqual(prefs.effectiveAppIconOverrideURL(forBundleIdentifier: "com.a")?.path, icon.path)
    }

    // MARK: Override value types

    func testAppOverrideEffectiveIconURLRequiresAnExistingPath() throws {
        let directory = makeTempDirectory()
        let file = directory.appendingPathComponent("real.png")
        try Data([1]).write(to: file)

        XCTAssertEqual(AppIconOverride(bundleIdentifier: "a", iconPath: file.path).effectiveIconURL?.path, file.path)
        XCTAssertNil(AppIconOverride(bundleIdentifier: "a", iconPath: "").effectiveIconURL)
        XCTAssertNil(AppIconOverride(bundleIdentifier: "a", iconPath: directory.appendingPathComponent("missing.png").path).effectiveIconURL)
    }

    func testTrashAndFolderOverrideEffectiveIconURLRequireAnExistingPath() throws {
        let directory = makeTempDirectory()
        let file = directory.appendingPathComponent("real.png")
        try Data([1]).write(to: file)

        XCTAssertNotNil(TrashIconOverride(state: .empty, iconPath: file.path).effectiveIconURL)
        XCTAssertNil(TrashIconOverride(state: .empty, iconPath: "/nonexistent/\(UUID().uuidString)").effectiveIconURL)
        XCTAssertNotNil(FolderIconOverride(folderPath: "/f", iconPath: file.path).effectiveIconURL)
        XCTAssertNil(FolderIconOverride(folderPath: "/f", iconPath: "").effectiveIconURL)
    }

    func testOverrideIdentifiers() {
        XCTAssertEqual(AppIconOverride(bundleIdentifier: "com.a", iconPath: "/x").id, "com.a")
        XCTAssertEqual(TrashIconOverride(state: .full, iconPath: "/x").id, "full")
        XCTAssertEqual(FolderIconOverride(folderPath: "/f", iconPath: "/x").id, "/f")
    }

    // MARK: Trash icon overrides

    private func seedTrashOverrides(_ overrides: [TrashIconOverride]) {
        defaults.set(encoded(overrides), forKey: PrefKeys.trashIconOverrides)
    }

    func testTrashOverridesDefaultToEmpty() {
        let prefs = makePrefs()
        XCTAssertEqual(prefs.trashIconOverrides, [])
        XCTAssertNil(prefs.trashIconOverride(forState: .empty))
        XCTAssertEqual(prefs.trashIconOverridePadding(forState: .full), 0)
    }

    func testTrashOverridesAreOrderedByStateNotInsertion() {
        let prefs = makePrefs()
        prefs.setTrashIconOverride(state: .full, iconPath: "/full.png")
        prefs.setTrashIconOverride(state: .empty, iconPath: "/empty.png")
        XCTAssertEqual(prefs.trashIconOverrides.map(\.state), [.empty, .full])
    }

    func testTrashOverrideRoundTripAndReplace() {
        let prefs = makePrefs()
        prefs.setTrashIconOverride(state: .empty, iconPath: "/a.png", paddingFraction: 0.1)
        prefs.setTrashIconOverride(state: .empty, iconPath: "/b.png")
        XCTAssertEqual(prefs.trashIconOverrides.count, 1)
        let reloaded = reload()
        XCTAssertEqual(reloaded.trashIconOverride(forState: .empty)?.iconPath, "/b.png")
        XCTAssertNil(reloaded.trashIconOverride(forState: .empty)?.paddingFraction)
    }

    func testTrashOverrideIgnoresEmptyPath() {
        let prefs = makePrefs()
        prefs.setTrashIconOverride(state: .empty, iconPath: "")
        XCTAssertEqual(prefs.trashIconOverrides, [])
    }

    func testTrashOverrideWithDuplicateStoredStatesDoesNotTrapAndKeepsFirst() {
        seedTrashOverrides([
            TrashIconOverride(state: .empty, iconPath: "/A"),
            TrashIconOverride(state: .empty, iconPath: "/B"),
            TrashIconOverride(state: .full, iconPath: "/C"),
        ])
        let prefs = makePrefs()
        XCTAssertEqual(prefs.trashIconOverride(forState: .empty)?.iconPath, "/A")

        prefs.setTrashIconOverride(state: .full, iconPath: "/D")

        XCTAssertEqual(prefs.trashIconOverrides.map(\.iconPath), ["/A", "/D"])
        XCTAssertEqual(prefs.trashIconOverrides.map(\.state), [.empty, .full])
    }

    func testTrashOverrideWithOnlyDuplicatesOfOneStateDoesNotTrap() {
        seedTrashOverrides((0..<500).map { TrashIconOverride(state: .full, iconPath: "/\($0)") })
        let prefs = makePrefs()
        prefs.setTrashIconOverride(state: .empty, iconPath: "/e")
        XCTAssertEqual(prefs.trashIconOverrides.map(\.iconPath), ["/e", "/0"])
    }

    func testTrashPaddingFractionUpdatesOnlyExistingOverrides() {
        let prefs = makePrefs()
        prefs.setTrashIconPaddingFraction(state: .empty, paddingFraction: 0.2)
        XCTAssertEqual(prefs.trashIconOverrides, [])
        prefs.setTrashIconOverride(state: .empty, iconPath: "/e.png")
        prefs.setTrashIconPaddingFraction(state: .empty, paddingFraction: 0.2)
        XCTAssertEqual(prefs.trashIconOverridePadding(forState: .empty), 0.2, accuracy: 1e-9)
    }

    func testRemoveTrashOverrideRemovesEveryDuplicate() {
        seedTrashOverrides([
            TrashIconOverride(state: .empty, iconPath: "/1"),
            TrashIconOverride(state: .empty, iconPath: "/2"),
            TrashIconOverride(state: .full, iconPath: "/3"),
        ])
        let prefs = makePrefs()
        prefs.removeTrashIconOverride(state: .empty)
        XCTAssertEqual(prefs.trashIconOverrides.map(\.state), [.full])
    }

    func testEffectiveTrashOverrideURLTracksFileExistence() throws {
        let directory = makeTempDirectory()
        let icon = directory.appendingPathComponent("trash.png")
        let prefs = makePrefs()
        prefs.setTrashIconOverride(state: .full, iconPath: icon.path)
        XCTAssertNil(prefs.effectiveTrashIconOverrideURL(forState: .full), "file does not exist yet")
        try Data([1]).write(to: icon)
        XCTAssertEqual(prefs.effectiveTrashIconOverrideURL(forState: .full)?.path, icon.path)
        XCTAssertNil(prefs.effectiveTrashIconOverrideURL(forState: .empty))
    }

    // MARK: Folder icon overrides

    private func seedFolderOverrides(_ overrides: [FolderIconOverride]) {
        defaults.set(encoded(overrides), forKey: PrefKeys.folderIconOverrides)
    }

    func testFolderOverridesDefaultToEmpty() {
        let prefs = makePrefs()
        XCTAssertEqual(prefs.folderIconOverrides, [])
        XCTAssertNil(prefs.folderIconOverride(forPath: "/x"))
        XCTAssertEqual(prefs.folderIconOverridePadding(forPath: "/x"), 0)
    }

    func testFolderOverrideRoundTripSortedAndReplace() {
        let prefs = makePrefs()
        prefs.setFolderIconOverride(folderPath: "/b", iconPath: "/1.png")
        prefs.setFolderIconOverride(folderPath: "/A", iconPath: "/2.png")
        prefs.setFolderIconOverride(folderPath: "/b", iconPath: "/3.png", paddingFraction: 0.4)
        XCTAssertEqual(prefs.folderIconOverrides.map(\.folderPath), ["/A", "/b"])
        let reloaded = reload()
        XCTAssertEqual(reloaded.folderIconOverride(forPath: "/b")?.iconPath, "/3.png")
        XCTAssertEqual(reloaded.folderIconOverridePadding(forPath: "/b"), 0.4, accuracy: 1e-9)
    }

    func testFolderOverrideIgnoresEmptyPathOrIcon() {
        let prefs = makePrefs()
        prefs.setFolderIconOverride(folderPath: "", iconPath: "/i.png")
        prefs.setFolderIconOverride(folderPath: "/f", iconPath: "")
        XCTAssertEqual(prefs.folderIconOverrides, [])
    }

    func testFolderOverrideWithDuplicateStoredPathsDoesNotTrapAndKeepsFirst() {
        seedFolderOverrides([
            FolderIconOverride(folderPath: "/dup", iconPath: "/first"),
            FolderIconOverride(folderPath: "/dup", iconPath: "/second"),
        ])
        let prefs = makePrefs()
        prefs.setFolderIconOverride(folderPath: "/new", iconPath: "/n")
        XCTAssertEqual(prefs.folderIconOverrides.map(\.folderPath), ["/dup", "/new"])
        XCTAssertEqual(prefs.folderIconOverride(forPath: "/dup")?.iconPath, "/first")
    }

    func testFolderPathsAreComparedVerbatim() {
        let prefs = makePrefs()
        prefs.setFolderIconOverride(folderPath: "/a/b", iconPath: "/1")
        prefs.setFolderIconOverride(folderPath: "/a/b/", iconPath: "/2")
        prefs.setFolderIconOverride(folderPath: "/a/../a/b", iconPath: "/3")
        XCTAssertEqual(prefs.folderIconOverrides.count, 3)
    }

    func testFolderPaddingFractionUpdatesOnlyExistingOverrides() {
        let prefs = makePrefs()
        prefs.setFolderIconPaddingFraction(folderPath: "/none", paddingFraction: 0.1)
        XCTAssertEqual(prefs.folderIconOverrides, [])
        prefs.setFolderIconOverride(folderPath: "/f", iconPath: "/i.png")
        prefs.setFolderIconPaddingFraction(folderPath: "/f", paddingFraction: 0.35)
        XCTAssertEqual(prefs.folderIconOverridePadding(forPath: "/f"), 0.35, accuracy: 1e-9)
    }

    func testRemoveFolderOverrideRemovesEveryDuplicate() {
        seedFolderOverrides([
            FolderIconOverride(folderPath: "/dup", iconPath: "/1"),
            FolderIconOverride(folderPath: "/dup", iconPath: "/2"),
            FolderIconOverride(folderPath: "/keep", iconPath: "/3"),
        ])
        let prefs = makePrefs()
        prefs.removeFolderIconOverride(folderPath: "/dup")
        XCTAssertEqual(prefs.folderIconOverrides.map(\.folderPath), ["/keep"])
    }

    func testEffectiveFolderOverrideURLTracksFileExistence() throws {
        let directory = makeTempDirectory()
        let icon = directory.appendingPathComponent("folder.png")
        let prefs = makePrefs()
        prefs.setFolderIconOverride(folderPath: "/f", iconPath: icon.path)
        XCTAssertNil(prefs.effectiveFolderIconOverrideURL(forPath: "/f"))
        try Data([1]).write(to: icon)
        XCTAssertEqual(prefs.effectiveFolderIconOverrideURL(forPath: "/f")?.path, icon.path)
    }

    // MARK: Launchpad and Start menu icon helpers

    func testLaunchpadIconOverrideURLRequiresAnExistingFile() throws {
        let directory = makeTempDirectory()
        let icon = directory.appendingPathComponent("lp.png")
        let prefs = makePrefs()
        XCTAssertNil(prefs.effectiveLaunchpadIconOverrideURL)
        XCTAssertEqual(prefs.effectiveLaunchpadIconOverridePadding, 0)

        prefs.launchpadIconPath = icon.path
        prefs.launchpadIconPaddingFraction = 0.3
        XCTAssertNil(prefs.effectiveLaunchpadIconOverrideURL)
        XCTAssertEqual(prefs.effectiveLaunchpadIconOverridePadding, 0, "padding only applies once the icon resolves")

        try Data([1]).write(to: icon)
        XCTAssertEqual(prefs.effectiveLaunchpadIconOverrideURL?.path, icon.path)
        XCTAssertEqual(prefs.effectiveLaunchpadIconOverridePadding, 0.3, accuracy: 1e-9)
    }

    func testStartMenuIconOverrideURLRequiresAnExistingFile() throws {
        let directory = makeTempDirectory()
        let icon = directory.appendingPathComponent("sm.png")
        let prefs = makePrefs()
        prefs.startMenuIconPath = icon.path
        prefs.startMenuIconPaddingFraction = 0.1
        XCTAssertNil(prefs.effectiveStartMenuIconOverrideURL)
        XCTAssertEqual(prefs.effectiveStartMenuIconOverridePadding, 0)
        try Data([1]).write(to: icon)
        XCTAssertEqual(prefs.effectiveStartMenuIconOverrideURL?.path, icon.path)
        XCTAssertEqual(prefs.effectiveStartMenuIconOverridePadding, 0.1, accuracy: 1e-9)
    }
}
