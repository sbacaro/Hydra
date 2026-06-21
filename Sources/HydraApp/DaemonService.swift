// Hydra Audio — GPL-3.0
// DaemonService — registers hydrad as a per-user LaunchAgent via SMAppService,
// so macOS starts it (at login / on register), keeps it alive, and relaunches it
// on crash. hydrad must be an AGENT (user GUI session) because it hosts VST
// plugin editor windows. Plist: Contents/Library/LaunchAgents/audio.hydra.daemon.plist,
// BundleProgram → the hydrad.app embedded under Contents/Library/Helpers/.

import Foundation
import ServiceManagement
import Combine
import AppKit
import os

@MainActor
final class DaemonService: ObservableObject {

    /// File name of the bundled LaunchAgents plist (no path).
    static let plistName = "audio.hydra.daemon.plist"
    /// Bundle id of the embedded hydrad helper (also the LaunchAgent label).
    static let helperBundleID = "audio.hydra.daemon"

    private let service = SMAppService.agent(plistName: DaemonService.plistName)
    private let log = Logger(subsystem: "audio.hydra.app", category: "DaemonService")

    @Published private(set) var status: SMAppService.Status = .notRegistered

    /// PID of the hydrad WE launched directly (the dev fallback). Only this one
    /// is terminated on quit — a launchd-managed instance is left to launchd.
    private var launchedHelperPID: pid_t?

    init() {
        status = service.status
        // Tie the directly-launched hydrad to the app's lifetime: kill it when
        // Hydra fully quits, so the daemon doesn't linger as an orphan process.
        // queue: nil → the block runs SYNCHRONOUSLY on the posting (main) thread
        // during termination, so it executes before the process exits.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminateLaunchedHelper() }
        }
    }

    /// Terminate the hydrad this app launched directly (if any).
    private func terminateLaunchedHelper() {
        guard let pid = launchedHelperPID,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.terminate()
        launchedHelperPID = nil
    }

    /// Registered and allowed to run.
    var isEnabled: Bool { status == .enabled }
    /// User must approve in System Settings → Login Items before it runs.
    var needsApproval: Bool { status == .requiresApproval }

    /// Bring hydrad up. App-managed (not launchd-managed): we launch the embedded
    /// helper DIRECTLY and immediately. This is reliable regardless of code-signing
    /// — it does NOT depend on launchd accepting the agent's code requirement
    /// (which goes stale across rebuilds under ad-hoc signing and makes launchd
    /// refuse to spawn it). The `helperRunning` guard means we never start a second
    /// instance (e.g. if a launchd-managed or manually-started hydrad is already up).
    /// The app shows a loading view until the WebSocket connects.
    func enable() {
        launchEmbeddedHelperIfNeeded()
        status = service.status
    }

    /// True when a hydrad process is already running (started by launchd or us).
    private var helperRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == DaemonService.helperBundleID
        }
    }

    /// hydrad.app embedded at Contents/Library/Helpers/ (see the Copy Files phase).
    private var embeddedHelperURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/Helpers/hydrad.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Launch the bundled hydrad directly if launchd hasn't brought it up.
    private func launchEmbeddedHelperIfNeeded() {
        guard !helperRunning else { return }
        guard let helper = embeddedHelperURL else {
            log.error("Embedded hydrad.app not found — rebuild after regenerating the project")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false            // background helper (LSUIElement)
        config.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: helper, configuration: config) { [weak self] runningApp, error in
            let pid = runningApp?.processIdentifier      // pid_t is Sendable
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.log.error("Direct hydrad launch failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    self.launchedHelperPID = pid
                    self.log.info("Launched embedded hydrad directly (SMAppService fallback)")
                }
            }
        }
    }

    /// Stop auto-launch (launchd stops hydrad).
    func disable() {
        Task {
            do { try await service.unregister() }
            catch { log.error("Failed to unregister hydrad agent: \(error.localizedDescription, privacy: .public)") }
            self.status = self.service.status
        }
    }

    func refresh() { status = service.status }
    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}
