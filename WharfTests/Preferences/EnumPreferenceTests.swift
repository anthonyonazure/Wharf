import XCTest
@testable import Wharf

/// An enum-backed preference stored as its raw string.
private struct EnumSpec {
    let name: String
    let key: String
    let defaultRaw: String
    /// The raw values persisted today. Pinned as literals so that renaming a
    /// case (which would silently reset every user's setting) fails a test.
    let expectedRaws: [String]
    let allRaws: [String]
    let read: (DockyPreferences) -> String
    /// `nil` for settings whose setter reaches a real machine service.
    let assign: ((DockyPreferences, String) -> Void)?
}

private let enumSpecs: [EnumSpec] = [
    EnumSpec(name: "tileClipShape", key: "docky.tileClipShape", defaultRaw: "rounded",
             expectedRaws: ["rounded", "circle"], allRaws: DockClipShape.allCases.map(\.rawValue),
             read: { $0.tileClipShape.rawValue },
             assign: { $0.tileClipShape = DockClipShape(rawValue: $1)! }),
    EnumSpec(name: "windowClipShape", key: "docky.windowClipShape", defaultRaw: "rounded",
             expectedRaws: ["rounded", "circle"], allRaws: DockClipShape.allCases.map(\.rawValue),
             read: { $0.windowClipShape.rawValue },
             assign: { $0.windowClipShape = DockClipShape(rawValue: $1)! }),
    EnumSpec(name: "windowBackgroundImageMode", key: "docky.windowBackgroundImageMode", defaultRaw: "fill",
             expectedRaws: ["fill", "sprite"], allRaws: DockBackgroundImageMode.allCases.map(\.rawValue),
             read: { $0.windowBackgroundImageMode.rawValue },
             assign: { $0.windowBackgroundImageMode = DockBackgroundImageMode(rawValue: $1)! }),
    EnumSpec(name: "windowPosition", key: "docky.windowPosition", defaultRaw: "system",
             expectedRaws: ["system", "left", "right", "bottom"], allRaws: DockWindowPosition.allCases.map(\.rawValue),
             read: { $0.windowPosition.rawValue },
             // Assigning a non-system edge while the system Dock is hidden moves the real Dock.
             assign: nil),
    EnumSpec(name: "windowDisplayTarget", key: "docky.windowDisplayTarget", defaultRaw: "primaryDisplay",
             expectedRaws: ["primaryDisplay", "displayContainingPointer", "allDisplays"],
             allRaws: DockWindowDisplayTarget.allCases.map(\.rawValue),
             read: { $0.windowDisplayTarget.rawValue },
             assign: { $0.windowDisplayTarget = DockWindowDisplayTarget(rawValue: $1)! }),
    EnumSpec(name: "windowSpaceBehavior", key: "docky.windowSpaceBehavior", defaultRaw: "allSpaces",
             expectedRaws: ["activeSpace", "allSpaces"], allRaws: DockWindowSpaceBehavior.allCases.map(\.rawValue),
             read: { $0.windowSpaceBehavior.rawValue },
             assign: { $0.windowSpaceBehavior = DockWindowSpaceBehavior(rawValue: $1)! }),
    EnumSpec(name: "dockContentMode", key: "wharf.dockContentMode", defaultRaw: "dock",
             expectedRaws: ["dock", "taskbar"], allRaws: DockContentMode.allCases.map(\.rawValue),
             read: { $0.dockContentMode.rawValue },
             assign: { $0.dockContentMode = DockContentMode(rawValue: $1)! }),
    EnumSpec(name: "windowGrouping", key: "wharf.windowGrouping", defaultRaw: "automatic",
             expectedRaws: ["always", "never", "automatic"], allRaws: DockWindowGrouping.allCases.map(\.rawValue),
             read: { $0.windowGrouping.rawValue },
             assign: { $0.windowGrouping = DockWindowGrouping(rawValue: $1)! }),
    EnumSpec(name: "folderBadgeMode", key: "docky.folderBadgeMode", defaultRaw: "combined",
             expectedRaws: ["combined", "perApp"], allRaws: FolderBadgeMode.allCases.map(\.rawValue),
             read: { $0.folderBadgeMode.rawValue },
             assign: { $0.folderBadgeMode = FolderBadgeMode(rawValue: $1)! }),
    EnumSpec(name: "folderBadgePreviewStyle", key: "docky.folderBadgePreviewStyle", defaultRaw: "dot",
             expectedRaws: ["dot", "number"], allRaws: FolderBadgePreviewStyle.allCases.map(\.rawValue),
             read: { $0.folderBadgePreviewStyle.rawValue },
             assign: { $0.folderBadgePreviewStyle = FolderBadgePreviewStyle(rawValue: $1)! }),
    EnumSpec(name: "windowPreviewLayout", key: "docky.windowPreviewLayout", defaultRaw: "auto",
             expectedRaws: ["auto", "thumbnails", "list"], allRaws: WindowSwitcherLayout.allCases.map(\.rawValue),
             read: { $0.windowPreviewLayout.rawValue },
             assign: { $0.windowPreviewLayout = WindowSwitcherLayout(rawValue: $1)! }),
    EnumSpec(name: "maximizedWindowBehavior", key: "docky.maximizedWindowBehavior", defaultRaw: "ignore",
             expectedRaws: ["ignore", "hideDocky", "resizeWindow"], allRaws: MaximizedWindowBehavior.allCases.map(\.rawValue),
             read: { $0.maximizedWindowBehavior.rawValue },
             assign: { $0.maximizedWindowBehavior = MaximizedWindowBehavior(rawValue: $1)! }),
    EnumSpec(name: "overflowBehavior", key: "docky.overflowBehavior", defaultRaw: "rescale",
             expectedRaws: ["rescale", "scroll"], allRaws: DockOverflowBehavior.allCases.map(\.rawValue),
             read: { $0.overflowBehavior.rawValue },
             assign: { $0.overflowBehavior = DockOverflowBehavior(rawValue: $1)! }),
    EnumSpec(name: "windowAxisSizing", key: "docky.windowAxisSizing", defaultRaw: "fitContent",
             expectedRaws: ["fitContent", "fullAxis"], allRaws: DockWindowAxisSizing.allCases.map(\.rawValue),
             read: { $0.windowAxisSizing.rawValue },
             assign: { $0.windowAxisSizing = DockWindowAxisSizing(rawValue: $1)! }),
    EnumSpec(name: "appTileFrontmostClickBehavior", key: "docky.appTileFrontmostClickBehavior", defaultRaw: "none",
             expectedRaws: ["none", "hide", "cycleWindows", "minimizeAll"],
             allRaws: AppTileFrontmostClickBehavior.allCases.map(\.rawValue),
             read: { $0.appTileFrontmostClickBehavior.rawValue },
             assign: { $0.appTileFrontmostClickBehavior = AppTileFrontmostClickBehavior(rawValue: $1)! }),
    EnumSpec(name: "activeIndicatorShape", key: "docky.activeIndicatorShape", defaultRaw: "dot",
             expectedRaws: ["none", "dot", "pill", "underline", "image"], allRaws: DockTileIndicatorShape.allCases.map(\.rawValue),
             read: { $0.activeIndicatorShape.rawValue },
             assign: { $0.activeIndicatorShape = DockTileIndicatorShape(rawValue: $1)! }),
    EnumSpec(name: "launchpadLayoutAxis", key: "docky.launchpadLayoutAxis",
             defaultRaw: LaunchpadLayoutAxis.defaultForCurrentOS.rawValue,
             expectedRaws: ["horizontal", "vertical"], allRaws: LaunchpadLayoutAxis.allCases.map(\.rawValue),
             read: { $0.launchpadLayoutAxis.rawValue },
             assign: { $0.launchpadLayoutAxis = LaunchpadLayoutAxis(rawValue: $1)! }),
    EnumSpec(name: "launchpadSortMode", key: "docky.launchpadSortMode", defaultRaw: "manual",
             expectedRaws: ["manual", "name", "dateCreated", "dateModified"], allRaws: LaunchpadSortMode.allCases.map(\.rawValue),
             read: { $0.launchpadSortMode.rawValue },
             assign: { $0.launchpadSortMode = LaunchpadSortMode(rawValue: $1)! }),
    EnumSpec(name: "windowSwitcherPreviewMode", key: "docky.windowSwitcherPreviewMode", defaultRaw: "inPlace",
             expectedRaws: ["inPlace", "instantFocus"], allRaws: WindowSwitcherPreviewMode.allCases.map(\.rawValue),
             read: { $0.windowSwitcherPreviewMode.rawValue },
             assign: { $0.windowSwitcherPreviewMode = WindowSwitcherPreviewMode(rawValue: $1)! }),
    EnumSpec(name: "windowSwitcherLayout", key: "docky.windowSwitcherLayout", defaultRaw: "auto",
             expectedRaws: ["auto", "thumbnails", "list"], allRaws: WindowSwitcherLayout.allCases.map(\.rawValue),
             read: { $0.windowSwitcherLayout.rawValue },
             assign: { $0.windowSwitcherLayout = WindowSwitcherLayout(rawValue: $1)! }),
]

