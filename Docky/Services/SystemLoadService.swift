//
//  SystemLoadService.swift
//  Wharf
//
//  Per-app CPU and memory, surfaced on the tiles while a modifier is held.
//
//  Sampling only runs while the modifier is down. A dock that polled every
//  process continuously would burn the CPU it is reporting on.
//

import AppKit
import Combine
import Darwin

struct AppLoadSample: Equatable {
    /// Percent of one core, matching how Activity Monitor reports it, so 150
    /// means an app is using one and a half cores.
    /// nil on an app's first sample: CPU is a rate, and a rate needs two
    /// readings. Reporting 0% there would show a busy app as idle.
    let cpuPercent: Double?
    /// Physical footprint in bytes, the same figure Activity Monitor calls
    /// Memory.
    let memoryBytes: UInt64
}

@MainActor
final class SystemLoadService: ObservableObject {
    static let shared = SystemLoadService()

    /// True while the readout modifier is held down.
    @Published private(set) var isShowingLoad = false

    /// Latest sample per bundle identifier. Empty while not sampling.
    @Published private(set) var samples: [String: AppLoadSample] = [:]

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var sampleTimer: Timer?

    /// Previous CPU time per pid, for turning a monotonically increasing
    /// counter into a rate.
    private var previousCPUTime: [pid_t: (nanos: UInt64, at: Date)] = [:]

    private init() {}

    func start() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in self?.handleFlags(event.modifierFlags) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in self?.handleFlags(event.modifierFlags) }
            return event
        }
    }

    private func handleFlags(_ flags: NSEvent.ModifierFlags) {
        let holdingModifier = flags.contains(.control)
        guard holdingModifier != isShowingLoad else { return }
        isShowingLoad = holdingModifier
        holdingModifier ? beginSampling() : endSampling()
    }

    private func beginSampling() {
        sample()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sampleTimer = timer
    }

    private func endSampling() {
        sampleTimer?.invalidate()
        sampleTimer = nil
        samples.removeAll()
        previousCPUTime.removeAll()
    }

    private func sample() {
        var next: [String: AppLoadSample] = [:]

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isTerminated {
            guard let bundleID = app.bundleIdentifier else { continue }
            guard let usage = usage(for: app.processIdentifier) else { continue }
            next[bundleID] = usage
        }

        samples = next
    }

    /// Reads the kernel's resource usage for a process.
    ///
    /// `proc_pid_rusage` works for processes owned by the same user without
    /// special entitlements, which is the case for everything a user's dock
    /// displays. CPU arrives as cumulative nanoseconds, so a rate needs two
    /// samples and the wall time between them.
    private func usage(for pid: pid_t) -> AppLoadSample? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return nil }

        let totalNanos = info.ri_user_time + info.ri_system_time
        let now = Date()
        var cpuPercent: Double?

        if let previous = previousCPUTime[pid] {
            let elapsed = now.timeIntervalSince(previous.at)
            if elapsed > 0, totalNanos >= previous.nanos {
                let deltaSeconds = Double(totalNanos - previous.nanos) / 1_000_000_000
                cpuPercent = (deltaSeconds / elapsed) * 100
            }
        }
        previousCPUTime[pid] = (totalNanos, now)

        return AppLoadSample(cpuPercent: cpuPercent, memoryBytes: info.ri_phys_footprint)
    }

    /// Formatted for a tile overlay, where there is room for roughly six
    /// characters.
    static func format(_ sample: AppLoadSample) -> String {
        let megabytes = Double(sample.memoryBytes) / 1_048_576
        let memoryText = megabytes >= 1024
            ? String(format: "%.1fG", megabytes / 1024)
            : String(format: "%.0fM", megabytes)
        guard let cpu = sample.cpuPercent else { return "— \(memoryText)" }
        return String(format: "%.0f%% %@", cpu, memoryText)
    }
}
