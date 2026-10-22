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
    /// Whether an app without a bundle ID may be added by its executable's
    /// name. Only for lists whose service matches by that name too
    /// (`BundleIDList.matchKey`); elsewhere such an entry would never match.
    var allowsExecutableNames = false

    @State private var typedBundleID = ""
    /// Why the last pick could not be added, shown until the next pick.
    @State private var pickerMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if bundleIDs.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary)
            } else {
                // Lazy, so a very long list does not build every row (and
                // look up every app icon) the moment the pane opens.
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(BundleIDList.deduplicated(bundleIDs), id: \.self) { bundleID in
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
                                bundleIDs = BundleIDList.removing(bundleID, from: bundleIDs)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove \(displayName(for: bundleID))")
                        }
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

            if let pickerMessage {
                Text(pickerMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                TextField("Bundle ID, for example com.apple.Terminal", text: $typedBundleID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addTyped() }
                Button("Add") { addTyped() }
                    .disabled(typedValidationError != nil)
            }

            // Said only once something is typed, so an empty field is quiet.
            if !typedBundleID.trimmingCharacters(in: .whitespaces).isEmpty,
               let typedValidationError {
                Text(typedValidationError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var typedValidationError: String? {
        BundleIDList.validationError(typedBundleID)
    }

    /// Bundle IDs ignore case, so "COM.APPLE.SAFARI" is a duplicate of
    /// "com.apple.Safari". The spelling first added is the one shown.
    private func add(_ bundleID: String) {
        let updated = BundleIDList.adding(bundleID, to: bundleIDs)
        if updated != bundleIDs { bundleIDs = updated }
    }

    private func addTyped() {
        // Return in the field skips the disabled button, so check here too.
        guard typedValidationError == nil else { return }
        add(typedBundleID)
        typedBundleID = ""
    }

    private func runningApps() -> [(name: String, bundleID: String)] {
        let listed = BundleIDList.matchSet(bundleIDs)
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (name: String, bundleID: String)? in
                guard let id = app.bundleIdentifier
                        ?? (allowsExecutableNames ? app.executableURL?.lastPathComponent : nil)
                else { return nil }
                let key = BundleIDList.normalized(id)
                guard !listed.contains(key), seen.insert(key).inserted else { return nil }
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
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pickerMessage = nil
        let bundle = Bundle(url: url)
        let name = FileManager.default.displayName(atPath: url.path)
        if let identifier = bundle?.bundleIdentifier {
            add(identifier)
        } else if allowsExecutableNames, let executable = bundle?.executableURL?.lastPathComponent {
            add(executable)
            pickerMessage = "\(name) has no bundle ID, so it was added by its program name, \(executable)."
        } else {
            pickerMessage = "\(name) could not be added: it has no bundle ID for Wharf to match it by."
        }
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
