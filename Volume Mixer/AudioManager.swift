import Foundation
import CoreAudio
import AppKit
import Observation

struct MixerRow: Identifiable {
    let id: String
    let name: String
    let iconURL: URL?
    let processes: [AudioObjectID]
    let pids: [pid_t]
    var status = "Direct playback"
    var details = ""
    var failed = false
}

// All resource ownership and process reconciliation happens on one serial queue.
private final class MixerBackend {
    var engines: [String: ProcessAudioEngine] = [:]
    var failures: [String: String] = [:]
    var failedDetails: [String: String] = [:]
    var previous: [String: [AudioObjectID]] = [:]
    var route: OutputRoute?
    var closed = false
    var levels: [String: Double] = [:]
    var muted: Set<String> = []
    var monitored: Set<String> = []
    var bypassed: Set<String> = []

    func gain(_ key: String) -> Float { muted.contains(key) ? 0 : Float(levels[key] ?? 1) }
    func stop(_ key: String) { engines.removeValue(forKey: key)?.stop() }
    func stopAll() { for key in Array(engines.keys) { stop(key) } }

    // Uses the macOS process ID to find the app responsible for playback.
    // Prefer a containing .app for bundled helpers, then a running GUI ancestor.
    func identity(_ pid: pid_t, object: AudioObjectID) -> (String, String, URL?) {
        let app = NSRunningApplication(processIdentifier: pid)
        if let url = app?.bundleURL {
            var outer = url
            var parent = url.deletingLastPathComponent()
            while parent.path.count > 1 {
                if parent.pathExtension == "app" { outer = parent }
                parent = parent.deletingLastPathComponent()
            }
            if (outer != url || app?.activationPolicy == .regular),
               let key = Bundle(url: outer)?.bundleIdentifier {
                let name = outer == url ? app?.localizedName : nil
                return (key, name ?? outer.deletingPathExtension().lastPathComponent, outer)
            }
        }
        var ancestor = MixerParent(pid)
        for _ in 0..<12 {
            guard ancestor > 1 else { break }
            if let owner = NSRunningApplication(processIdentifier: ancestor), owner.activationPolicy == .regular,
               let key = owner.bundleIdentifier { return (key, owner.localizedName ?? key, owner.bundleURL) }
            ancestor = MixerParent(ancestor)
        }
        let bundle = app?.bundleIdentifier ?? (try? HAL.string(object, kAudioProcessPropertyBundleID))
        let key = bundle.flatMap { $0.isEmpty ? nil : $0 } ?? "pid.\(pid)"
        return (key, app?.localizedName ?? bundle ?? "Process \(pid)", app?.bundleURL)
    }

