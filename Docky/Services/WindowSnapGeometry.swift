//
//  WindowSnapGeometry.swift
//  Wharf
//
//  Pure geometry for window snapping: the action list, target rects, gaps,
//  the dock strip, display moves and the per-window restore history.
//
//  Adapted from Vorssaint (https://github.com/vorssaint/vorssaint-utils,
//  GPL-3.0-or-later, Copyright (C) 2026 Vorssaint), chiefly
//  WindowLayoutSupport.swift (WindowLayoutAction, WindowLayoutGeometry,
//  WindowLayoutHistory). Wharf is GPL-3.0 as well.
//
//  Foundation and CoreGraphics only (CGRect math), on purpose: nothing here
//  touches AppKit, NSScreen or the accessibility API, so it compiles on its
//  own and the test harness in
//  Tests/WindowSnap runs it without a window on screen. Every rect is in
//  AppKit screen space (origin bottom-left, Y grows up), so "top" is maxY.
//

import CoreGraphics
import Foundation

nonisolated enum WindowSnapAction: String, CaseIterable, Identifiable, Codable {
    case leftHalf, rightHalf, topHalf, bottomHalf, centerHalf
    case leftThird, centerThird, rightThird
    case leftTwoThirds, centerTwoThirds, rightTwoThirds
    case topThird, middleThird, bottomThird
    case topTwoThirds, middleTwoThirds, bottomTwoThirds
    case leftQuarter, leftMiddleQuarter, rightMiddleQuarter, rightQuarter
    case topQuarter, upperMiddleQuarter, lowerMiddleQuarter, bottomQuarter
    case topLeftSixth, topCenterSixth, topRightSixth
    case bottomLeftSixth, bottomCenterSixth, bottomRightSixth
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize, maximizeWithMargin, center
    case previousDisplay, nextDisplay, restore

    var id: String { rawValue }

    /// Groups for the settings list and the context menu, in display order.
    enum Group: String, CaseIterable, Identifiable {
        case halves, thirds, quarters, sixths, corners, whole, displays

        var id: String { rawValue }

        var title: String {
            switch self {
            case .halves: "Halves"
            case .thirds: "Thirds"
            case .quarters: "Quarters"
            case .sixths: "Sixths"
            case .corners: "Corners"
            case .whole: "Maximize, Center and Restore"
            case .displays: "Displays"
            }
        }

        var actions: [WindowSnapAction] {
            WindowSnapAction.allCases.filter { $0.group == self }
        }
    }

    var group: Group {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf, .centerHalf:
            .halves
        case .leftThird, .centerThird, .rightThird,
             .leftTwoThirds, .centerTwoThirds, .rightTwoThirds,
             .topThird, .middleThird, .bottomThird,
             .topTwoThirds, .middleTwoThirds, .bottomTwoThirds:
            .thirds
        case .leftQuarter, .leftMiddleQuarter, .rightMiddleQuarter, .rightQuarter,
             .topQuarter, .upperMiddleQuarter, .lowerMiddleQuarter, .bottomQuarter:
            .quarters
        case .topLeftSixth, .topCenterSixth, .topRightSixth,
             .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth:
            .sixths
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            .corners
        case .maximize, .maximizeWithMargin, .center, .restore:
            .whole
        case .previousDisplay, .nextDisplay:
            .displays
        }
    }

    var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .centerHalf: "Center Half"
        case .leftThird: "Left Third"
        case .centerThird: "Center Third"
        case .rightThird: "Right Third"
        case .leftTwoThirds: "Left Two Thirds"
        case .centerTwoThirds: "Center Two Thirds"
        case .rightTwoThirds: "Right Two Thirds"
        case .topThird: "Top Third"
        case .middleThird: "Middle Third"
        case .bottomThird: "Bottom Third"
        case .topTwoThirds: "Top Two Thirds"
        case .middleTwoThirds: "Middle Two Thirds"
        case .bottomTwoThirds: "Bottom Two Thirds"
        case .leftQuarter: "Left Quarter"
        case .leftMiddleQuarter: "Left Middle Quarter"
        case .rightMiddleQuarter: "Right Middle Quarter"
        case .rightQuarter: "Right Quarter"
        case .topQuarter: "Top Quarter"
        case .upperMiddleQuarter: "Upper Middle Quarter"
        case .lowerMiddleQuarter: "Lower Middle Quarter"
        case .bottomQuarter: "Bottom Quarter"
        case .topLeftSixth: "Top Left Sixth"
        case .topCenterSixth: "Top Center Sixth"
        case .topRightSixth: "Top Right Sixth"
        case .bottomLeftSixth: "Bottom Left Sixth"
        case .bottomCenterSixth: "Bottom Center Sixth"
        case .bottomRightSixth: "Bottom Right Sixth"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .maximize: "Maximize"
        case .maximizeWithMargin: "Maximize with Margin"
        case .center: "Center"
        case .previousDisplay: "Previous Display"
        case .nextDisplay: "Next Display"
        case .restore: "Restore"
        }
    }

    var symbolName: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.inset.filled"
        case .rightHalf: "rectangle.righthalf.inset.filled"
        case .topHalf: "rectangle.tophalf.inset.filled"
        case .bottomHalf: "rectangle.bottomhalf.inset.filled"
        case .centerHalf, .centerThird, .centerTwoThirds: "rectangle.center.inset.filled"
        case .leftThird: "rectangle.leftthird.inset.filled"
        case .rightThird: "rectangle.rightthird.inset.filled"
        case .leftTwoThirds: "rectangle.leadinghalf.filled"
        case .rightTwoThirds: "rectangle.trailinghalf.filled"
        case .topThird, .topQuarter: "rectangle.topthird.inset.filled"
        case .middleThird, .middleTwoThirds: "rectangle.portrait.center.inset.filled"
        case .bottomThird, .bottomQuarter: "rectangle.bottomthird.inset.filled"
        case .topTwoThirds, .upperMiddleQuarter: "rectangle.tophalf.inset.filled"
        case .bottomTwoThirds, .lowerMiddleQuarter: "rectangle.bottomhalf.inset.filled"
        case .leftQuarter: "rectangle.portrait.leftthird.inset.filled"
        case .leftMiddleQuarter: "rectangle.portrait.lefthalf.inset.filled"
        case .rightMiddleQuarter: "rectangle.portrait.righthalf.inset.filled"
        case .rightQuarter: "rectangle.portrait.rightthird.inset.filled"
        case .topLeftSixth, .topLeft: "arrow.up.left"
        case .topCenterSixth: "arrow.up"
        case .topRightSixth, .topRight: "arrow.up.right"
        case .bottomLeftSixth, .bottomLeft: "arrow.down.left"
        case .bottomCenterSixth: "arrow.down"
        case .bottomRightSixth, .bottomRight: "arrow.down.right"
        case .maximize: "arrow.up.left.and.arrow.down.right"
        case .maximizeWithMargin: "rectangle.inset.filled"
        case .center: "scope"
        case .previousDisplay: "arrow.left.to.line"
        case .nextDisplay: "arrow.right.to.line"
        case .restore: "arrow.uturn.backward"
        }
    }

    /// Carbon hot key id, used to match a key press back to its action. Only
    /// lives for the process: stored shortcuts are keyed by `rawValue`, so
    /// adding a case and shifting these numbers is harmless.
    var hotKeyID: UInt32 {
        UInt32(Self.allCases.firstIndex(of: self)! + 1)
    }

    init?(hotKeyID: UInt32) {
        guard let action = Self.allCases.first(where: { $0.hotKeyID == hotKeyID }) else { return nil }
        self = action
    }

    /// Actions whose target is computed from the current frame rather than
    /// tiled against the screen. They take no window gap.
    var tilesScreen: Bool {
        switch self {
        case .maximize, .maximizeWithMargin, .center, .previousDisplay, .nextDisplay, .restore:
            false
        default:
            true
        }
    }
}