final class EnumPreferenceTests: DockyPreferencesTestCase {
    func testRawValuesAreThePersistedContract() {
        for spec in enumSpecs {
            XCTAssertEqual(spec.allRaws, spec.expectedRaws, spec.name)
        }
    }

    func testDefaultIsAmongTheValidRawValues() {
        for spec in enumSpecs {
            XCTAssertTrue(spec.allRaws.contains(spec.defaultRaw), spec.name)
        }
    }

    func testMissingKeyYieldsDefault() {
        let prefs = makePrefs()
        for spec in enumSpecs {
            XCTAssertEqual(spec.read(prefs), spec.defaultRaw, spec.name)
        }
    }

    func testEveryValidRawValueRoundTripsThroughInit() {
        for spec in enumSpecs {
            for raw in spec.allRaws {
                defaults.set(raw, forKey: spec.key)
                XCTAssertEqual(spec.read(makePrefs()), raw, "\(spec.name)=\(raw)")
            }
        }
    }

    func testUnknownRawValueFallsBackToDefault() {
        let hostile: [String] = [
            "", " ", "bogus", "ROUNDED", "Rounded", " rounded", "rounded ", "rounded\n", "rounded\0",
            "docky.tileClipShape", "../../etc/passwd", "🙂", "null", "0", "-1", "{}", "[]",
            String(repeating: "x", count: 100_000),
        ]
        for spec in enumSpecs {
            for raw in hostile {
                defaults.set(raw, forKey: spec.key)
                XCTAssertEqual(spec.read(makePrefs()), spec.defaultRaw, "\(spec.name)=\(raw.prefix(20))")
            }
        }
    }

