// Hydra Audio — GPL-3.0
// The engine: one IOProc attached to the backplane. Reads the 256 input
// channels, lets MatrixStore apply the patch matrix, writes the 256 outputs.

import Foundation
import CoreAudio
import Synchronization
import HydraCore

/// Engine metrics shared between the audio IOProc / CoreAudio notification
/// thread and reader properties. Held in a reference type so it can be captured
/// into the escaping IOProc block WITHOUT capturing `AudioEngine` (which would
/// retain it). Backed by `Atomic`, so reads/writes are race-free by the language
/// model — replacing the old hand-allocated `UnsafeMutablePointer` cells.
private final class EngineMetrics: @unchecked Sendable {
    /// Smoothed render-time/cycle-period ratio, stored as the Double bit pattern.
    let loadBits = Atomic<UInt64>(0)
    /// CoreAudio processor-overload count since the engine started.
    let xruns = Atomic<Int>(0)
}

final class AudioEngine {

    private let store: MatrixStore
    private var deviceID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private(set) var isRunning = false

    // Metrics (Phase 7) — written on the audio thread, read anywhere.
    private let metrics = EngineMetrics()
    private var overloadAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDeviceProcessorOverload,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var overloadBlock: AudioObjectPropertyListenerBlock?

    var cpuLoad: Double {
        Double(bitPattern: metrics.loadBits.load(ordering: .relaxed))
    }
    var xruns: Int {
        metrics.xruns.load(ordering: .relaxed)
    }

    init(store: MatrixStore) {
        self.store = store
    }

    /// Attach + start if the backplane is present. Returns true if state changed.
    @discardableResult
    func startIfPossible() -> Bool {
        guard !isRunning else { return false }
        guard let device = BackplaneProbe.backplaneDeviceID() else { return false }

        var pid: AudioDeviceIOProcID?
        let metrics = self.metrics
        var lastStart: UInt64 = 0
        // Signpost the render cycle so XRUN/dropout hunts can be done in
        // Instruments (Points of Interest, subsystem "audio.hydra"). No-op cost
        // when nothing is recording; lock-free + allocation-free otherwise.
        let signposter = HydraSignpost.audio
        let renderID = signposter.makeSignpostID()
        let create = AudioDeviceCreateIOProcIDWithBlock(&pid, device, nil) { [store] _, inputData, _, outputData, _ in
            let begin = mach_absolute_time()
            let interval = signposter.beginInterval("render", id: renderID)
            store.process(inputData, outputData)
            signposter.endInterval("render", interval)
            let end = mach_absolute_time()
            // load = busy time / cycle period (both in mach ticks; the
            // ratio cancels the timebase). Exponential smoothing ~1 s.
            if lastStart != 0, end > begin, begin > lastStart {
                let cycle = Double(begin - lastStart)
                let busy = Double(end - begin)
                let instant = min(busy / cycle, 1)
                let previous = Double(bitPattern: metrics.loadBits.load(ordering: .relaxed))
                metrics.loadBits.store((previous + 0.1 * (instant - previous)).bitPattern,
                                       ordering: .relaxed)
            }
            lastStart = begin
        }
        guard create == noErr, let pid else {
            log("Engine: AudioDeviceCreateIOProcIDWithBlock failed (\(create))")
            return false
        }
        let start = AudioDeviceStart(device, pid)
        guard start == noErr else {
            log("Engine: AudioDeviceStart failed (\(start))")
            AudioDeviceDestroyIOProcID(device, pid)
            return false
        }

        deviceID = device
        procID = pid
        isRunning = true
        metrics.xruns.store(0, ordering: .relaxed)
        metrics.loadBits.store(Double(0).bitPattern, ordering: .relaxed)

        // XRUN counter: CoreAudio posts processor-overload when a cycle missed
        // its deadline. This block is the sole writer of `xruns`, so a plain
        // load+store is correct (no atomic RMW needed).
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            let count = metrics.xruns.load(ordering: .relaxed) + 1
            metrics.xruns.store(count, ordering: .relaxed)
            // Mark the XRUN on the Instruments timeline too, so a dropout can be
            // correlated with whatever the render interval was doing around it.
            signposter.emitEvent("xrun", id: renderID)
            HydraLog.audio.error("Processor overload (XRUN #\(count, privacy: .public))")
        }
        overloadBlock = block
        AudioObjectAddPropertyListenerBlock(device, &overloadAddress, nil, block)

        log("Engine started — IOProc attached to the backplane")
        return true
    }

    /// Stop + detach (e.g. the backplane disappeared). Returns true if state changed.
    @discardableResult
    func stop() -> Bool {
        guard isRunning, let pid = procID else { return false }
        AudioDeviceStop(deviceID, pid)
        AudioDeviceDestroyIOProcID(deviceID, pid)
        if let block = overloadBlock {
            AudioObjectRemovePropertyListenerBlock(deviceID, &overloadAddress, nil, block)
            overloadBlock = nil
        }
        metrics.loadBits.store(Double(0).bitPattern, ordering: .relaxed)
        procID = nil
        deviceID = 0
        isRunning = false
        log("Engine stopped")
        return true
    }
}
