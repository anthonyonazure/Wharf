import XCTest
@testable import Wharf

// MARK: - Model

final class LaunchpadLayoutModelTests: XCTestCase {

    private func app(_ id: String) -> LaunchpadLayoutItem { .app(bundleID: id) }
    private func folder(_ id: String, _ name: String = "F", _ bundles: [String]) -> LaunchpadLayoutItem {
        .folder(LaunchpadFolder(id: id, name: name, bundleIDs: bundles))
    }

    func testItemIdentifiersAreNamespaced() {
        XCTAssertEqual(app("com.a").id, "app:com.a")
        XCTAssertEqual(folder("uuid-1", "F", []).id, "folder:uuid-1")
    }

    func testAppAndFolderWithSameStringDoNotCollide() {
        XCTAssertNotEqual(app("x").id, folder("x", "F", []).id)
    }

    func testBundleIDsExposeFolderMembers() {
        XCTAssertEqual(app("a").bundleIDs, ["a"])
        XCTAssertEqual(folder("f", "F", ["a", "b"]).bundleIDs, ["a", "b"])
        XCTAssertEqual(folder("f", "F", []).bundleIDs, [])
    }

    func testEmptyLayout() {
        XCTAssertTrue(LaunchpadLayout.empty.items.isEmpty)
        XCTAssertEqual(LaunchpadLayout.empty, LaunchpadLayout(items: []))
    }

