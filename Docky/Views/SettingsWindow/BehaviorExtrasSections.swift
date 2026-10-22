//
//  BehaviorExtrasSections.swift
//  Wharf
//
//  Sections added to existing Behavior panes: the Win key tap and the
//  per-app exclusion editor under Windows Keyboard, and fixed Space order
//  under Visibility. Kept here so BehaviorSettingsView only gains one line
//  per pane.
//

import SwiftUI

/// Win key tap and per-app exclusions, shown below the Windows Keyboard
/// switches.
struct WindowsKeyboardExtrasSections: View {
    @Bindable private var preferences = DockyPreferences.shared
    @Bindable private var extras = BehaviorExtrasPreferences.shared

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Win Key Opens", selection: $extras.winTapAction) {
                    ForEach(WinKeyTapAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                .font(.headline)

                Text("Press and release the Win key on its own, with nothing else between, to open the Start Menu or Launchpad, as on Windows. Tap again to close it. Win key shortcuts still work as before. Launchpad opens only when the Launchpad overlay is turned on under Features, Launchpad.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if extras.winTapAction == .launchpad, !preferences.enablesLaunchpadOverlay {
                    Text("The Launchpad overlay is off, so a Win key tap does nothing. Turn on Enable Launchpad under Features, Launchpad.")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Win Key")
        }
        .disabled(!preferences.windowsKeyboardMode)

        Section {
            BundleIDListEditor(
                bundleIDs: $preferences.windowsKeyboardExcludedBundleIDs,
                emptyText: "No apps excluded. Control keeps its Windows meaning everywhere.",
                allowsExecutableNames: true
            )

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Take Snips in Excluded Apps Too", isOn: $extras.snipInExcludedApps)
                    .disabled(!preferences.windowsKeyboardSnipShortcut)
                Text("Off: in an excluded app, Win+Shift+S goes to the app itself, so a remote desktop or virtual machine can take its own snip. On: Win+Shift+S takes a Mac snip in every app.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Excluded Apps")
        } footer: {
            Text("In these apps the Win key belongs to the app: Control keeps its Mac meaning, nothing is translated, a Win key tap does nothing and Win+Shift+S reaches the app unless the switch above says otherwise. Terminals are on the list by default, so Ctrl+C there still interrupts a running process.")
                .foregroundStyle(.secondary)
        }
        .disabled(!preferences.windowsKeyboardMode)
    }
}

/// Fixed Space order, shown in the Visibility pane.
struct FixedSpaceOrderSection: View {
    var body: some View {
        // The section and its status messages live in FixedSpaceOrderSectionBody.swift.
        FixedSpaceOrderSectionBody()
    }
}
