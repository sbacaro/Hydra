// Hydra Audio — GPL-3.0
// The engine: one IOProc attached to the backplane. Reads the 256 input
// channels, lets MatrixStore apply the patch matrix, writes the 256 outputs.

import Foundation
import CoreAudio
import HydraCore

final class AudioEngine {

    private let store: MatrixStore
    private var deviceID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private(set) var isRunning = false

    // Metrics (Phase 7) — written on the audio thread, read anywhere.
    // cpuLoad = smoothed (render time / cycle period); xruns = CoreAudio
    // processor-overload notifications since the engine started.
    private let loadBits = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    private let xrunCount = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private var lastCycleStart: UInt64 = 0
    private var overloadAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDeviceProcessorOverload,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var overloadBlock: AudioObjectPropertyListenerBlock?

    var cpuLoad: Double {
        Double(bitPattern: loadBits.pointee)
    }
    var xruns: Int {
        Int(xrunCount.pointee)
    }

    init(store: MatrixStore) {
        self.store = store
        loadBits.initialize(to: 0)
        xrunCount.initialize(to: 0)
    }

    deinit {
        loadBits.deallocate()
        xrunCount.deallocate()
    }

    /// Attach + start if the backplane is present. Returns true if state changed.
    @discardableResult
    func startIfPossible() -> Bool {
        guard !isRunning else { return false }
        guard let device = BackplaneProbe.backplaneDeviceID() else { return false }

        var pid: AudioDeviceIOProcID?
        let loadBits = self.loadBits
        var lastStart: UInt64 = 0
        let create = AudioDeviceCreateIOProcIDWithBlock(&pid, device, nil) { [store] _, inputData, _, outputData, _ in
            let begin = mach_absolute_time()
            store.process(inputData, outputData)
            let end = mach_absolute_time()
            // load = busy time / cycle period (both in mach ticks; the
            // ratio cancels the timebase). Exponential smoothing ~1 s.
            if lastStart != 0, end > begin, begin > lastStart {
                let cycle = Double(begin - lastStart)
                let busy = Double(end - begin)
                let instant = min(busy / cycle, 1)
                let previous = Double(bitPattern: loadBits.pointee)
                loadBits.pointee = (previous + 0.1 * (instant - previous)).bitPattern
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
        xrunCount.pointee = 0
        loadBits.pointee = Double(0).bitPattern

        // XRUN counter: CoreAudio posts processor-overload when a cycle
        // missed its deadline.
        let xrunCount = self.xrunCount
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            xrunCount.pointee += 1
            log("Engine: processor overload (XRUN #\(xrunCount.pointee))")
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
        loadBits.pointee = Double(0).bitPattern
        procID = nil
        deviceID = 0
        isRunning = false
        log("Engine stopped")
        return true
    }
}
