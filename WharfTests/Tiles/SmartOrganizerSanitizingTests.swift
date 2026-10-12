import XCTest
@testable import Wharf

/// The Smart Organize feature asks an on-device language model for a pinned
/// layout. Model output is untrusted: it may invent bundle identifiers, repeat
/// apps, stack dividers or propose widgets that do not exist. These tests drive
/// the validation layer (`sanitizedPinnedItems`) and the deterministic
/// fallback (`heuristicSuggestedItems`) directly. `organize(items:)` itself is
/// not called because it reaches the nondeterministic FoundationModels path.
@available(macOS 26.0, *)
@MainActor
final class SmartOrganizerSanitizingTests: XCTestCase {
    private typealias Service = PinnedDockSmartOrganizerService
    private let service = PinnedDockSmartOrganizerService.shared

    // MARK: - Builders

    private func apps(_ ids: String...) -> [Service.AvailableApp] {
        ids.map { Service.AvailableApp(bundleIdentifier: $0, displayName: $0) }
    }

    private func widget(
        _ kind: WidgetKind = .weather,
        owner: String = "owner.weather",
        span: TileSpan = .three
    ) -> Service.AvailableWidget {
        Service.AvailableWidget(kind: kind, ownerBundleIdentifier: owner, defaultSpan: span, title: kind.rawValue)
    }

    private func sanitize(
        _ suggested: [Service.SuggestedItem],
        apps: [Service.AvailableApp],
        widgets: [Service.AvailableWidget] = [],
        existing: [PinnedTileItem] = []
    ) -> [PinnedTileItem] {
        service.sanitizedPinnedItems(from: suggested, apps: apps, availableWidgets: widgets, existingItems: existing)
    }

    /// Compact description of a result for readable assertions.
    private func shape(_ items: [PinnedTileItem]) -> [String] {
        items.map { item in
            switch item.kind {
            case .app: return item.bundleIdentifier ?? "?"
            case .appFolder: return "folder[\(item.folderBundleIdentifiers.joined(separator: ","))]"
            case .divider: return "divider"
            case .spacer: return "spacer"
            case .flexibleSpacer: return "flex"
            case .widget: return "widget:\(item.widgetKind?.rawValue ?? "?"):\(item.widgetSpan?.rawValue ?? 0)"
            case .smartStack: return "stack"
            case .launchpad: return "launchpad"
            case .startMenu: return "start"
            }
        }
    }

    private func appIDs(in items: [PinnedTileItem]) -> [String] {
        items.flatMap { item -> [String] in
            switch item.kind {
            case .app: return [item.bundleIdentifier ?? ""]
            case .appFolder: return item.folderBundleIdentifiers
            default: return []
            }
        }
    }

    // MARK: - Model cannot add or substitute apps

    func testInventedAppIsDropped() {
        let result = sanitize([.app("com.evil.injected"), .app("a")], apps: apps("a", "b"))
        XCTAssertEqual(shape(result), ["a", "b"])
    }

    func testInventedAppInsideAFolderIsDropped() {
        let result = sanitize(
            [.folder(title: "Dev", bundleIdentifiers: ["a", "com.evil", "b"])],
            apps: apps("a", "b", "c")
        )
        XCTAssertEqual(shape(result), ["folder[a,b]", "c"])
    }

    func testFolderOfOnlyInventedAppsProducesNothingAndRealAppsSurvive() {
        let result = sanitize(
            [.folder(title: "Evil", bundleIdentifiers: ["x", "y", "z"])],
            apps: apps("a", "b")
        )
        XCTAssertEqual(shape(result), ["a", "b"])
    }

    func testOutputAppSetNeverExceedsInput() {
        let result = sanitize(
            [.app("1"), .app("2"), .folder(title: "F", bundleIdentifiers: ["3", "4", "5"]), .app("a")],
            apps: apps("a", "b")
        )
        XCTAssertTrue(Set(appIDs(in: result)).isSubset(of: ["a", "b"]))
    }

