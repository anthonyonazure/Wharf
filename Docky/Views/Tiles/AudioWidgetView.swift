//
//  AudioWidgetView.swift
//  Wharf
//
//  Volume, mute and output device, one click from the dock.
//
//  The tile shows the state (icon and level). The detail lives in a popover
//  because a slider needs room and a dock tile does not have it.
//

import SwiftUI

struct AudioWidgetView: View {
    let span: TileSpan

    @ObservedObject private var audio = AudioControlService.shared
    @State private var isShowingPopover = false

    var body: some View {
        Button {
            isShowingPopover = true
        } label: {
            content
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowingPopover, arrowEdge: .top) {
            popover
                .frame(width: 260)
                .padding(12)
        }
        .help(helpText)
    }

    // MARK: - Tile

    private var content: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thinMaterial)

            VStack(spacing: 2) {
                Image(systemName: symbolName)
                    .font(.system(size: span == .one ? 16 : 20, weight: .medium))
                    .foregroundStyle(audio.isMuted ? .secondary : .primary)

                if span != .one {
                    Text(levelText)
                        .font(.system(size: 9, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var symbolName: String {
        if audio.isMuted || audio.volume == 0 { return "speaker.slash.fill" }
        switch audio.volume {
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    private var levelText: String {
        if audio.isMuted { return "Muted" }
        guard audio.canSetVolume else { return "Fixed" }
        return "\(Int((audio.volume * 100).rounded()))%"
    }

    private var helpText: String {
        let device = audio.outputDevices.first { $0.id == audio.defaultDeviceID }?.name ?? "No output"
        return "\(device): \(levelText)"
    }

    // MARK: - Popover

    private var popover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    audio.toggleMute()
                } label: {
                    Image(systemName: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
                .help(audio.isMuted ? "Unmute" : "Mute")

                Slider(
                    value: Binding(
                        get: { Double(audio.volume) },
                        set: { audio.setVolume(Float($0)) }
                    ),
                    in: 0...1
                )
                .disabled(!audio.canSetVolume)
            }

            if !audio.canSetVolume {
                Text("This output has no software volume. Use the volume control on the device itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("Output")
                .font(.headline)

            if audio.outputDevices.isEmpty {
                Text("No output devices found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(audio.outputDevices) { device in
                        deviceRow(device)
                    }
                }
            }
        }
    }

    private func deviceRow(_ device: AudioOutputDevice) -> some View {
        Button {
            audio.selectOutput(device)
        } label: {
            HStack {
                Text(device.name)
                    .lineLimit(1)
                Spacer()
                if device.id == audio.defaultDeviceID {
                    Image(systemName: "checkmark")
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }
}
