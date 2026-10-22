//
//  WindowSnapDragSettingsSection.swift
//  Wharf
//
//  The Drag Triggers section of the Window Snapping pane: snap by dragging a
//  window to a screen edge, or by dragging it with modifier keys held. See
//  WindowSnapDragService.
//

import AppKit
import SwiftUI

struct WindowSnapDragSettingsSection: View {
    @Bindable private var preferences = DockyPreferences.shared
    @ObservedObject private var permissions = PermissionsService.shared
    @State private var systemTilingEnabled = WindowSnapDragService.isSystemTilingEnabled

    var body: some View {
        Section("Drag Triggers") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Snap by Dragging to a Screen Edge", isOn: $preferences.windowSnapEdgeDragEnabled)
                    .font(.headline)

                Text("Drag a window by its title bar to the left or right edge for a half, the top edge to maximize, the bottom edge for the bottom half, or a corner for a quarter. A preview shows where it will go; let go to snap, or press Escape to cancel.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if preferences.windowSnapEdgeDragEnabled, systemTilingEnabled {
                    HStack {
                        Text("macOS window tiling is also on and will act on the same drags. Turn off its edge dragging in Desktop & Dock.")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Open Desktop & Dock") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Edge Hit Zone")
                        .font(.headline)
                    Spacer()
                    Text("\(Int(preferences.windowSnapDragHitZone)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $preferences.windowSnapDragHitZone, in: WindowSnapDragZones.hitZoneRange, step: 1)
                Text("How close to an edge the pointer must come.")
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Delay Before Preview")
                        .font(.headline)
                    Spacer()
                    Text(String(format: "%.2f s", preferences.windowSnapDragDwell))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $preferences.windowSnapDragDwell, in: WindowSnapDragZones.dwellRange, step: 0.05)
                Text("How long the pointer rests at an edge before the preview shows, so a window swept past an edge does not snap.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .disabled(!preferences.windowSnapEdgeDragEnabled)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Snap by Dragging with Modifier Keys", isOn: $preferences.windowSnapModifierDragEnabled)
                    .font(.headline)

                Text("Hold \(preferences.windowSnapDragModifiers.displayString) while dragging a window anywhere to show a map of zones on that display: halves at the sides, thirds in the middle, quarters in the corners, top and bottom halves along the top and bottom. Let go over a zone to snap. You can press the keys after the drag has started.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Modifier Keys")
                    Spacer()
                    WindowSnapDragModifierRecorder(modifiers: $preferences.windowSnapDragModifiers)
                    Button("Reset") {
                        preferences.windowSnapDragModifiers = .defaultValue
                    }
                    .buttonStyle(.bordered)
                    .disabled(preferences.windowSnapDragModifiers == .defaultValue)
                }
                .disabled(!preferences.windowSnapModifierDragEnabled)
            }
            .padding(.vertical, 4)

            if preferences.windowSnapEdgeDragEnabled || preferences.windowSnapModifierDragEnabled,
               permissions.accessibility != .granted {
                HStack {
                    Text("Accessibility is not granted, so drag snapping is doing nothing.")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Reset Permission") {
                        Task { await PermissionsService.shared.resetPermission(for: .accessibility) }
                    }
                }
            }
        }
        .disabled(!preferences.windowSnapEnabled)
        .onAppear {
            systemTilingEnabled = WindowSnapDragService.isSystemTilingEnabled
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            systemTilingEnabled = WindowSnapDragService.isSystemTilingEnabled
        }
    }
}

/// Records a modifier set: click, hold the keys, let go. The largest set held
/// at once is kept. Escape cancels; Shift alone is refused.
private struct WindowSnapDragModifierRecorder: View {
    @Binding var modifiers: WindowSnapDragModifiers
    @State private var isRecording = false
    @State private var peak: WindowSnapDragModifiers = []
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stop() : start()
        } label: {
            Text(label)
                .monospaced()
                .frame(minWidth: 120)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .accentColor : nil)
        .onDisappear(perform: stop)
    }

    private var label: String {
        guard isRecording else { return modifiers.displayString }
        return peak.isEmpty ? "Hold keys" : peak.displayString
    }

    private func start() {
        peak = []
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            if event.type == .keyDown {
                if event.keyCode == 53 { stop() }
                return nil
            }
            let held = WindowSnapDragModifiers(eventFlags: event.modifierFlags.rawValue)
            if held.isEmpty {
                if peak.isUsable { modifiers = peak }
                stop()
            } else {
                peak.formUnion(held)
            }
            return event
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
        peak = []
    }
}