    func testEveryInputAppSurvivesEvenIfTheModelOmitsIt() {
        let result = sanitize([.app("b")], apps: apps("a", "b", "c"))
        XCTAssertEqual(shape(result), ["b", "a", "c"])
    }

    func testEmptySuggestionKeepsAllAppsInInputOrder() {
        XCTAssertEqual(shape(sanitize([], apps: apps("c", "a", "b"))), ["c", "a", "b"])
    }

    func testBundleIdentifierMatchingIsExact() {
        let result = sanitize([.app("A"), .app(" a"), .app("a ")], apps: apps("a"))
        XCTAssertEqual(shape(result), ["a"])
    }

    func testSubstitutionByLookalikeIdentifierIsRejected() {
        let result = sanitize([.app("com.apple.Safari.evil")], apps: apps("com.apple.Safari"))
        XCTAssertEqual(shape(result), ["com.apple.Safari"])
    }

    // MARK: - Duplicates

    func testRepeatedAppAppearsOnce() {
        let result = sanitize([.app("a"), .app("a"), .app("b"), .app("a")], apps: apps("a", "b"))
        XCTAssertEqual(shape(result), ["a", "b"])
    }

    func testAppAlreadyInAFolderIsNotPlacedAgain() {
        let result = sanitize(
            [.folder(title: "F", bundleIdentifiers: ["a", "b"]), .app("a")],
            apps: apps("a", "b", "c")
        )
        XCTAssertEqual(shape(result), ["folder[a,b]", "c"])
    }

    func testSecondFolderCannotReuseAnApp() {
        let result = sanitize(
            [
                .folder(title: "One", bundleIdentifiers: ["a", "b"]),
                .folder(title: "Two", bundleIdentifiers: ["b", "c", "d"]),
            ],
            apps: apps("a", "b", "c", "d")
        )
        XCTAssertEqual(shape(result), ["folder[a,b]", "folder[c,d]"])
    }

    func testDuplicateAppsInTheInputAreHandled() {
        let result = sanitize([.app("a")], apps: apps("a", "a", "b", "a"))
        XCTAssertEqual(shape(result), ["a", "b"])
    }

    func testFolderListingTheSameAppTwiceDoesNotContainItTwice() {
        // A folder of ["a", "a"] would pass the "at least two apps" check
        // while holding one app. The model must not be able to produce it.
        let result = sanitize(
            [.folder(title: "F", bundleIdentifiers: ["a", "a", "b"])],
            apps: apps("a", "b", "c")
        )
        let members = result.first(where: { $0.kind == .appFolder })?.folderBundleIdentifiers ?? []
        XCTAssertEqual(members, ["a", "b"])
    }

    func testEveryAppAppearsExactlyOnceForAdversarialSuggestions() {
        let inputs = apps("a", "b", "c", "d", "e")
        let suggestions: [Service.SuggestedItem] = [
            .app("a"), .app("a"), .folder(title: "x", bundleIdentifiers: ["b", "c", "evil"]),
            .app("c"), .folder(title: "y", bundleIdentifiers: ["d"]), .app("ghost"), .app("d"),
        ]
        let ids = appIDs(in: sanitize(suggestions, apps: inputs))
        XCTAssertEqual(ids.sorted(), ["a", "b", "c", "d", "e"])
    }

    // MARK: - Folders

    func testFolderWithOneKnownAppIsFlattened() {
        let result = sanitize([.folder(title: "F", bundleIdentifiers: ["a", "evil"])], apps: apps("a", "b"))
        XCTAssertEqual(shape(result), ["a", "b"])
    }

    func testFolderWithNoAppsIsDropped() {
        let result = sanitize([.folder(title: "F", bundleIdentifiers: [])], apps: apps("a"))
        XCTAssertEqual(shape(result), ["a"])
    }

