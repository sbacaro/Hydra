// Hydra Audio — GPL-3.0
// DeviceOutputTap — captures the audio APPS PLAY TO a device's output, via a
// Core Audio process tap bound to that device (macOS 14.4+) wrapped in a private
// aggregate device — the same mechanism Loopback / Audio Hijack use. This is what
// makes a third-party loopback/bridge device (e.g. "Pro Tools Audio Bridge")
// capturable: its OUTPUT carries the audio, while its input is silent.
//
// Surfaces as a `captap:<uid>` source node in the engine, so a capture flow can
// route it onward (e.g. to a Hydra bridge or an interface).

import Foundation
import CoreAudio
import HydraCore
import HydraRT

final class DeviceOutputTap: EngineTap {
    let nodeID: String
    let deviceUID: String
    let deviceName: String
    /// Real width of the tapped device output (queried from the aggregate).
    private(set) var inChannels: Int = 2
    let outChannels: Int = 0
    private(set) var inRing: ChannelRing? = nil
    let outRing: ChannelRing? = nil
    private(set) var inStaging: UnsafeMutablePointer<Float>? = nil
    let outStaging: UnsafeMutablePointer<Float>? = nil

    private var procScratch: UnsafeMutablePointer<Float>? = nil   // full aggregate width
    private var tapScratch: UnsafeMutablePointer<Float>? = nil    // gathered tap channels
    /// Full input width of the aggregate (clock sub-device inputs + tap channels).
    private var totalInputChannels: Int = 2
    /// Where the tap's channels begin in the flattened aggregate input (the clock
    /// sub-device's input channels come first).
    private var tapOffset: Int = 0
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?

