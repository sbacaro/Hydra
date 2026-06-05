// Hydra Audio — GPL-3.0
// Per-app capture via Core Audio process taps (Phase 3, macOS 14.4+ API).
//
// One grid node per APP, not per process: browsers spawn several helper
// processes sharing (a variant of) the app's bundle ID, so processes are
// grouped under a canonical bundle ID (".helper…" suffixes stripped) and the
// tap mixes ALL of the group's processes. When the process set changes (a
// helper spawns/dies) the tap is rebuilt transparently.
//
// Volume compensation: process taps deliver audio post output-volume, so the
// capture level would follow the system volume knob. The manager watches the
// default output device's volume and applies the inverse gain (clamped) to
// every tap, keeping the captured level constant.
//
// Captured apps persist by canonical bundle ID → relaunch re-binds (§7.8).
// Capture requires TCC consent (NSAudioCaptureUsageDescription embedded).

import Foundation
import CoreAudio
import Accelerate
import AppKit
import HydraCore

// MARK: - AppTap: one captured app (possibly many processes)

final class AppTap: EngineTap {
    let nodeID: String
    let appName: String
    /// Process objects included in the tap (to detect membership changes).
    let objectSet: Set<AudioObjectID>
    let inChannels: Int = Hydra.appTapChannels
    let outChannels: Int = 0
    let inRing: ChannelRing?
    let outRing: ChannelRing? = nil
    let inStaging: UnsafeMutablePointer<Float>?
    let outStaging: UnsafeMutablePointer<Float>? = nil

    /// Fixed makeup undoing the tap's stereo-mixdown attenuation, so captures
    /// sit at the same level as soundcard routing. Calibration constant:
    /// Hydra.appTapMakeupDB. (Tap level does NOT follow the volume knob, so
    /// no dynamic compensation is applied.)
    var makeupGain: Float = Gain.linear(fromDecibels: Hydra.appTapMakeupDB)

    private let procScratch: UnsafeMutablePointer<Float>
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?

    init?(nodeID: String, name: String, processObjects: [AudioObjectID], engineRate: Double) {
        self.nodeID = nodeID
        self.appName = name
        self.objectSet = Set(processObjects)

        let channels = Hydra.appTapChannels
        procScratch = .allocate(capacity: Hydra.maxIOFrames * channels)
        procScratch.initialize(repeating: 0, count: Hydra.maxIOFrames * channels)
        let staging = UnsafeMutablePointer<Float>.allocate(capacity: Hydra.maxIOFrames * channels)
        staging.initialize(repeating: 0, count: Hydra.maxIOFrames * channels)
        inStaging = staging

        // 1. Tap: stereo mixdown of the app's processes, private, audible.
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.name = "Hydra tap: \(name)"
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.unmuted

        var tap: AudioObjectID = 0
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != 0 else {
            log("App tap \"\(name)\": AudioHardwareCreateProcessTap failed (\(status)) — check audio-capture permission (TCC)")
            EventCenter.shared.emit(.error, "Could not capture \(name). Check System Settings → Privacy & Security → Screen & System Audio Recording.")
            procScratch.deallocate()
            staging.deallocate()
            inRing = nil
            return nil
        }
        tapID = tap

        // 2. Private aggregate device wrapping the tap (drift-compensated).
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Hydra Tap (\(name))",
            kAudioAggregateDeviceUIDKey: Hydra.internalAggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]
        var aggregate: AudioObjectID = 0
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard status == noErr, aggregate != 0 else {
            log("App tap \"\(name)\": aggregate creation failed (\(status))")
            AudioHardwareDestroyProcessTap(tap)
            procScratch.deallocate()
            staging.deallocate()
            inRing = nil
            return nil
        }
        aggregateID = aggregate

