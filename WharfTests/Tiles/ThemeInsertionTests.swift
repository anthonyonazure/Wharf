import XCTest
@testable import Wharf

/// `TileStore.applyingThemeLayoutInsertions(to:insertions:)`: themes ship JSON
/// that injects spacers, dividers and widgets next to named anchors. Theme
/// files are third-party input, so every malformed shape must be skipped, not
/// trapped on.
@MainActor
final class ThemeInsertionTests: XCTestCase {
    private func app(_ bundleID: String) -> Tile {
        Tile(id: "pinned:\(bundleID)", content: .app(AppTile(bundleIdentifier: bundleID, displayName: bundleID)))
    }

    private var baseTiles: [Tile] {
        [
            app("com.apple.finder"),
            app("com.apple.Safari"),
            Tile(id: "divider:running", content: .divider),
            Tile(id: "divider:trailing", content: .divider),
            Tile(id: "trailing:trash", content: .trash),
        ]
    }

    private func apply(_ insertions: [ThemeLayoutInsertion]?, to tiles: [Tile]? = nil) -> [Tile] {
        TileStore.applyingThemeLayoutInsertions(to: tiles ?? baseTiles, insertions: insertions)
    }

    private func ids(_ tiles: [Tile]) -> [String] { tiles.map(\.id) }

    // MARK: - No-ops

    func testNilInsertionsLeaveTilesUntouched() {
        XCTAssertEqual(apply(nil), baseTiles)
    }

    func testEmptyInsertionsLeaveTilesUntouched() {
        XCTAssertEqual(apply([]), baseTiles)
    }

    func testEmptyTileListWithAnyInsertionStaysEmpty() {
        XCTAssertEqual(apply([ThemeLayoutInsertion(kind: "spacer", after: "x")], to: []), [])
    }

    // MARK: - Structural kinds

    func testStructuralKindsInsertTheRightContent() {
        let table: [(String, TileContent)] = [
            ("spacer", .spacer), ("flexibleSpacer", .flexibleSpacer), ("divider", .divider),
        ]
        for (kind, content) in table {
            let result = apply([ThemeLayoutInsertion(kind: kind, after: "pinned:com.apple.finder")])
            XCTAssertEqual(result.count, baseTiles.count + 1, kind)
            XCTAssertEqual(result[1].content, content, kind)
            XCTAssertEqual(result[1].id, "theme:insert:0:\(kind)")
        }
    }

    func testAfterInsertsImmediatelyAfterTheAnchor() {
        let result = apply([ThemeLayoutInsertion(kind: "spacer", after: "pinned:com.apple.finder")])
        XCTAssertEqual(ids(result), [
            "pinned:com.apple.finder", "theme:insert:0:spacer", "pinned:com.apple.Safari",
            "divider:running", "divider:trailing", "trailing:trash",
        ])
    }

    func testBeforeInsertsImmediatelyBeforeTheAnchor() {
        let result = apply([ThemeLayoutInsertion(kind: "spacer", before: "divider:trailing")])
        XCTAssertEqual(ids(result), [
            "pinned:com.apple.finder", "pinned:com.apple.Safari", "divider:running",
            "theme:insert:0:spacer", "divider:trailing", "trailing:trash",
        ])
    }

    func testAfterWinsWhenBothAnchorsAreSet() {
        let result = apply([ThemeLayoutInsertion(kind: "spacer", after: "pinned:com.apple.finder", before: "trailing:trash")])
        XCTAssertEqual(result[1].id, "theme:insert:0:spacer")
    }

    func testInsertAfterTheLastTileAppends() {
        let result = apply([ThemeLayoutInsertion(kind: "divider", after: "trailing:trash")])
        XCTAssertEqual(result.last?.id, "theme:insert:0:divider")
    }

    func testInsertBeforeTheFirstTilePrepends() {
        let result = apply([ThemeLayoutInsertion(kind: "divider", before: "pinned:com.apple.finder")])
        XCTAssertEqual(result.first?.id, "theme:insert:0:divider")
    }

