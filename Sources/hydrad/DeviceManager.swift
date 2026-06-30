// Hydra Audio — GPL-3.0
// Physical devices in the grid (Phase 2b). Every connected interface can be
// opted into the grid; each used+present device gets its own IOProc whose
// audio crosses clock domains through ChannelRings (consumer-side ASRC).
// Used devices are persisted by UID, so the patch re-binds automatically
// when a device returns (Section 7.8).

import Foundation
import CoreAudio
import HydraCore
import HydraRT

// MARK: - DeviceIO: one opted-in, present device

final class DeviceIO {
    let uid: String
    let name: String
    let deviceID: AudioObjectID
    let inChannels: Int
    let outChannels: Int
    let sampleRate: Double
    /// Capture the input WITHOUT driving the output — the engine opens an
    /// input-only IOProc (disables this proc's output streams). Set for a device a
    /// capture flow reads as its source: a loopback/bridge device (e.g. "Pro Tools
    /// Audio Bridge") goes silent if a second client also writes its output, so we
    /// stay a pure capture client — exactly what Audio Hijack does.
    let captureInputOnly: Bool
    /// Grid node id. Generic physical devices use `dev:<uid>`; Hydra Audio
    /// Bridges pass an explicit `bridge:<id>` so they read as first-class nodes.
    private let nodeIDOverride: String?
    var nodeID: String { nodeIDOverride ?? Hydra.deviceNodeID(uid: uid) }

    /// Device clock → engine clock (read by the engine's IOProc).
    let inRing: ChannelRing?
    /// Engine clock → device clock (read by this device's IOProc).
    let outRing: ChannelRing?
    /// Engine-side staging (written/read only inside the engine IOProc).
    let inStaging: UnsafeMutablePointer<Float>?
    let outStaging: UnsafeMutablePointer<Float>?
    /// Device-thread scratch for ABL flatten/distribute.
    private let procInScratch: UnsafeMutablePointer<Float>?
    private let procOutScratch: UnsafeMutablePointer<Float>?

    private var procID: AudioDeviceIOProcID?

    init(uid: String, name: String, deviceID: AudioObjectID,
         inChannels: Int, outChannels: Int,
         sampleRate: Double, engineRate: Double, nodeID: String? = nil,
         captureInputOnly: Bool = false) {
        self.uid = uid
        self.name = name
        self.deviceID = deviceID
        self.inChannels = inChannels
        self.outChannels = outChannels
        self.sampleRate = sampleRate
        self.nodeIDOverride = nodeID
        self.captureInputOnly = captureInputOnly

        if inChannels > 0 {
            inRing = ChannelRing(channels: inChannels,
                                 producerRate: sampleRate, consumerRate: engineRate)
            inStaging = .allocate(capacity: Hydra.maxIOFrames * inChannels)
            inStaging?.initialize(repeating: 0, count: Hydra.maxIOFrames * inChannels)
            procInScratch = .allocate(capacity: Hydra.maxIOFrames * inChannels)
        } else {
            inRing = nil; inStaging = nil; procInScratch = nil
        }
        if outChannels > 0 {
            outRing = ChannelRing(channels: outChannels,
                                  producerRate: engineRate, consumerRate: sampleRate)
            outStaging = .allocate(capacity: Hydra.maxIOFrames * outChannels)
            outStaging?.initialize(repeating: 0, count: Hydra.maxIOFrames * outChannels)
            procOutScratch = .allocate(capacity: Hydra.maxIOFrames * outChannels)
        } else {
            outRing = nil; outStaging = nil; procOutScratch = nil
        }
    }

    deinit {
        stop()
        inStaging?.deallocate()
        outStaging?.deallocate()
        procInScratch?.deallocate()
        procOutScratch?.deallocate()
    }

