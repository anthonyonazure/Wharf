//
//  PreviewActionsSettingsSection.swift
//  Wharf
//
//  The "Preview Actions" group shown under Window Preview in Window
//  Management settings.
//

import SwiftUI

struct PreviewActionsSettingsSection: View {
    @Bindable private var preferences = PreviewActionsPreferences.shared
    @ObservedObject private var permissions = PermissionsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview Actions")
                .font(.headline)

            Toggle("Close Button", isOn: $preferences.showsClose)
            Toggle("Minimize Button", isOn: $preferences.showsMinimize)
            Toggle("Snap Menu", isOn: $preferences.showsSnapMenu)

            Text("Buttons that appear on a preview card while the pointer is over it. They act on that window only. Snap offers Left Half, Right Half, Maximize and, with more than one display, Next Display. A minimized window shows a restore button instead.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if preferences.anyPreviewActionOn, permissions.accessibility != .granted {
                HStack {
                    Text("Accessibility is not granted, so Preview Actions can not move or close windows.")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Reset Permission") {
                        Task { await PermissionsService.shared.resetPermission(for: .accessibility) }
                    }
                }
            }

            Divider()

            Toggle("Layouts in Dock Menus", isOn: $preferences.showsLayoutsInDockMenus)
            Text("Adds a Layouts submenu to the dock's right-click menu and the Wharf menu bar item, with one-click restore and Save Current Layout. Hold Option while the menu is open to also open apps a layout needs.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}
