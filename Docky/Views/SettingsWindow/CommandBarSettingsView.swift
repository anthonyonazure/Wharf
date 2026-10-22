//
//  CommandBarSettingsView.swift
//  Wharf
//
//  Settings for the Command Bar: the on switch, its global shortcut, which
//  sources it searches, how many results it shows, and its history.
//

import SwiftUI

struct CommandBarSettingsView: View {
    @Bindable private var preferences = CommandBarPreferences.shared
    @ObservedObject private var service = CommandBarService.shared
    @ObservedObject private var permissions = PermissionsService.shared

    @State private var isRecording = false
    @State private var conflictMessage: String?
    @State private var isShowingResetConfirmation = false

    private var needsAccessibility: Bool {
        CommandBarPreferences.Source.allCases.contains { $0.needsAccessibility && preferences.isOn($0) }
    }

    var body: some View {
        Form {
            Section("Command Bar") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Enable Command Bar", isOn: $preferences.enabled)
                        .font(.headline)

                    Text("Press the shortcut anywhere to open one search field that finds apps, open windows, files and the menu commands of the app in front, snaps the window in front, and answers sums and unit conversions. Use the arrow keys to choose, Return to open, Tab for more actions and Escape to close. Windows, menu commands and snapping need Accessibility permission.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if preferences.enabled, needsAccessibility, permissions.accessibility != .granted {
                        HStack {
                            Text("Accessibility is not granted, so windows, menu commands and snapping are missing from the Command Bar.")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Reset Permission") {
                                Task { await PermissionsService.shared.resetPermission(for: .accessibility) }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Shortcut")
                        Spacer()
                        ShortcutRecorderControl(
                            shortcut: preferences.shortcut,
                            isRecording: $isRecording,
                            resetShortcut: CommandBarPreferences.DefaultValues.shortcut
                        ) { shortcut in
                            record(shortcut)
                        }
                    }
                    if let conflictMessage {
                        Text(conflictMessage)
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if preferences.enabled, let activeConflict = service.activeConflictMessage {
                        Text(activeConflict + " The shortcut is off until you record a different one.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if preferences.enabled, service.isShortcutUnavailable {
                        Text("Another app already uses this shortcut, so it does nothing. Launchers such as Raycast and Alfred often use Option-Space. Record a different one.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!preferences.enabled)
            }

            Section("Search") {
                ForEach(CommandBarPreferences.Source.allCases) { source in
                    Toggle(isOn: Binding(
                        get: { preferences.isOn(source) },
                        set: { preferences.setSource(source, on: $0) }
                    )) {
                        HStack(spacing: 10) {
                            Image(systemName: source.symbolName)
                                .frame(width: 20)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.title)
                                Text(source.detail)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                Stepper(value: $preferences.maxResults, in: CommandBarPreferences.maxResultsRange) {
                    HStack {
                        Text("Maximum Results")
                        Spacer()
                        Text("\(preferences.maxResults)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!preferences.enabled)

            Section {
                HStack {
                    Text("Results you choose often or recently rank higher. The history stays on this Mac.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Clear History") {
                        preferences.clearHistory()
                    }
                    .disabled(preferences.recency.entries.isEmpty)
                }
                HStack {
                    Spacer()
                    Button("Reset Command Bar") {
                        isShowingResetConfirmation = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: isRecording) { recording in
            service.isRecordingShortcut = recording
        }
        .onDisappear {
            service.isRecordingShortcut = false
        }
        .alert("Reset Command Bar?", isPresented: $isShowingResetConfirmation) {
            Button("Reset", role: .destructive) {
                preferences.resetToDefaults()
                conflictMessage = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Turns the Command Bar off, puts the shortcut back to Option-Space, turns every source on and shows 8 results.")
        }
    }

    /// Refuses a shortcut Wharf already uses and says why, instead of saving
    /// one that cannot work.
    private func record(_ shortcut: KeyboardShortcut) {
        if let message = service.conflictMessage(for: shortcut) {
            conflictMessage = message
            return
        }
        conflictMessage = nil
        preferences.shortcut = shortcut
    }
}
