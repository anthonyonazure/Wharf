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
            }
            .padding(.vertical, 4)
        } header: {
            Text("Win Key")
        }
        .disabled(!preferences.windowsKeyboardMode)

        Section {
            BundleIDListEditor(
                bundleIDs: $preferences.windowsKeyboardExcludedBundleIDs,
                emptyText: "No apps excluded. Control keeps its Windows meaning everywhere."
            )
        } header: {
            Text("Excluded Apps")
        } footer: {
            Text("In these apps Control keeps its Mac meaning, nothing is translated and a Win key tap does nothing. Terminals are on the list by default, so Ctrl+C there still interrupts a running process. Win+Shift+S still takes a snip everywhere.")
                .foregroundStyle(.secondary)
        }
        .disabled(!preferences.windowsKeyboardMode)
    }
}

/// Fixed Space order, shown in the Visibility pane.
struct FixedSpaceOrderSection: View {
    @Bindable private var extras = BehaviorExtrasPreferences.shared

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Keep Spaces in a Fixed Order", isOn: $extras.spacesOrderFixed)
                    .font(.headline)
                    .disabled(SpacesOrderService.shared.isManaged)

                Text("Stops macOS from rearranging Spaces based on most recent use, so each desktop stays where you put it. This is the same switch as in System Settings, Desktop & Dock, Mission Control. Wharf remembers your previous setting and puts it back when you turn this off. The Dock restarts briefly to apply the change.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if SpacesOrderService.shared.isManaged {
                    Text("A management profile controls this setting, so Wharf leaves it alone.")
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Spaces")
        }
    }
}