    func start() -> Bool {
        guard procID == nil else { return true }
        var pid: AudioDeviceIOProcID?
        let inRing = self.inRing
        let outRing = self.outRing
        let inScratch = self.procInScratch
        let outScratch = self.procOutScratch
        let inChans = self.inChannels
        let outChans = self.outChannels
        // Input-only: never touch the device's output (don't even write silence) —
        // combined with disabling this proc's output streams below, the engine is a
        // pure capture client, like Audio Hijack.
        let inputOnly = self.captureInputOnly
        // Diagnostic (capture devices only): log the input level every ~2 s so we
        // can see whether the device is actually delivering audio to Hydra.
        let diagName = self.name
        var diagFrames = 0
        var diagPeak: Float = 0

        let status = AudioDeviceCreateIOProcIDWithBlock(&pid, deviceID, nil) { _, inputData, _, outputData, _ in
            // Device clock domain. Capture: flatten → ring.
            if let inRing, let inScratch {
                let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
                let frames = ABLUtil.flatten(inList, into: inScratch,
                                             totalChannels: inChans,
                                             maxFrames: Hydra.maxIOFrames)
                if frames > 0 {
                    inRing.write(from: inScratch, frames: frames)
                    if inputOnly {
                        let n = frames * inChans
                        var p: Float = 0
                        for k in 0..<n { let v = abs(inScratch[k]); if v > p { p = v } }
                        if p > diagPeak { diagPeak = p }
                        diagFrames += frames
                        if diagFrames >= 96_000 {
                            let db = 20 * log10(max(diagPeak, 1e-7))
                            log(String(format: "Capture \"%@\": input %.1f dBFS", diagName, db))
                            diagFrames = 0; diagPeak = 0
                        }
                    }
                }
            }
            guard !inputOnly else { return }
            // Playback: ring (resampled to this device's clock) → ABL.
            let outList = UnsafeMutableAudioBufferListPointer(outputData)
            for buffer in outList {
                if let raw = buffer.mData {
                    memset(raw, 0, Int(buffer.mDataByteSize))
                }
            }
            if let outRing, let outScratch {
                let frames = min(ABLUtil.frameCount(outList), Hydra.maxIOFrames)
                if frames > 0 {
                    outRing.readResampled(into: outScratch, frames: frames)
                    ABLUtil.distribute(outScratch, frames: frames,
                                       totalChannels: outChans, into: outList)
                }
            }
        }
        guard status == noErr, let pid else {
            log("Device \"\(name)\": IOProc creation failed (\(status))")
            return false
        }
        // Make this proc an input-only client so our silence never mixes into (and,
        // on some loopback devices, erases) what another app feeds the input.
        if captureInputOnly {
            Self.setOutputStreamsDisabled(deviceID: deviceID, proc: pid)
        }
        guard AudioDeviceStart(deviceID, pid) == noErr else {
            log("Device \"\(name)\": AudioDeviceStart failed")
            AudioDeviceDestroyIOProcID(deviceID, pid)
            return false
        }
        procID = pid
        log("Device attached: \"\(name)\" — \(inChannels) in / \(outChannels) out @ \(Int(sampleRate)) Hz\(captureInputOnly ? " (input-only capture)" : "")")
        EventCenter.shared.emit(.resourceRestored, "\(name) connected — patch re-bound.")
        return true
    }

    func stop() {
        guard let pid = procID else { return }
        AudioDeviceStop(deviceID, pid)
        AudioDeviceDestroyIOProcID(deviceID, pid)
        procID = nil
        log("Device detached: \"\(name)\"")
        EventCenter.shared.emit(.resourceLost, "\(name) disconnected — its patch will re-bind when it returns.")
    }

