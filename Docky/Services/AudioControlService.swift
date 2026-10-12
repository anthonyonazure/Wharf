//
//  AudioControlService.swift
//  Wharf
//
//  System output volume, mute, and output-device switching for the Audio
//  widget. Talks to CoreAudio directly: no permission prompt, no helper app.
//
//  The service listens for changes instead of polling. The volume keys, the
//  menu bar and another app can all move the volume; a widget that only knew
//  its own last write would show a stale number within seconds.
//

import AudioToolbox
import Combine
import CoreAudio
import Foundation

struct AudioOutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
}

@MainActor
final class AudioControlService: ObservableObject {
    static let shared = AudioControlService()

    @Published private(set) var volume: Float = 0
    @Published private(set) var isMuted = false
    /// False for outputs that expose no software volume (many HDMI and
    /// DisplayPort monitors). The widget disables the slider rather than
    /// pretending it works.
    @Published private(set) var canSetVolume = true
    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published private(set) var defaultDeviceID: AudioDeviceID = 0

    private var listener: AudioObjectPropertyListenerBlock?
    private var listenedDevice: AudioDeviceID = 0

    private init() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        listener = block

        var devicesAddress = Self.address(kAudioHardwarePropertyDevices)
        var defaultAddress = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, DispatchQueue.main, block
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddress, DispatchQueue.main, block
        )
        refresh()
    }

    // MARK: - Actions

    func setVolume(_ newValue: Float) {
        let device = defaultDeviceID
        guard device != 0 else { return }
        let clamped = Self.clampedVolume(newValue)
        var value = Float32(clamped)
        var address = Self.address(Self.virtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return }
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        // Dragging the slider up from zero while muted should be audible.
        if clamped > 0, isMuted { setMuted(false) }
        refresh()
    }

    func setMuted(_ muted: Bool) {
        let device = defaultDeviceID
        guard device != 0 else { return }
        var value: UInt32 = muted ? 1 : 0
        var address = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return }
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        refresh()
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    func selectOutput(_ device: AudioOutputDevice) {
        var value = device.id
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &value
        )
        refresh()
    }

    // MARK: - State

    private func refresh() {
        let device = Self.readDefaultOutputDevice()
        if device != defaultDeviceID { defaultDeviceID = device }
        rebindDeviceListener(to: device)

        let readVolume = Self.readVolume(device)
        volume = readVolume ?? 0
        canSetVolume = readVolume != nil && Self.isVolumeSettable(device)
        isMuted = Self.readMuted(device)

        let devices = Self.readOutputDevices()
        if devices != outputDevices { outputDevices = devices }
    }

    /// Volume and mute live on the device, so the listener has to follow the
    /// default output when it changes.
    private func rebindDeviceListener(to device: AudioDeviceID) {
        guard device != listenedDevice, let listener else { return }
        if listenedDevice != 0 {
            for var address in Self.deviceAddresses {
                AudioObjectRemovePropertyListenerBlock(listenedDevice, &address, DispatchQueue.main, listener)
            }
        }
        listenedDevice = device
        guard device != 0 else { return }
        for var address in Self.deviceAddresses {
            AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, listener)
        }
    }

    // MARK: - Pure helpers

    /// Slider value limited to the 0...1 range CoreAudio accepts.
    nonisolated static func clampedVolume(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    // MARK: - CoreAudio reads

    /// `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`, written as its
    /// four-character code ('vmvc') because the named constant is deprecated.
    nonisolated private static let virtualMainVolume = AudioObjectPropertySelector(0x766D_7663)

    nonisolated private static var deviceAddresses: [AudioObjectPropertyAddress] {
        [
            address(virtualMainVolume, scope: kAudioDevicePropertyScopeOutput),
            address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput),
        ]
    }

    nonisolated private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    nonisolated static func readDefaultOutputDevice() -> AudioDeviceID {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr ? device : 0
    }

    nonisolated static func readVolume(_ device: AudioDeviceID) -> Float? {
        guard device != 0 else { return nil }
        var address = address(virtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        // A driver can report NaN or an out-of-range level. Treat that as "no
        // usable volume" rather than letting it reach a number conversion.
        guard value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }

    nonisolated private static func isVolumeSettable(_ device: AudioDeviceID) -> Bool {
        var address = address(virtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    nonisolated static func readMuted(_ device: AudioDeviceID) -> Bool {
        guard device != 0 else { return false }
        var address = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    nonisolated static func readOutputDevices() -> [AudioOutputDevice] {
        var address = address(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasOutputStreams(id), let name = deviceName(id) else { return nil }
            return AudioOutputDevice(id: id, name: name)
        }
    }

    nonisolated private static func hasOutputStreams(_ device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    nonisolated private static func deviceName(_ device: AudioDeviceID) -> String? {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name else { return nil }
        return name.takeRetainedValue() as String
    }
}