    func testWrongTypeFallsBackToDefault() {
        let wrongValues: [Any] = [Data([0x72, 0x6F]), ["rounded"], ["k": "v"], Date(timeIntervalSince1970: 0)]
        for spec in enumSpecs {
            for wrong in wrongValues {
                defaults.set(wrong, forKey: spec.key)
                XCTAssertEqual(spec.read(makePrefs()), spec.defaultRaw, "\(spec.name) \(type(of: wrong))")
            }
        }
    }

    func testNumbersStoredUnderEnumKeysFallBackToDefault() {
        for spec in enumSpecs {
            for number in [0, 1, 5, -1, Int.max] {
                defaults.set(number, forKey: spec.key)
                XCTAssertEqual(spec.read(makePrefs()), spec.defaultRaw, "\(spec.name)=\(number)")
            }
        }
    }

    func testSetterPersistsRawValueAndSurvivesReload() {
        for spec in enumSpecs {
            guard let assign = spec.assign else { continue }
            for raw in spec.allRaws where raw != spec.defaultRaw {
                defaults.removeObject(forKey: spec.key)
                let prefs = makePrefs()
                assign(prefs, raw)
                XCTAssertEqual(spec.read(prefs), raw, spec.name)
                XCTAssertEqual(defaults.string(forKey: spec.key), raw, spec.name)
                XCTAssertEqual(spec.read(reload()), raw, "\(spec.name)=\(raw)")
            }
        }
    }

    func testSetterToDefaultValueWritesNothing() {
        for spec in enumSpecs {
            guard let assign = spec.assign else { continue }
            let prefs = makePrefs()
            assign(prefs, spec.defaultRaw)
            XCTAssertNil(defaults.object(forKey: spec.key), spec.name)
        }
    }

    func testSettingBackToDefaultOverwritesStoredValue() {
        for spec in enumSpecs {
            guard let assign = spec.assign, let other = spec.allRaws.first(where: { $0 != spec.defaultRaw }) else { continue }
            let prefs = makePrefs()
            assign(prefs, other)
            assign(prefs, spec.defaultRaw)
            XCTAssertEqual(defaults.string(forKey: spec.key), spec.defaultRaw, spec.name)
            XCTAssertEqual(spec.read(reload()), spec.defaultRaw, spec.name)
        }
    }

