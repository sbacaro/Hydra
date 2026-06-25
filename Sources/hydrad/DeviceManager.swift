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
         sampleRate: Double, engineRate: Double, nodeID: String? = nil) {
        self.uid = uid
        self.name = name
        self.deviceID = deviceID
        self.inChannels = inChannels
        self.outChannels = outChannels
        self.sampleRate = sampleRate
        self.nodeIDOverride = nodeID

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

        let status = AudioDeviceCreateIOProcIDWithBlock(&pid, deviceID, nil) { _, inputData, _, outputData, _ in
            // Device clock domain. Capture: flatten → ring.
            if let inRing, let inScratch {
                let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
                let frames = ABLUtil.flatten(inList, into: inScratch,
                                             totalChannels: inChans,
                                             maxFrames: Hydra.maxIOFrames)
                if frames > 0 {
                    inRing.write(from: inScratch, frames: frames)
                }
            }
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
        guard AudioDeviceStart(deviceID, pid) == noErr else {
            log("Device \"\(name)\": AudioDeviceStart failed")
            AudioDeviceDestroyIOProcID(deviceID, pid)
            return false
        }
        procID = pid
        log("Device attached: \"\(name)\" — \(inChannels) in / \(outChannels) out @ \(Int(sampleRate)) Hz")
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
}

extension DeviceIO: EngineTap {}

// MARK: - DeviceManager

final class DeviceManager {

    private let store: MatrixStore
    private let queue = DispatchQueue(label: "hydra.devices")
    private var usedUIDs: Set<String>
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

        // Detach: no longer wanted or unplugged.
        for (uid, io) in active where !wantedUIDs.contains(uid) {
            io.stop()
            active.removeValue(forKey: uid)
        }
        // Attach new ones.
        for dev in wanted where active[dev.uid] == nil {
            let io = DeviceIO(uid: dev.uid, name: dev.name, deviceID: dev.id,
                              inChannels: dev.inChannels, outChannels: dev.outChannels,
                              sampleRate: dev.sampleRate, engineRate: engineRate)
            if io.start() {
                active[dev.uid] = io
            }
        }

        // Rebind the matrix to the new device set (atomic snapshot swap).
        store.setDeviceTaps(active.values.sorted { $0.uid < $1.uid })
        onChange?(infosLocked())
    }
}
