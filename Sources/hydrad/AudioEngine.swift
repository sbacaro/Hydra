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

    init(store: MatrixStore) {
        self.store = store
    }

    /// Attach + start if the backplane is present. Returns true if state changed.
    @discardableResult
    func startIfPossible() -> Bool {
        guard !isRunning else { return false }
        guard let device = BackplaneProbe.backplaneDeviceID() else { return false }

        var pid: AudioDeviceIOProcID?
        let create = AudioDeviceCreateIOProcIDWithBlock(&pid, device, nil) { [store] _, inputData, _, outputData, _ in
            store.process(inputData, outputData)
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
        log("Engine started — IOProc attached to the backplane")
        return true
    }

    /// Stop + detach (e.g. the backplane disappeared). Returns true if state changed.
    @discardableResult
    func stop() -> Bool {
        guard isRunning, let pid = procID else { return false }
        AudioDeviceStop(deviceID, pid)
        AudioDeviceDestroyIOProcID(deviceID, pid)
        procID = nil
        deviceID = 0
        isRunning = false
        log("Engine stopped")
        return true
    }
}
