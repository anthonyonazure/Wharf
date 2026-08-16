//
//  LayoutsSettingsView.swift
//  Wharf
//
//  Save and restore window layouts across displays.
//

import SwiftUI

struct LayoutsSettingsView: View {
    @ObservedObject private var service = WorkspaceLayoutService.shared
    @State private var newLayoutName = ""
    @State private var lastResult: String?
    @State private var renamingID: String?
    @State private var renameText = ""

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Save Current Layout")
                        .font(.headline)

                    HStack {
                        TextField("Name (e.g. Work, Research, Meeting)", text: $newLayoutName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(capture)

                        Button("Save", action: capture)
                            .disabled(trimmedName.isEmpty)
                    }

                    Text("Records where every open window sits, including which display it is on. Saving with an existing name overwrites that layout.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let lastResult {
                        Text(lastResult)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                if service.layouts.isEmpty {
                    Text("No layouts saved yet. Arrange your windows the way you want them, then save the arrangement above.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 4)
                } else {
                    ForEach(service.layouts) { layout in
                        layoutRow(layout)
                    }
                }
            } header: {
                Text("Saved Layouts")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func layoutRow(_ layout: WorkspaceLayout) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if renamingID == layout.id {
                    TextField("Name", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            service.rename(layout, to: renameText)
                            renamingID = nil
                        }
                } else {
                    Text(layout.name)
                        .font(.headline)
                }

                Spacer()

                Button("Restore") { restore(layout) }
                Button("Restore & Launch") { restoreLaunching(layout) }

                Menu {
                    Button("Rename…") {
                        renameText = layout.name
                        renamingID = layout.id
                    }
                    Button("Overwrite with Current Windows") {
                        service.capture(name: layout.name)
                        lastResult = "Overwrote \(layout.name)."
                    }
                    Divider()
                    Button("Delete", role: .destructive) { service.delete(layout) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Text("\(layout.placements.count) windows across \(displayCount(layout)) display\(displayCount(layout) == 1 ? "" : "s") · \(layout.bundleIdentifiers.count) apps")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var trimmedName: String {
        newLayoutName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func displayCount(_ layout: WorkspaceLayout) -> Int {
        Set(layout.placements.compactMap(\.displayUUID)).count
    }

    private func capture() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        service.capture(name: name)
        lastResult = "Saved \(name)."
        newLayoutName = ""
    }

    private func restore(_ layout: WorkspaceLayout) {
        let result = service.restore(layout)
        lastResult = summary(for: layout, result: result, launched: 0)
    }

    /// Launches whatever the layout needs before placing windows.
    ///
    /// An app that was just launched has no window yet, so placement runs on a
    /// delay. Restoring immediately would move only the windows that already
    /// existed and silently skip everything it just opened.
    private func restoreLaunching(_ layout: WorkspaceLayout) {
        let launched = service.launchMissingApps(for: layout)
        guard launched > 0 else {
            restore(layout)
            return
        }

        lastResult = "Launching \(launched) app\(launched == 1 ? "" : "s")…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let result = service.restore(layout)
            lastResult = summary(for: layout, result: result, launched: launched)
        }
    }

    private func summary(for layout: WorkspaceLayout, result: (moved: Int, missed: Int), launched: Int) -> String {
        var parts = ["Restored \(layout.name): \(result.moved) window\(result.moved == 1 ? "" : "s") placed"]
        if result.missed > 0 {
            parts.append("\(result.missed) not found")
        }
        if launched > 0 {
            parts.append("\(launched) app\(launched == 1 ? "" : "s") launched")
        }
        return parts.joined(separator: ", ") + "."
    }
}
