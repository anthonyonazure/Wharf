//
//  DockRowLayoutTests.swift
//  Wharf
//
//  Standalone checks for Docky/Services/DockRowLayout.swift, compiled with
//  that file into a small executable. Run: scripts/test-dock-rows.sh
//

import Foundation

private var failures = 0
private var checks = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL line \(line): \(message)")
    }
}

private func expectClose(_ actual: Double?, _ expected: Double, _ message: String, line: Int = #line) {
    guard let actual else {
        expect(false, "\(message): got nil, expected \(expected)", line: line)
        return
    }
    expect(abs(actual - expected) < 0.001, "\(message): got \(actual), expected \(expected)", line: line)
}

private typealias L = DockRowLayout

/// A tile for the checks: an id plus its resting size. Dividers are the two
/// section breaks the tile view uses.
private struct Item {
    let id: String
    let along: Double
    let cross: Double
    var isBreak: Bool { id == "divider:running" || id == "divider:trailing" }
}

// A 48 pt tile with 4 pt of padding above and below, 4 pt apart; 8 pt at
// each end of the dock. Dividers are 10 pt wide and as tall as a tile.
private let spacing = 4.0
private let edge = 8.0
private let tileCross = 56.0
private func tile(_ id: String) -> Item { Item(id: id, along: 48, cross: tileCross) }
private func divider(_ id: String) -> Item { Item(id: id, along: 10, cross: tileCross) }

private func measure(_ items: [Item], rows: Int) -> L.Extent {
    L.contentExtent(
        L.components(items, isSectionBreak: \.isBreak),
        rowCount: rows,
        spacing: spacing,
        edgePadding: edge,
        emptyCross: tileCross
    ) { L.Extent(along: $0.along, cross: $0.cross) }
}

private func center(of id: String, in items: [Item], rows: Int) -> Double? {
    L.restAlongCenter(
        where: { $0.id == id },
        in: L.components(items, isSectionBreak: \.isBreak),
        rowCount: rows,
        spacing: spacing,
        edgePadding: edge,
        emptyCross: tileCross
    ) { L.Extent(along: $0.along, cross: $0.cross) }
}

private let twelve = (0..<12).map { tile("t\($0)") }

private func testChunk() {
    expect(L.chunk([1, 2, 3, 4, 5], intoRows: 1) == [[1, 2, 3, 4, 5]], "one row keeps everything")
    expect(L.chunk([1, 2, 3, 4, 5], intoRows: 2) == [[1, 2, 3], [4, 5]], "fills rows in reading order")
    expect(L.chunk([1, 2], intoRows: 3) == [[1, 2]], "fewer items than rows stays one row")
    expect(L.chunk([Int](), intoRows: 3) == [[]], "empty stays one empty row")
    expect(L.clampedRowCount(0) == 1 && L.clampedRowCount(9) == 5 && L.clampedRowCount(3) == 3, "row count clamps to 1...5")
}

private func testSingleRowIsUnchanged() {
    // The old single strip formula: every tile and divider summed with
    // spacing between them, plus edge padding.
    let items = [tile("a"), tile("b"), divider("divider:running"), tile("c")]
    let size = measure(items, rows: 1)
    expectClose(size.along, 48 * 3 + 10 + 3 * spacing + edge * 2, "single row length")
    expectClose(size.cross, tileCross, "single row thickness")
    expectClose(center(of: "c", in: items, rows: 1), edge + 48 + 4 + 48 + 4 + 10 + 4 + 24, "single row center")
}

private func testRowsGrowTheThickness() {
    // This is the number the window reservation follows: a bottom or top dock
    // gets taller, a left or right dock gets wider, by a tile plus a gap per row.
    let one = measure(twelve, rows: 1)
    let three = measure(twelve, rows: 3)
    expectClose(three.cross - one.cross, 2 * (tileCross + spacing), "each extra row adds a tile plus a gap")
    expectClose(three.along, 4 * 48 + 3 * spacing + edge * 2, "three rows of four")
    expect(three.along < one.along, "rows make the dock shorter")
    let five = measure(twelve, rows: 5)
    expectClose(five.cross, 4 * tileCross + 3 * spacing, "12 tiles in 5 rows wrap 3 per row, so 4 rows")
}

private func testSectionsWrapSeparately() {
    // Pinned apps, a running divider, then running windows. With two rows the
    // view wraps each section on its own; the flat list would have wrapped
    // the divider into the middle of a row.
    let items = [tile("p0"), tile("p1"), tile("p2"), divider("divider:running")]
        + (0..<6).map { tile("r\($0)") }
    let size = measure(items, rows: 2)
    let pinned = 2 * 48 + spacing          // two pinned in the first row
    let running = 3 * 48 + 2 * spacing     // three running in the first row
    expectClose(size.along, pinned + spacing + 10 + spacing + running + edge * 2, "sections wrap on their own")
    expectClose(size.cross, 2 * tileCross + spacing, "two rows thick")

    // r3 starts the running section's second row, so it sits right after the
    // divider, not after r0 to r2.
    let sectionStart = edge + pinned + spacing + 10 + spacing
    expectClose(center(of: "r3", in: items, rows: 2), sectionStart + 24, "second row starts at its section")
    expectClose(center(of: "p2", in: items, rows: 2), edge + 24, "pinned second row")
}

private func testSmallSectionStaysOneRow() {
    // A section no larger than the row count is not wrapped, so a mostly
    // empty dock is not padded out to the full row count.
    let items = [tile("a"), divider("divider:running"), tile("b")]
    expectClose(measure(items, rows: 3).cross, tileCross, "tiny sections stay one row")
}

private func testEmptyDock() {
    let size = measure([], rows: 3)
    expectClose(size.along, edge * 2, "empty dock is just its padding")
    expectClose(size.cross, tileCross, "empty dock keeps a tile's thickness")
    expect(center(of: "x", in: twelve, rows: 2) == nil, "unknown tile has no center")
}

@main
struct DockRowLayoutTests {
    static func main() {
        testChunk()
        testSingleRowIsUnchanged()
        testRowsGrowTheThickness()
        testSectionsWrapSeparately()
        testSmallSectionStaysOneRow()
        testEmptyDock()

        if failures == 0 {
            print("PASS: \(checks) checks")
            exit(0)
        } else {
            print("FAILED: \(failures) of \(checks) checks")
            exit(1)
        }
    }
}