nonisolated enum WindowSnapGeometry {
    enum DockEdge: Equatable {
        case top, bottom, left, right
    }

    /// Accepted gap range in points. Applies between neighboring windows and
    /// against the screen edges.
    static let gapRange: ClosedRange<Double> = 0...40

    /// Fixed inset for Maximize with Margin, as a percentage of each axis.
    static let marginPercent: Double = 5

    /// How far a window may miss its target and still count as there.
    static let frameTolerance: CGFloat = 8

    /// Edge-detection slack, matching `WindowReservationService`.
    static let edgeTolerance: CGFloat = 2

    static func clampedGap(_ gap: Double) -> CGFloat {
        guard gap.isFinite else { return 0 }
        return CGFloat(min(max(gap, gapRange.lowerBound), gapRange.upperBound))
    }

    // MARK: - Dock strip

    /// Which edge of `visible` a dock frame is anchored to, or nil when it
    /// floats free of every edge. Same rule as `WindowReservationService`: a
    /// dock that touches an edge but does not span to the opposite one is on
    /// that edge. When a small dock touches two edges (a corner), the edge it
    /// intrudes into least wins, since that is its thin side.
    static func dockEdge(of dock: CGRect, in visible: CGRect) -> DockEdge? {
        guard !dock.isNull, !dock.isEmpty, dock.intersects(visible) else { return nil }
        let t = edgeTolerance
        var candidates: [(edge: DockEdge, intrusion: CGFloat)] = []
        if dock.minX <= visible.minX + t, dock.maxX < visible.maxX - t {
            candidates.append((.left, dock.maxX - visible.minX))
        }
        if dock.maxX >= visible.maxX - t, dock.minX > visible.minX + t {
            candidates.append((.right, visible.maxX - dock.minX))
        }
        if dock.minY <= visible.minY + t, dock.maxY < visible.maxY - t {
            candidates.append((.bottom, dock.maxY - visible.minY))
        }
        if dock.maxY >= visible.maxY - t, dock.minY > visible.minY + t {
            candidates.append((.top, visible.maxY - dock.minY))
        }
        return candidates.min { $0.intrusion < $1.intrusion }?.edge
    }

    /// The visible frame with the dock's strip taken off the edge it sits on,
    /// so a snapped window never lands under Wharf even when Resize Windows is
    /// off. A nil dock (hidden, or none on this screen) leaves it unchanged.
    static func subtractingDock(_ dock: CGRect?, from visible: CGRect) -> CGRect {
        guard let dock, let edge = dockEdge(of: dock, in: visible) else { return visible }
        var result = visible
        switch edge {
        case .left:
            let newMinX = min(max(visible.minX, dock.maxX), visible.maxX)
            result.origin.x = newMinX
            result.size.width = visible.maxX - newMinX
        case .right:
            let newMaxX = max(min(visible.maxX, dock.minX), visible.minX)
            result.size.width = newMaxX - visible.minX
        case .bottom:
            let newMinY = min(max(visible.minY, dock.maxY), visible.maxY)
            result.origin.y = newMinY
            result.size.height = visible.maxY - newMinY
        case .top:
            let newMaxY = max(min(visible.maxY, dock.minY), visible.minY)
            result.size.height = newMaxY - visible.minY
        }
        return result
    }

    // MARK: - Target rects

    /// Where `action` puts a window whose frame is `current`, on a screen whose
    /// usable area is `area` (already minus the dock strip). `gap` is applied
    /// to the screen edges and split between neighboring tiles, so two
    /// adjacent windows end up exactly `gap` apart. Restore and the display
    /// moves are not handled here and return `current`.
    static func targetRect(
        for action: WindowSnapAction,
        current: CGRect,
        area: CGRect,
        gap: CGFloat = 0
    ) -> CGRect {
        let frame: CGRect
        switch action {
        case .maximizeWithMargin, .center, .restore, .previousDisplay, .nextDisplay:
            frame = area
        default:
            frame = screenGapFrame(area, gap: gap)
        }
        let rect = ungappedRect(for: action, current: current, area: frame)
        guard action.tilesScreen else { return rect }
        return windowGapped(rect, in: frame, gap: gap)
    }

    /// `area` pulled in by the gap on every side. Keeps at least 80 points per
    /// axis so a large gap on a small display degrades instead of inverting.
    static func screenGapFrame(_ area: CGRect, gap: CGFloat) -> CGRect {
        guard gap > 0 else { return area }
        let dx = min(gap, max(0, (area.width - 80) / 2))
        let dy = min(gap, max(0, (area.height - 80) / 2))
        return area.insetBy(dx: dx, dy: dy)
    }

    /// Takes half the gap off every edge a tile shares with a neighbor. An
    /// edge is shared exactly when it does not lie on the (gapped) frame.
    private static func windowGapped(_ rect: CGRect, in frame: CGRect, gap: CGFloat) -> CGRect {
        guard gap > 0 else { return rect }
        let half = gap / 2
        var result = rect
        if result.minX - frame.minX > 1 {
            result.origin.x += half
            result.size.width -= half
        }
        if frame.maxX - result.maxX > 1 {
            result.size.width -= half
        }
        if result.minY - frame.minY > 1 {
            result.origin.y += half
            result.size.height -= half
        }
        if frame.maxY - result.maxY > 1 {
            result.size.height -= half
        }
        result.size.width = max(1, result.size.width)
        result.size.height = max(1, result.size.height)
        return roundedEdges(result)
    }

    /// Rounds each edge to the nearest point. Unlike `integral`, which grows a
    /// fractional rect outward, this keeps tiles that share an edge sharing it,
    /// so a third at 386.67 points does not overlap its neighbor by a point.
    static func roundedEdges(_ rect: CGRect) -> CGRect {
        let minX = rect.minX.rounded()
        let minY = rect.minY.rounded()
        let maxX = rect.maxX.rounded()
        let maxY = rect.maxY.rounded()
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    private static func ungappedRect(for action: WindowSnapAction, current: CGRect, area v: CGRect) -> CGRect {
        let halfW = v.width / 2
        let halfH = v.height / 2
        let thirdW = v.width / 3
        let thirdH = v.height / 3
        let quarterW = v.width / 4
        let quarterH = v.height / 4

        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            roundedEdges(CGRect(x: x, y: y, width: w, height: h))
        }

        switch action {
        case .leftHalf: return r(v.minX, v.minY, halfW, v.height)
        case .rightHalf: return r(v.midX, v.minY, halfW, v.height)
        case .topHalf: return r(v.minX, v.midY, v.width, halfH)
        case .bottomHalf: return r(v.minX, v.minY, v.width, halfH)
        case .centerHalf: return r(v.midX - halfW / 2, v.minY, halfW, v.height)

        case .leftThird: return r(v.minX, v.minY, thirdW, v.height)
        case .centerThird: return r(v.minX + thirdW, v.minY, thirdW, v.height)
        case .rightThird: return r(v.maxX - thirdW, v.minY, thirdW, v.height)
        case .leftTwoThirds: return r(v.minX, v.minY, thirdW * 2, v.height)
        case .centerTwoThirds: return r(v.midX - thirdW, v.minY, thirdW * 2, v.height)
        case .rightTwoThirds: return r(v.maxX - thirdW * 2, v.minY, thirdW * 2, v.height)
        case .topThird: return r(v.minX, v.maxY - thirdH, v.width, thirdH)
        case .middleThird: return r(v.minX, v.minY + thirdH, v.width, thirdH)
        case .bottomThird: return r(v.minX, v.minY, v.width, thirdH)
        case .topTwoThirds: return r(v.minX, v.maxY - thirdH * 2, v.width, thirdH * 2)
        case .middleTwoThirds: return r(v.minX, v.midY - thirdH, v.width, thirdH * 2)
        case .bottomTwoThirds: return r(v.minX, v.minY, v.width, thirdH * 2)

        case .leftQuarter: return r(v.minX, v.minY, quarterW, v.height)
        case .leftMiddleQuarter: return r(v.minX + quarterW, v.minY, quarterW, v.height)
        case .rightMiddleQuarter: return r(v.minX + quarterW * 2, v.minY, quarterW, v.height)
        case .rightQuarter: return r(v.maxX - quarterW, v.minY, quarterW, v.height)
        case .topQuarter: return r(v.minX, v.maxY - quarterH, v.width, quarterH)
        case .upperMiddleQuarter: return r(v.minX, v.minY + quarterH * 2, v.width, quarterH)
        case .lowerMiddleQuarter: return r(v.minX, v.minY + quarterH, v.width, quarterH)
        case .bottomQuarter: return r(v.minX, v.minY, v.width, quarterH)

        case .topLeftSixth: return r(v.minX, v.midY, thirdW, halfH)
        case .topCenterSixth: return r(v.minX + thirdW, v.midY, thirdW, halfH)
        case .topRightSixth: return r(v.maxX - thirdW, v.midY, thirdW, halfH)
        case .bottomLeftSixth: return r(v.minX, v.minY, thirdW, halfH)
        case .bottomCenterSixth: return r(v.minX + thirdW, v.minY, thirdW, halfH)
        case .bottomRightSixth: return r(v.maxX - thirdW, v.minY, thirdW, halfH)

        case .topLeft: return r(v.minX, v.midY, halfW, halfH)
        case .topRight: return r(v.midX, v.midY, halfW, halfH)
        case .bottomLeft: return r(v.minX, v.minY, halfW, halfH)
        case .bottomRight: return r(v.midX, v.minY, halfW, halfH)

        case .maximize:
            return roundedEdges(v)
        case .maximizeWithMargin:
            let fraction = CGFloat(marginPercent / 100)
            return roundedEdges(v.insetBy(dx: v.width * fraction, dy: v.height * fraction))
        case .center:
            let width = min(current.width, v.width)
            let height = min(current.height, v.height)
            return r(v.midX - width / 2, v.midY - height / 2, width, height)
        case .previousDisplay, .nextDisplay, .restore:
            return roundedEdges(current)
        }
    }

    /// Re-anchors a target when the app refused the size (a minimum or fixed
    /// size): keep the edge or center the action is about, at the size the
    /// window actually took, and keep it inside the usable area.
    static func anchoredRect(
        for action: WindowSnapAction,
        target: CGRect,
        actualSize: CGSize,
        area: CGRect
    ) -> CGRect {
        switch action {
        case .maximize, .restore, .previousDisplay, .nextDisplay:
            return roundedEdges(target)
        default:
            break
        }

        let size = CGSize(width: max(1, actualSize.width), height: max(1, actualSize.height))
        var origin = target.origin

        switch action {
        case .rightHalf, .rightThird, .rightTwoThirds, .rightMiddleQuarter, .rightQuarter, .bottomRightSixth, .bottomRight:
            origin.x = target.maxX - size.width
        case .centerHalf, .centerThird, .centerTwoThirds, .topCenterSixth, .bottomCenterSixth,
             .maximizeWithMargin, .center:
            origin.x = target.midX - size.width / 2
        case .topRightSixth, .topRight:
            origin.x = target.maxX - size.width
        default:
            origin.x = target.minX
        }

        switch action {
        case .topHalf, .topThird, .topTwoThirds, .topQuarter, .upperMiddleQuarter,
             .topLeftSixth, .topCenterSixth, .topRightSixth, .topLeft, .topRight:
            origin.y = target.maxY - size.height
        case .middleThird, .middleTwoThirds, .maximizeWithMargin, .center:
            origin.y = target.midY - size.height / 2
        default:
            origin.y = target.minY
        }

        return roundedEdges(clamp(CGRect(origin: origin, size: size), into: area))
    }

    /// Moves `rect` so it sits inside `area`, without resizing it. A rect wider
    /// or taller than the area is pinned to the area's left or top edge.
    static func clamp(_ rect: CGRect, into area: CGRect) -> CGRect {
        var origin = rect.origin
        if rect.width <= area.width {
            origin.x = min(max(origin.x, area.minX), area.maxX - rect.width)
        } else {
            origin.x = area.minX
        }
        if rect.height <= area.height {
            origin.y = min(max(origin.y, area.minY), area.maxY - rect.height)
        } else {
            origin.y = area.maxY - rect.height
        }
        return CGRect(origin: origin, size: rect.size)
    }

    /// True when the app took a size larger than asked for. Some apps keep an
    /// edge out from under a side dock and refuse a size that would put it
    /// there, so any excess counts; half a point absorbs rounding.
    /// (Vorssaint WindowMaximizerSupport.overshoots.)
    static func overshoots(_ actual: CGSize, target: CGSize) -> Bool {
        actual.width > target.width + 0.5 || actual.height > target.height + 0.5
    }

    // MARK: - Display moves

    /// Maps a window from one display's usable area to another's, keeping its
    /// relative position and size proportionally, then clamps it on screen. A
    /// window that fills the source fills the destination.
    static func rectForDisplay(current: CGRect, source: CGRect, destination: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0, destination.width > 0, destination.height > 0 else {
            return roundedEdges(current)
        }

        if current.width >= source.width - frameTolerance,
           current.height >= source.height - frameTolerance {
            return roundedEdges(destination)
        }

        let scaleX = destination.width / source.width
        let scaleY = destination.height / source.height
        let width = min(destination.width, max(1, current.width * scaleX))
        let height = min(destination.height, max(1, current.height * scaleY))
        let x = destination.minX + (current.minX - source.minX) * scaleX
        let y = destination.minY + (current.minY - source.minY) * scaleY
        return roundedEdges(clamp(CGRect(x: x, y: y, width: width, height: height), into: destination))
    }

    /// The next or previous display, ordered left to right then bottom to
    /// top, wrapping around. Nil with a single display.
    static func adjacentDisplayIndex(currentIndex: Int, frames: [CGRect], forward: Bool) -> Int? {
        guard frames.count > 1, frames.indices.contains(currentIndex) else { return nil }
        let ordered = frames.indices.sorted { lhsIndex, rhsIndex in
            let lhs = frames[lhsIndex]
            let rhs = frames[rhsIndex]
            if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
            if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
            return lhsIndex < rhsIndex
        }
        guard let position = ordered.firstIndex(of: currentIndex) else { return nil }
        let destination = (position + (forward ? 1 : ordered.count - 1)) % ordered.count
        return ordered[destination]
    }

    /// Index of the frame `rect` overlaps most, or nil when it overlaps none.
    static func indexOfLargestOverlap(_ rect: CGRect, in frames: [CGRect]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (index, frame) in frames.enumerated() {
            let overlap = frame.intersection(rect)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > 0, area > (best?.area ?? 0) {
                best = (index, area)
            }
        }
        return best?.index
    }

    /// Flips a rect between AX space (origin top-left of the primary display,
    /// Y grows down) and AppKit space. The transform is its own inverse.
    static func flipY(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func isClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }
}

