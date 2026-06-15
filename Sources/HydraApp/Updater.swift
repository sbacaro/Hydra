// Hydra Audio — GPL-3.0
// In-app auto-update via Sparkle.
//
// Checks on launch + every 24h (Info.plist: SUEnableAutomaticChecks /
// SUScheduledCheckInterval). When an update is found Sparkle shows its standard
// update window (the "notification"); we also publish `availableVersion` so the
// main window's banner and the menu bar can nudge the user. Updates ship as a
// signed Hydra.app zip attached to the newest GitHub Release (EdDSA-verified
// against SUPublicEDKey). The HAL driver is refreshed separately on launch when
// its version changes — see InstallManager.refreshDriverIfOutdated().

import Foundation
import Combine
import Sparkle

@MainActor
final class Updater: ObservableObject {

    /// Set when Sparkle finds a valid update; drives the in-app banner + menu item.
    @Published private(set) var availableVersion: String?

    /// Bound to the Settings toggle "Check for updates automatically".
    @Published var automaticallyChecks: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    private let controller: SPUStandardUpdaterController
    private let bridge = UpdaterBridge()

    init() {
        // startingUpdater: false — AppDelegate calls start() once the app has
        // finished launching (Sparkle recommends not starting it in init()).
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: bridge, userDriverDelegate: nil)
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates

        bridge.onFoundUpdate = { [weak self] version in self?.availableVersion = version }
        bridge.onNoUpdate    = { [weak self] in self?.availableVersion = nil }
    }

    /// Begin scheduled (launch + periodic) checks. Call once, after launch.
    func start() { controller.startUpdater() }

    /// User-initiated check (menu / Settings / banner). Presents Sparkle's UI,
    /// including a "you're up to date" message when there's nothing new.
    func checkForUpdates() { controller.checkForUpdates(nil) }

    /// False briefly during an in-progress check/install (disables the menu item).
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
}

/// NSObject bridge for Sparkle's delegate callbacks (called on the main thread),
/// forwarding into the @MainActor model.
private final class UpdaterBridge: NSObject, SPUUpdaterDelegate {
    var onFoundUpdate: ((String) -> Void)?
    var onNoUpdate: (() -> Void)?

    // Sparkle delivers delegate callbacks on the main thread, so we can safely
    // assume main-actor isolation and update the @MainActor model synchronously.
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { onFoundUpdate?(version) }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { onNoUpdate?() }
    }
}
