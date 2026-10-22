//
//  WindowSnapDragZones.swift
//  Wharf
//
//  Pure logic for the drag triggers of window snapping: which snap action a
//  pointer position means while a window is dragged to a screen edge, or
//  dragged with the snap modifiers held; how a drag is told apart from a
//  resize or a content drag; the dwell before a preview arms; and the
//  modifier set.
//
//  Adapted from Vorssaint (https://github.com/vorssaint/vorssaint-utils,
//  GPL-3.0-or-later, Copyright (C) 2026 Vorssaint), chiefly
//  WindowGestureSupport.swift (WindowEdgeSnapSupport.target, classify,
//  startsAtResizeHandle, systemTilingEnabled, WindowEdgeSnapPointerTrail).
//  Wharf is GPL-3.0 as well.
//
//  Foundation and CoreGraphics only, like WindowSnapGeometry.swift, so the
//  checks in Tests/WindowSnap run it without a window on screen
//  (scripts/test-snap-zones.sh). Rects and points are in AppKit screen space
//  (origin bottom-left, Y grows up) unless a function says otherwise.
//

import CoreGraphics
import Foundation

nonisolated enum WindowSnapDragZones {
    /// One display: its full frame and its visibleFrame (minus menu bar and
    /// system Dock).
    struct Screen: Equatable {
        let frame: CGRect
        let visibleFrame: CGRect
    }

    /// The action an edge drag would apply, and on which display.
    struct EdgeHit: Equatable {
        let action: WindowSnapAction
        let screenIndex: Int
    }

    /// One region of the modifier-drag overlay and the action it stands for.
    struct ModifierZone: Equatable {
        let action: WindowSnapAction
        let rect: CGRect
    }

    enum DragClassification: Equatable {
        /// The window has not moved yet; keep watching.
        case waiting
        /// The window follows the pointer: a real title bar drag.
        case moving
        /// The window changes size with an edge anchored: a native resize.
        case resizing
        /// The window moved, but not with the pointer.
        case unrelated
    }

    /// Accepted edge hit zone in points, and its default.
    static let hitZoneRange: ClosedRange<Double> = 2...40
    static let defaultHitZone: Double = 12

    /// Accepted dwell in seconds before an edge preview arms, and its default.
    static let dwellRange: ClosedRange<Double> = 0...1
    static let defaultDwell: Double = 0.15

    /// Points per second across a seam two displays share, above which the
    /// pointer is passing to the next display rather than aiming at the edge.
    static let crossingSpeed: CGFloat = 400

    /// How far the pointer must travel before a press counts as a drag.
    static let dragSlop: CGFloat = 6

    /// How far the pointer may travel with the window standing still before
    /// the drag is written off as a content drag (selecting text, say).
    static let giveUpDistance: CGFloat = 80

    private static let movementThreshold: CGFloat = 2
    private static let sizeTolerance: CGFloat = 2
    private static let resizeCornerDistance: CGFloat = 12
    private static let resizeEdgeDistance: CGFloat = 5

    static func clampedHitZone(_ value: Double) -> CGFloat {
        guard value.isFinite else { return CGFloat(defaultHitZone) }
        return CGFloat(min(max(value, hitZoneRange.lowerBound), hitZoneRange.upperBound))
    }

    static func clampedDwell(_ value: Double) -> TimeInterval {
        guard value.isFinite else { return defaultDwell }
        return min(max(value, dwellRange.lowerBound), dwellRange.upperBound)
    }

    // MARK: - Edge drag

    /// How far a corner reaches along a horizontal edge.
    static func horizontalCornerLength(for frame: CGRect) -> CGFloat {
        min(max(frame.width * 0.18, 96), 180)
    }

    /// How far a corner reaches along a vertical edge.
    static func verticalCornerLength(for frame: CGRect) -> CGFloat {
        min(max(frame.height * 0.18, 80), 160)
    }

    static func action(for edge: Edge) -> WindowSnapAction {
        switch edge {
        case .left: .leftHalf
        case .right: .rightHalf
        case .top: .maximize
        case .bottom: .bottomHalf
        case .topLeft: .topLeft
        case .topRight: .topRight
        case .bottomLeft: .bottomLeft
        case .bottomRight: .bottomRight
        }
    }

    enum Edge: Equatable {
        case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
    }

    /// The edge or corner under `point`, or nil when it is in no hit zone.
    ///
    /// The top edge starts at the bottom of the menu bar, so the whole menu
    /// bar counts. An edge with no display beyond it stops the pointer and
    /// counts at any speed. A seam two displays share counts only while the
    /// pointer moves slowly across it, the way macOS tiling tells aiming from
    /// passing; speed along an edge never counts.
    static func edgeHit(
        at point: CGPoint,
        screens: [Screen],
        velocity: CGVector = .zero,
        hitZone: CGFloat
    ) -> EdgeHit? {
        guard let index = screenIndex(for: point, in: screens.map(\.frame), slack: hitZone) else { return nil }
        let screen = screens[index]
        let frame = screen.frame
        guard frame.width > 0, frame.height > 0 else { return nil }

        let frames = screens.map(\.frame)
        let isSeam = { (probe: CGPoint) in frames.enumerated().contains { $0.offset != index && $0.element.contains(probe) } }
        let settledAcross = abs(velocity.dx) <= crossingSpeed
        let settledUpDown = abs(velocity.dy) <= crossingSpeed

        let nearLeft = abs(point.x - frame.minX) <= hitZone
            && (settledAcross || !isSeam(CGPoint(x: frame.minX - 0.5, y: point.y)))
        let nearRight = abs(point.x - frame.maxX) <= hitZone
            && (settledAcross || !isSeam(CGPoint(x: frame.maxX + 0.5, y: point.y)))
        let visibleTop = min(max(screen.visibleFrame.maxY, frame.minY), frame.maxY)
        let nearTop = point.y >= visibleTop - hitZone && point.y <= frame.maxY + hitZone
            && (settledUpDown || !isSeam(CGPoint(x: point.x, y: frame.maxY + 0.5)))
        let nearBottom = abs(point.y - frame.minY) <= hitZone
            && (settledUpDown || !isSeam(CGPoint(x: point.x, y: frame.minY - 0.5)))

        let horizontalCorner = horizontalCornerLength(for: frame)
        let verticalCorner = verticalCornerLength(for: frame)
        let edge: Edge
        if nearTop {
            if point.x <= frame.minX + horizontalCorner {
                edge = .topLeft
            } else if point.x >= frame.maxX - horizontalCorner {
                edge = .topRight
            } else {
                edge = .top
            }
        } else if nearBottom {
            if point.x <= frame.minX + horizontalCorner {
                edge = .bottomLeft
            } else if point.x >= frame.maxX - horizontalCorner {
                edge = .bottomRight
            } else {
                edge = .bottom
            }
        } else if nearLeft {
            if point.y >= frame.maxY - verticalCorner {
                edge = .topLeft
            } else if point.y <= frame.minY + verticalCorner {
                edge = .bottomLeft
            } else {
                edge = .left
            }
        } else if nearRight {
            if point.y >= frame.maxY - verticalCorner {
                edge = .topRight
            } else if point.y <= frame.minY + verticalCorner {
                edge = .bottomRight
            } else {
                edge = .right
            }
        } else {
            return nil
        }
        return EdgeHit(action: action(for: edge), screenIndex: index)
    }

    /// The display a point belongs to: the nearest frame within `slack`. On a
    /// seam, where two frames are both at distance zero, the one that holds
    /// the point (half-open, so a seam belongs to the display on its right
    /// or above it) wins, then the earlier index.
    static func screenIndex(for point: CGPoint, in frames: [CGRect], slack: CGFloat = 0) -> Int? {
        var best: (index: Int, distance: CGFloat, holds: Bool)?
        for (index, frame) in frames.enumerated() where frame.width > 0 && frame.height > 0 {
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            let distance = hypot(dx, dy)
            guard distance <= slack else { continue }
            let holds = frame.contains(point)
            if let current = best {
                if distance < current.distance || (distance == current.distance && holds && !current.holds) {
                    best = (index, distance, holds)
                }
            } else {
                best = (index, distance, holds)
            }
        }
        return best?.index
    }

    // MARK: - Modifier drag

    /// Column boundaries of the modifier overlay, as fractions of the width.
    static let modifierColumns: [CGFloat] = [0, 0.2, 0.4, 0.6, 0.8, 1]
    /// Row boundaries, as fractions of the height from the bottom.
    static let modifierRows: [CGFloat] = [0, 0.25, 0.75, 1]

    /// The regions of the modifier-drag overlay over `area`, in drawing
    /// order. The middle band holds left half, left third, center third,
    /// right third and right half; the top and bottom bands hold the corner
    /// quarters at their ends and the top or bottom half between them.
    static func modifierZones(in area: CGRect) -> [ModifierZone] {
        func span(_ fractions: [CGFloat], _ from: Int, _ to: Int, _ origin: CGFloat, _ length: CGFloat) -> (CGFloat, CGFloat) {
            let start = (origin + fractions[from] * length).rounded()
            let end = (origin + fractions[to] * length).rounded()
            return (start, end - start)
        }
        func rect(columns: (Int, Int), row: Int) -> CGRect {
            let x = span(modifierColumns, columns.0, columns.1, area.minX, area.width)
            let y = span(modifierRows, row, row + 1, area.minY, area.height)
            return CGRect(x: x.0, y: y.0, width: x.1, height: y.1)
        }
        return [
            ModifierZone(action: .topLeft, rect: rect(columns: (0, 1), row: 2)),
            ModifierZone(action: .topHalf, rect: rect(columns: (1, 4), row: 2)),
            ModifierZone(action: .topRight, rect: rect(columns: (4, 5), row: 2)),
            ModifierZone(action: .leftHalf, rect: rect(columns: (0, 1), row: 1)),
            ModifierZone(action: .leftThird, rect: rect(columns: (1, 2), row: 1)),
            ModifierZone(action: .centerThird, rect: rect(columns: (2, 3), row: 1)),
            ModifierZone(action: .rightThird, rect: rect(columns: (3, 4), row: 1)),
            ModifierZone(action: .rightHalf, rect: rect(columns: (4, 5), row: 1)),
            ModifierZone(action: .bottomLeft, rect: rect(columns: (0, 1), row: 0)),
            ModifierZone(action: .bottomHalf, rect: rect(columns: (1, 4), row: 0)),
            ModifierZone(action: .bottomRight, rect: rect(columns: (4, 5), row: 0)),
        ]
    }

    /// The modifier-drag action for a pointer over `area`. A pointer outside
    /// the area (over the menu bar or the dock strip) takes the nearest zone.
    static func modifierAction(at point: CGPoint, in area: CGRect) -> WindowSnapAction? {
        guard area.width > 0, area.height > 0 else { return nil }
        let fx = min(max((point.x - area.minX) / area.width, 0), 1)
        let fy = min(max((point.y - area.minY) / area.height, 0), 1)
        let column = band(fx, in: modifierColumns)
        let row = band(fy, in: modifierRows)
        switch (row, column) {
        case (2, 0): return .topLeft
        case (2, 4): return .topRight
        case (2, _): return .topHalf
        case (0, 0): return .bottomLeft
        case (0, 4): return .bottomRight
        case (0, _): return .bottomHalf
        case (_, 0): return .leftHalf
        case (_, 1): return .leftThird
        case (_, 2): return .centerThird
        case (_, 3): return .rightThird
        default: return .rightHalf
        }
    }

    /// Index of the band `fraction` falls in; the last boundary belongs to the
    /// last band.
    private static func band(_ fraction: CGFloat, in boundaries: [CGFloat]) -> Int {
        for index in 1..<boundaries.count where fraction < boundaries[index] {
            return index - 1
        }
        return boundaries.count - 2
    }

    // MARK: - Telling a window drag apart

    /// True when a press at `point` lands on the resize border or a resize
    /// corner of `frame`, so the drag that follows is a resize. Any space,
    /// as long as both arguments share it.
    static func startsAtResizeHandle(_ point: CGPoint, frame: CGRect) -> Bool {
        guard point.x >= frame.minX - resizeCornerDistance,
              point.x <= frame.maxX + resizeCornerDistance,
              point.y >= frame.minY - resizeCornerDistance,
              point.y <= frame.maxY + resizeCornerDistance else { return false }
        let nearVerticalCorner = abs(point.x - frame.minX) <= resizeCornerDistance
            || abs(point.x - frame.maxX) <= resizeCornerDistance
        let nearHorizontalCorner = abs(point.y - frame.minY) <= resizeCornerDistance
            || abs(point.y - frame.maxY) <= resizeCornerDistance
        let nearEdge = abs(point.x - frame.minX) <= resizeEdgeDistance
            || abs(point.x - frame.maxX) <= resizeEdgeDistance
            || abs(point.y - frame.minY) <= resizeEdgeDistance
            || abs(point.y - frame.maxY) <= resizeEdgeDistance
        return nearEdge || (nearVerticalCorner && nearHorizontalCorner)
    }

    /// A pointer drag is a window move only once the window follows it.
    /// Content drags leave the frame still, and a native resize keeps two
    /// edges anchored. A snapped window that restores its old size as it
    /// starts moving still counts as a move. Any space, as long as all four
    /// arguments share it.
    static func classify(
        initialFrame: CGRect,
        currentFrame: CGRect,
        pointerStart: CGPoint,
        pointerNow: CGPoint
    ) -> DragClassification {
        let sizeChanged = abs(currentFrame.width - initialFrame.width) > sizeTolerance
            || abs(currentFrame.height - initialFrame.height) > sizeTolerance
        if sizeChanged, sharesPerpendicularEdges(initialFrame, currentFrame) {
            return .resizing
        }

        let windowDelta = CGPoint(x: currentFrame.minX - initialFrame.minX, y: currentFrame.minY - initialFrame.minY)
        let pointerDelta = CGPoint(x: pointerNow.x - pointerStart.x, y: pointerNow.y - pointerStart.y)
        let windowDistance = hypot(windowDelta.x, windowDelta.y)
        guard windowDistance > movementThreshold else { return .waiting }

        let pointerDistance = hypot(pointerDelta.x, pointerDelta.y)
        guard pointerDistance > movementThreshold else { return .unrelated }
        let alignment = (windowDelta.x * pointerDelta.x + windowDelta.y * pointerDelta.y)
            / (windowDistance * pointerDistance)
        let ratio = windowDistance / pointerDistance
        return alignment >= 0.6 && ratio >= 0.2 && ratio <= 1.8 ? .moving : .unrelated
    }

    private static func sharesPerpendicularEdges(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let sharesVerticalEdge = abs(lhs.minX - rhs.minX) <= sizeTolerance
            || abs(lhs.maxX - rhs.maxX) <= sizeTolerance
        let sharesHorizontalEdge = abs(lhs.minY - rhs.minY) <= sizeTolerance
            || abs(lhs.maxY - rhs.maxY) <= sizeTolerance
        return sharesVerticalEdge && sharesHorizontalEdge
    }

    // MARK: - macOS tiling

    /// Whether macOS's own edge tiling is on. Its switches read as on while
    /// their preference was never written. With Separate Spaces off they are
    /// grayed out and inert, so they do not count then.
    static func systemTilingEnabled(valueFor: (String) -> Bool?, displaysSpan: Bool) -> Bool {
        if displaysSpan { return false }
        return systemTilingKeys.contains { valueFor($0) ?? true }
    }

    static let systemTilingKeys = [
        "EnableTilingByEdgeDrag",
        "EnableTilingOptionAccelerator",
        "EnableTopTilingByEdgeDrag",
    ]
}