// MARK: - Shortcut resolution

nonisolated enum WindowSnapShortcuts {
    /// What an action's shortcut resolves to: the stored one, the default when
    /// nothing is stored, or nil when the user cleared it (stored but invalid).
    static func resolved<S>(stored: S?, isCleared: (S) -> Bool, fallback: S?) -> S? {
        guard let stored else { return fallback }
        return isCleared(stored) ? nil : stored
    }

    enum Conflict<S>: Equatable where S: Equatable {
        case action(WindowSnapAction)
        case reserved(String)
    }

    /// The first thing `candidate` collides with: another snap action, or a
    /// named shortcut Wharf already owns. `excluding` is the action being
    /// edited, so re-recording its own shortcut is not a conflict.
    static func conflict<S: Equatable>(
        for candidate: S,
        excluding: WindowSnapAction?,
        assigned: [WindowSnapAction: S],
        reserved: [(name: String, shortcut: S)]
    ) -> Conflict<S>? {
        if let hit = reserved.first(where: { $0.shortcut == candidate }) {
            return .reserved(hit.name)
        }
        for action in WindowSnapAction.allCases where action != excluding {
            if assigned[action] == candidate { return .action(action) }
        }
        return nil
    }
}

// MARK: - Restore history

/// Pre-snap frames per window, newest last, so Restore walks back through
/// them. In memory for this session only and bounded per window.
/// (Adapted from Vorssaint WindowLayoutHistory.)
nonisolated struct WindowSnapHistory<Key: Hashable> {
    static var perWindowLimit: Int { 20 }

    private var framesByWindow: [Key: [CGRect]] = [:]

    init() {}

    var isEmpty: Bool { framesByWindow.isEmpty }

    mutating func record(_ frame: CGRect, for key: Key) {
        var frames = framesByWindow[key] ?? []
        if let last = frames.last, WindowSnapGeometry.isClose(last, frame, tolerance: 1) { return }
        frames.append(frame)
        if frames.count > Self.perWindowLimit {
            frames.removeFirst(frames.count - Self.perWindowLimit)
        }
        framesByWindow[key] = frames
    }

    /// The newest remembered frame that differs from `current`, removed from
    /// the history. Frames equal to `current` are dropped on the way, so a
    /// Restore never "restores" to where the window already is.
    mutating func popPrevious(for key: Key, current: CGRect) -> CGRect? {
        guard var frames = framesByWindow[key] else { return nil }
        defer {
            if frames.isEmpty {
                framesByWindow.removeValue(forKey: key)
            } else {
                framesByWindow[key] = frames
            }
        }
        while let previous = frames.popLast() {
            if !WindowSnapGeometry.isClose(previous, current, tolerance: 1) {
                return previous
            }
        }
        return nil
    }

    func count(for key: Key) -> Int {
        framesByWindow[key]?.count ?? 0
    }

    mutating func removeStale(keeping live: Set<Key>) {
        framesByWindow = framesByWindow.filter { live.contains($0.key) }
    }
}