    // MARK: - Anchor resolution

    func testAnchorResolvesByBundleIdentifier() {
        let result = apply([ThemeLayoutInsertion(kind: "spacer", after: "com.apple.Safari")])
        XCTAssertEqual(result[2].id, "theme:insert:0:spacer")
    }

    func testExactTileIDWinsOverBundleIdentifier() {
        let tiles = [
            Tile(id: "com.apple.Safari", content: .divider),
            app("com.apple.Safari"),
        ]
        let result = apply([ThemeLayoutInsertion(kind: "spacer", after: "com.apple.Safari")], to: tiles)
        XCTAssertEqual(ids(result), ["com.apple.Safari", "theme:insert:0:spacer", "pinned:com.apple.Safari"])
    }

    func testUnknownAnchorIsSkipped() {
        XCTAssertEqual(apply([ThemeLayoutInsertion(kind: "spacer", after: "nope")]), baseTiles)
    }

    func testMissingAnchorsAreSkipped() {
        XCTAssertEqual(apply([ThemeLayoutInsertion(kind: "spacer")]), baseTiles)
    }

    func testEmptyAnchorStringMatchesNothing() {
        XCTAssertEqual(apply([ThemeLayoutInsertion(kind: "spacer", after: "")]), baseTiles)
    }

    func testAnchorMatchingIsCaseSensitive() {
        XCTAssertEqual(apply([ThemeLayoutInsertion(kind: "spacer", after: "COM.APPLE.SAFARI")]), baseTiles)
    }

    func testAnchorCanBeAnEarlierThemeInsertion() {
        let result = apply([
            ThemeLayoutInsertion(kind: "spacer", after: "pinned:com.apple.finder"),
            ThemeLayoutInsertion(kind: "divider", after: "theme:insert:0:spacer"),
        ])
        XCTAssertEqual(Array(ids(result).prefix(3)), ["pinned:com.apple.finder", "theme:insert:0:spacer", "theme:insert:1:divider"])
    }

    func testInsertionIndexInIDCountsSkippedEntries() {
        let result = apply([
            ThemeLayoutInsertion(kind: "bogus", after: "pinned:com.apple.finder"),
            ThemeLayoutInsertion(kind: "spacer", after: "pinned:com.apple.finder"),
        ])
        XCTAssertEqual(result[1].id, "theme:insert:1:spacer")
        XCTAssertEqual(result.count, baseTiles.count + 1)
    }

    // MARK: - Widget kinds

    func testWidgetKindInsertsWidgetWithCatalogDefaultSpan() {
        let result = apply([ThemeLayoutInsertion(kind: "search", after: "pinned:com.apple.finder")])
        guard case .widget(let widget) = result[1].content else { return XCTFail("expected a widget") }
        XCTAssertEqual(widget.kind, .search)
        XCTAssertEqual(widget.span, WidgetCatalog.search.defaultSpan)
        XCTAssertEqual(widget.ownerBundleIdentifier, WidgetCatalog.search.ownerBundleIdentifier)
        XCTAssertEqual(result[1].id, "theme:insert:0:search")
    }

    func testWidgetSpanOverrideIsApplied() {
        for raw in 1...4 {
            let result = apply([ThemeLayoutInsertion(kind: "weather", after: "pinned:com.apple.finder", span: raw)])
            guard case .widget(let widget) = result[1].content else { return XCTFail("expected a widget") }
            XCTAssertEqual(widget.span.rawValue, raw)
        }
    }

    func testInvalidSpanFallsBackToCatalogDefault() {
        for raw in [0, -1, 5, 99, Int.max] {
            let result = apply([ThemeLayoutInsertion(kind: "weather", after: "pinned:com.apple.finder", span: raw)])
            guard case .widget(let widget) = result[1].content else { return XCTFail("expected a widget") }
            XCTAssertEqual(widget.span, WidgetCatalog.weather.defaultSpan, "span \(raw)")
        }
    }

