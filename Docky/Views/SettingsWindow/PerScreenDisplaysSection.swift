//
//  PerScreenDisplaysSection.swift
//  Wharf
//
//  Settings, Behavior, Placement, Displays: one row per connected display,
//  each either following the global settings or carrying its own edge, tile
//  size and autohide. Overrides are stored by display UUID in
//  `PerDisplaySettings`, so they come back when a monitor is plugged in again;
//  a display that is not connected is simply not listed, and its stored
//  override is left alone.
//

import AppKit
import SwiftUI

struct PerScreenDisplaysSection: View {
    @Bindable private var preferences = DockyPreferences.shared
    private let perDisplay = PerDisplaySettings.shared
    @State private var displays: [ConnectedDisplay] = ConnectedDisplay.current()

    var body: some View {
        Section {
            if displays.isEmpty {
                Text("No displays with a stable identifier are connected.")
                    .foregroundStyle(.secondary)
            }

            ForEach(displays) { display in
                displayRow(display)
            }

            if preferences.windowDisplayTarget != .allDisplays {
                Text("These settings take effect when Display is set to All Displays. In the single dock modes every display uses the global settings.")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Displays")
        } footer: {
            Text("Each display can keep its own dock edge, tile size and autohide. Settings are remembered when a display is unplugged and come back when it is reconnected.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = ConnectedDisplay.current()
        }
    }

    @ViewBuilder
    private func displayRow(_ display: ConnectedDisplay) -> some View {
        let usesGlobal = !(perDisplay.override(forKey: display.key)?.hasDockSettings ?? false)

        VStack(alignment: .leading, spacing: 8) {
            Text(display.name)
                .font(.headline)

            Toggle("Use global settings", isOn: usesGlobalBinding(display.key))

            if !usesGlobal {
                HStack {
                    Text("Position")
                    Spacer()
                    Picker("Position", selection: positionBinding(display.key)) {
                        ForEach(DockWindowPosition.allCases) { position in
                            Text(position.title).tag(position)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }

                HStack {
                    Text("Tile Size")
                    Slider(value: tileSizeBinding(display.key), in: PerScreenResolution.tileSizeRange, step: 1) {
                        Text("Tile Size")
                    }
                    .labelsHidden()
                    Text("\(Int(tileSizeBinding(display.key).wrappedValue.rounded())) pt")
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }

                Toggle("Autohide", isOn: autohideBinding(display.key))
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Bindings

    private var globalPosition: DockWindowPosition { preferences.windowPosition }
    private var globalTileSize: Double { Double(DockSettingsService.shared.displayTileSize) }
    private var globalAutohide: Bool { preferences.autohidesWindow }

    private func usesGlobalBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { !(perDisplay.override(forKey: key)?.hasDockSettings ?? false) },
            set: { useGlobal in
                let existing = perDisplay.override(forKey: key)
                if useGlobal {
                    perDisplay.setOverride(PerScreenResolution.clearingDockSettings(existing), forKey: key)
                } else {
                    perDisplay.setOverride(
                        PerScreenResolution.seeded(
                            from: existing,
                            globalPosition: globalPosition.rawValue,
                            globalTileSize: globalTileSize,
                            globalAutohide: globalAutohide
                        ),
                        forKey: key
                    )
                }
            }
        )
    }

    private func positionBinding(_ key: String) -> Binding<DockWindowPosition> {
        Binding(
            get: {
                PerScreenResolution.position(override: perDisplay.override(forKey: key)?.position, global: globalPosition)
            },
            set: { newValue in update(key) { $0.position = newValue.rawValue } }
        )
    }

    private func tileSizeBinding(_ key: String) -> Binding<Double> {
        Binding(
            get: {
                PerScreenResolution.tileSize(override: perDisplay.override(forKey: key)?.tileSize, global: globalTileSize)
            },
            set: { newValue in update(key) { $0.tileSize = newValue } }
        )
    }

    private func autohideBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: {
                PerScreenResolution.autohide(override: perDisplay.override(forKey: key)?.autohide, global: globalAutohide)
            },
            set: { newValue in update(key) { $0.autohide = newValue } }
        )
    }

    private func update(_ key: String, _ change: (inout DisplayOverride) -> Void) {
        var current = perDisplay.override(forKey: key) ?? DisplayOverride()
        change(&current)
        perDisplay.setOverride(current, forKey: key)
    }
}

/// A connected display, named for the list and keyed by its persistent UUID.
private struct ConnectedDisplay: Identifiable {
    let key: String
    let name: String
    var id: String { key }

    static func current() -> [ConnectedDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let displayID = screen.displayID,
                  let key = PerDisplaySettings.key(for: displayID) else { return nil }
            let isMain = screen == NSScreen.screens.first
            return ConnectedDisplay(key: key, name: isMain ? "\(screen.localizedName) (main)" : screen.localizedName)
        }
    }
}