    /// Turn OFF every output stream for `proc` via kAudioDevicePropertyIOProcStreamUsage,
    /// so this IOProc is an input-only client and never contributes to the device's
    /// output mix. Struct: { void* mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[]; }.
    /// IMPORTANT: the struct's `mIOProc` identifies which IOProc is being queried/set,
    /// so it MUST be filled in before BOTH the Get and the Set — otherwise the call
    /// silently no-ops and the engine stays an output client (clobbering loopbacks).
    private static func setOutputStreamsDisabled(deviceID: AudioObjectID, proc: AudioDeviceIOProcID) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOProcStreamUsage,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<UInt>.alignment)
        defer { raw.deallocate() }
        let procPtr = unsafeBitCast(proc, to: UnsafeMutableRawPointer?.self)
        // Identify the proc BEFORE querying its current stream usage.
        raw.assumingMemoryBound(to: UnsafeMutableRawPointer?.self).pointee = procPtr
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, raw) == noErr else {
            log("Device input-only: could not read IOProc stream usage")
            return
        }
        // Re-assert the proc (the Get may have cleared it), then turn every output stream off.
        raw.assumingMemoryBound(to: UnsafeMutableRawPointer?.self).pointee = procPtr
        let countOffset = MemoryLayout<UnsafeMutableRawPointer?>.stride
        let n = raw.load(fromByteOffset: countOffset, as: UInt32.self)
        let flags = raw.advanced(by: countOffset + MemoryLayout<UInt32>.stride)
                       .assumingMemoryBound(to: UInt32.self)
        for i in 0..<Int(n) { flags[i] = 0 }
        let result = AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, raw)
        if result != noErr {
            log("Device input-only: could not disable output streams (\(result)) — capture may still drive output")
        } else {
            log("Device input-only: disabled \(n) output stream(s) for capture IOProc")
        }
    }
}

extension DeviceIO: EngineTap {}

// MARK: - DeviceManager

// @unchecked Sendable: all mutable state is confined to the serial `queue`
// (matches BridgeManager). Lets the queue.async capture self without a warning.
final class DeviceManager: @unchecked Sendable {

    private let store: MatrixStore
    private let queue = DispatchQueue(label: "hydra.devices")
    private var usedUIDs: Set<String>
    /// Device UIDs a capture flow reads as a SOURCE — opened input-only (we don't
    /// drive their output) so loopback/bridge devices aren't disturbed. Driven by
    /// RouteManager; does not change behaviour for any other device.
    private var captureOnlyUIDs: Set<String> = []
    private var active: [String: DeviceIO] = [:]
    /// Called (on the manager queue) after every refresh with the fresh
    /// device list — broadcast hook. Receives the list directly so the
    /// callback never re-enters the manager queue (that would deadlock).
    var onChange: (([PhysicalDeviceInfo]) -> Void)?

