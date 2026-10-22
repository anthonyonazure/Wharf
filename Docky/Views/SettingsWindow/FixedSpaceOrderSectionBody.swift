//
//  FixedSpaceOrderSectionBody.swift
//  Wharf
//
//  The Fixed Space order section of the Visibility pane, with the states
//  SpacesOrderService reports: managed by a profile, a stored value Wharf
//  does not recognize, a change that has not taken yet, a previous setting
//  not yet put back, and a Dock that did not restart. Also the short note
//  under Reset Behavior when the restore is still pending.
//

import SwiftUI

struct FixedSpaceOrderSectionBody: View {
    @Bindable private var extras = BehaviorExtrasPreferences.shared
    private var service = SpacesOrderService.shared

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Keep Spaces in a Fixed Order", isOn: $extras.spacesOrderFixed)
                    .font(.headline)
                    // Turning it off always stays possible.
                    .disabled(service.availability != .available && !extras.spacesOrderFixed)

                Text("Stops macOS from rearranging Spaces based on most recent use, so each desktop stays where you put it. This is the same switch as in System Settings, Desktop & Dock, Mission Control. Wharf remembers your previous setting and puts it back when you turn this off. The Dock restarts briefly to apply the change.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(messages, id: \.self) { message in
                    Text(message)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Spaces")
        }
        .onAppear { service.refreshStatus() }
        .onChange(of: extras.spacesOrderFixed) { service.refreshStatus() }
    }

    private var messages: [String] {
        var lines: [String] = []
        switch service.availability {
        case .available:
            break
        case .managed:
            lines.append("A management profile controls this setting, so Wharf leaves it alone.")
        case .unsupportedValue:
            lines.append("The Dock's setting for this holds a value Wharf does not recognize, so Wharf leaves it alone. Turning \"Automatically rearrange Spaces based on most recent use\" off and on once in System Settings, Desktop & Dock, Mission Control fixes it.")
        }
        if extras.spacesOrderFixed, service.lastFailure != nil {
            lines.append(service.retriesExhausted
                ? "Wharf could not change the Spaces setting. Your choice is kept, and Wharf tries again the next time it starts or the Dock restarts. Turn this off and on to try now."
                : "Wharf could not change the Spaces setting yet. Your choice is kept, and Wharf is trying again.")
        }
        if let restore = SpacesOrderRestoreNote.message(for: service) {
            lines.append(restore)
        }
        if service.dockRestartGaveUp {
            lines.append("The Dock did not restart to apply the change. It takes effect the next time the Dock starts, for example after you log out and back in.")
        }
        return lines
    }
}

/// Shown under Reset Behavior (and in the section above) while Wharf still
/// owes the user their previous Spaces setting.
struct SpacesOrderRestoreNote: View {
    private var service = SpacesOrderService.shared

    static func message(for service: SpacesOrderService) -> String? {
        guard service.restorePending else { return nil }
        return "Wharf could not put your previous Spaces setting back yet. It keeps the record and tries again; until then Spaces stay in a fixed order."
    }

    var body: some View {
        if let message = Self.message(for: service) {
            Text(message)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