        // 3. Ring: producer = aggregate clock, consumer = engine clock.
        let aggregateRate = BackplaneProbe.nominalSampleRate(aggregate)
        inRing = ChannelRing(channels: channels,
                             producerRate: aggregateRate > 0 ? aggregateRate : engineRate,
                             consumerRate: engineRate)
    }

    deinit {
        stop()
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        inStaging?.deallocate()
        procScratch.deallocate()
    }

    func start() -> Bool {
        guard procID == nil, let ring = inRing else { return procID != nil }
        var pid: AudioDeviceIOProcID?
        let scratch = procScratch
        let channels = inChannels

        let status = AudioDeviceCreateIOProcIDWithBlock(&pid, aggregateID, nil) { [self] _, inputData, _, _, _ in
            let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let frames = ABLUtil.flatten(inList, into: scratch,
                                         totalChannels: channels,
                                         maxFrames: Hydra.maxIOFrames)
            guard frames > 0 else { return }
            // Undo the output-volume attenuation (taps are post-volume).
            var gain = makeupGain
            if gain != 1.0 {
                vDSP_vsmul(scratch, 1, &gain, scratch, 1, vDSP_Length(frames * channels))
            }
            ring.write(from: scratch, frames: frames)
        }
        guard status == noErr, let pid else {
            log("App tap \"\(appName)\": IOProc creation failed (\(status))")
            return false
        }
        guard AudioDeviceStart(aggregateID, pid) == noErr else {
            log("App tap \"\(appName)\": AudioDeviceStart failed")
            AudioDeviceDestroyIOProcID(aggregateID, pid)
            return false
        }
        procID = pid
        log("App capture started: \"\(appName)\" (\(objectSet.count) process(es))")
        return true
    }

    func stop() {
        guard let pid = procID else { return }
        AudioDeviceStop(aggregateID, pid)
        AudioDeviceDestroyIOProcID(aggregateID, pid)
        procID = nil
        log("App capture stopped: \"\(appName)\"")
    }
}

// MARK: - ProcessTapManager

final class ProcessTapManager {

    private let store: MatrixStore
    private let queue = DispatchQueue(label: "hydra.apptaps")
    /// Captured apps persisted by canonical bundle ID.
    private var capturedBundleIDs: Set<String>
    /// Captured pid-only entries (not persisted).
    private var capturedPIDs: Set<Int32> = []
    private var active: [String: AppTap] = [:]   // nodeID → tap
    var onChange: (([AppInfo]) -> Void)?
    /// Current makeup (dB), updated from Settings via setConfig.
    private var makeupDB: Float = Hydra.appTapMakeupDB

    func setMakeup(dB: Float) {
        queue.sync {
            makeupDB = dB
            let linear = Gain.linear(fromDecibels: dB)
            for tap in active.values {
                tap.makeupGain = linear
            }
        }
    }

