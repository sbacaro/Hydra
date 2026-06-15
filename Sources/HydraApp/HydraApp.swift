// Hydra Audio — GPL-3.0
// App entry point. UI only — all audio work lives in hydrad.
//
// Hydra is a *menu-bar-first* app: at launch (e.g. when started at login) it runs
// as an accessory with NO Dock icon and NO window — just the menu bar extra. A Dock
// icon and the app menu appear only while an ordinary window (main / Settings /
// About) is open, and disappear again when the last one closes. See AppDelegate.

import SwiftUI
import AppKit
import HydraCore

@main
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
                .environmentObject(client)
                .environmentObject(client.signals)
                .environmentObject(client.meters)
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
                .environmentObject(client)
                .environmentObject(client.signals)
                .environmentObject(client.meters)
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
                .environmentObject(client)
                .environmentObject(updater)
        } label: {
            // Glanceable status: the icon itself reflects engine/daemon health —
            // the whole point of a menu bar extra (status without opening the app).
            // A dedicated view observes the client so the glyph updates live.
            MenuBarStatusLabel()
                .environmentObject(client)
        }
        .menuBarExtraStyle(.window)
    }
}

/// "Check for Updates…" in the app menu (just below About). Drives Sparkle's
/// standard update UI; also reachable from the menu bar panel and Settings.
struct UpdateCommands: Commands {
    let updater: Updater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
        }
    }
}

/// The menu bar glyph. Observes the client so the symbol reflects state live:
/// offline → slashed, problem (no backplane) → warning, otherwise running waveform.
private struct MenuBarStatusLabel: View {
    @EnvironmentObject private var client: DaemonClient

    var body: some View {
        Image(systemName: symbol)
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

        // Begin Sparkle's scheduled checks (on launch + every 24h per Info.plist).
        updater.start()

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