    func testFolderGetsTheModelTitleWhenUsable() {
        let result = sanitize([.folder(title: "Chat", bundleIdentifiers: ["a", "b"])], apps: apps("a", "b"))
        XCTAssertEqual(result.first?.folderDisplayName, "Chat")
        XCTAssertEqual(result.first?.kind, .appFolder)
    }

    func testFolderGetsAGeneratedTitleWhenTheModelTitleIsEmpty() {
        let result = sanitize([.folder(title: "  \"\"  ", bundleIdentifiers: ["a", "b"])], apps: apps("a", "b"))
        let title = result.first?.folderDisplayName ?? ""
        XCTAssertFalse(title.isEmpty)
    }

    func testFolderDefaultsToGridContentView() {
        let result = sanitize([.folder(title: "F", bundleIdentifiers: ["a", "b"])], apps: apps("a", "b"))
        XCTAssertEqual(result.first?.folderContentViewMode, .grid)
    }

    func testFolderIDsAreFreshAndUnique() {
        let result = sanitize(
            [
                .folder(title: "A", bundleIdentifiers: ["a", "b"]),
                .folder(title: "B", bundleIdentifiers: ["c", "d"]),
            ],
            apps: apps("a", "b", "c", "d")
        )
        let ids = result.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("custom:") })
    }

    // MARK: - Widgets

    func testUnknownWidgetIsDropped() {
        let result = sanitize([.widget(kind: .weather, ownerBundleIdentifier: "evil.owner", span: .three)], apps: apps("a"), widgets: [widget()])
        XCTAssertEqual(shape(result), ["a"])
    }

    func testWidgetWithKnownKindButWrongOwnerIsDropped() {
        let result = sanitize([.widget(kind: .weather, ownerBundleIdentifier: "owner.other", span: .three)], apps: apps("a"), widgets: [widget()])
        XCTAssertEqual(shape(result), ["a"])
    }

    func testWidgetWithKnownOwnerButWrongKindIsDropped() {
        let result = sanitize([.widget(kind: .clock, ownerBundleIdentifier: "owner.weather", span: .three)], apps: apps("a"), widgets: [widget()])
        XCTAssertEqual(shape(result), ["a"])
    }

    func testKnownWidgetIsKeptWithRequestedSpan() {
        let result = sanitize([.widget(kind: .weather, ownerBundleIdentifier: "owner.weather", span: .two)], apps: apps("a"), widgets: [widget()])
        XCTAssertEqual(shape(result), ["widget:weather:2", "a"])
        XCTAssertEqual(result.first?.widgetOwnerBundleIdentifier, "owner.weather")
    }

    func testUnsupportedSpanFallsBackToTheWidgetDefault() {
        let date = widget(.calendarDate, owner: "owner.date", span: .one)
        let result = sanitize([.widget(kind: .calendarDate, ownerBundleIdentifier: "owner.date", span: .three)], apps: apps("a"), widgets: [date])
        XCTAssertEqual(result.first?.widgetSpan, .one)
    }

    func testSameWidgetTwiceIsKeptOnce() {
        let suggestion = Service.SuggestedItem.widget(kind: .weather, ownerBundleIdentifier: "owner.weather", span: .three)
        let result = sanitize([suggestion, .app("a"), suggestion], apps: apps("a"), widgets: [widget()])
        XCTAssertEqual(shape(result), ["widget:weather:3", "a"])
    }

    func testDuplicateWidgetRegistrationsDoNotTrap() {
        // Regression: Dictionary(uniqueKeysWithValues:) trapped when two
        // registrations (for example from external bundles) shared a key.
        let duplicated = [widget(.weather, owner: "o", span: .two), widget(.weather, owner: "o", span: .three)]
        let result = sanitize([.widget(kind: .weather, ownerBundleIdentifier: "o", span: .one)], apps: apps("a"), widgets: duplicated)
        XCTAssertEqual(result.filter { $0.kind == .widget }.count, 1)
    }

    func testWidgetSuggestionWithNoWidgetsAvailableIsDropped() {
        let result = sanitize([.widget(kind: .weather, ownerBundleIdentifier: "o", span: .three)], apps: apps("a"))
        XCTAssertEqual(shape(result), ["a"])
    }

    // MARK: - Launchpad and smart stack

    func testSecondLaunchpadIsDropped() {
        let result = sanitize([.launchpad, .app("a"), .launchpad], apps: apps("a"))
        XCTAssertEqual(shape(result), ["launchpad", "a"])
    }

    func testSecondSmartStackIsDropped() {
        let result = sanitize([.smartStack, .app("a"), .smartStack], apps: apps("a"))
        XCTAssertEqual(shape(result), ["stack", "a"])
    }

    func testExistingLaunchpadIsRestoredAtTheFrontWhenTheModelDropsIt() {
        let result = sanitize([.app("b")], apps: apps("a", "b"), existing: [.launchpad(id: "custom:lp")])
        XCTAssertEqual(shape(result), ["launchpad", "b", "a"])
    }

    func testExistingLaunchpadIsNotDuplicatedWhenTheModelKeepsIt() {
        let result = sanitize([.app("a"), .launchpad], apps: apps("a"), existing: [.launchpad(id: "custom:lp")])
        XCTAssertEqual(shape(result).filter { $0 == "launchpad" }.count, 1)
    }

    func testLaunchpadIsNotInventedWhenNoneExisted() {
        XCTAssertFalse(shape(sanitize([.app("a")], apps: apps("a"))).contains("launchpad"))
    }

    // MARK: - Dividers and spacers

    func testLeadingAndTrailingDividersAreStripped() {
        let result = sanitize([.divider, .app("a"), .divider], apps: apps("a"))
        XCTAssertEqual(shape(result), ["a"])
    }

    func testConsecutiveSeparatorsCollapseToTheFirst() {
        let result = sanitize([.app("a"), .divider, .spacer, .divider, .app("b")], apps: apps("a", "b"))
        XCTAssertEqual(shape(result), ["a", "divider", "b"])
    }

    func testOnlySeparatorsProduceAnEmptyLayout() {
        XCTAssertEqual(shape(sanitize([.divider, .spacer, .divider], apps: [])), [])
    }

    func testSeparatorBetweenRealItemsIsKept() {
        let result = sanitize([.app("a"), .spacer, .app("b")], apps: apps("a", "b"))
        XCTAssertEqual(shape(result), ["a", "spacer", "b"])
    }

    func testSeparatorsLeftDanglingAfterDroppedItemsAreStripped() {
        let result = sanitize([.app("a"), .divider, .app("ghost"), .divider], apps: apps("a"))
        XCTAssertEqual(shape(result), ["a"])
    }

    func testNormalizedPinnedItemsDirectly() {
        let input: [PinnedTileItem] = [
            .divider(), .spacer(), .app(bundleIdentifier: "a"), .divider(), .flexibleSpacer(),
            .app(bundleIdentifier: "b"), .spacer(), .divider(),
        ]
        XCTAssertEqual(shape(service.normalizedPinnedItems(input)), ["a", "divider", "b"])
    }

    func testNormalizedPinnedItemsOfEmptyList() {
        XCTAssertEqual(service.normalizedPinnedItems([]), [])
    }

    // MARK: - Volume

    func testTenThousandInventedSuggestionsAreAllDropped() {
        let suggested = (0..<10_000).map { Service.SuggestedItem.app("evil.\($0)") }
        XCTAssertEqual(shape(sanitize(suggested, apps: apps("a", "b"))), ["a", "b"])
    }

    func testManyRealAppsAllSurvive() {
        let ids = (0..<500).map { "app.\($0)" }
        let inputs = ids.map { Service.AvailableApp(bundleIdentifier: $0, displayName: $0) }
        let result = sanitize(ids.reversed().map(Service.SuggestedItem.app), apps: inputs)
        XCTAssertEqual(appIDs(in: result), Array(ids.reversed()))
    }

    // MARK: - sanitizeFolderTitle

    func testFolderTitleSanitizing() {
        let cases: [(String, String)] = [
            ("Dev Tools", "Dev Tools"),
            ("\"Dev Tools\"", "Dev Tools"),
            ("\u{201C}Dev Tools\u{201D}", "Dev Tools"),
            ("  Work   Apps. ", "Work Apps"),
            ("Chat!!!", "Chat"),
            ("-- Media --", "Media"),
            ("A\nB", "A B"),
            ("Tabs\tand\tspaces", "Tabs and spaces"),
            ("", "FALLBACK"),
            ("   ", "FALLBACK"),
            ("!!!", "FALLBACK"),
            ("\"\"", "FALLBACK"),
            ("Caf\u{00E9} \u{4E2D}\u{6587}", "Caf\u{00E9} \u{4E2D}\u{6587}"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(service.sanitizeFolderTitle(input, fallback: "FALLBACK"), expected, "input '\(input)'")
        }
    }

    func testFolderTitleIsLimitedToTwentyEightCharacters() {
        let long = String(repeating: "abcd ", count: 20)
        let title = service.sanitizeFolderTitle(long, fallback: "F")
        XCTAssertLessThanOrEqual(title.count, 28)
        XCTAssertFalse(title.hasSuffix(" "))
    }

    func testFolderTitleOfAHugeStringDoesNotTrap() {
        let title = service.sanitizeFolderTitle(String(repeating: "x", count: 1_000_000), fallback: "F")
        XCTAssertEqual(title.count, 28)
    }

    // MARK: - flattenedApps

    func testFlattenedAppsDeduplicatesAcrossAppsAndFolders() {
        let items: [PinnedTileItem] = [
            .app(bundleIdentifier: "zz.test.b"),
            .appFolder(bundleIdentifiers: ["zz.test.a", "zz.test.b", "zz.test.c"]),
            .app(bundleIdentifier: "zz.test.a"),
        ]
        XCTAssertEqual(service.flattenedApps(from: items).map(\.bundleIdentifier), ["zz.test.a", "zz.test.b", "zz.test.c"])
    }

    func testFlattenedAppsIgnoresNonAppItemsAndMissingIdentifiers() {
        let missing = PinnedTileItem(
            id: "x", kind: .app, bundleIdentifier: nil, folderDisplayName: nil, folderBundleIdentifiers: [],
            appFolderDisplayMode: nil, folderContentViewMode: nil, widgetKind: nil, widgetOwnerBundleIdentifier: nil,
            widgetSpan: nil, hiddenWidgetOwnerBundleIdentifiers: []
        )
        let items: [PinnedTileItem] = [.divider(), .spacer(), .launchpad(), .smartStack(), .startMenu(), missing]
        XCTAssertEqual(service.flattenedApps(from: items), [])
    }

    func testFlattenedAppsFallsBackToTheBundleIdentifierAsName() {
        let id = "zz.test.not.installed.\(UUID().uuidString)"
        let apps = service.flattenedApps(from: [.app(bundleIdentifier: id)])
        XCTAssertEqual(apps.first?.displayName, id)
    }

    func testFlattenedAppsSortsByNameCaseInsensitively() {
        let items: [PinnedTileItem] = [
            .app(bundleIdentifier: "zz.test.Banana"), .app(bundleIdentifier: "zz.test.apple"), .app(bundleIdentifier: "zz.test.Cherry"),
        ]
        XCTAssertEqual(
            service.flattenedApps(from: items).map(\.bundleIdentifier),
            ["zz.test.apple", "zz.test.Banana", "zz.test.Cherry"]
        )
    }

    // MARK: - Heuristic fallback

    private func named(_ pairs: (String, String)...) -> [Service.AvailableApp] {
        pairs.map { Service.AvailableApp(bundleIdentifier: $0.0, displayName: $0.1) }
    }

    func testHeuristicGroupsThreeBrowsersIntoAFolder() {
        let input = named(("com.apple.Safari", "Safari"), ("com.google.Chrome", "Chrome"), ("org.mozilla.firefox", "Firefox"))
        let result = service.heuristicSuggestedItems(apps: input, availableWidgets: [], existingItems: [])
        XCTAssertEqual(result, [.folder(title: "Browse", bundleIdentifiers: ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox"]), .divider])
    }

    func testHeuristicLeavesSmallGroupsAsLooseApps() {
        let input = named(("com.apple.Safari", "Safari"), ("com.google.Chrome", "Chrome"))
        let result = service.heuristicSuggestedItems(apps: input, availableWidgets: [], existingItems: [])
        XCTAssertEqual(result, [.app("com.apple.Safari"), .app("com.google.Chrome"), .divider])
    }

    func testHeuristicPutsUnmatchedAppsInTheAppsGroupWithoutATrailingDivider() {
        let input = named(("com.example.one", "One"), ("com.example.two", "Two"))
        let result = service.heuristicSuggestedItems(apps: input, availableWidgets: [], existingItems: [])
        XCTAssertEqual(result, [.app("com.example.one"), .app("com.example.two")])
    }

    func testHeuristicStartsWithLaunchpadWhenOneExisted() {
        let input = named(("com.example.one", "One"))
        let result = service.heuristicSuggestedItems(apps: input, availableWidgets: [], existingItems: [.launchpad()])
        XCTAssertEqual(Array(result.prefix(2)), [.launchpad, .divider])
    }

    func testHeuristicAppendsThePreferredWidgetAfterADivider() {
        let input = named(("com.example.one", "One"))
        let widgets = [widget(.nowPlaying, owner: "np", span: .three), widget(.weather, owner: "w", span: .two)]
        let result = service.heuristicSuggestedItems(apps: input, availableWidgets: widgets, existingItems: [])
        XCTAssertEqual(Array(result.suffix(2)), [.divider, .widget(kind: .weather, ownerBundleIdentifier: "w", span: .two)])
    }

    func testHeuristicOfNoAppsAndNoWidgetsIsEmpty() {
        XCTAssertEqual(service.heuristicSuggestedItems(apps: [], availableWidgets: [], existingItems: []), [])
    }

    func testHeuristicOutputSanitizesToEveryAppExactlyOnce() {
        let sets: [[Service.AvailableApp]] = [
            named(("com.apple.Safari", "Safari"), ("com.google.Chrome", "Chrome"), ("org.mozilla.firefox", "Firefox"),
                  ("com.apple.dt.Xcode", "Xcode"), ("com.mitchellh.ghostty", "Ghostty"), ("com.figma.Desktop", "Figma"),
                  ("com.apple.MobileSMS", "Messages"), ("com.tinyspeck.slackmacgap", "Slack"), ("com.apple.mail", "Mail"),
                  ("com.example.notes", "Notes"), ("com.example.music", "Music")),
            named(("a", "A")),
            [],
            named(("x.xcode", "Xcode"), ("x.code", "Code"), ("x.cursor", "Cursor"), ("x.docker", "Docker")),
        ]
        for input in sets {
            let suggested = service.heuristicSuggestedItems(apps: input, availableWidgets: [widget()], existingItems: [])
            let result = sanitize(suggested, apps: input, widgets: [widget()])
            XCTAssertEqual(appIDs(in: result).sorted(), input.map(\.bundleIdentifier).sorted())
        }
    }

    func testHeuristicOnLargeInputDoesNotTrap() {
        let input = (0..<2_000).map { Service.AvailableApp(bundleIdentifier: "bulk.app.\($0)", displayName: "Bulk \($0)") }
        let suggested = service.heuristicSuggestedItems(apps: input, availableWidgets: [], existingItems: [])
        XCTAssertEqual(appIDs(in: sanitize(suggested, apps: input)).count, 2_000)
    }
}
