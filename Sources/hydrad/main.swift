// Hydra Audio — GPL-3.0
//
// (Intentionally empty.)
//
// This used to be the `hydrad` executable's entry point. The audio engine is now
// folded into Hydra.app and starts in-process via `DaemonRuntime.start()` — see
// DaemonRuntime.swift. The VST scan-worker mode that lived here is now
// `DaemonRuntime.runScanWorkerIfRequested()`, called from the app's main.swift.
//
// HydraDaemon is built as a framework, so this file carries no top-level code.
