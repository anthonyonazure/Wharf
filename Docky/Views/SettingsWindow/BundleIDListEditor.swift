//
//  BundleIDListEditor.swift
//  Wharf
//
//  An editable list of apps, stored as bundle IDs. Apps can be added from
//  what is running now, picked from the Applications folder, or typed in by
//  bundle ID, and removed one at a time. Used by the Windows Keyboard
//  exclusions and the Focus Follows Mouse exclusions.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BundleIDListEditor: View {
    @Binding var bundleIDs: [String]
    var emptyText = "No apps added."

    @State private var typedBundleID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if bundleIDs.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(bundleIDs, id: \.self) { bundleID in
                    HStack(spacing: 8) {
                        Image(nsImage: icon(for: bundleID))
                            .resizable()
                            .frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(displayName(for: bundleID))
                            Text(bundleID)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            bundleIDs.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(displayName(for: bundleID))")
                    }
                }
            }

            HStack {
                Menu("Add Running App") {
                    let apps = runningApps()
                    if apps.isEmpty {
                        Text("Every running app is already in the list")
                    }
                    ForEach(apps, id: \.bundleID) { app in
                        Button(app.name) { add(app.bundleID) }
                    }
                }
                .fixedSize()

                Button("Choose App…") { chooseApp() }
                Spacer()
            }

            HStack {
                TextField("Bundle ID, for example com.apple.Terminal", text: $typedBundleID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addTyped() }
                Button("Add") { addTyped() }
                    .disabled(typedBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add(_ bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !bundleIDs.contains(trimmed) else { return }
        bundleIDs.append(trimmed)
    }

    private func addTyped() {
        add(typedBundleID)
        typedBundleID = ""
    }

    private func runningApps() -> [(name: String, bundleID: String)] {
        let listed = Set(bundleIDs)
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (name: String, bundleID: String)? in
                guard let id = app.bundleIdentifier, !listed.contains(id), seen.insert(id).inserted else { return nil }
                return (app.localizedName ?? id, id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK,
              let url = panel.url,
              let identifier = Bundle(url: url)?.bundleIdentifier else { return }
        add(identifier)
    }

    /// Friendly name, falling back to the bundle ID when the app is not
    /// installed.
    private func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func icon(for bundleID: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
