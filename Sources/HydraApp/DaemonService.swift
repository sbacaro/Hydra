// Hydra Audio — GPL-3.0
// DaemonService — starts the Hydra audio engine IN-PROCESS.
//
// Hydra used to ship the engine as a separate `hydrad` LaunchAgent process; the
// app launched it and talked to it over a loopback WebSocket. The engine now
// runs inside Hydra.app itself (see HydraDaemon/DaemonRuntime), so there is no
// second process to register, launch, or kill. This type keeps the small surface
// the UI already calls (`enable()`, `isEnabled`) and now just boots the in-process
// runtime; the UI is still a WebSocket client of ws://127.0.0.1:59731, which now
// loops back within the same process.

import Foundation
import ServiceManagement
import Combine
import AppKit
import HydraDaemon
import os

@MainActor
final class DaemonService: ObservableObject {

    private let log = Logger(subsystem: "audio.hydra.app", category: "DaemonService")

    /// True once the in-process engine has been started.
    @Published private(set) var isEnabled = false

    init() {}

    /// Bring the audio engine up, in-process. Idempotent.
    func enable() {
        DaemonRuntime.start()
        isEnabled = true
        log.info("Hydra audio engine started in-process")
    }

    /// Open System Settings → Login Items, where the user can toggle "Open Hydra
    /// at login" (the app itself — there is no separate helper anymore).
    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}