    func discover() throws -> [MixerRow] {
        let objects = try HAL.ids(HAL.system, kAudioHardwarePropertyProcessObjectList)
        var rows: [String: MixerRow] = [:]
        for object in objects {
            guard let pid = try? HAL.read(object, kAudioProcessPropertyPID, pid_t(0)),
                  pid > 0, pid != ProcessInfo.processInfo.processIdentifier,
                  (try? HAL.read(object, kAudioProcessPropertyIsRunningOutput, UInt32(0))) == 1 else { continue }
            let (id, name, url) = identity(pid, object: object)
            let old = rows[id]
            rows[id] = MixerRow(id: id, name: name, iconURL: url,
                                processes: ((old?.processes ?? []) + [object]).sorted(),
                                pids: ((old?.pids ?? []) + [pid]).sorted())
        }
        return rows.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func scan() -> ([MixerRow], String, String?) {
        guard !closed else { return ([], "", nil) }
        do {
            let current = try OutputRoute.current()
            if route != current { stopAll(); failures.removeAll(); route = current }
            var rows = try discover()
            let ids = Set(rows.map(\.id))
            for key in Array(engines.keys) where !ids.contains(key) { stop(key) }
            failures = failures.filter { ids.contains($0.key) }
            failedDetails = failedDetails.filter { ids.contains($0.key) }
            for i in rows.indices {
                let key = rows[i].id
                if previous[key] != rows[i].processes { stop(key); failures[key] = nil }
                do { try update(&rows[i], route: current) }
                catch {
                    failedDetails[key] = rows[i].details
                    stop(key)
                    failures[key] = error.localizedDescription
                }
                if let failure = failures[key] {
                    rows[i].failed = true
                    rows[i].details = failedDetails[key] ?? ""
                    rows[i].status = "Direct playback • \(failure)"
                }
            }
            previous = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.processes) })
            return (rows, current.name, nil)
        } catch {
            stopAll(); route = nil
            return ([], "Output unavailable", error.localizedDescription)
        }
    }

    func create(_ row: MixerRow, _ route: OutputRoute, render: Bool) throws -> ProcessAudioEngine {
        let engine = ProcessAudioEngine(processes: row.processes, route: route, rendering: render)
        try engine.start(gain: gain(row.id))
        engines[row.id] = engine
        return engine
    }

    func update(_ row: inout MixerRow, route: OutputRoute) throws {
        let key = row.id
        guard !bypassed.contains(key), gain(key) < 1 || monitored.contains(key) else {
            stop(key)
            return
        }
        guard failures[key] == nil else { return }
        let engine = try engines[key] ?? create(row, route, render: false)
        let meter = engine.meter
        let now = ProcessInfo.processInfo.systemUptime
        if meter.calls != engine.lastCalls {
            engine.lastCalls = meter.calls
            engine.lastCallbackTime = now
        }
        row.details = "\(Int(route.rate)) Hz • \(route.channels) ch • \(meter.calls) callbacks • \(meter.signals) signal blocks"
        guard meter.faults == 0 else { throw MixerError("Audio buffer layout changed. Retry on a supported output.") }
        guard now-engine.lastCallbackTime < 5 else { throw MixerError("No audio callbacks. Check the output and retry.") }
        if !engine.rendering, meter.signals > 0, gain(key) < 1 {
            stop(key)
            _ = try create(row, route, render: true)
            row.status = "Starting processed playback"
        } else if !engine.rendering || meter.signals == 0 {
            if meter.signals == 0 && now-engine.started > 8 {
                throw MixerError("No signal. Check playback, the output device and System Audio Recording permission.")
            }
            row.status = meter.signals == 0 ? "Waiting for audio" : "Monitoring • \(db(meter.rms))"
        } else {
            row.status = "Mixing • in \(db(meter.rms)) • out \(db(meter.outputRMS))"
        }
    }

    private func db(_ rms: Float) -> String {
        rms > 0 ? String(format: "%.1f dBFS", 20 * log10(rms)) : "silent"
    }
}

@Observable
@MainActor
final class AudioManager {
    var rows: [MixerRow] = []
    var output = "Finding output…"
    var issue: String?
    var appVolumes: [String: Double]
    var muted: Set<String>
    private let queue = DispatchQueue(label: "com.alexpham.VolumeMixer.control")
    private let backend = MixerBackend()
    private var closed = false

    init() {
        appVolumes = (UserDefaults.standard.dictionary(forKey: "levels") as? [String: Double] ?? [:])
            .mapValues { min(1, max(0, $0)) }
        muted = Set(UserDefaults.standard.stringArray(forKey: "muted") ?? [])
        backend.levels = appVolumes
        backend.muted = muted
    }

    func refresh() async {
        guard !closed else { return }
        let result: ([MixerRow], String, String?) = await withCheckedContinuation { continuation in
            queue.async { [backend] in continuation.resume(returning: backend.scan()) }
        }
        guard !closed else { return }
        (rows, output, issue) = result
    }

    func setVolume(_ value: Double, for key: String) {
        appVolumes[key] = min(1, max(0, value))
        muted.remove(key)
        sync(key)
    }
    func toggleMute(_ key: String) {
        if !muted.insert(key).inserted { muted.remove(key) }
        sync(key)
    }
    private func sync(_ key: String) {
        UserDefaults.standard.set(appVolumes, forKey: "levels")
        UserDefaults.standard.set(Array(muted), forKey: "muted")
        let level = appVolumes[key] ?? 1, mute = muted.contains(key)
        queue.async { [backend] in
            backend.levels[key] = level
            if mute { backend.muted.insert(key) } else { backend.muted.remove(key) }
            backend.bypassed.remove(key)
            backend.engines[key]?.setVolume(backend.gain(key))
        }
    }
    func monitor(_ key: String) {
        queue.async { [backend] in
            backend.failures[key] = nil
            backend.bypassed.remove(key)
            backend.monitored.insert(key)
        }
    }
    func bypass(_ key: String) {
        appVolumes[key] = 1
        muted.remove(key)
        sync(key)
        queue.async { [backend] in
            backend.stop(key)
            backend.failures[key] = nil
            backend.bypassed.insert(key)
            backend.monitored.remove(key)
        }
    }
    func shutdown() {
        guard !closed else { return }
        closed = true
        queue.sync { backend.closed = true; backend.stopAll() }
    }
}
