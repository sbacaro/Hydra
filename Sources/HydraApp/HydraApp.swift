// Hydra Audio — GPL-3.0
// App entry point. UI only — all audio work lives in hydrad.

import SwiftUI
import HydraCore

@main
struct HydraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var client = DaemonClient()
    @StateObject private var daemon = DaemonService()

    var body: some Scene {
        WindowGroup("Hydra Soundcard") {
            ContentView()
                .environmentObject(client)
                .environmentObject(client.signals)
                .environmentObject(client.meters)
                .environmentObject(daemon)
                .onAppear {
                    // Ensure hydrad is registered as a LaunchAgent and running,
                    // then connect. DaemonClient reconnects on its own once the
                    // agent is up, so order isn't critical.
                    daemon.enable()
                    client.start()
                }
        }
        .commands {
            AboutCommands()
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
        }

        Window("About Hydra", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        // Menu bar: status at a glance + scene quick-switch (Section 7.3).
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(client)
        } label: {
            // Glanceable status: the icon itself reflects engine/daemon health —
            // the whole point of a menu bar extra (status without opening the app).
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    /// Menu bar glyph by state: offline → slashed, problem (no backplane) →
    /// warning, otherwise the running waveform.
    private var menuBarSymbol: String {
        guard client.connectionState == .connected else { return "waveform.slash" }
        if client.status?.backplaneInstalled != true { return "exclamationmark.triangle.fill" }
        return "waveform.path"
    }
}

/// Ensures a proper foreground app (with window + focus) when launched
/// via the command line instead of from an .app bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
