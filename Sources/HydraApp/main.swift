// Hydra Audio — GPL-3.0
// Process entry point.
//
// Hydra is a single process now: the audio engine (HydraDaemon) runs in-process
// (see DaemonService / DaemonRuntime). This explicit entry point exists so we can
// intercept the VST scan-worker invocation BEFORE SwiftUI starts. The scanner
// spawns this same executable as `Hydra --scan-bundle <bundle> --out <file>`
// (Bundle.main.executableURL → Hydra.app), loads ONE plugin in this throwaway
// process, writes the result, and exits — isolating plugin scan hangs/crashes
// from the real app. In the normal case it falls through to the SwiftUI app.

import Foundation
import HydraDaemon

if DaemonRuntime.runScanWorkerIfRequested() {
    exit(0)
}

HydraApp.main()