    func testEnumTitlesAreNeverEmpty() {
        XCTAssertTrue(DockClipShape.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(DockWindowPosition.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(DockWindowDisplayTarget.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(DockWindowSpaceBehavior.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(DockContentMode.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(DockWindowGrouping.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(DockOverflowBehavior.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(DockWindowAxisSizing.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(DockBackgroundImageMode.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(MaximizedWindowBehavior.allCases.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
        XCTAssertTrue(AppTileFrontmostClickBehavior.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(DockTileIndicatorShape.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(FolderBadgeMode.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(FolderBadgePreviewStyle.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(FolderTileDisplayMode.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(AppFolderTileDisplayMode.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(FolderTileContentViewMode.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(FolderTileSortMode.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(WindowSwitcherLayout.allCases.allSatisfy { !$0.title.isEmpty && !$0.summary.isEmpty })
        XCTAssertTrue(WindowSwitcherPreviewMode.allCases.allSatisfy { !$0.title.isEmpty && !$0.summary.isEmpty })
        XCTAssertTrue(LaunchpadLayoutAxis.allCases.allSatisfy { !$0.title.isEmpty && !$0.summary.isEmpty })
        XCTAssertTrue(LaunchpadSortMode.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(TrashIconState.allCases.allSatisfy { !$0.title.isEmpty })
    }

    // MARK: Pure enum logic

    func testWindowPositionResolvesSystemOrientation() {
        XCTAssertEqual(DockWindowPosition.system.resolved(systemOrientation: .bottom), .bottom)
        XCTAssertEqual(DockWindowPosition.system.resolved(systemOrientation: .left), .left)
        XCTAssertEqual(DockWindowPosition.system.resolved(systemOrientation: .right), .right)
    }

    func testExplicitWindowPositionIgnoresSystemOrientation() {
        for orientation in [DockSettingsService.Orientation.bottom, .left, .right] {
            XCTAssertEqual(DockWindowPosition.left.resolved(systemOrientation: orientation), .left)
            XCTAssertEqual(DockWindowPosition.right.resolved(systemOrientation: orientation), .right)
            XCTAssertEqual(DockWindowPosition.bottom.resolved(systemOrientation: orientation), .bottom)
        }
    }

    func testResolvedPositionVerticality() {
        XCTAssertTrue(ResolvedDockWindowPosition.left.isVertical)
        XCTAssertTrue(ResolvedDockWindowPosition.right.isVertical)
        XCTAssertFalse(ResolvedDockWindowPosition.top.isVertical)
        XCTAssertFalse(ResolvedDockWindowPosition.bottom.isVertical)
    }

    func testOnlyAllDisplaysUsesMoreThanOneWindow() {
        XCTAssertTrue(DockWindowDisplayTarget.primaryDisplay.usesSingleWindow)
        XCTAssertTrue(DockWindowDisplayTarget.displayContainingPointer.usesSingleWindow)
        XCTAssertFalse(DockWindowDisplayTarget.allDisplays.usesSingleWindow)
    }

    func testSpaceBehaviorCollectionFlags() {
        let active = DockWindowSpaceBehavior.activeSpace.collectionBehavior(includesFullScreenAuxiliary: true)
        XCTAssertTrue(active.contains(.moveToActiveSpace))
        XCTAssertFalse(active.contains(.canJoinAllSpaces))
        XCTAssertFalse(active.contains(.fullScreenAuxiliary))

        let all = DockWindowSpaceBehavior.allSpaces.collectionBehavior(includesFullScreenAuxiliary: false)
        XCTAssertTrue(all.contains(.canJoinAllSpaces))
        XCTAssertFalse(all.contains(.fullScreenAuxiliary))

        let allAux = DockWindowSpaceBehavior.allSpaces.collectionBehavior(includesFullScreenAuxiliary: true)
        XCTAssertTrue(allAux.contains(.fullScreenAuxiliary))
    }

    func testClipShapeCornerRadius() {
        XCTAssertEqual(DockClipShape.rounded.resolvedCornerRadius(base: 10, maximum: 30), 10)
        XCTAssertEqual(DockClipShape.rounded.resolvedCornerRadius(base: 50, maximum: 30), 30)
        XCTAssertEqual(DockClipShape.circle.resolvedCornerRadius(base: 10, maximum: 30), 30)
        XCTAssertEqual(DockClipShape.circle.resolvedCornerRadius(base: 100, maximum: 0), 0)
    }

    func testSwitcherLayoutResolution() {
        XCTAssertEqual(WindowSwitcherLayout.auto.resolved(canCaptureThumbnails: true), .thumbnails)
        XCTAssertEqual(WindowSwitcherLayout.auto.resolved(canCaptureThumbnails: false), .list)
        XCTAssertEqual(WindowSwitcherLayout.thumbnails.resolved(canCaptureThumbnails: false), .thumbnails)
        XCTAssertEqual(WindowSwitcherLayout.list.resolved(canCaptureThumbnails: true), .list)
    }

    func testTrashIconStateSystemImageNames() {
        XCTAssertEqual(TrashIconState.empty.systemImageName, "NSTrashEmpty")
        XCTAssertEqual(TrashIconState.full.systemImageName, "NSTrashFull")
    }

    // MARK: FolderTileContentViewMode lenient decoding

    func testFolderContentViewModeDecodesEveryKnownValue() throws {
        for mode in FolderTileContentViewMode.allCases {
            let data = try JSONEncoder().encode(mode)
            XCTAssertEqual(try JSONDecoder().decode(FolderTileContentViewMode.self, from: data), mode)
        }
    }

    func testFolderContentViewModeFallsBackToGridForUnknownValues() throws {
        for literal in ["\"carousel\"", "\"\"", "\"GRID\"", "5", "true", "null", "[]", "{}", "1.5"] {
            let decoded = try JSONDecoder().decode(
                [FolderTileContentViewMode].self,
                from: Data("[\(literal)]".utf8)
            )
            XCTAssertEqual(decoded, [.grid], literal)
        }
    }
}
