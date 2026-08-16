//
//  UpdatesSettingsView.swift
//  Docky
//

import SwiftUI

struct UpdatesSettingsView: View {
    @ObservedObject private var appUpdateService = AppUpdateService.shared

    private let updateIntervals: [TimeInterval] = [3600, 86_400, 604_800, 2_629_800]

    var body: some View {
        Form {
            Section("Updates") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("Check for Updates…") {
                            appUpdateService.checkForUpdates()
                        }
                        .disabled(!appUpdateService.canCheckForUpdates)

                        Spacer()
                    }

                    Toggle("Automatically Check for Updates", isOn: $appUpdateService.automaticallyChecksForUpdates)
                        .font(.headline)

                    Toggle("Automatically Download Updates", isOn: $appUpdateService.automaticallyDownloadsUpdates)
                        .font(.headline)
                        .disabled(!appUpdateService.automaticallyChecksForUpdates)

                    HStack {
                        Text("Check Interval")
                            .font(.headline)

                        Spacer()

                        Picker("Check Interval", selection: $appUpdateService.updateCheckInterval) {
                            ForEach(updateIntervals, id: \.self) { interval in
                                Text(title(for: interval)).tag(interval)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .disabled(!appUpdateService.automaticallyChecksForUpdates)
                    }

                    Text("Wharf can periodically check getdocky.com for new signed releases. Sparkle stores these update preferences directly in your user defaults.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }

    private func title(for interval: TimeInterval) -> String {
        switch interval {
        case 3600:
            "Hourly"
        case 86_400:
            "Daily"
        case 604_800:
            "Weekly"
        case 2_629_800:
            "Monthly"
        default:
            "Custom"
        }
    }
}