// MARK: - Dwell

/// Arms a candidate only after it has stayed the same for the dwell time, so
/// a window swept past an edge does not flash a preview.
nonisolated struct WindowSnapDragDwell<Value: Equatable> {
    private(set) var candidate: Value?
    private var since: TimeInterval = 0

    init() {}

    /// Feeds the current candidate; returns it once it has held for `dwell`.
    mutating func update(_ value: Value?, at now: TimeInterval, dwell: TimeInterval) -> Value? {
        if value != candidate {
            candidate = value
            since = now
        }
        return armed(at: now, dwell: dwell)
    }

    func armed(at now: TimeInterval, dwell: TimeInterval) -> Value? {
        guard let candidate, now - since >= dwell else { return nil }
        return candidate
    }

    /// Seconds left until the current candidate arms, or nil when there is
    /// none or it already has.
    func remaining(at now: TimeInterval, dwell: TimeInterval) -> TimeInterval? {
        guard candidate != nil else { return nil }
        let left = dwell - (now - since)
        return left > 0 ? left : nil
    }

    mutating func reset() {
        candidate = nil
        since = 0
    }
}

// MARK: - Pointer speed

/// The pointer's recent path, kept just long enough to tell how fast it is
/// moving across a seam. Speed is read over a short span rather than between
/// two events, since events can arrive a millisecond apart.
/// (Adapted from Vorssaint WindowEdgeSnapPointerTrail.)
nonisolated struct WindowSnapDragPointerTrail {
    static let span: TimeInterval = 0.05
    static let minimumSpan: TimeInterval = 0.02
    static let stillAfter: TimeInterval = 0.1
    static let capacity = 512

    private var samples: [(time: TimeInterval, point: CGPoint)] = []

    init() {}

    mutating func append(_ point: CGPoint, at time: TimeInterval) {
        if let last = samples.last {
            if time < last.time {
                samples.removeAll()
            } else if time - last.time >= Self.stillAfter {
                // After a pause the path restarts from where the pointer
                // rested, so a flick out of a stop reads fast.
                samples = [(time - Self.minimumSpan, last.point)]
            }
        }
        samples.append((time, point))
        while samples.count > 2, time - samples[1].time >= Self.span {
            samples.removeFirst()
        }
        if samples.count > Self.capacity {
            samples.removeFirst(samples.count - Self.capacity)
        }
    }

    mutating func reset() {
        samples.removeAll()
    }

    /// Points per second, in the space the points were given in.
    func velocity(at now: TimeInterval) -> CGVector {
        guard samples.count > 1, let last = samples.last, let first = samples.first,
              now - last.time < Self.stillAfter else { return .zero }
        let elapsed = max(last.time - first.time, Self.minimumSpan)
        return CGVector(dx: (last.point.x - first.point.x) / elapsed, dy: (last.point.y - first.point.y) / elapsed)
    }
}

