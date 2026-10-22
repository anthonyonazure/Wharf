//
//  WindowSnapDragOverlay.swift
//  Wharf
//
//  The translucent preview shown while a window is dragged to snap: the rect
//  the window will take on release, and for a modifier drag the zone map of
//  the display under the pointer. A click-through panel that covers one
//  display; it never takes focus or a mouse event. See WindowSnapDragService.
//

import AppKit

final class WindowSnapDragOverlay {
    private var panel: NSPanel?
    private let canvas = WindowSnapDragOverlayView()

    /// Shows `target` on the display whose frame is `screenFrame`. Pass the
    /// modifier zones to draw the zone map too, with `highlighted` lit.
    /// Every rect is in AppKit screen space.
    func show(
        screenFrame: CGRect,
        target: CGRect,
        zones: [WindowSnapDragZones.ModifierZone] = [],
        highlighted: WindowSnapAction? = nil
    ) {
        let panel = panel ?? makePanel()
        self.panel = panel
        if panel.frame != screenFrame {
            panel.setFrame(screenFrame, display: false)
        }
        let origin = screenFrame.origin
        canvas.target = target.offsetBy(dx: -origin.x, dy: -origin.y)
        canvas.zones = zones.map {
            WindowSnapDragZones.ModifierZone(action: $0.action, rect: $0.rect.offsetBy(dx: -origin.x, dy: -origin.y))
        }
        canvas.highlighted = highlighted
        canvas.needsDisplay = true
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = canvas
        return panel
    }
}

private final class WindowSnapDragOverlayView: NSView {
    var target: CGRect = .zero
    var zones: [WindowSnapDragZones.ModifierZone] = []
    var highlighted: WindowSnapAction?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor

        if !zones.isEmpty {
            let labelAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9),
                .shadow: {
                    let shadow = NSShadow()
                    shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
                    shadow.shadowBlurRadius = 3
                    return shadow
                }(),
            ]
            for zone in zones {
                let rect = zone.rect.insetBy(dx: 3, dy: 3)
                let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
                let isLit = zone.action == highlighted
                (isLit ? accent.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.12)).setFill()
                path.fill()
                (isLit ? accent.withAlphaComponent(0.7) : NSColor.white.withAlphaComponent(0.35)).setStroke()
                path.lineWidth = isLit ? 2 : 1
                path.stroke()

                let label = zone.action.title as NSString
                let size = label.size(withAttributes: labelAttributes)
                if size.width < rect.width - 8, size.height < rect.height - 8 {
                    label.draw(
                        at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                        withAttributes: labelAttributes
                    )
                }
            }
        }

        guard target.width > 0, target.height > 0 else { return }
        let preview = NSBezierPath(roundedRect: target.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10)
        accent.withAlphaComponent(0.22).setFill()
        preview.fill()
        accent.withAlphaComponent(0.85).setStroke()
        preview.lineWidth = 2
        preview.stroke()
    }
}
