//
//  WindowSnappingSettingsView.swift
//  Wharf
//
//  Settings for window snapping: the on switch, the gap, and a recordable
//  global shortcut for every snap action. See WindowSnapService.
//

import SwiftUI

struct WindowSnappingSettingsView: View {
    @Bindable private var preferences = DockyPreferences.shared
    @ObservedObject private var permissions = PermissionsService.shared
    private let service = WindowSnapService.shared

    @State private var recordingAction: WindowSnapAction?
    @State private var conflictAction: WindowSnapAction?
    @State private var conflictMessage = ""
    @State private var isShowingResetConfirmation = false

    var body: some View {
        Form {
            Section("Window Snapping") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Enable Window Snapping", isOn: $preferences.windowSnapEnabled)
                        .font(.headline)

                    Text("Move the frontmost window into halves, thirds, quarters, sixths or corners, maximize it, center it, or send it to another display, all from the keyboard. Snapped windows stop at the edge of Wharf's dock, even when Resize Windows is off. Requires Accessibility permission.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if preferences.windowSnapEnabled, permissions.accessibility != .granted {
                        HStack {
                            Text("Accessibility is not granted, so Window Snapping is doing nothing.")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Reset Permission") {
                                Task { await PermissionsService.shared.resetPermission(for: .accessibility) }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Gap")
                            .font(.headline)
                        Spacer()
                        Text("\(Int(preferences.windowSnapGap)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: $preferences.windowSnapGap,
                        in: WindowSnapGeometry.gapRange,
                        step: 1
                    )

                    Text("Space left between snapped windows and between a window and the screen edge.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                .disabled(!preferences.windowSnapEnabled)
            }

            WindowSnapDragSettingsSection()

            ForEach(WindowSnapAction.Group.allCases) { group in
                Section(group.title) {
                    ForEach(group.actions) { action in
                        shortcutRow(for: action)
                    }
                }
                .disabled(!preferences.windowSnapEnabled)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset Window Snapping") {
                        isShowingResetConfirmation = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: recordingAction) { newValue in
            service.isRecordingShortcut = newValue != nil
        }
        .onDisappear {
            service.isRecordingShortcut = false
        }
        .alert("Reset Window Snapping?", isPresented: $isShowingResetConfirmation) {
            Button("Reset", role: .destructive) {
                preferences.resetWindowSnappingToDefaults()
                conflictAction = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Turns snapping on, sets the gap to 0, puts every shortcut back to its default and turns the drag triggers off.")
        }
    }

    @ViewBuilder
    private func shortcutRow(for action: WindowSnapAction) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: action.symbolName)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                Text(action.title)
                Spacer()

                ShortcutRecorderControl(
                    shortcut: preferences.windowSnapShortcut(for: action) ?? .empty,
                    isRecording: recordingBinding(for: action),
                    resetShortcut: action.defaultShortcut
                ) { shortcut in
                    record(shortcut, for: action)
                }

                if action.defaultShortcut != nil {
                    Button("Clear") {
                        record(.empty, for: action)
                    }
                    .buttonStyle(.bordered)
                    .disabled(preferences.windowSnapShortcut(for: action) == nil)
                }
            }

            if conflictAction == action {
                Text(conflictMessage)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if service.unavailableActions.contains(action) {
                Text("Another app already uses this shortcut, so it does nothing. Record a different one.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func recordingBinding(for action: WindowSnapAction) -> Binding<Bool> {
        Binding(
            get: { recordingAction == action },
            set: { recordingAction = $0 ? action : (recordingAction == action ? nil : recordingAction) }
        )
    }

    /// Refuses a shortcut that collides with another snap action or one Wharf
    /// already owns, and says why, instead of saving a key that cannot work.
    private func record(_ shortcut: KeyboardShortcut, for action: WindowSnapAction) {
        if let message = service.conflictMessage(for: shortcut, action: action) {
            conflictAction = action
            conflictMessage = message
            return
        }
        if conflictAction == action {
            conflictAction = nil
        }
        preferences.setWindowSnapShortcut(shortcut, for: action)
    }
}
