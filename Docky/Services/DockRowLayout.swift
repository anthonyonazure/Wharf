//
//  DockRowLayout.swift
//  Wharf
//
//  Pure row arithmetic for multi-row docks. Foundation only, so it can be
//  checked without a window: scripts/test-dock-rows.sh.
//
//  The tile view wraps each section (pinned, running, trailing) into rows on
//  its own, with the section dividers standing between them. The window used
//  to be measured by wrapping the whole flat tile list instead, dividers and
//  all, so the panel it asked for did not match the rows it then drew. Both
//  sides now go through this file, so they cannot drift apart again.
//

import Foundation

enum DockRowLayout {
    static let rowRange = 1...5

    static func clampedRowCount(_ value: Int) -> Int {
        min(max(value, rowRange.lowerBound), rowRange.upperBound)
    }

    /// Splits items into at most `rowCount` rows, filling each row in order
    /// so items keep their reading order rather than being dealt round-robin.
    static func chunk<T>(_ items: [T], intoRows rowCount: Int) -> [[T]] {
        guard rowCount > 1, items.count > rowCount else { return [items] }
        let perRow = Int((Double(items.count) / Double(rowCount)).rounded(.up))
        return stride(from: 0, to: items.count, by: perRow).map { start in
            Array(items[start..<min(start + perRow, items.count)])
        }
    }

    /// Size of one item, or of a whole block, measured along the dock's long
    /// axis and across it.
    struct Extent: Equatable {
        var along: Double
        var cross: Double
    }

    /// A run of tiles that wraps into rows, or a section divider that does not.
    enum Component<T> {
        case section([T])
        case divider(T)
    }

    /// Splits a flat list the same way the tile view does: every item that
    /// `isSectionBreak` accepts becomes a divider, and the runs between them
    /// become sections. Empty runs are dropped.
    static func components<T>(_ items: [T], isSectionBreak: (T) -> Bool) -> [Component<T>] {
        var result: [Component<T>] = []
        var current: [T] = []
        for item in items {
            if isSectionBreak(item) {
                if !current.isEmpty { result.append(.section(current)) }
                current = []
                result.append(.divider(item))
            } else {
                current.append(item)
            }
        }
        if !current.isEmpty { result.append(.section(current)) }
        return result
    }

    /// One section wrapped into rows: as long as its longest row, as thick as
    /// every row stacked with a gap between each.
    static func sectionExtent(_ sizes: [Extent], rowCount: Int, spacing: Double, emptyCross: Double) -> Extent {
        let rows = chunk(sizes, intoRows: clampedRowCount(rowCount))
        let metrics = rows.map { row -> Extent in
            let along = row.reduce(0) { $0 + $1.along } + Double(max(0, row.count - 1)) * spacing
            let cross = row.map(\.cross).max() ?? emptyCross
            return Extent(along: along, cross: cross)
        }
        let along = metrics.map(\.along).max() ?? 0
        let cross = metrics.reduce(0) { $0 + $1.cross } + Double(max(0, metrics.count - 1)) * spacing
        return Extent(along: along, cross: cross)
    }

    /// The whole dock: sections and dividers side by side along the axis with
    /// `spacing` between them and `edgePadding` at both ends; as thick as the
    /// thickest of them. An empty dock keeps `emptyCross` so the chrome never
    /// collapses to nothing.
    static func contentExtent<T>(
        _ components: [Component<T>],
        rowCount: Int,
        spacing: Double,
        edgePadding: Double,
        emptyCross: Double,
        extent: (T) -> Extent
    ) -> Extent {
        let blocks = components.map { component -> Extent in
            switch component {
            case .divider(let item):
                return extent(item)
            case .section(let items):
                return sectionExtent(items.map(extent), rowCount: rowCount, spacing: spacing, emptyCross: emptyCross)
            }
        }
        let along = blocks.reduce(0) { $0 + $1.along }
            + Double(max(0, blocks.count - 1)) * spacing
            + edgePadding * 2
        let cross = blocks.map(\.cross).max() ?? emptyCross
        return Extent(along: along, cross: cross)
    }

    /// Resting along-axis center of the first item `matches` accepts, measured
    /// from the leading edge of the content. Only items in the same row and
    /// the blocks before its section count toward the offset; a tile in row
    /// two does not sit after every tile in row one.
    static func restAlongCenter<T>(
        where matches: (T) -> Bool,
        in components: [Component<T>],
        rowCount: Int,
        spacing: Double,
        edgePadding: Double,
        emptyCross: Double,
        extent: (T) -> Extent
    ) -> Double? {
        var offset = edgePadding
        for component in components {
            switch component {
            case .divider(let item):
                let along = extent(item).along
                if matches(item) { return offset + along / 2 }
                offset += along + spacing
            case .section(let items):
                for row in chunk(items, intoRows: clampedRowCount(rowCount)) {
                    var rowOffset = offset
                    for item in row {
                        let along = extent(item).along
                        if matches(item) { return rowOffset + along / 2 }
                        rowOffset += along + spacing
                    }
                }
                let block = sectionExtent(items.map(extent), rowCount: rowCount, spacing: spacing, emptyCross: emptyCross)
                offset += block.along + spacing
            }
        }
        return nil
    }
}