    init?(deviceUID: String, deviceName: String, engineRate: Double) {
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.nodeID = Hydra.captureTapNodeID(uid: deviceUID)

        // 1. Tap THIS DEVICE's output specifically: only the audio apps play TO
        //    `deviceUID`, independent of the Mac's default output device. That is
        //    what lets Pro Tools keep "Pro Tools Audio Bridge 2-A" as its output
        //    bus while the system default stays on the speakers — capture with no
        //    doubling and no need to switch the system output.
        //
        //    A *global* system tap (the fallback below) instead captures whatever
        //    the default output is mixing, so it only "works" when the system
        //    output IS the playback device — which doubles the audio. We fall back
        //    to it only if the device-bound tap can't be created on this OS.
        let description: CATapDescription
        var tap: AudioObjectID = 0

        let deviceDescription = Self.makeDeviceTap(deviceUID: deviceUID)
        deviceDescription.name = "Hydra capture: \(deviceName)"
        deviceDescription.isPrivate = true
        deviceDescription.muteBehavior = CATapMuteBehavior.unmuted
        var status = AudioHardwareCreateProcessTap(deviceDescription, &tap)

        if status == noErr, tap != 0 {
            description = deviceDescription
            log("Capture tap \"\(deviceName)\": device-bound tap created for \(deviceUID)")
        } else {
            log("Capture tap \"\(deviceName)\": device-bound tap failed (\(status)) — falling back to global system tap")
            let exclude = Self.currentProcessObject().map { [$0] } ?? [AudioObjectID]()
            let global = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
            global.name = "Hydra capture (global): \(deviceName)"
            global.isPrivate = true
            global.muteBehavior = CATapMuteBehavior.unmuted
            status = AudioHardwareCreateProcessTap(global, &tap)
            guard status == noErr, tap != 0 else {
                log("Capture tap \"\(deviceName)\": AudioHardwareCreateProcessTap failed (\(status)) — check audio-capture permission (TCC)")
                EventCenter.shared.emit(.error, "Could not capture \(deviceName). Check System Settings → Privacy & Security → Screen & System Audio Recording.")
                return nil
            }
            description = global
        }
        tapID = tap

        // 2. Private aggregate device wrapping the tap (drift-compensated).
        //    CRITICAL: a device-bound tap delivers ZERO samples unless the
        //    aggregate has a REAL device as its main sub-device (the clock).
        //    We clock on the TAPPED device itself: it shares the tap's clock
        //    (no drift → the ring runs its cheap unity path, not polyphase) and
        //    Hydra never uses it for output, so there's no IO contention with the
        //    flow's destination. Fall back to any 0-input output device if the
        //    tapped device can't be aggregated.
        func aggregateDict(clockUID: String) -> [String: Any] {
            [
                kAudioAggregateDeviceNameKey: "Hydra Capture (\(deviceName))",
                kAudioAggregateDeviceUIDKey: Hydra.internalAggregateUIDPrefix + UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: clockUID,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID]],
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapUIDKey: description.uuid.uuidString,
                     kAudioSubTapDriftCompensationKey: true]
                ]
            ]
        }
        var aggregate: AudioObjectID = 0
        status = AudioHardwareCreateAggregateDevice(aggregateDict(clockUID: deviceUID) as CFDictionary, &aggregate)
        if status == noErr, aggregate != 0 {
            log("Capture tap \"\(deviceName)\": aggregate clocked by tapped device \(deviceUID)")
        } else if let alt = Self.clockDeviceUID(excludingUID: deviceUID) {
            log("Capture tap \"\(deviceName)\": tapped-device clock failed (\(status)) — falling back to \(alt)")
            status = AudioHardwareCreateAggregateDevice(aggregateDict(clockUID: alt) as CFDictionary, &aggregate)
        }
        guard status == noErr, aggregate != 0 else {
            log("Capture tap \"\(deviceName)\": aggregate creation failed (\(status))")
            AudioHardwareDestroyProcessTap(tap)
            return nil
        }
        aggregateID = aggregate

        // 3. Work out where the tap's channels live in the aggregate's input. The
        //    clock sub-device's input channels (silent, on the PT bridge) come
        //    first; the tap (= the device's OUTPUT width) follows. So we read the
        //    full width but expose only the tap channels (offset = total − tap).
        let total = max(1, min(BackplaneProbe.channelCount(aggregate, scope: kAudioDevicePropertyScopeInput),
                               Hydra.backplaneChannels))
        let tapWidth: Int = {
            if let devID = BackplaneProbe.deviceID(forUID: deviceUID) {
                let w = BackplaneProbe.channelCount(devID, scope: kAudioDevicePropertyScopeOutput)
                if w > 0 { return min(w, total) }
            }
            return total
        }()
        let channels = max(1, tapWidth)
        let offset = max(0, total - channels)
        totalInputChannels = total
        tapOffset = offset
        inChannels = channels

        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: Hydra.maxIOFrames * total)
        scratch.initialize(repeating: 0, count: Hydra.maxIOFrames * total)
        procScratch = scratch
        let gather = UnsafeMutablePointer<Float>.allocate(capacity: Hydra.maxIOFrames * channels)
        gather.initialize(repeating: 0, count: Hydra.maxIOFrames * channels)
        tapScratch = gather
        let staging = UnsafeMutablePointer<Float>.allocate(capacity: Hydra.maxIOFrames * channels)
        staging.initialize(repeating: 0, count: Hydra.maxIOFrames * channels)
        inStaging = staging

        let aggregateRate = BackplaneProbe.nominalSampleRate(aggregate)
        inRing = ChannelRing(channels: channels,
                             producerRate: aggregateRate > 0 ? aggregateRate : engineRate,
                             consumerRate: engineRate)
        log("Capture tap \"\(deviceName)\": tapping device output — \(channels) ch "
            + "(aggregate input \(total) ch, tap offset \(offset), rate \(Int(aggregateRate)) Hz)")
    }

    deinit {
        stop()
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        inStaging?.deallocate()
        procScratch?.deallocate()
        tapScratch?.deallocate()
    }

    func start() -> Bool {
        guard procID == nil, let ring = inRing,
              let scratch = procScratch, let gather = tapScratch else { return procID != nil }
        var pid: AudioDeviceIOProcID?
        let channels = inChannels            // tap channels (what the engine sees)
        let total = totalInputChannels       // full aggregate input width
        let offset = tapOffset               // where the tap channels start
        let nm = deviceName
        var diagFrames = 0
        var diagPeak: Float = 0

        let status = AudioDeviceCreateIOProcIDWithBlock(&pid, aggregateID, nil) { _, inputData, _, _, _ in
            let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let frames = ABLUtil.flatten(inList, into: scratch,
                                         totalChannels: total, maxFrames: Hydra.maxIOFrames)
            guard frames > 0 else { return }
            // Gather just the tap's channels (they sit after the clock sub-device's
            // input channels) into a tight `channels`-wide buffer for the ring.
            var f = 0
            while f < frames {
                let s = f * total + offset
                let d = f * channels
                var c = 0
                while c < channels { gather[d + c] = scratch[s + c]; c += 1 }
                f += 1
            }
            let n = frames * channels
            // Diagnostic: log the captured level every ~10 s.
            var p: Float = 0
            for k in 0..<n { let v = abs(gather[k]); if v > p { p = v } }
            if p > diagPeak { diagPeak = p }
            diagFrames += frames
            if diagFrames >= 480_000 {
                log(String(format: "Capture tap \"%@\": output %.1f dBFS", nm, 20 * log10(max(diagPeak, 1e-7))))
                diagFrames = 0; diagPeak = 0
            }
            ring.write(from: gather, frames: frames)
        }
        guard status == noErr, let pid else {
            log("Capture tap \"\(deviceName)\": IOProc creation failed (\(status))")
            return false
        }
        guard AudioDeviceStart(aggregateID, pid) == noErr else {
            log("Capture tap \"\(deviceName)\": AudioDeviceStart failed")
            AudioDeviceDestroyIOProcID(aggregateID, pid)
            return false
        }
        procID = pid
        log("Capture tap started: \"\(deviceName)\" — \(channels) ch")
        return true
    }

    func stop() {
        guard let pid = procID else { return }
        AudioDeviceStop(aggregateID, pid)
        AudioDeviceDestroyIOProcID(aggregateID, pid)
        procID = nil
    }

    /// A real, 0-input OUTPUT device to clock the capture aggregate. A device-bound
    /// tap yields no samples without a real main sub-device; a 0-input device keeps
    /// the tap's channels at input offset 0. Skips the tapped device and internals.
    private static func clockDeviceUID(excludingUID: String) -> String? {
        var candidates: [(uid: String, builtIn: Bool)] = []
        for id in BackplaneProbe.allDeviceIDs() {
            guard let uid = BackplaneProbe.deviceUID(id), uid != excludingUID,
                  !uid.hasPrefix(Hydra.internalAggregateUIDPrefix) else { continue }
            let ins = BackplaneProbe.channelCount(id, scope: kAudioDevicePropertyScopeInput)
            let outs = BackplaneProbe.channelCount(id, scope: kAudioDevicePropertyScopeOutput)
            guard ins == 0, outs > 0 else { continue }
            candidates.append((uid, Self.transportType(id) == kAudioDeviceTransportTypeBuiltIn))
        }
        // Prefer the built-in output (Mac speakers) — a stable, always-present clock.
        return candidates.first(where: { $0.builtIn })?.uid ?? candidates.first?.uid
    }

    private static func transportType(_ id: AudioObjectID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t)
        return t
    }

    /// A tap bound to a specific device's first output stream — captures only the
    /// audio apps play TO `deviceUID`, regardless of the system default output.
    /// Passes every process object (minus Hydra) so it captures *all* audio that
    /// reaches the device, not just one app.
    private static func makeDeviceTap(deviceUID: String) -> CATapDescription {
        let mine = currentProcessObject()
        let processes = allProcessObjects().filter { mine == nil || $0 != mine! }
        return CATapDescription(processes: processes,
                                deviceUID: deviceUID,
                                stream: 0)
    }

    /// Every Core Audio process object (macOS 14.4+) for CATapDescription.
    private static func allProcessObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &dataSize, &ids) == noErr else { return [] }
        return ids
    }

    /// The Core Audio process-object for THIS process (Hydra), so we can exclude it
    /// from the system tap and never re-capture our own playback.
    private static func currentProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var obj: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pid) { pidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &obj)
        }
        return status == noErr && obj != 0 ? obj : nil
    }
}