    func testLayoutRoundTripsThroughJSON() throws {
        let layout = LaunchpadLayout(items: [
            app("com.a"), folder("id-1", "Utilities", ["com.b", "com.c"]), app("com.d"),
        ])
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(LaunchpadLayout.self, from: data), layout)
    }

    func testUnicodeNamesAndIdentifiersRoundTrip() throws {
        let layout = LaunchpadLayout(items: [
            app("com.例え.アプリ"), folder("üñí", "📁 Tools “quoted” \\ / \n tab\t", ["é", "🙂"]),
        ])
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(LaunchpadLayout.self, from: data), layout)
    }

    func testVeryLongStringsRoundTrip() throws {
        let long = String(repeating: "x", count: 100_000)
        let layout = LaunchpadLayout(items: [folder(long, long, [long])])
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(LaunchpadLayout.self, from: data), layout)
    }

    func testUnknownItemKindIsRejected() throws {
        let data = try JSONEncoder().encode(LaunchpadLayout(items: [app("a")]))
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"app\"", with: "\"widget\"")
        XCTAssertThrowsError(try JSONDecoder().decode(LaunchpadLayout.self, from: Data(text.utf8)))
    }

    func testStructurallyWrongPayloadsAreRejected() {
        let payloads = ["", "null", "[]", "{}", #"{"items": null}"#, #"{"items": "x"}"#, #"{"items": [1]}"#, #"{"items": [{}]}"#,
                        #"{"items": [{"app": null}]}"#, #"{"items": [{"app": {"bundleID": 5}}]}"#]
        for payload in payloads {
            XCTAssertThrowsError(try JSONDecoder().decode(LaunchpadLayout.self, from: Data(payload.utf8)), payload)
        }
    }

    func testFoldersCannotNest() throws {
        // A folder's members are bundle id strings, so the model has no way
        // to express a folder inside a folder, and the decoder refuses one.
        let data = try JSONEncoder().encode(LaunchpadLayout(items: [folder("outer", "O", ["a"])]))
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: #""bundleIDs":["a"]"#, with: #""bundleIDs":[{"folder":{"_0":{"id":"inner","name":"I","bundleIDs":["b"]}}}]"#)
        XCTAssertThrowsError(try JSONDecoder().decode(LaunchpadLayout.self, from: Data(text.utf8)))
    }

    func testPathologicallyDeepJSONIsRejectedNotFatal() {
        let depth = 20_000
        let text = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        XCTAssertThrowsError(try JSONDecoder().decode(LaunchpadLayout.self, from: Data(text.utf8)))
    }

    func testHugeLayoutRoundTrips() throws {
        let items = (0..<20_000).map { app("com.example.app\($0)") }
        let layout = LaunchpadLayout(items: items)
        let start = Date()
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(LaunchpadLayout.self, from: data).items.count, 20_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    // MARK: Drag payload

    func testDragPayloadAccessors() {
        let top = LaunchpadDragPayload(source: .topLevelApp(bundleID: "a"))
        XCTAssertEqual(top.bundleID, "a")
        XCTAssertNil(top.originFolderID)

        let folder = LaunchpadDragPayload(source: .topLevelFolder(folderID: "f"))
        XCTAssertNil(folder.bundleID)
        XCTAssertNil(folder.originFolderID)

        let inside = LaunchpadDragPayload(source: .folderApp(folderID: "f", bundleID: "b"))
        XCTAssertEqual(inside.bundleID, "b")
        XCTAssertEqual(inside.originFolderID, "f")
    }

    func testDragPayloadRoundTrips() throws {
        for source in [
            LaunchpadDragPayload.Source.topLevelApp(bundleID: "a"),
            .topLevelFolder(folderID: "f"),
            .folderApp(folderID: "f", bundleID: "b"),
        ] {
            let payload = LaunchpadDragPayload(source: source)
            let data = try JSONEncoder().encode(payload)
            XCTAssertEqual(try JSONDecoder().decode(LaunchpadDragPayload.self, from: data), payload)
        }
    }

    func testForeignDragDataIsRejected() {
        for text in ["", "hello", #"{"source": "app"}"#, #"{"source": {"unknown": {}}}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(LaunchpadDragPayload.self, from: Data(text.utf8)), text)
        }
    }

    // MARK: Pagination

    func testPaginationBasics() {
        XCTAssertEqual(launchpadPaginate(Array(1...10), pageSize: 4), [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10]])
        XCTAssertEqual(launchpadPaginate(Array(1...8), pageSize: 4), [[1, 2, 3, 4], [5, 6, 7, 8]])
        XCTAssertEqual(launchpadPaginate([1], pageSize: 4), [[1]])
        XCTAssertEqual(launchpadPaginate([1, 2, 3], pageSize: 1), [[1], [2], [3]])
    }

    func testPaginationAlwaysYieldsAtLeastOnePage() {
        XCTAssertEqual(launchpadPaginate([Int](), pageSize: 4).count, 1)
        XCTAssertTrue(launchpadPaginate([Int](), pageSize: 4)[0].isEmpty)
    }

    func testNonPositivePageSizesYieldASingleEmptyPage() {
        for size in [0, -1, -100, Int.min] {
            let pages = launchpadPaginate([1, 2, 3], pageSize: size)
            XCTAssertEqual(pages.count, 1, "size \(size)")
            XCTAssertTrue(pages[0].isEmpty)
        }
    }

    func testHugePageSizeDoesNotOverflow() {
        let pages = launchpadPaginate([1, 2, 3], pageSize: Int.max)
        XCTAssertEqual(pages, [[1, 2, 3]])
    }

    func testPageSizeLargerThanCount() {
        XCTAssertEqual(launchpadPaginate([1, 2], pageSize: 50), [[1, 2]])
    }

    func testPaginationPreservesOrderAndCount() {
        let items = Array(0..<1_003)
        for size in [1, 7, 35, 100, 1_003, 1_004] {
            let pages = launchpadPaginate(items, pageSize: size)
            XCTAssertEqual(pages.flatMap { $0 }, items, "size \(size)")
            XCTAssertEqual(pages.count, (items.count + size - 1) / size)
            XCTAssertTrue(pages.dropLast().allSatisfy { $0.count == size })
        }
    }

    func testPaginationOfHugeListIsFast() {
        let items = Array(0..<500_000)
        let start = Date()
        XCTAssertEqual(launchpadPaginate(items, pageSize: 35).count, 14_286)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}

// MARK: - Resolving a layout against installed apps

final class LaunchpadResolveTests: XCTestCase {

    private func apps(_ ids: [String]) -> [String: AppTile] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, AppTile(bundleIdentifier: $0, displayName: $0.uppercased())) })
    }

    private func resolve(_ items: [LaunchpadLayoutItem], installed: [String]) -> [LaunchpadEntry] {
        LaunchpadOverlayService.resolveEntries(layout: LaunchpadLayout(items: items), appsByBundleID: apps(installed))
    }

    func testInstalledAppsResolveInLayoutOrder() {
        let entries = resolve([.app(bundleID: "b"), .app(bundleID: "a")], installed: ["a", "b"])
        XCTAssertEqual(entries.map(\.id), ["app:b", "app:a"])
    }

    func testUninstalledAppsAreOmitted() {
        let entries = resolve([.app(bundleID: "a"), .app(bundleID: "gone")], installed: ["a"])
        XCTAssertEqual(entries.map(\.id), ["app:a"])
    }

    func testFolderWithTwoInstalledAppsStaysAFolder() {
        let folder = LaunchpadFolder(id: "f", name: "Tools", bundleIDs: ["a", "b"])
        let entries = resolve([.folder(folder)], installed: ["a", "b"])
        XCTAssertEqual(entries.count, 1)
        guard case .folder(let tile) = entries[0] else { return XCTFail("expected a folder") }
        XCTAssertEqual(tile.displayName, "Tools")
        XCTAssertEqual(tile.identifier, "virtual:f")
        XCTAssertEqual(tile.apps.map(\.bundleIdentifier), ["a", "b"])
    }

    func testFolderWithOneSurvivorRendersAsPlainApp() {
        let folder = LaunchpadFolder(id: "f", name: "Tools", bundleIDs: ["a", "gone"])
        let entries = resolve([.folder(folder)], installed: ["a"])
        XCTAssertEqual(entries.map(\.id), ["app:a"])
    }

    func testFolderWithNoSurvivorsIsOmitted() {
        let folder = LaunchpadFolder(id: "f", name: "Tools", bundleIDs: ["gone", "gone2"])
        XCTAssertTrue(resolve([.folder(folder)], installed: ["a"]).isEmpty)
    }

    func testEmptyFolderIsOmitted() {
        XCTAssertTrue(resolve([.folder(LaunchpadFolder(id: "f", name: "x", bundleIDs: []))], installed: ["a"]).isEmpty)
    }

    func testAppsWithinFolderKeepFolderOrder() {
        let folder = LaunchpadFolder(id: "f", name: "x", bundleIDs: ["c", "a", "b"])
        guard case .folder(let tile) = resolve([.folder(folder)], installed: ["a", "b", "c"])[0] else {
            return XCTFail("expected a folder")
        }
        XCTAssertEqual(tile.apps.map(\.bundleIdentifier), ["c", "a", "b"])
    }

    func testNoInstalledAppsYieldsNoEntries() {
        XCTAssertTrue(resolve([.app(bundleID: "a")], installed: []).isEmpty)
    }

    func testAppNotInLayoutIsNotInvented() {
        XCTAssertTrue(resolve([], installed: ["a", "b"]).isEmpty)
    }

    func testEntriesAreUniqueEvenWhenPersistedDataRepeatsAnApp() {
        expectKnownBug("The LaunchpadFolder contract says the resolver dedupes across folders, preferring the earliest, but resolveEntries does not. Hand-edited or corrupted persisted data shows the same app twice, with duplicate view identities.")
        let items: [LaunchpadLayoutItem] = [
            .app(bundleID: "a"),
            .folder(LaunchpadFolder(id: "f1", name: "One", bundleIDs: ["a", "b"])),
            .folder(LaunchpadFolder(id: "f2", name: "Two", bundleIDs: ["b", "c"])),
            .app(bundleID: "c"),
        ]
        let entries = resolve(items, installed: ["a", "b", "c"])
        let appIDs = entries.flatMap { entry -> [String] in
            switch entry {
            case .app(let app): return [app.bundleIdentifier]
            case .folder(let tile): return tile.apps.map(\.bundleIdentifier)
            }
        }
        XCTAssertEqual(appIDs.count, Set(appIDs).count)
    }

    func testDuplicateFolderIdentifiersDoNotCrash() {
        let items: [LaunchpadLayoutItem] = [
            .folder(LaunchpadFolder(id: "same", name: "One", bundleIDs: ["a", "b"])),
            .folder(LaunchpadFolder(id: "same", name: "Two", bundleIDs: ["c", "d"])),
        ]
        XCTAssertEqual(resolve(items, installed: ["a", "b", "c", "d"]).count, 2)
    }

    func testLargeLayoutResolvesQuickly() {
        let ids = (0..<20_000).map { "app\($0)" }
        let start = Date()
        let entries = resolve(ids.map { .app(bundleID: $0) }, installed: ids)
        XCTAssertEqual(entries.count, 20_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}

// MARK: - Service

@MainActor
final class LaunchpadLayoutServiceTests: XCTestCase {

    private let key = LaunchpadLayoutService.Keys.layout

    private func makeService(defaults: UserDefaults? = nil) -> (LaunchpadLayoutService, UserDefaults) {
        let defaults = defaults ?? makeIsolatedDefaults()
        return (LaunchpadLayoutService(defaults: defaults), defaults)
    }

    private func seeded(_ items: [LaunchpadLayoutItem]) -> LaunchpadLayoutService {
        let (service, _) = makeService()
        service.seedIfEmpty(items)
        return service
    }

    private func app(_ id: String) -> LaunchpadLayoutItem { .app(bundleID: id) }
    private func folder(_ id: String, _ bundles: [String], name: String = "F") -> LaunchpadLayoutItem {
        .folder(LaunchpadFolder(id: id, name: name, bundleIDs: bundles))
    }
    private func ids(_ service: LaunchpadLayoutService) -> [String] { service.layout.items.map(\.id) }

    /// Every bundle id in the layout, in order, folders flattened.
    private func allBundles(_ service: LaunchpadLayoutService) -> [String] {
        service.layout.items.flatMap(\.bundleIDs)
    }

    // MARK: Persistence

    func testStartsEmptyWithNoPersistedData() {
        let (service, _) = makeService()
        XCTAssertEqual(service.layout, .empty)
    }

    func testPersistedLayoutIsRestored() throws {
        let defaults = makeIsolatedDefaults()
        let layout = LaunchpadLayout(items: [app("a"), folder("f", ["b", "c"])])
        defaults.set(try JSONEncoder().encode(layout), forKey: key)
        XCTAssertEqual(LaunchpadLayoutService(defaults: defaults).layout, layout)
    }

    func testCorruptPersistedDataFallsBackToEmpty() {
        let payloads: [Data] = [
            Data(), Data("not json".utf8), Data("[]".utf8), Data(#"{"items": [{"nope": 1}]}"#.utf8),
            Data(repeating: 0xFF, count: 512), Data(String(repeating: "[", count: 50_000).utf8),
        ]
        for payload in payloads {
            let defaults = makeIsolatedDefaults()
            defaults.set(payload, forKey: key)
            XCTAssertEqual(LaunchpadLayoutService(defaults: defaults).layout, .empty)
        }
    }

    func testWrongTypeUnderTheKeyFallsBackToEmpty() {
        let defaults = makeIsolatedDefaults()
        defaults.set("a string, not data", forKey: key)
        XCTAssertEqual(LaunchpadLayoutService(defaults: defaults).layout, .empty)
        defaults.set(42, forKey: key)
        XCTAssertEqual(LaunchpadLayoutService(defaults: defaults).layout, .empty)
    }

    func testMutationsPersistAndSurviveRestart() throws {
        let (service, defaults) = makeService()
        service.seedIfEmpty([app("a"), app("b"), app("c")])
        service.moveItem(id: "app:c", toIndex: 0)
        let reloaded = LaunchpadLayoutService(defaults: defaults)
        XCTAssertEqual(reloaded.layout, service.layout)
        XCTAssertEqual(ids(reloaded), ["app:c", "app:a", "app:b"])
    }

    func testPersistedDuplicatesAreLoadedAsIs() throws {
        // Loading does not repair; repair happens through prune/append and the
        // resolver. Recorded so the behavior is intentional.
        let defaults = makeIsolatedDefaults()
        let layout = LaunchpadLayout(items: [app("a"), app("a"), folder("f", ["a", "a"])])
        defaults.set(try JSONEncoder().encode(layout), forKey: key)
        XCTAssertEqual(allBundles(LaunchpadLayoutService(defaults: defaults)), ["a", "a", "a", "a"])
    }

    // MARK: Seeding

    func testSeedOnlyAppliesToAnEmptyLayout() {
        let (service, _) = makeService()
        service.seedIfEmpty([app("a")])
        service.seedIfEmpty([app("z")])
        XCTAssertEqual(ids(service), ["app:a"])
    }

    func testSeedWithNothingKeepsTheLayoutEmpty() {
        let (service, defaults) = makeService()
        service.seedIfEmpty([])
        XCTAssertEqual(service.layout, .empty)
        XCTAssertNil(defaults.data(forKey: key), "an empty seed is not persisted")
    }

    // MARK: Lookups

    func testFolderLookup() {
        let service = seeded([app("a"), folder("f", ["b", "c"], name: "Tools")])
        XCTAssertEqual(service.folder(withID: "f")?.name, "Tools")
        XCTAssertNil(service.folder(withID: "a"))
        XCTAssertNil(service.folder(withID: ""))
        XCTAssertNil(service.folder(withID: "missing"))
    }

    func testReferencedBundleIDsCoverTopLevelAndFolders() {
        let service = seeded([app("a"), folder("f", ["b", "c"])])
        XCTAssertEqual(service.allReferencedBundleIDs, ["a", "b", "c"])
    }

    // MARK: Top-level reorder

    func testMoveToIndex() {
        let service = seeded([app("a"), app("b"), app("c"), app("d")])
        service.moveItem(id: "app:a", toIndex: 2)
        XCTAssertEqual(ids(service), ["app:b", "app:c", "app:a", "app:d"])
    }

    func testMoveClampsOutOfRangeTargets() {
        let service = seeded([app("a"), app("b"), app("c")])
        service.moveItem(id: "app:a", toIndex: 99)
        XCTAssertEqual(ids(service), ["app:b", "app:c", "app:a"])
        service.moveItem(id: "app:a", toIndex: -50)
        XCTAssertEqual(ids(service), ["app:a", "app:b", "app:c"])
        service.moveItem(id: "app:b", toIndex: Int.max)
        XCTAssertEqual(ids(service), ["app:a", "app:c", "app:b"])
        service.moveItem(id: "app:b", toIndex: Int.min)
        XCTAssertEqual(ids(service), ["app:b", "app:a", "app:c"])
    }

    func testMoveOfUnknownItemIsIgnored() {
        let service = seeded([app("a"), app("b")])
        service.moveItem(id: "app:ghost", toIndex: 0)
        XCTAssertEqual(ids(service), ["app:a", "app:b"])
    }

    func testMoveOnEmptyLayoutIsIgnored() {
        let (service, _) = makeService()
        service.moveItem(id: "app:a", toIndex: 0)
        XCTAssertEqual(service.layout, .empty)
    }

    func testMoveToSamePositionDoesNotPersist() {
        let (service, defaults) = makeService()
        service.seedIfEmpty([app("a"), app("b")])
        let before = defaults.data(forKey: key)
        service.moveItem(id: "app:a", toIndex: 0)
        XCTAssertEqual(defaults.data(forKey: key), before)
    }

    func testMoveRelativeBeforeAndAfter() {
        let service = seeded([app("a"), app("b"), app("c"), app("d")])
        service.moveItem(id: "app:d", relativeTo: "app:b", position: .before)
        XCTAssertEqual(ids(service), ["app:a", "app:d", "app:b", "app:c"])
        service.moveItem(id: "app:a", relativeTo: "app:c", position: .after)
        XCTAssertEqual(ids(service), ["app:d", "app:b", "app:c", "app:a"])
    }

    func testMoveRelativeToMissingAnchorIsIgnored() {
        let service = seeded([app("a"), app("b")])
        service.moveItem(id: "app:a", relativeTo: "app:ghost", position: .after)
        XCTAssertEqual(ids(service), ["app:a", "app:b"])
    }

    func testMoveRelativeToItselfChangesNothing() {
        let service = seeded([app("a"), app("b"), app("c")])
        service.moveItem(id: "app:b", relativeTo: "app:b", position: .before)
        XCTAssertEqual(ids(service), ["app:a", "app:b", "app:c"])
        service.moveItem(id: "app:b", relativeTo: "app:b", position: .after)
        XCTAssertEqual(ids(service), ["app:a", "app:b", "app:c"])
    }

    func testMoveRelativePopsAppOutOfItsFolder() {
        let service = seeded([folder("f", ["a", "b", "c"]), app("z")])
        service.moveItem(id: "app:a", relativeTo: "app:z", position: .after)
        XCTAssertEqual(ids(service), ["folder:f", "app:z", "app:a"])
        XCTAssertEqual(service.folder(withID: "f")?.bundleIDs, ["b", "c"])
        XCTAssertEqual(Set(allBundles(service)), ["a", "b", "c", "z"])
    }

    // MARK: Folders

    func testCreateFolderMergesTwoApps() throws {
        let service = seeded([app("a"), app("b"), app("c")])
        let id = try XCTUnwrap(service.createFolder(merging: "c", intoSlotOf: "a", name: "Pair"))
        XCTAssertEqual(service.folder(withID: id)?.bundleIDs, ["a", "c"])
        XCTAssertEqual(service.folder(withID: id)?.name, "Pair")
        XCTAssertEqual(service.layout.items.count, 2)
        XCTAssertEqual(ids(service), ["folder:\(id)", "app:b"])
    }

    func testCreateFolderRefusesSelfMerge() {
        let service = seeded([app("a"), app("b")])
        XCTAssertNil(service.createFolder(merging: "a", intoSlotOf: "a", name: "x"))
        XCTAssertEqual(ids(service), ["app:a", "app:b"])
    }

    func testCreateFolderFromAppInsideAnotherFolderCollapsesThatFolder() throws {
        let service = seeded([folder("f", ["x", "y"]), app("a")])
        let id = try XCTUnwrap(service.createFolder(merging: "x", intoSlotOf: "a", name: "New"))
        XCTAssertEqual(service.folder(withID: id)?.bundleIDs, ["a", "x"])
        XCTAssertNil(service.folder(withID: "f"), "the two-app folder collapses to a plain app")
        XCTAssertEqual(Set(allBundles(service)), ["a", "x", "y"])
    }

    func testCreateFolderWithMissingTargetLeavesLayoutUntouched() {
        expectKnownBug("createFolder removes the dragged app before checking that the target exists. When the target is missing it returns nil but the dragged app has already been dropped from the in-memory layout.")
        let service = seeded([app("a"), app("b")])
        let before = service.layout
        XCTAssertNil(service.createFolder(merging: "a", intoSlotOf: "ghost", name: "x"))
        XCTAssertEqual(service.layout, before)
    }

    func testCreateFolderWithTargetInsideFolderLeavesLayoutUntouched() {
        expectKnownBug("Same ordering bug: a target that lives in a folder (not top level) fails after the dragged app was already removed.")
        let service = seeded([folder("f", ["x", "y"]), app("a")])
        let before = service.layout
        XCTAssertNil(service.createFolder(merging: "a", intoSlotOf: "x", name: "n"))
        XCTAssertEqual(service.layout, before)
    }

    func testAddAppToFolder() {
        let service = seeded([folder("f", ["a", "b"]), app("c"), app("d")])
        service.addApp(bundleID: "c", toFolderWithID: "f")
        XCTAssertEqual(service.folder(withID: "f")?.bundleIDs, ["a", "b", "c"])
        XCTAssertEqual(ids(service), ["folder:f", "app:d"])
    }

    func testAddAppMovesItBetweenFolders() {
        let service = seeded([folder("f", ["a", "b", "c"]), folder("g", ["x", "y"])])
        service.addApp(bundleID: "c", toFolderWithID: "g")
        XCTAssertEqual(service.folder(withID: "f")?.bundleIDs, ["a", "b"])
        XCTAssertEqual(service.folder(withID: "g")?.bundleIDs, ["x", "y", "c"])
    }

    func testAddAppToMissingFolderKeepsTheApp() {
        expectKnownBug("addApp removes the app from its current location before looking up the destination folder, so a missing folder id silently deletes the app from the layout.")
        let service = seeded([app("a"), app("b")])
        service.addApp(bundleID: "a", toFolderWithID: "ghost")
        XCTAssertTrue(service.allReferencedBundleIDs.contains("a"))
    }

    func testAddAppBackToItsOwnTwoAppFolderKeepsTheFolder() {
        expectKnownBug("Re-adding a member to its own two-app folder removes it first, which collapses the folder to a plain app, then finds no folder to add to: the folder is destroyed and the app lost.")
        let service = seeded([folder("f", ["a", "b"])])
        service.addApp(bundleID: "a", toFolderWithID: "f")
        XCTAssertEqual(Set(service.folder(withID: "f")?.bundleIDs ?? []), ["a", "b"])
    }

    func testAddAppBackToItsOwnLargerFolderMovesItToTheEnd() {
        let service = seeded([folder("f", ["a", "b", "c"])])
        service.addApp(bundleID: "a", toFolderWithID: "f")
        XCTAssertEqual(service.folder(withID: "f")?.bundleIDs, ["b", "c", "a"])
    }

    func testRemoveFromFolderPlacesAppAfterFolder() {
        let service = seeded([folder("f", ["a", "b", "c"]), app("z")])
        service.removeFromFolder(bundleID: "b")
        XCTAssertEqual(service.folder(withID: "f")?.bundleIDs, ["a", "c"])
        XCTAssertEqual(ids(service), ["folder:f", "app:b", "app:z"])
    }

    func testRemoveFromTwoAppFolderDissolvesIt() {
        let service = seeded([folder("f", ["a", "b"]), app("z")])
        service.removeFromFolder(bundleID: "a")
        XCTAssertNil(service.folder(withID: "f"))
        XCTAssertEqual(ids(service), ["app:b", "app:a", "app:z"])
    }

    func testRemoveFromFolderOfAppNotInAnyFolderIsIgnored() {
        let service = seeded([folder("f", ["a", "b"]), app("z")])
        service.removeFromFolder(bundleID: "z")
        service.removeFromFolder(bundleID: "ghost")
        XCTAssertEqual(ids(service), ["folder:f", "app:z"])
    }

    func testRemoveFromSingleMemberFolderTurnsFolderIntoThatApp() {
        // A persisted one-app folder (hand-edited data) dissolves cleanly.
        let service = seeded([folder("f", ["a"]), app("z")])
        service.removeFromFolder(bundleID: "a")
        XCTAssertEqual(ids(service), ["app:a", "app:z"])
    }

    func testMoveAppInFolder() {
        let service = seeded([folder("f", ["a", "b", "c", "d"])])
        service.moveAppInFolder(folderID: "f", bundleID: "a", toIndex: 2)
        XCTAssertEqual(service.folder(withID: "f")?.bundleIDs, ["b", "c", "a", "d"])
        service.moveAppInFolder(folderID: "f", bundleID: "d", toIndex: 0)
        XCTAssertEqual(service.folder(withID: "f")?.bundleIDs, ["d", "b", "c", "a"])
    }

    func testMoveAppInFolderClampsAndIgnoresBadInput() {
        let service = seeded([folder("f", ["a", "b", "c"])])
        service.moveAppInFolder(folderID: "f", bundleID: "a", toIndex: 99)
        XCTAssertEqual(service.folder(withID: "f")?.bundleIDs, ["b", "c", "a"])
        service.moveAppInFolder(folderID: "f", bundleID: "a", toIndex: -9)
        XCTAssertEqual(service.folder(withID: "f")?.bundleIDs, ["a", "b", "c"])
        service.moveAppInFolder(folderID: "f", bundleID: "ghost", toIndex: 0)
        service.moveAppInFolder(folderID: "ghost", bundleID: "a", toIndex: 0)
        service.moveAppInFolder(folderID: "f", bundleID: "a", toIndex: Int.max)
        XCTAssertEqual(service.folder(withID: "f")?.bundleIDs, ["b", "c", "a"])
    }

    func testRenameFolderTrimsAndRejectsBlank() {
        let service = seeded([folder("f", ["a", "b"], name: "Old")])
        service.renameFolder(id: "f", to: "  New Name \n")
        XCTAssertEqual(service.folder(withID: "f")?.name, "New Name")
        for blank in ["", "   ", "\n\t "] {
            service.renameFolder(id: "f", to: blank)
            XCTAssertEqual(service.folder(withID: "f")?.name, "New Name")
        }
    }

    func testRenameFolderToSameNameDoesNotPersist() {
        let (service, defaults) = makeService()
        service.seedIfEmpty([folder("f", ["a", "b"], name: "Same")])
        let before = defaults.data(forKey: key)
        service.renameFolder(id: "f", to: " Same ")
        XCTAssertEqual(defaults.data(forKey: key), before)
    }

    func testRenameUnknownFolderIsIgnored() {
        let service = seeded([folder("f", ["a", "b"], name: "Old")])
        service.renameFolder(id: "ghost", to: "X")
        XCTAssertEqual(service.folder(withID: "f")?.name, "Old")
    }

    func testRenameAcceptsVeryLongAndUnicodeNames() {
        let service = seeded([folder("f", ["a", "b"])])
        let long = String(repeating: "名", count: 10_000)
        service.renameFolder(id: "f", to: long)
        XCTAssertEqual(service.folder(withID: "f")?.name, long)
    }

    func testUngroupSplicesAppsAtTheFolderPosition() {
        let service = seeded([app("x"), folder("f", ["a", "b", "c"]), app("y")])
        service.ungroupFolder(id: "f")
        XCTAssertEqual(ids(service), ["app:x", "app:a", "app:b", "app:c", "app:y"])
    }

    func testUngroupIgnoresAppsAndUnknownIDs() {
        let service = seeded([app("x"), folder("f", ["a", "b"])])
        service.ungroupFolder(id: "x")
        service.ungroupFolder(id: "ghost")
        XCTAssertEqual(ids(service), ["app:x", "folder:f"])
    }

    // MARK: Install and uninstall reconciliation

    func testAppendNewAppsAddsOnlyUnknownOnes() {
        let service = seeded([app("a"), folder("f", ["b", "c"])])
        service.appendNewApps(["a", "b", "d", "e"])
        XCTAssertEqual(ids(service), ["app:a", "folder:f", "app:d", "app:e"])
    }

    func testAppendNewAppsWithNothingNewDoesNotPersist() {
        let (service, defaults) = makeService()
        service.seedIfEmpty([app("a")])
        let before = defaults.data(forKey: key)
        service.appendNewApps(["a"])
        service.appendNewApps([])
        XCTAssertEqual(defaults.data(forKey: key), before)
    }

    func testAppendNewAppsDeduplicatesItsOwnInput() {
        expectKnownBug("appendNewApps filters against the layout once, so an id repeated within the input is appended repeatedly.")
        let service = seeded([app("a")])
        service.appendNewApps(["n", "n", "n"])
        XCTAssertEqual(allBundles(service).filter { $0 == "n" }.count, 1)
    }

    func testPruneRemovesMissingAppsAndCollapsesFolders() {
        let service = seeded([app("a"), app("gone"), folder("f", ["b", "gone2", "c"]), folder("g", ["x", "gone3"]), folder("h", ["gone4", "gone5"])])
        service.pruneMissingApps(installedBundleIDs: ["a", "b", "c", "x"])
        XCTAssertEqual(ids(service), ["app:a", "folder:f", "app:x"])
        XCTAssertEqual(service.folder(withID: "f")?.bundleIDs, ["b", "c"])
    }

    func testPruneWithEverythingInstalledChangesNothing() {
        let (service, defaults) = makeService()
        service.seedIfEmpty([app("a"), folder("f", ["b", "c"])])
        let before = defaults.data(forKey: key)
        service.pruneMissingApps(installedBundleIDs: ["a", "b", "c", "extra"])
        XCTAssertEqual(defaults.data(forKey: key), before)
    }

    func testPruneWithNothingInstalledEmptiesTheLayout() {
        let service = seeded([app("a"), folder("f", ["b", "c"])])
        service.pruneMissingApps(installedBundleIDs: [])
        XCTAssertEqual(service.layout, .empty)
    }

    func testPruneCollapsesPersistedOneAppFolder() {
        let service = seeded([folder("f", ["a"]), app("b")])
        service.pruneMissingApps(installedBundleIDs: ["a", "b"])
        XCTAssertEqual(ids(service), ["app:a", "app:b"])
    }

    // MARK: Invariants under arbitrary sequences

    /// Small deterministic generator so failures reproduce.
    private struct LCG {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(max(bound, 1)))
        }
    }

    func testRandomEditSequencesPreserveEveryAppExactlyOnce() {
        for seed in 1...25 {
            var rng = LCG(state: UInt64(seed))
            let universe = (0..<12).map { "app\($0)" }
            let (service, _) = makeService()
            service.seedIfEmpty(universe.map { .app(bundleID: $0) })
            var folderCounter = 0

            for step in 0..<150 {
                let items = service.layout.items
                guard !items.isEmpty else { break }
                switch rng.next(7) {
                case 0:
                    service.moveItem(id: items[rng.next(items.count)].id, toIndex: rng.next(items.count + 2) - 1)
                case 1:
                    service.moveItem(
                        id: items[rng.next(items.count)].id,
                        relativeTo: items[rng.next(items.count)].id,
                        position: rng.next(2) == 0 ? .before : .after
                    )
                case 2:
                    let dragged = universe[rng.next(universe.count)]
                    let target = universe[rng.next(universe.count)]
                    // Only attempt merges that can succeed: the target must be top level.
                    let targetIsTopLevel = items.contains { if case .app(let id) = $0 { return id == target }; return false }
                    if targetIsTopLevel, dragged != target {
                        folderCounter += 1
                        service.createFolder(merging: dragged, intoSlotOf: target, name: "F\(folderCounter)")
                    }
                case 3:
                    let folders = items.compactMap { item -> LaunchpadFolder? in
                        if case .folder(let f) = item { return f }; return nil
                    }
                    if let f = folders.isEmpty ? nil : folders[rng.next(folders.count)] {
                        let candidates = universe.filter { !f.bundleIDs.contains($0) }
                        if !candidates.isEmpty {
                            service.addApp(bundleID: candidates[rng.next(candidates.count)], toFolderWithID: f.id)
                        }
                    }
                case 4:
                    service.removeFromFolder(bundleID: universe[rng.next(universe.count)])
                case 5:
                    let folders = items.compactMap { item -> LaunchpadFolder? in
                        if case .folder(let f) = item { return f }; return nil
                    }
                    if !folders.isEmpty {
                        let f = folders[rng.next(folders.count)]
                        service.moveAppInFolder(folderID: f.id, bundleID: f.bundleIDs[rng.next(f.bundleIDs.count)], toIndex: rng.next(f.bundleIDs.count + 2) - 1)
                    }
                default:
                    let folders = items.compactMap { item -> LaunchpadFolder? in
                        if case .folder(let f) = item { return f }; return nil
                    }
                    if !folders.isEmpty, rng.next(3) == 0 {
                        service.ungroupFolder(id: folders[rng.next(folders.count)].id)
                    }
                }

                let bundles = allBundles(service)
                XCTAssertEqual(Set(bundles), Set(universe), "seed \(seed) step \(step): an app was lost or invented")
                XCTAssertEqual(bundles.count, Set(bundles).count, "seed \(seed) step \(step): duplicate app")
                for item in service.layout.items {
                    if case .folder(let folder) = item {
                        XCTAssertGreaterThanOrEqual(folder.bundleIDs.count, 2, "seed \(seed) step \(step): degenerate folder")
                    }
                }
                let itemIDs = ids(service)
                XCTAssertEqual(itemIDs.count, Set(itemIDs).count, "seed \(seed) step \(step): duplicate item id")
            }
        }
    }

    func testRandomPersistedRoundTripAfterEdits() {
        var rng = LCG(state: 99)
        let (service, defaults) = makeService()
        service.seedIfEmpty((0..<30).map { .app(bundleID: "a\($0)") })
        for _ in 0..<60 {
            let items = service.layout.items
            service.moveItem(id: items[rng.next(items.count)].id, toIndex: rng.next(items.count))
        }
        XCTAssertEqual(LaunchpadLayoutService(defaults: defaults).layout, service.layout)
    }
}