    private static let persistURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hydra", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("apps.json")
    }()

    init(store: MatrixStore) {
        self.store = store
        if let data = try? Data(contentsOf: Self.persistURL),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            capturedBundleIDs = Set(ids)
        } else {
            capturedBundleIDs = []
        }
    }

    func startMonitoring() {
        var processList = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &processList, queue) { [weak self] _, _ in
            self?.refreshLocked()
        }
        queue.sync { refreshLocked() }
    }

    func setCapture(pid: Int32, captured: Bool) {
        queue.sync {
            guard let group = appGroups().first(where: { $0.pids.contains(pid) }) else { return }
            if let bundleID = group.bundleID {
                if captured { capturedBundleIDs.insert(bundleID) } else { capturedBundleIDs.remove(bundleID) }
                if let data = try? JSONEncoder().encode(Array(capturedBundleIDs).sorted()) {
                    try? data.write(to: Self.persistURL, options: .atomic)
                }
            } else {
                if captured { capturedPIDs.formUnion(group.pids) } else { capturedPIDs.subtract(group.pids) }
            }
            refreshLocked()
        }
    }

    func infos() -> [AppInfo] {
        queue.sync { infosLocked() }
    }

    // MARK: Internals (manager queue only)

    /// "com.google.Chrome.helper(.x)" → "com.google.Chrome": helpers group
    /// with their app under one node (fallback when the responsible-process
    /// lookup is unavailable).
    private static func canonicalBundleID(_ raw: String) -> String {
        if let range = raw.range(of: ".helper", options: [.caseInsensitive]) {
            return String(raw[..<range.lowerBound])
        }
        return raw
    }

    /// macOS's "responsible process" lookup: maps helper processes (WebKit
    /// GPU/WebContent, Chrome Helper, …) to the app the user actually knows.
    /// Resolved via dlsym — the symbol is stable but not in the public SDK.
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsiblePID: ResponsibleFn? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFn.self)
    }()

    /// The user-facing app behind a (possibly helper) pid, if resolvable.
    private static func responsibleApp(for pid: Int32) -> NSRunningApplication? {
        guard let fn = responsiblePID else { return nil }
        let rpid = fn(pid_t(pid))
        guard rpid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: rpid)
    }

    private struct RawProcess {
        let object: AudioObjectID
        let pid: Int32
        let bundleID: String?    // canonical
        let name: String
        let isPlaying: Bool
        let isRegularApp: Bool
    }

    private struct AppGroup {
        let bundleID: String?    // canonical (nil → pid-only)
        let name: String
        let pids: [Int32]
        let objects: [AudioObjectID]
        let isPlaying: Bool
        let isRegularApp: Bool
        var nodeID: String { Hydra.appNodeID(bundleID: bundleID, pid: pids.first ?? 0) }
    }

    private func rawProcesses() -> [RawProcess] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &objects) == noErr else { return [] }

        let myPID = ProcessInfo.processInfo.processIdentifier
        return objects.compactMap { object in
            guard let pid: Int32 = processProperty(object, kAudioProcessPropertyPID),
                  pid != myPID else { return nil }
            let rawBundle: String? = processStringProperty(object, kAudioProcessPropertyBundleID)
            let playing: Int32 = processProperty(object, kAudioProcessPropertyIsRunningOutput) ?? 0
            let runningApp = NSRunningApplication(processIdentifier: pid_t(pid))

            // Commercial identity: prefer the responsible app (Safari behind
            // WebKit GPU, Google Chrome behind its helpers), then the helper
            // suffix strip, then the raw bundle.
            let responsible = Self.responsibleApp(for: pid)
            let bundleID: String? = responsible?.bundleIdentifier
                ?? rawBundle.flatMap { $0.isEmpty ? nil : Self.canonicalBundleID($0) }
            let name = responsible?.localizedName
                ?? runningApp?.localizedName
                ?? bundleID?.components(separatedBy: ".").last
                ?? "pid \(pid)"
            let isRegular = responsible?.activationPolicy == .regular
                || runningApp?.activationPolicy == .regular
            return RawProcess(object: object, pid: pid, bundleID: bundleID, name: name,
                              isPlaying: playing != 0,
                              isRegularApp: isRegular)
        }
    }

    private func appGroups() -> [AppGroup] {
        var byBundle: [String: [RawProcess]] = [:]
        var pidOnly: [RawProcess] = []
        for proc in rawProcesses() {
            if let bundleID = proc.bundleID {
                byBundle[bundleID, default: []].append(proc)
            } else {
                pidOnly.append(proc)
            }
        }

        var groups: [AppGroup] = byBundle.map { bundleID, members in
            // Prefer the real app's display name over a helper's.
            let displayName = NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == bundleID }?.localizedName
                ?? members.first(where: { $0.isRegularApp })?.name
                ?? members[0].name
            return AppGroup(bundleID: bundleID,
                            name: displayName,
                            pids: members.map(\.pid).sorted(),
                            objects: members.map(\.object),
                            isPlaying: members.contains { $0.isPlaying },
                            isRegularApp: members.contains { $0.isRegularApp })
        }
        groups.append(contentsOf: pidOnly.map {
            AppGroup(bundleID: nil, name: $0.name, pids: [$0.pid], objects: [$0.object],
                     isPlaying: $0.isPlaying, isRegularApp: $0.isRegularApp)
        })
        return groups
    }

    private func isCaptured(_ group: AppGroup) -> Bool {
        if let bundleID = group.bundleID { return capturedBundleIDs.contains(bundleID) }
        return group.pids.contains { capturedPIDs.contains($0) }
    }

    private func infosLocked() -> [AppInfo] {
        appGroups()
            // Show real apps always; everything else only while playing or captured.
            .filter { $0.isRegularApp || $0.isPlaying || isCaptured($0) }
            .map { AppInfo(pid: $0.pids.first ?? 0, bundleID: $0.bundleID, name: $0.name,
                           isPlaying: $0.isPlaying, captured: isCaptured($0)) }
            .sorted {
                if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private func refreshLocked() {
        let groups = appGroups()
        let engineRate = BackplaneProbe.backplaneDeviceID()
            .map(BackplaneProbe.nominalSampleRate) ?? Hydra.defaultSampleRate

        let wanted = groups.filter { isCaptured($0) }
        let wantedByNode = Dictionary(uniqueKeysWithValues: wanted.map { ($0.nodeID, $0) })

        // Drop taps for apps that quit / were un-captured, and taps whose
        // process set changed (helper spawned or died) — those are rebuilt.
        for (nodeID, tap) in active {
            let group = wantedByNode[nodeID]
            if group == nil || Set(group!.objects) != tap.objectSet {
                tap.stop()
                active.removeValue(forKey: nodeID)
            }
        }
        // Create/rebuild taps.
        for (nodeID, group) in wantedByNode where active[nodeID] == nil {
            if let tap = AppTap(nodeID: nodeID, name: group.name,
                                processObjects: group.objects, engineRate: engineRate),
               tap.start() {
                tap.makeupGain = Gain.linear(fromDecibels: makeupDB)
                active[nodeID] = tap
            }
        }

        store.setAppTaps(active.values.sorted { $0.nodeID < $1.nodeID })
        onChange?(infosLocked())
    }

    // MARK: Property helpers

    private func processProperty<T: FixedWidthInteger>(_ object: AudioObjectID,
                                                       _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func processStringProperty(_ object: AudioObjectID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }
}