    private static let persistURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hydra", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("devices.json")
    }()

    init(store: MatrixStore) {
        self.store = store
        if let data = try? Data(contentsOf: Self.persistURL),
           let uids = try? JSONDecoder().decode([String].self, from: data) {
            usedUIDs = Set(uids)
        } else {
            usedUIDs = []
        }
    }

    func startMonitoring() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue) { [weak self] _, _ in
            self?.refreshLocked()
        }
        queue.sync { refreshLocked() }
    }

    func setUse(uid: String, used: Bool) {
        queue.sync {
            if used { usedUIDs.insert(uid) } else { usedUIDs.remove(uid) }
            if let data = try? JSONEncoder().encode(Array(usedUIDs).sorted()) {
                try? data.write(to: Self.persistURL, options: .atomic)
            }
            refreshLocked()
        }
    }

    /// Devices that capture flows read as a source — captured input-only. When the
    /// set changes, re-open the affected IOProcs in the right mode.
    func setCaptureOnly(_ uids: Set<String>) {
        queue.async { [weak self] in
            guard let self, uids != self.captureOnlyUIDs else { return }
            self.captureOnlyUIDs = uids
            self.refreshLocked()
        }
    }

    /// All known devices: present ones, plus used-but-absent ones (so the UI
    /// can show that their patch is waiting to re-bind).
    func infos() -> [PhysicalDeviceInfo] {
        queue.sync { infosLocked() }
    }

    // MARK: Internals (manager queue only)

    private struct Present {
        let uid: String
        let name: String
        let id: AudioObjectID
        let inChannels: Int
        let outChannels: Int
        let sampleRate: Double
    }

    private func presentDevices() -> [Present] {
        BackplaneProbe.allDeviceIDs().compactMap { id in
            guard let name = BackplaneProbe.deviceName(id),
                  name != Hydra.backplaneDeviceName,
                  let uid = BackplaneProbe.deviceUID(id),
                  // Hydra's own tap plumbing (private aggregates) is not a
                  // user-facing device.
                  !uid.hasPrefix(Hydra.internalAggregateUIDPrefix),
                  // Hydra Audio Bridges are first-class nodes (BridgeManager),
                  // not generic physical devices — keep them out of this list.
                  !Hydra.isBridgeUID(uid),
                  !name.hasPrefix("Hydra Tap (") else { return nil }
            let inCh = BackplaneProbe.channelCount(id, scope: kAudioDevicePropertyScopeInput)
            let outCh = BackplaneProbe.channelCount(id, scope: kAudioDevicePropertyScopeOutput)
            guard inCh > 0 || outCh > 0,
                  inCh <= Hydra.maxDeviceChannels, outCh <= Hydra.maxDeviceChannels else { return nil }
            return Present(uid: uid, name: name, id: id,
                           inChannels: inCh, outChannels: outCh,
                           sampleRate: BackplaneProbe.nominalSampleRate(id))
        }
    }

    private func infosLocked() -> [PhysicalDeviceInfo] {
        let present = presentDevices()
        var infos = present.map {
            PhysicalDeviceInfo(uid: $0.uid, name: $0.name,
                               inputChannels: $0.inChannels, outputChannels: $0.outChannels,
                               sampleRate: $0.sampleRate,
                               used: usedUIDs.contains($0.uid), present: true)
        }
        let presentUIDs = Set(present.map(\.uid))
        for uid in usedUIDs.subtracting(presentUIDs) {
            infos.append(PhysicalDeviceInfo(uid: uid, name: active[uid]?.name ?? uid,
                                            inputChannels: 0, outputChannels: 0,
                                            sampleRate: 0, used: true, present: false))
        }
        return infos.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func refreshLocked() {
        let present = presentDevices()
        let engineRate = BackplaneProbe.backplaneDeviceID()
            .map(BackplaneProbe.nominalSampleRate) ?? Hydra.defaultSampleRate
        let wanted = present.filter { usedUIDs.contains($0.uid) }
        let wantedUIDs = Set(wanted.map(\.uid))
        // A device is opened input-only only when a capture flow uses it as a
        // source AND it actually has an input to capture.
        func inputOnly(_ dev: Present) -> Bool {
            captureOnlyUIDs.contains(dev.uid) && dev.inChannels > 0
        }

        // Detach: no longer wanted, unplugged, OR its input-only mode flipped
        // (a flow started/stopped using it as a source) — rebuild the IOProc.
        for (uid, io) in active {
            let desiredInputOnly = present.first { $0.uid == uid }.map(inputOnly) ?? io.captureInputOnly
            if !wantedUIDs.contains(uid) || io.captureInputOnly != desiredInputOnly {
                io.stop()
                active.removeValue(forKey: uid)
            }
        }
        // Attach new ones.
        for dev in wanted where active[dev.uid] == nil {
            let io = DeviceIO(uid: dev.uid, name: dev.name, deviceID: dev.id,
                              inChannels: dev.inChannels, outChannels: dev.outChannels,
                              sampleRate: dev.sampleRate, engineRate: engineRate,
                              captureInputOnly: inputOnly(dev))
            if io.start() {
                active[dev.uid] = io
            }
        }

        // Rebind the matrix to the new device set (atomic snapshot swap).
        store.setDeviceTaps(active.values.sorted { $0.uid < $1.uid })
        onChange?(infosLocked())
    }
}