// MARK: - Modifier set

/// The modifiers that turn a window drag into a modifier drag. Raw values
/// match the device-independent bits of `NSEvent.ModifierFlags` and
/// `CGEventFlags`, so an event's flags convert with `init(eventFlags:)`.
nonisolated struct WindowSnapDragModifiers: OptionSet, Equatable {
    let rawValue: UInt

    init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    static let shift = WindowSnapDragModifiers(rawValue: 1 << 17)
    static let control = WindowSnapDragModifiers(rawValue: 1 << 18)
    static let option = WindowSnapDragModifiers(rawValue: 1 << 19)
    static let command = WindowSnapDragModifiers(rawValue: 1 << 20)

    static let all: WindowSnapDragModifiers = [.shift, .control, .option, .command]
    static let defaultValue: WindowSnapDragModifiers = [.control, .option]

    /// Keeps only the four modifier bits of an event's flags.
    init(eventFlags: UInt) {
        self.init(rawValue: eventFlags & Self.all.rawValue)
    }

    /// A stored value, or the default when it holds no usable set.
    init(storedValue: Int?) {
        let value = WindowSnapDragModifiers(eventFlags: UInt(truncatingIfNeeded: max(storedValue ?? 0, 0)))
        self = value.isUsable ? value : .defaultValue
    }

    /// Usable when it has Control, Option or Command. Shift alone would fire
    /// on every Shift drag, such as extending a selection.
    var isUsable: Bool {
        !intersection([.control, .option, .command]).isEmpty
    }

    /// Exactly these modifiers are down, no more and no fewer.
    func matches(eventFlags: UInt) -> Bool {
        isUsable && WindowSnapDragModifiers(eventFlags: eventFlags) == self
    }

    /// Symbols in the order macOS menus use.
    var displayString: String {
        var result = ""
        if contains(.control) { result += "\u{2303}" }
        if contains(.option) { result += "\u{2325}" }
        if contains(.shift) { result += "\u{21E7}" }
        if contains(.command) { result += "\u{2318}" }
        return result
    }
}
