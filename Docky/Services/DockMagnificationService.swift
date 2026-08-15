//
//  DockMagnificationService.swift
//  Docky
//
//  Drives the live "scale icons under the cursor" effect. Pointer state is
//  pushed from a SwiftUI `.onContinuousHover` on the tile container; the
//  enter/exit ramp is interpolated here so neither the cursor stream nor
//  the magnification factor ever pop.
//

import Combine
import CoreGraphics
import Foundation
import Observation
import QuartzCore

@Observable
final class DockMagnificationService {
    static let shared = DockMagnificationService()

    /// Animated factor in [0, 1]. Multiplied into the per-icon falloff so the
    /// effect ramps in/out without a jarring snap when the cursor crosses
    /// the dock boundary.
    private(set) var strength: CGFloat = 0

    /// Pointer location in the tile container's local coordinate space, or
    /// nil when the pointer is outside the magnification region.
    private(set) var pointerLocation: CGPoint? = nil

    /// Maps the cosine half-bell so that t=0 → 1 and t=1 → 0.
    /// Apple Dock's curve has been studied this way; not a perfect match
    /// but visually very close.
    private static let rampDuration: CFTimeInterval = 0.15

    @ObservationIgnored private var rampSource: CGFloat = 0
    @ObservationIgnored private var rampTarget: CGFloat = 0
    @ObservationIgnored private var rampStart: CFTimeInterval = 0
    @ObservationIgnored private var rampTimer: Timer?

    init() {}

    /// Pointer has entered the dock hit region and we now have a live axis
    /// coordinate to track. Called from `.onContinuousHover` with
    /// `.active(location)`.
    func updatePointer(at location: CGPoint) {
        // Sub-pixel pointer jitter would publish identical-looking values
        // and re-render the dock for nothing. Round-trip suppression keeps
        // mouseMoved spam from spiking CPU.
        if let current = pointerLocation,
           abs(current.x - location.x) < 0.25,
           abs(current.y - location.y) < 0.25 {
            // Skip publishing, but still nudge the ramp in case strength
            // was driving back toward zero.
        } else {
            pointerLocation = location
        }
        beginRamp(to: 1)
    }

    /// Pointer has left the dock hit region. We keep the last known
    /// location so the cosine falloff has an anchor to shrink against
    /// during the ramp-down; once strength reaches zero the location is
    /// cleared by `tick()`.
    func clearPointer() {
        beginRamp(to: 0)
    }

    private func beginRamp(to target: CGFloat) {
        // Already heading to (or sitting at) this target: no-op.
        // Previously this restarted the timer on every mouseMoved once
        // the initial ramp had finished, which kept it firing at 120Hz
        // for the lifetime of the hover and pegged CPU.
        if rampTarget == target { return }
        rampSource = strength
        rampTarget = target
        rampStart = CACurrentMediaTime()
        startTimerIfNeeded()
    }

    private func startTimerIfNeeded() {
        guard rampTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        rampTimer = timer
    }

    private func tick() {
        let elapsed = CACurrentMediaTime() - rampStart
        let t = min(1, max(0, elapsed / Self.rampDuration))
        let eased = 1 - pow(1 - t, 2)
        let next = rampSource + (rampTarget - rampSource) * CGFloat(eased)
        if abs(next - strength) > 0.0001 {
            strength = next
        }
        guard t >= 1 else { return }
        if abs(strength - rampTarget) > 0.0001 {
            strength = rampTarget
        }
        if rampTarget == 0 {
            pointerLocation = nil
        }
        rampTimer?.invalidate()
        rampTimer = nil
    }
}

/// Stateless 1D magnification math. Lives outside the service so callers can
/// plug in their own base/max/radius for a given layout pass without
/// threading those through publishers.
struct DockMagnificationModel {
    /// Resting tile extent along the dock axis.
    var baseSize: CGFloat
    /// Peak tile extent at the cursor.
    var maxSize: CGFloat
    /// Radius (along the dock axis) over which the falloff is non-zero.
    /// Typically ~2.5 × baseSize.
    var influenceRadius: CGFloat
    /// Global 0…1 ramp from `DockMagnificationService`.
    var strength: CGFloat
    /// Cursor position along the dock axis, in the same coordinate space as
    /// `restAxisCenter`. Nil disables magnification.
    var cursorAxisLocation: CGFloat?

    /// Magnified along-axis extent for a tile whose rest center is at
    /// `restAxisCenter`. Falls back to `restSize` when magnification is off.
    func magnifiedExtent(restSize: CGFloat, restAxisCenter: CGFloat) -> CGFloat {
        guard strength > 0,
              maxSize > restSize,
              let cursor = cursorAxisLocation,
              influenceRadius > 0 else {
            return restSize
        }
        let distance = abs(cursor - restAxisCenter)
        let t = min(1, distance / influenceRadius)
        let falloff = 0.5 * (1 + cos(.pi * t)) * strength
        return restSize + (maxSize - restSize) * falloff
    }
}
