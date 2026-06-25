// Hydra Audio — GPL-3.0
// The SwiftUI app. The audio engine (HydraDaemon) runs in-process — see
// DaemonService / DaemonRuntime. The process entry point is main.swift, which
// calls HydraApp.main() after handling the VST scan-worker invocation.
//
// Hydra is a *menu-bar-first* app: at launch (e.g. when started at login) it runs
// as an accessory with NO Dock icon and NO window — just the menu bar extra. A Dock
// icon and the app menu appear only while an ordinary window (main / Settings /
// About) is open, and disappear again when the last one closes. See AppDelegate.

import SwiftUI
import AppKit
import HydraCore

// NOTE: no `@main` — see main.swift for the process entry point.
struct HydraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // First run still presents the window so the Welcome flow can show; once the
    // user has been onboarded, launch leaves just the menu bar.
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    // Services are owned by the AppDelegate (not @StateObject here) so they start at
    // launch even though the main window is suppressed — the menu bar needs a live
    // client, and hydrad must come up at login regardless of any window being shown.
    private var client: DaemonClient { appDelegate.client }
    private var daemon: DaemonService { appDelegate.daemon }
    private var updater: Updater { appDelegate.updater }

    var body: some Scene {
        WindowGroup("Hydra Soundcard", id: "main") {
            ContentView()
                .environment(client)
                .environment(client.signals)
                .environment(client.meters)
                .environmentObject(daemon)
                .environmentObject(updater)
        }
        // Don't auto-open the main window at launch: login should leave just the
        // menu bar. The user opens it on demand from the menu bar ("Open Hydra").
        // Exception: the very first run presents it so onboarding can appear.
        .defaultLaunchBehavior(hasSeenWelcome ? .suppressed : .automatic)
        .commands {
            AboutCommands()
            UpdateCommands(updater: updater)
            WelcomeCommands()
            // ⌘, and the "Settings…" menu item are provided automatically by the
            // Settings scene below — no custom command group needed.
        }

        // Native Settings window (Apple HIG): a real, listable window with proper
        // title-bar chrome and the standard toolbar pane switcher — instead of a
        // sheet whose tab strip bled into the main window behind it.
        Settings {
            SettingsView()
                .environment(client)
                .environment(client.signals)
                .environment(client.meters)
                .environmentObject(daemon)
                .environmentObject(updater)
        }

        Window("About Hydra", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        // Menu bar: status at a glance + scene quick-switch (Section 7.3).
        MenuBarExtra {
            MenuBarPanel()
                .environment(client)
                .environmentObject(updater)
        } label: {
            // Glanceable status: the icon itself reflects engine/daemon health —
            // the whole point of a menu bar extra (status without opening the app).
            // A dedicated view observes the client so the glyph updates live.
            MenuBarStatusLabel()
                .environment(client)
        }
        .menuBarExtraStyle(.window)
    }
}

/// "Check for Updates…" in the app menu (just below About). Triggers the in-app
/// updater (see Updater.swift); also reachable from the menu bar panel and Settings.
struct UpdateCommands: Commands {
    let updater: Updater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
        }
    }
}

/// Posted by the AppDelegate when the user reopens Hydra (Dock/Applications) and
/// no main window exists yet. The always-alive menu-bar label opens one.
extension Notification.Name {
    static let hydraOpenMainWindow = Notification.Name("hydraOpenMainWindow")
}

/// The menu bar glyph. Observes the client so the symbol reflects state live:
/// offline → slashed, problem (no backplane) → warning, otherwise running waveform.
/// Also the always-present scene view that fulfils "reopen → open main window".
private struct MenuBarStatusLabel: View {
    @Environment(DaemonClient.self) private var client
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .onReceive(NotificationCenter.default.publisher(for: .hydraOpenMainWindow)) { _ in
                openWindow(id: "main")
            }
    }

    private var symbol: String {
        guard client.connectionState == .connected else { return "waveform.slash" }
        if client.status?.backplaneInstalled != true { return "exclamationmark.triangle.fill" }
        return "waveform.path"
    }
}

/// Owns the long-lived services and drives the Dock-icon policy: accessory (no Dock
/// icon) when only the menu bar is showing, regular while an ordinary window is open.
/// @MainActor because it constructs and drives main-actor services and AppKit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let client = DaemonClient()
    let daemon = DaemonService()
    let updater = Updater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-first: no Dock icon at launch.
        NSApp.setActivationPolicy(.accessory)

        // Begin the in-app updater's scheduled checks (on launch + every 24h).
        updater.start()

        // Subscribe to MetricKit so crash/hang/performance reports are captured
        // locally (no third-party telemetry).
        MetricsReporter.shared.start()

        // First run still presents the onboarding window (see the App's launch
        // behavior). Since we're an LSUIElement agent, foreground it explicitly so
        // the Welcome flow appears in front instead of behind other apps.
        if !UserDefaults.standard.bool(forKey: "hasSeenWelcome") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }

        // Bring hydrad up and connect now, independent of any window.
        daemon.enable()
        client.start()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(windowDidBecomeKey(_:)),
                       name: NSWindow.didBecomeKeyNotification, object: nil)
        nc.addObserver(self, selector: #selector(windowWillClose(_:)),
                       name: NSWindow.willCloseNotification, object: nil)
    }

    // It's a menu bar app: closing the last window must not quit it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking Hydra in Finder/Applications/Dock while it's already running as a
    /// menu-bar accessory must OPEN the main window (not just no-op). First launch
    /// already shows the window via the App's `.defaultLaunchBehavior`.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { isOrdinaryWindow($0) && $0.title == "Hydra Soundcard" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // No main window exists yet (suppressed launch / was closed) — ask the
            // always-alive menu-bar scene to create it via SwiftUI's openWindow.
            NotificationCenter.default.post(name: .hydraOpenMainWindow, object: nil)
        }
        return true
    }

    /// A real app window (main / Settings / About) — not the menu-bar popover panel,
    /// which must never give Hydra a Dock presence.
    private func isOrdinaryWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled) && window.canBecomeMain
    }

    @objc private func windowDidBecomeKey(_ note: Notification) {
        guard let w = note.object as? NSWindow, isOrdinaryWindow(w) else { return }
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    @objc private func windowWillClose(_ note: Notification) {
        guard let closing = note.object as? NSWindow, isOrdinaryWindow(closing) else { return }
        // After this window finishes closing, drop the Dock icon if no other
        // ordinary window remains visible.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let stillOpen = NSApp.windows.contains { $0.isVisible && self.isOrdinaryWindow($0) }
            if !stillOpen { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
