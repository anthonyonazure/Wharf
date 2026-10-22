//
//  WindowBehaviorSettingsView.swift
//  Wharf
//
//  One pane for the three Window Behavior features: green button maximize,
//  quit on close, and Command-Q and Command-W protection. Each has its own
//  switch, all off by default. See WindowBehaviorPreferences.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WindowBehaviorSettingsView: View {
    @Bindable private var preferences = WindowBehaviorPreferences.shared
    @ObservedObject private var permissions = PermissionsService.shared
    @State private var isShowingResetConfirmation = false

    private var anyFeatureOn: Bool {
        preferences.maximizeEnabled || preferences.quitOnCloseEnabled || preferences.quitGuardEnabled
    }

    var body: some View {
        Form {
            if anyFeatureOn, permissions.accessibility != .granted {
                Section {
                    HStack {
                        Text("Accessibility is not granted, so Window Behavior is doing nothing.")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Reset Permission") {
                            Task { await PermissionsService.shared.resetPermission(for: .accessibility) }
                        }
                    }
                }
            }

            maximizeSection
            quitOnCloseSection
            quitGuardSection

            Section {
                HStack {
                    Spacer()
                    Button("Reset Window Behavior") {
                        isShowingResetConfirmation = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert("Reset Window Behavior?", isPresented: $isShowingResetConfirmation) {
            Button("Reset", role: .destructive) {
                preferences.resetToDefaults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Turns all three features off and empties their app lists.")
        }
    }

    // MARK: Green button

    private var maximizeSection: some View {
        Section("Green Button") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Green Button Maximizes", isOn: $preferences.maximizeEnabled)
                    .font(.headline)
                Text("Clicking a window's green button fills the screen, stopping at the menu bar, the Dock and Wharf's dock and keeping the Window Snapping gap, instead of entering full screen. Click it again to put the window back. Hold Option while clicking for the real full screen. Requires Accessibility permission.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

            BundleListEditor(
                title: "Apps that keep full screen",
                emptyText: "No exceptions. Add games, players or anything that should still go full screen.",
                identifiers: $preferences.maximizeExceptions
            )
            .disabled(!preferences.maximizeEnabled)
        }
    }

    // MARK: Quit on close

    private var quitOnCloseSection: some View {
        Section("Quit on Close") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Quit Apps When Their Last Window Closes", isOn: $preferences.quitOnCloseEnabled)
                    .font(.headline)
                Text("For the apps listed below, closing the last window quits the app, as on Windows. The app gets a normal quit request, so it still asks about unsaved changes. Apps that only live in the menu bar, apps that never opened a window, and hidden or minimized windows are left alone. Requires Accessibility permission.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

            BundleListEditor(
                title: "Apps that quit on close",
                emptyText: "No apps yet. Nothing quits until you add one.",
                identifiers: $preferences.quitOnCloseApps
            )
            .disabled(!preferences.quitOnCloseEnabled)
        }
    }

    // MARK: Quit protection

    private var quitGuardSection: some View {
        Section("Quit and Close Protection") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Protect Command-Q and Command-W", isOn: $preferences.quitGuardEnabled)
                    .font(.headline)
                Text("Stops a stray Command-Q or Command-W from quitting an app or closing a window. Choose whether the shortcut must be held, pressed twice, or pressed with an extra modifier. A small panel says what to do. Requires Accessibility permission.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

            Group {
                Toggle("Protect Command-Q (quit)", isOn: $preferences.quitGuardProtectsQuit)
                Toggle("Protect Command-W (close window)", isOn: $preferences.quitGuardProtectsClose)

                Picker("Default protection", selection: $preferences.quitGuardDefaultMode) {
                    ForEach(QuitGuardMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Hold for")
                        Spacer()
                        Text(String(format: "%.1f s", preferences.quitGuardHoldMilliseconds / 1_000))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $preferences.quitGuardHoldMilliseconds, in: QuitGuardStateMachine.holdRange, step: 50)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Second press within")
                        Spacer()
                        Text(String(format: "%.1f s", preferences.quitGuardDoublePressMilliseconds / 1_000))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $preferences.quitGuardDoublePressMilliseconds,
                        in: QuitGuardStateMachine.doublePressRange,
                        step: 50
                    )
                }

                Picker("Extra modifier", selection: $preferences.quitGuardExtraModifier) {
                    ForEach(QuitGuardModifier.allCases) { modifier in
                        Text(modifier.title).tag(modifier)
                    }
                }
                if preferences.quitGuardExtraModifier == .control {
                    Text("Control-Command-Q is also the macOS Lock Screen shortcut.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                QuitGuardOverridesEditor(overrides: $preferences.quitGuardOverrides)
            }
            .disabled(!preferences.quitGuardEnabled)
        }
    }
}

// MARK: - Bundle id list

/// A list of apps by bundle id, with an add menu of running apps and a
/// chooser for any app on disk.
private struct BundleListEditor: View {
    let title: String
    let emptyText: String
    @Binding var identifiers: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                AddAppMenu(excluded: identifiers) { identifier in
                    identifiers = WindowBehaviorBundleList.sanitized(identifiers + [identifier])
                }
            }
            if identifiers.isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(identifiers, id: \.self) { identifier in
                    HStack {
                        AppLabel(bundleIdentifier: identifier)
                        Spacer()
                        Button {
                            identifiers.removeAll { $0 == identifier }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct QuitGuardOverridesEditor: View {
    @Binding var overrides: [String: QuitGuardMode]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Per-app protection")
                Spacer()
                AddAppMenu(excluded: Array(overrides.keys)) { identifier in
                    overrides[identifier] = .off
                }
            }
            if overrides.isEmpty {
                Text("Every app uses the default. Add an app to give it its own protection, or none.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(overrides.keys.sorted(), id: \.self) { identifier in
                    HStack {
                        AppLabel(bundleIdentifier: identifier)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { overrides[identifier] ?? .off },
                            set: { overrides[identifier] = $0 }
                        )) {
                            ForEach(QuitGuardMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button {
                            overrides.removeValue(forKey: identifier)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AddAppMenu: View {
    let excluded: [String]
    let add: (String) -> Void

    var body: some View {
        Menu("Add App") {
            let running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
                .compactMap { app -> (String, String)? in
                    guard let id = app.bundleIdentifier,
                          !WindowBehaviorBundleList.contains(id, in: excluded) else { return nil }
                    return (id, app.localizedName ?? id)
                }
                .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
            ForEach(running, id: \.0) { id, name in
                Button(name) { add(id) }
            }
            if !running.isEmpty { Divider() }
            Button("Choose an App…") { chooseApp() }
        }
        .fixedSize()
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        guard panel.runModal() == .OK,
              let url = panel.url,
              let identifier = Bundle(url: url)?.bundleIdentifier
        else { return }
        add(identifier)
    }
}

private struct AppLabel: View {
    let bundleIdentifier: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleIdentifier)
                Text(bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