    func testSpanIsIgnoredForStructuralKinds() {
        let result = apply([ThemeLayoutInsertion(kind: "spacer", after: "pinned:com.apple.finder", span: 3)])
        XCTAssertEqual(result[1].content, .spacer)
    }

    func testUnknownKindsAreSkipped() {
        for kind in ["", "SPACER", "Spacer", "hologram", "external:", "calendar ", " spacer"] {
            XCTAssertEqual(apply([ThemeLayoutInsertion(kind: kind, after: "pinned:com.apple.finder")]), baseTiles, "kind '\(kind)'")
        }
    }

    func testKnownWidgetKindWithoutARegistrationIsSkipped() {
        // `.layouts` and `.clock` are valid WidgetKinds but have no static
        // catalog registration, so a theme cannot inject them.
        for kind in ["layouts", "clock"] {
            XCTAssertEqual(apply([ThemeLayoutInsertion(kind: kind, after: "pinned:com.apple.finder")]), baseTiles, kind)
        }
    }

    func testUnregisteredExternalWidgetKindIsSkipped() {
        let kind = "external:test.unregistered.\(UUID().uuidString)"
        XCTAssertEqual(apply([ThemeLayoutInsertion(kind: kind, after: "pinned:com.apple.finder")]), baseTiles)
    }

    // MARK: - Volume and ordering

    func testManyInsertionsAtOneAnchorStackInReverseOrderOfApplication() {
        let insertions = (0..<5).map { _ in ThemeLayoutInsertion(kind: "spacer", after: "pinned:com.apple.finder") }
        let result = apply(insertions)
        XCTAssertEqual(Array(ids(result).prefix(6)), [
            "pinned:com.apple.finder",
            "theme:insert:4:spacer", "theme:insert:3:spacer", "theme:insert:2:spacer",
            "theme:insert:1:spacer", "theme:insert:0:spacer",
        ])
    }

    func testThousandInsertionsDoNotTrap() {
        let insertions = (0..<1_000).map { index in
            ThemeLayoutInsertion(kind: index.isMultiple(of: 2) ? "spacer" : "divider", before: "trailing:trash")
        }
        let result = apply(insertions)
        XCTAssertEqual(result.count, baseTiles.count + 1_000)
        XCTAssertEqual(Set(ids(result)).count, result.count, "generated ids must stay unique")
    }

    func testOriginalTilesKeepTheirRelativeOrder() {
        let insertions = [
            ThemeLayoutInsertion(kind: "spacer", after: "com.apple.Safari"),
            ThemeLayoutInsertion(kind: "divider", before: "divider:running"),
            ThemeLayoutInsertion(kind: "search", after: "divider:trailing"),
        ]
        let original = Set(ids(baseTiles))
        let result = ids(apply(insertions)).filter(original.contains)
        XCTAssertEqual(result, ids(baseTiles))
    }

    // MARK: - ThemeLayoutInsertion decoding

    func testInsertionDecodesFromThemeJSON() throws {
        let json = #"[{"kind":"search","after":"divider:trailing","span":2},{"kind":"spacer","before":"com.apple.Safari"}]"#
        let decoded = try JSONDecoder().decode([ThemeLayoutInsertion].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0], ThemeLayoutInsertion(kind: "search", after: "divider:trailing", span: 2))
        XCTAssertEqual(decoded[1], ThemeLayoutInsertion(kind: "spacer", before: "com.apple.Safari"))
    }

    func testInsertionWithoutKindFailsToDecode() {
        XCTAssertThrowsError(try JSONDecoder().decode(ThemeLayoutInsertion.self, from: Data(#"{"after":"x"}"#.utf8)))
    }

    func testInsertionWithWrongTypedSpanFailsToDecode() {
        XCTAssertThrowsError(try JSONDecoder().decode(ThemeLayoutInsertion.self, from: Data(#"{"kind":"spacer","span":"wide"}"#.utf8)))
    }
}
