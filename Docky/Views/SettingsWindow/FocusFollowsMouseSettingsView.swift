//
//  FocusFollowsMouseSettingsView.swift
//  Wharf
//
//  Settings for focus follows mouse: the switch, the pause, which displays
//  it runs on, and apps it leaves alone. See FocusFollowsMouseService.
//

import AppKit
import SwiftUI

struct FocusFollowsMouseSettingsView: View {
    @Bindable private var preferences = BehaviorExtrasPreferences.shared
    @ObservedObject private var permissions = PermissionsService.shared

    @State private var screens: [ScreenChoice] = ScreenChoice.current()

    var body: some View {
        Form {
            Section("Focus Follows Mouse") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Enable Focus Follows Mouse", isOn: $preferences.focusFollowsMouseEnabled)
                        .font(.headline)

                    Text("Rest the pointer on a window and it comes to the front with keyboard focus, no click needed, the way classic Unix window managers work. It waits for the pointer to stop, so windows you cross on the way are left alone, and it never acts while a menu is open, a mouse button is down or a modifier key is held. Wharf's own windows and the Dock are never raised. Requires Accessibility permission.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if preferences.focusFollowsMouseEnabled, permissions.accessibility != .granted {
                        HStack {
                            Text("Accessibility is not granted, so Focus Follows Mouse is doing nothing.")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Reset Permission") {
                                Task { await PermissionsService.shared.resetPermission(for: .accessibility) }
                            }
                        }
                    }

                    if preferences.focusFollowsMouseEnabled, preferences.focusFollowsMouseDisplays.isEmpty {
                        Text("No display is turned on below, so nothing happens yet.")
                            .foregroundStyle(.orange)
                    } else if preferences.focusFollowsMouseEnabled,
                              !FocusDisplaySelection.hasConnectedMatch(
                                saved: preferences.focusFollowsMouseDisplays, connected: screens.map(\.key)) {
                        Text("None of the displays turned on below is connected, so nothing happens until one is.")
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Pause Before Focus")
                            .font(.headline)
                        Spacer()
                        Text("\(preferences.focusFollowsMouseDelay) ms")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: Binding(
                            get: { Double(preferences.focusFollowsMouseDelay) },
                            set: { preferences.focusFollowsMouseDelay = Int($0) }
                        ),
                        in: Double(FocusFollowsMouseTiming.delayRange.lowerBound)...Double(FocusFollowsMouseTiming.delayRange.upperBound),
                        step: 50
                    )

                    Text("How long the pointer has to rest on a window before it takes focus.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                .disabled(!preferences.focusFollowsMouseEnabled)
            }

            Section {
                if screens.isEmpty {
                    Text("No displays found.")
                        .foregroundStyle(.secondary)
                }
                ForEach(screens) { screen in
                    Toggle(screen.name, isOn: displayBinding(for: screen.key))
                }
                // Saved displays that are unplugged now. They are kept so the
                // feature comes back when the display does, and shown so they
                // can be removed by hand; nothing is pruned silently.
                ForEach(disconnectedKeys, id: \.self) { key in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Display not connected")
                            Text(key)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") {
                            preferences.focusFollowsMouseDisplays.removeAll { $0 == key }
                        }
                    }
                }
            } header: {
                Text("Displays")
            } footer: {
                Text("Off for every display until you turn one on, so a shared desk keeps macOS's click to focus where you want it. A display that is turned on but not connected stays on the list and works again when you plug it back in; it alone does not keep Focus Follows Mouse running.")
                    .foregroundStyle(.secondary)
            }
            .disabled(!preferences.focusFollowsMouseEnabled)

            Section {
                BundleIDListEditor(
                    bundleIDs: $preferences.focusFollowsMouseExcludedBundleIDs,
                    emptyText: "No apps excluded."
                )
            } header: {
                Text("Excluded Apps")
            } footer: {
                Text("Windows of these apps are never raised by hovering.")
                    .foregroundStyle(.secondary)
            }
            .disabled(!preferences.focusFollowsMouseEnabled)
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = ScreenChoice.current()
        }
    }

    private var disconnectedKeys: [String] {
        FocusDisplaySelection.disconnected(saved: preferences.focusFollowsMouseDisplays, connected: screens.map(\.key))
    }

    private func displayBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { preferences.focusFollowsMouseDisplays.contains(key) },
            set: { isOn in
                if isOn {
                    if !preferences.focusFollowsMouseDisplays.contains(key) {
                        preferences.focusFollowsMouseDisplays.append(key)
                    }
                } else {
                    preferences.focusFollowsMouseDisplays.removeAll { $0 == key }
                }
            }
        )
    }
}

/// A connected display, named for the list and keyed by its persistent UUID.
private struct ScreenChoice: Identifiable {
    let key: String
    let name: String
    var id: String { key }

    static func current() -> [ScreenChoice] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let key = PerDisplaySettings.key(for: CGDirectDisplayID(number.uint32Value)) else { return nil }
            let isMain = screen == NSScreen.screens.first
            return ScreenChoice(key: key, name: isMain ? "\(screen.localizedName) (main)" : screen.localizedName)
        }
    }
}
