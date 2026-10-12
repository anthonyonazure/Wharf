import AppKit
import XCTest
@testable import Wharf

/// Parsing and validation of the context menu catalog. Documents are built
/// from JSON in memory and handed to the service's test initializer, so the
/// app bundle's real catalog is only read by the one test that guards it.
final class MenuCatalogTests: XCTestCase {

    // MARK: JSON builders

    private func action(
        id: String,
        kind: String = "builtin",
        builtin: String? = "openApp",
        tiles: [String] = ["app"],
        extra: String = ""
    ) -> String {
        var fields = [
            #""id": "\#(id)""#, #""title": "T \#(id)""#, #""kind": "\#(kind)""#,
            #""tileTypes": \#(tiles.map { "\"\($0)\"" }.joined(separator: ",").wrapped)"#,
            #""permissions": []"#, #""inputs": []"#, #""destructive": false"#,
            #""requiresFrontmost": false"#, #""holdOption": false"#,
        ]
        if let builtin { fields.append(#""builtinIdentifier": "\#(builtin)""#) }
        if !extra.isEmpty { fields.append(extra) }
        return "{\(fields.joined(separator: ","))}"
    }

    private func actionsDoc(_ packages: [[String]]) -> String {
        let body = packages.enumerated().map { index, actions in
            #"{"id": "pkg\#(index)", "title": "P", "author": "A", "version": "1", "reviewStatus": "curated", "actions": [\#(actions.joined(separator: ","))]}"#
        }
        return #"{"version": 1, "packages": [\#(body.joined(separator: ","))]}"#
    }

    private func menusDoc(_ menus: [String]) -> String {
        #"{"version": 1, "menus": [\#(menus.joined(separator: ","))]}"#
    }

    private func menu(_ tile: String, _ items: [String]) -> String {
        #"{"tileType": "\#(tile)", "items": [\#(items.joined(separator: ","))]}"#
    }

    private func item(_ actionID: String, extra: String = "") -> String {
        #"{"type": "action", "action": "\#(actionID)"\#(extra.isEmpty ? "" : "," + extra)}"#
    }

    private var divider: String { #"{"type": "divider"}"# }

    private func makeService(actions: String, menus: String) throws -> MenuCatalogService {
        let actionsDocument = try JSONDecoder().decode(CatalogActionsDocument.self, from: Data(actions.utf8))
        let menusDocument = try JSONDecoder().decode(CatalogMenusDocument.self, from: Data(menus.utf8))
        return MenuCatalogService(actionsDocument: actionsDocument, menusDocument: menusDocument)
    }

    private let trash = Tile(id: "trash", content: .trash)

    private func titles(_ actions: [ContextAction]?) -> [String] {
        (actions ?? []).map { $0.kind == .divider ? "|" : $0.title }
    }

    // MARK: Action validation

    func testValidBuiltinActionIsAccepted() throws {
        let service = try makeService(actions: actionsDoc([[action(id: "a")]]), menus: menusDoc([]))
        XCTAssertEqual(service.acceptedActionIDs, ["a"])
        XCTAssertTrue(service.diagnostics.isEmpty)
    }

    func testEveryBuiltinIdentifierIsRecognized() throws {
        let identifiers = [
            "openApp", "showAllWindows", "togglePinnedApp", "showAppInFinder", "hideApp", "quitApp",
            "openFolderInFinder", "revealFolderInFinder", "openTrash", "emptyTrash",
        ]
        let actions = identifiers.map { action(id: "act.\($0)", builtin: $0) }
        let service = try makeService(actions: actionsDoc([actions]), menus: menusDoc([]))
        XCTAssertEqual(service.acceptedActionIDs.count, identifiers.count)
        XCTAssertTrue(service.diagnostics.isEmpty, "\(service.diagnostics)")
    }

    func testUnknownBuiltinIdentifierIsRejected() throws {
        let actions = [
            action(id: "unknown", builtin: "formatDisk"),
            action(id: "missing", builtin: nil),
            action(id: "wrongcase", builtin: "OpenApp"),
            action(id: "empty", builtin: ""),
        ]
        let service = try makeService(actions: actionsDoc([actions]), menus: menusDoc([]))
        XCTAssertTrue(service.acceptedActionIDs.isEmpty)
        XCTAssertEqual(service.diagnostics.count, 4)
        XCTAssertTrue(service.diagnostics.allSatisfy { $0.contains("unknown builtin identifier") })
    }

    func testAppleScriptNeedsTargetAndScript() throws {
        let actions = [
            action(id: "no-target", kind: "applescript", builtin: nil, extra: #""script": "beep""#),
            action(id: "empty-target", kind: "applescript", builtin: nil, extra: #""targetApp": "", "script": "beep""#),
            action(id: "no-script", kind: "applescript", builtin: nil, extra: #""targetApp": "com.apple.finder""#),
            action(id: "empty-script", kind: "applescript", builtin: nil, extra: #""targetApp": "com.apple.finder", "script": """#),
            action(id: "ok", kind: "applescript", builtin: nil, extra: #""targetApp": "com.apple.finder", "script": "beep""#),
        ]
        let service = try makeService(actions: actionsDoc([actions]), menus: menusDoc([]))
        XCTAssertEqual(service.acceptedActionIDs, ["ok"])
        XCTAssertEqual(service.diagnostics.count, 4)
    }

    func testAppleScriptPlaceholdersMustBeDeclaredInputs() throws {
        let undeclared = action(
            id: "undeclared", kind: "applescript", builtin: nil,
            extra: #""targetApp": "x", "script": "tell app \"{{displayName}}\" to quit""#
        )
        let declared = action(
            id: "declared", kind: "applescript", builtin: nil,
            extra: #""targetApp": "x", "script": "tell app \"{{displayName}}\" to quit", "inputs": ["displayName"]"#
        ).replacingOccurrences(of: #""inputs": [],"#, with: "")
        let service = try makeService(actions: actionsDoc([[undeclared, declared]]), menus: menusDoc([]))
        XCTAssertEqual(service.acceptedActionIDs, ["declared"])
        XCTAssertTrue(service.diagnostics.first?.contains("unknown placeholders: displayName") == true)
    }

    func testPlaceholderListIsSortedInDiagnostics() throws {
        let script = "{{zeta}} {{alpha}} {{mid_1}}"
        let doc = actionsDoc([[action(id: "x", kind: "applescript", builtin: nil, extra: #""targetApp": "t", "script": "\#(script)""#)]])
        let service = try makeService(actions: doc, menus: menusDoc([]))
        XCTAssertTrue(service.diagnostics.first?.contains("alpha, mid_1, zeta") == true, "\(service.diagnostics)")
    }

    func testMalformedPlaceholdersAreNotCountedAsPlaceholders() throws {
        // Only {{letters_digits_underscore}} is a placeholder; spaces, dashes
        // and unbalanced braces are plain script text.
        let scripts = ["{{ spaced }}", "{{dash-ed}}", "{single}", "{{unclosed", "}}{{", "{{}}", "{{a.b}}"]
        for script in scripts {
            let doc = actionsDoc([[action(id: "x", kind: "applescript", builtin: nil, extra: #""targetApp": "t", "script": "\#(script)""#)]])
            let service = try makeService(actions: doc, menus: menusDoc([]))
            XCTAssertEqual(service.acceptedActionIDs, ["x"], script)
        }
    }

    func testMenuClickNeedsTargetAndPath() throws {
        let actions = [
            action(id: "no-target", kind: "menuClick", builtin: nil, extra: #""path": ["File", "New"]"#),
            action(id: "no-path", kind: "menuClick", builtin: nil, extra: #""targetApp": "com.apple.finder""#),
            action(id: "empty-path", kind: "menuClick", builtin: nil, extra: #""targetApp": "com.apple.finder", "path": []"#),
            action(id: "ok", kind: "menuClick", builtin: nil, extra: #""targetApp": "com.apple.finder", "path": ["File", "New Window"]"#),
        ]
        let service = try makeService(actions: actionsDoc([actions]), menus: menusDoc([]))
        XCTAssertEqual(service.acceptedActionIDs, ["ok"])
    }

    func testDuplicateActionIDsKeepTheFirst() throws {
        let first = action(id: "dup", builtin: "openApp")
        let second = action(id: "dup", builtin: "quitApp")
        let service = try makeService(actions: actionsDoc([[first], [second]]), menus: menusDoc([]))
        XCTAssertEqual(service.acceptedActionIDs, ["dup"])
        XCTAssertEqual(service.diagnostics.count, 1)
        XCTAssertTrue(service.diagnostics[0].contains("Duplicate action id 'dup'"))
    }

    func testDuplicateWithinOnePackageIsAlsoReported() throws {
        let service = try makeService(
            actions: actionsDoc([[action(id: "d"), action(id: "d"), action(id: "d")]]),
            menus: menusDoc([])
        )
        XCTAssertEqual(service.diagnostics.count, 2)
    }

    func testPackageSummariesIncludeRejectedActionsInCount() throws {
        let doc = actionsDoc([[action(id: "ok"), action(id: "bad", builtin: "nope")], []])
        let service = try makeService(actions: doc, menus: menusDoc([]))
        XCTAssertEqual(service.packageSummaries.map(\.actionCount), [2, 0])
        XCTAssertEqual(service.packageSummaries.map(\.id), ["pkg0", "pkg1"])
    }

    func testManyActionsValidateQuickly() throws {
        let actions = (0..<5_000).map { action(id: "a\($0)") }
        let start = Date()
        let service = try makeService(actions: actionsDoc([actions]), menus: menusDoc([]))
        XCTAssertEqual(service.acceptedActionIDs.count, 5_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    // MARK: Document decoding

    func testDocumentsRejectUnknownEnumValues() {
        let badKind = actionsDoc([[action(id: "x", kind: "shellScript", builtin: nil)]])
        XCTAssertThrowsError(try JSONDecoder().decode(CatalogActionsDocument.self, from: Data(badKind.utf8)))
        let badTile = actionsDoc([[action(id: "x", tiles: ["dock"])]])
        XCTAssertThrowsError(try JSONDecoder().decode(CatalogActionsDocument.self, from: Data(badTile.utf8)))
        let badPermission = actionsDoc([[action(id: "x", extra: #""permissions": ["root"]"#).replacingOccurrences(of: #""permissions": [],"#, with: "")]])
        XCTAssertThrowsError(try JSONDecoder().decode(CatalogActionsDocument.self, from: Data(badPermission.utf8)))
    }

    func testDocumentsRejectMissingRequiredFields() {
        for json in [
            #"{"version": 1}"#, #"{"packages": []}"#, #"{"version": "1", "packages": []}"#,
            #"{"version": 1, "packages": [{"id": "p"}]}"#,
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(CatalogActionsDocument.self, from: Data(json.utf8)), json)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(CatalogMenusDocument.self, from: Data(#"{"version": 1}"#.utf8)))
    }

    func testEmptyDocumentsProduceAnEmptyCatalog() throws {
        let service = try makeService(actions: actionsDoc([]), menus: menusDoc([]))
        XCTAssertTrue(service.acceptedActionIDs.isEmpty)
        XCTAssertTrue(service.acceptedMenuTileTypes.isEmpty)
        XCTAssertTrue(service.packageSummaries.isEmpty)
        XCTAssertTrue(service.diagnostics.isEmpty)
    }

    // MARK: Menu validation

    func testMenuReferencingUnknownActionIsRejected() throws {
        let service = try makeService(
            actions: actionsDoc([[action(id: "a")]]),
            menus: menusDoc([menu("app", [item("a"), item("ghost")])])
        )
        XCTAssertTrue(service.acceptedMenuTileTypes.isEmpty)
        XCTAssertTrue(service.diagnostics.first?.contains("unknown action id 'ghost'") == true)
    }

    func testMenuActionWithoutIdentifierIsRejected() throws {
        let service = try makeService(
            actions: actionsDoc([[action(id: "a")]]),
            menus: menusDoc([menu("app", [#"{"type": "action"}"#])])
        )
        XCTAssertTrue(service.acceptedMenuTileTypes.isEmpty)
    }

    func testMenuActionMustSupportTheTileType() throws {
        let service = try makeService(
            actions: actionsDoc([[action(id: "folder-only", builtin: "openFolderInFinder", tiles: ["folder"])]]),
            menus: menusDoc([menu("app", [item("folder-only")])])
        )
        XCTAssertTrue(service.acceptedMenuTileTypes.isEmpty)
        XCTAssertTrue(service.diagnostics.first?.contains("does not support tile type 'app'") == true)
    }

    func testAlternateActionIsValidatedToo() throws {
        let actions = actionsDoc([[action(id: "a"), action(id: "folder-only", builtin: "openFolderInFinder", tiles: ["folder"])]])
        let unknown = try makeService(actions: actions, menus: menusDoc([menu("app", [item("a", extra: #""alternateAction": "ghost""#)])]))
        XCTAssertTrue(unknown.acceptedMenuTileTypes.isEmpty)
        let wrongTile = try makeService(actions: actions, menus: menusDoc([menu("app", [item("a", extra: #""alternateAction": "folder-only""#)])]))
        XCTAssertTrue(wrongTile.acceptedMenuTileTypes.isEmpty)
        let fine = try makeService(actions: actions, menus: menusDoc([menu("app", [item("a", extra: #""alternateAction": "a""#)])]))
        XCTAssertEqual(fine.acceptedMenuTileTypes, [.app])
    }

    func testSubmenuRules() throws {
        let actions = actionsDoc([[action(id: "a")]])
        let cases: [(String, Bool)] = [
            (#"{"type": "submenu", "title": "Sub", "children": [{"type": "action", "action": "a"}]}"#, true),
            (#"{"type": "submenu", "children": [{"type": "action", "action": "a"}]}"#, false),
            (#"{"type": "submenu", "title": "", "children": [{"type": "action", "action": "a"}]}"#, false),
            (#"{"type": "submenu", "title": "Sub"}"#, false),
            (#"{"type": "submenu", "title": "Sub", "children": []}"#, false),
            (#"{"type": "submenu", "title": "Sub", "children": [{"type": "action", "action": "ghost"}]}"#, false),
        ]
        for (json, valid) in cases {
            let service = try makeService(actions: actions, menus: menusDoc([menu("app", [json])]))
            XCTAssertEqual(service.acceptedMenuTileTypes == [.app], valid, json)
        }
    }

    func testDeeplyNestedSubmenusValidate() throws {
        var json = item("a")
        for level in 0..<40 {
            json = #"{"type": "submenu", "title": "L\#(level)", "children": [\#(json)]}"#
        }
        let service = try makeService(actions: actionsDoc([[action(id: "a")]]), menus: menusDoc([menu("app", [json])]))
        XCTAssertEqual(service.acceptedMenuTileTypes, [.app])
    }

    func testDuplicateMenuForTileTypeKeepsTheFirst() throws {
        let service = try makeService(
            actions: actionsDoc([[action(id: "a"), action(id: "b")]]),
            menus: menusDoc([menu("app", [item("a")]), menu("app", [item("b")])])
        )
        XCTAssertEqual(service.acceptedMenuTileTypes, [.app])
        XCTAssertTrue(service.diagnostics.first?.contains("Duplicate menu definition") == true)
    }

    func testOneBadMenuDoesNotDiscardTheOthers() throws {
        let service = try makeService(
            actions: actionsDoc([[action(id: "a", tiles: ["app", "trash"])]]),
            menus: menusDoc([menu("app", [item("ghost")]), menu("trash", [item("a")])])
        )
        XCTAssertEqual(service.acceptedMenuTileTypes, [.trash])
    }

    // MARK: Menu building

    private func trashActions(_ extras: [String: String] = [:]) -> [String] {
        ["first", "second", "third"].map {
            action(id: $0, builtin: "openTrash", tiles: ["trash"], extra: extras[$0] ?? "")
        }
    }

    func testMenuItemsAreBuiltInOrder() throws {
        let service = try makeService(
            actions: actionsDoc([trashActions()]),
            menus: menusDoc([menu("trash", [item("first"), item("second"), item("third")])])
        )
        XCTAssertEqual(titles(service.contextActions(for: trash, modifierFlags: [])), ["T first", "T second", "T third"])
    }

    func testDividersAreTrimmedAndCollapsed() throws {
        let service = try makeService(
            actions: actionsDoc([trashActions()]),
            menus: menusDoc([menu("trash", [divider, divider, item("first"), divider, divider, item("second"), divider])])
        )
        XCTAssertEqual(titles(service.contextActions(for: trash, modifierFlags: [])), ["T first", "|", "T second"])
    }

    func testMenuOfOnlyDividersIsEmpty() throws {
        let service = try makeService(
            actions: actionsDoc([trashActions()]),
            menus: menusDoc([menu("trash", [divider, divider])])
        )
        XCTAssertEqual(service.contextActions(for: trash, modifierFlags: [])?.count, 0)
    }

    func testWhenConditionHidesItems() throws {
        let extras = ["second": #""when": {"flag": "isRunning"}"#, "third": #""when": {"not": {"flag": "isRunning"}}"#]
        let service = try makeService(
            actions: actionsDoc([trashActions(extras)]),
            menus: menusDoc([menu("trash", [item("first"), item("second"), item("third")])])
        )
        // A trash tile is never "running".
        XCTAssertEqual(titles(service.contextActions(for: trash, modifierFlags: [])), ["T first", "T third"])
    }

    func testMenuItemLevelWhenIsAppliedBeforeTheAction() throws {
        let service = try makeService(
            actions: actionsDoc([trashActions()]),
            menus: menusDoc([menu("trash", [item("first", extra: #""when": {"flag": "optionKey"}"#), item("second")])])
        )
        XCTAssertEqual(titles(service.contextActions(for: trash, modifierFlags: [])), ["T second"])
        XCTAssertEqual(titles(service.contextActions(for: trash, modifierFlags: .option)), ["T first", "T second"])
    }

    func testAlternateActionAppliesWhenItsConditionHolds() throws {
        let service = try makeService(
            actions: actionsDoc([trashActions()]),
            menus: menusDoc([menu("trash", [
                item("first", extra: #""alternateAction": "second", "alternateActionWhen": {"flag": "optionKey"}"#),
            ])])
        )
        XCTAssertEqual(titles(service.contextActions(for: trash, modifierFlags: [])), ["T first"])
        XCTAssertEqual(titles(service.contextActions(for: trash, modifierFlags: .option)), ["T second"])
    }

    func testAlternateTitleAppliesWhenItsConditionHolds() throws {
        let extra = #""alternateTitle": "Alt", "alternateTitleWhen": {"flag": "optionKey"}"#
        let service = try makeService(
            actions: actionsDoc([[action(id: "first", builtin: "openTrash", tiles: ["trash"], extra: extra)]]),
            menus: menusDoc([menu("trash", [item("first")])])
        )
        XCTAssertEqual(titles(service.contextActions(for: trash, modifierFlags: [])), ["T first"])
        XCTAssertEqual(titles(service.contextActions(for: trash, modifierFlags: .option)), ["Alt"])
    }

    func testDestructiveFlagsAreCarried() throws {
        let extras = [
            "first": #""destructive": true"#,
            "second": #""destructiveWhen": {"flag": "optionKey"}"#,
        ]
        let defs = [
            action(id: "first", builtin: "emptyTrash", tiles: ["trash"], extra: extras["first"]!)
                .replacingOccurrences(of: #""destructive": false,"#, with: ""),
            action(id: "second", builtin: "emptyTrash", tiles: ["trash"], extra: extras["second"]!),
        ]
        let service = try makeService(actions: actionsDoc([defs]), menus: menusDoc([menu("trash", [item("first"), item("second")])]))
        let plain = try XCTUnwrap(service.contextActions(for: trash, modifierFlags: []))
        XCTAssertTrue(plain[0].isDestructive)
        XCTAssertFalse(plain[1].isDestructive)
        let optioned = try XCTUnwrap(service.contextActions(for: trash, modifierFlags: .option))
        XCTAssertTrue(optioned[1].isDestructive)
    }

    func testToggleFlagDrivesCheckmarkState() throws {
        let defs = [action(id: "first", builtin: "openTrash", tiles: ["trash"], extra: #""toggleFlag": "optionKey""#)]
        let service = try makeService(actions: actionsDoc([defs]), menus: menusDoc([menu("trash", [item("first")])]))
        XCTAssertEqual(service.contextActions(for: trash, modifierFlags: [])?.first?.isOn, false)
        XCTAssertEqual(service.contextActions(for: trash, modifierFlags: .option)?.first?.isOn, true)
    }

    func testEmptySubmenuIsDroppedAndPopulatedOneKept() throws {
        let extras = ["second": #""when": {"flag": "isRunning"}"#]
        let sub = #"{"type": "submenu", "title": "Sub", "children": [{"type": "action", "action": "first"}]}"#
        let hidden = #"{"type": "submenu", "title": "Hidden", "children": [{"type": "action", "action": "second"}]}"#
        let service = try makeService(
            actions: actionsDoc([trashActions(extras)]),
            menus: menusDoc([menu("trash", [sub, hidden])])
        )
        let built = try XCTUnwrap(service.contextActions(for: trash, modifierFlags: []))
        XCTAssertEqual(built.map(\.title), ["Sub"])
        XCTAssertEqual(built.first?.kind, .submenu)
        XCTAssertEqual(built.first?.children.map(\.title), ["T first"])
    }

    func testUnsupportedTileKindsReturnNil() throws {
        let service = try makeService(actions: actionsDoc([trashActions()]), menus: menusDoc([menu("trash", [item("first")])]))
        for content in [TileContent.spacer, .flexibleSpacer, .divider] {
            XCTAssertNil(service.contextActions(for: Tile(id: "x", content: content), modifierFlags: []))
        }
    }

    func testMissingMenuForTileTypeReturnsNilAndRecordsDiagnostic() throws {
        let service = try makeService(actions: actionsDoc([trashActions()]), menus: menusDoc([]))
        XCTAssertNil(service.contextActions(for: trash, modifierFlags: []))
        XCTAssertTrue(service.diagnostics.contains { $0.contains("Missing menu definition for tile type 'trash'") })
    }

    func testFolderTilesUseTheFolderMenuAndPath() throws {
        let defs = [action(id: "reveal", builtin: "revealFolderInFinder", tiles: ["folder"])]
        let service = try makeService(actions: actionsDoc([defs]), menus: menusDoc([menu("folder", [item("reveal")])]))
        let folder = FolderTile(url: URL(fileURLWithPath: "/tmp"), displayName: "tmp", displayMode: .folder)
        let tile = Tile(id: "folder:/tmp", content: .folder(folder))
        XCTAssertEqual(titles(service.contextActions(for: tile, modifierFlags: [])), ["T reveal"])
    }

    // MARK: Conditions

    private func context(
        flags: NSEvent.ModifierFlags = [],
        bundleIdentifier: String? = "com.example.app",
        running: Bool = false,
        pinned: Bool = false,
        canTogglePin: Bool = true,
        finder: Bool = false
    ) -> CatalogActionContext {
        CatalogActionContext(
            tile: trash, modifierFlags: flags, bundleIdentifier: bundleIdentifier, displayName: "Name",
            appBundlePath: "/Applications/X.app", folderPath: "/tmp", filePath: "/tmp/f",
            isRunning: running, isPinned: pinned, canTogglePin: canTogglePin, isFinder: finder
        )
    }

    private func condition(_ json: String) throws -> CatalogCondition {
        try JSONDecoder().decode(CatalogCondition.self, from: Data(json.utf8))
    }

    func testFlagConditions() throws {
        let cases: [(String, CatalogActionContext, Bool)] = [
            ("isRunning", context(running: true), true), ("isRunning", context(), false),
            ("isPinned", context(pinned: true), true), ("isPinned", context(), false),
            ("canTogglePin", context(canTogglePin: true), true), ("canTogglePin", context(canTogglePin: false), false),
            ("isFinder", context(finder: true), true), ("isFinder", context(), false),
            ("optionKey", context(flags: .option), true), ("optionKey", context(flags: [.command, .shift]), false),
        ]
        for (flag, ctx, expected) in cases {
            XCTAssertEqual(try condition(#"{"flag": "\#(flag)"}"#).evaluate(in: ctx), expected, flag)
        }
    }

    func testBundleIdentifierCondition() throws {
        let c = try condition(#"{"bundleIdentifierEquals": "com.apple.Safari"}"#)
        XCTAssertTrue(c.evaluate(in: context(bundleIdentifier: "com.apple.Safari")))
        XCTAssertFalse(c.evaluate(in: context(bundleIdentifier: "com.apple.safari")), "case sensitive")
        XCTAssertFalse(c.evaluate(in: context(bundleIdentifier: nil)))
        XCTAssertFalse(c.evaluate(in: context(bundleIdentifier: "com.apple.Safari ")))
    }

    func testCombinators() throws {
        let all = try condition(#"{"all": [{"flag": "isRunning"}, {"flag": "isPinned"}]}"#)
        XCTAssertTrue(all.evaluate(in: context(running: true, pinned: true)))
        XCTAssertFalse(all.evaluate(in: context(running: true)))

        let any = try condition(#"{"any": [{"flag": "isRunning"}, {"flag": "isPinned"}]}"#)
        XCTAssertTrue(any.evaluate(in: context(pinned: true)))
        XCTAssertFalse(any.evaluate(in: context()))

        let not = try condition(#"{"not": {"flag": "isRunning"}}"#)
        XCTAssertTrue(not.evaluate(in: context()))
        XCTAssertFalse(not.evaluate(in: context(running: true)))
    }

    func testEmptyCombinators() throws {
        XCTAssertTrue(try condition(#"{"all": []}"#).evaluate(in: context()), "all of nothing holds")
        XCTAssertFalse(try condition(#"{"any": []}"#).evaluate(in: context()), "any of nothing fails")
    }

    func testNestedCombinators() throws {
        let c = try condition("""
        {"all": [{"not": {"flag": "isFinder"}}, {"any": [{"flag": "isRunning"}, {"bundleIdentifierEquals": "com.example.app"}]}]}
        """)
        XCTAssertTrue(c.evaluate(in: context()))
        XCTAssertFalse(c.evaluate(in: context(finder: true)))
        XCTAssertFalse(c.evaluate(in: context(bundleIdentifier: "other")))
        XCTAssertTrue(c.evaluate(in: context(bundleIdentifier: "other", running: true)))
    }

    func testMalformedConditionsAreRejected() {
        for json in [
            "{}", #"{"flag": "teleport"}"#, #"{"flag": 3}"#, #"{"all": "x"}"#, #"{"not": []}"#,
            #"{"unknown": true}"#, "[]", "null", #"{"bundleIdentifierEquals": null}"#,
        ] {
            XCTAssertThrowsError(try condition(json), json)
        }
    }

    func testConditionWithMultipleKeysUsesTheFirstRecognizedOne() throws {
        // Documented contract says "exactly one"; the decoder takes the first
        // key it finds, in the order flag, bundleIdentifierEquals, all, any, not.
        let c = try condition(#"{"flag": "isRunning", "not": {"flag": "isRunning"}}"#)
        XCTAssertTrue(c.evaluate(in: context(running: true)))
    }

    func testVeryDeepConditionDecodesAndEvaluates() throws {
        var json = #"{"flag": "isRunning"}"#
        for _ in 0..<150 { json = #"{"not": \#(json)}"# }
        let c = try condition(json)
        // 150 negations cancel out.
        XCTAssertTrue(c.evaluate(in: context(running: true)))
    }

    func testConditionRoundTrip() throws {
        let original = try condition(#"{"all": [{"flag": "isRunning"}, {"not": {"bundleIdentifierEquals": "x"}}]}"#)
        let again = try JSONDecoder().decode(CatalogCondition.self, from: try JSONEncoder().encode(original))
        for ctx in [context(running: true), context(), context(bundleIdentifier: "x", running: true)] {
            XCTAssertEqual(original.evaluate(in: ctx), again.evaluate(in: ctx))
        }
    }

    // MARK: Context values

    func testContextInputValues() {
        let ctx = context(bundleIdentifier: "b")
        XCTAssertEqual(ctx.stringValue(for: .bundleIdentifier), "b")
        XCTAssertEqual(ctx.stringValue(for: .displayName), "Name")
        XCTAssertEqual(ctx.stringValue(for: .appBundlePath), "/Applications/X.app")
        XCTAssertEqual(ctx.stringValue(for: .folderPath), "/tmp")
        XCTAssertEqual(ctx.stringValue(for: .filePath), "/tmp/f")
        XCTAssertNil(context(bundleIdentifier: nil).stringValue(for: .bundleIdentifier))
    }

    func testPermissionRequirementMapping() {
        XCTAssertEqual(CatalogPermissionRequirement.finderAutomation.permission, .finderAutomation)
        XCTAssertEqual(CatalogPermissionRequirement.accessibility.permission, .accessibility)
        XCTAssertEqual(CatalogPermissionRequirement.systemEventsAutomation.permission, .systemEventsAutomation)
        XCTAssertEqual(CatalogPermissionRequirement.allCases.count, 3)
    }

    func testPackageManifestProjection() throws {
        let doc = try JSONDecoder().decode(CatalogActionsDocument.self, from: Data(actionsDoc([[action(id: "a")]]).utf8))
        let manifest = doc.packages[0].manifest
        XCTAssertEqual(manifest.id, "pkg0")
        XCTAssertEqual(manifest.reviewStatus, "curated")
    }

    // MARK: The shipped catalog

    private func shippedDocument<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Docky/MenuCatalog/\(name).json")
        let data = try Data(contentsOf: source)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func testShippedCatalogValidatesWithNoDiagnostics() throws {
        let actions = try shippedDocument("actions", as: CatalogActionsDocument.self)
        let menus = try shippedDocument("menus", as: CatalogMenusDocument.self)
        let service = MenuCatalogService(actionsDocument: actions, menusDocument: menus)
        XCTAssertEqual(service.diagnostics, [])
        XCTAssertEqual(service.acceptedMenuTileTypes, Set(MenuTileType.allCases))
    }

    func testShippedActionIDsAreUniqueAndAllAccepted() throws {
        let actions = try shippedDocument("actions", as: CatalogActionsDocument.self)
        let ids = actions.packages.flatMap(\.actions).map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        let service = MenuCatalogService(
            actionsDocument: actions,
            menusDocument: try shippedDocument("menus", as: CatalogMenusDocument.self)
        )
        XCTAssertEqual(service.acceptedActionIDs, Set(ids))
    }

    func testShippedCatalogIsAlsoPresentInTheAppBundle() throws {
        let appCopy = Bundle.main.url(forResource: "actions", withExtension: "json", subdirectory: "MenuCatalog")
            ?? Bundle.main.url(forResource: "actions", withExtension: "json")
        let url = try XCTUnwrap(appCopy, "the catalog must be a bundle resource or reload() reports a diagnostic")
        XCTAssertNoThrow(try JSONDecoder().decode(CatalogActionsDocument.self, from: Data(contentsOf: url)))
    }

    func testShippedTrashMenuBuildsWithoutAppState() throws {
        let service = MenuCatalogService(
            actionsDocument: try shippedDocument("actions", as: CatalogActionsDocument.self),
            menusDocument: try shippedDocument("menus", as: CatalogMenusDocument.self)
        )
        let built = try XCTUnwrap(service.contextActions(for: trash, modifierFlags: []))
        XCTAssertFalse(built.isEmpty)
        XCTAssertNotEqual(built.first?.kind, .divider)
        XCTAssertNotEqual(built.last?.kind, .divider)
    }
}

private extension String {
    /// "a,b" -> "[a,b]"
    var wrapped: String { "[\(self)]" }
}
