// Hydra Audio — GPL-3.0
// App entry point. UI only — all audio work lives in hydrad.

import SwiftUI
import HydraCore

@main
struct HydraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var client = DaemonClient()

    var body: some Scene {
        WindowGroup("Hydra") {
            ContentView()
                .environmentObject(client)
                .environmentObject(client.signals)
                .onAppear { client.start() }
        }
        .windowStyle(.hiddenTitleBar) // custom top bar draws its own chrome
        .commands {
            AboutCommands()
        }

        Window("About Hydra", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(client)
        }

        // Menu bar: status at a glance + scene quick-switch (Section 7.3).
        MenuBarExtra("Hydra", systemImage: "waveform.path") {
            MenuBarPanel()
                .environmentObject(client)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu bar panel: status line, scene list (click to apply) and save-as field.
struct MenuBarPanel: View {
    @EnvironmentObject private var client: DaemonClient
    @State private var newSceneName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status line
            HStack(spacing: 8) {
                Circle()
                    .fill(client.connectionState == .connected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(statusLine)
                    .font(.caption)
                Spacer()
            }

            Divider()

            // Scenes
            Text("Scenes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if client.scenes.isEmpty {
                Text("No scenes yet — patch the grid, then save the snapshot below.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(client.scenes) { scene in
                    HStack {
                        Button {
                            client.applyScene(scene.id)
                        } label: {
                            Label("\(scene.name) (\(scene.connections.count))",
                                  systemImage: "square.grid.3x3.topleft.filled")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .help("Apply \"\(scene.name)\" — replaces the whole matrix atomically")

                        Button {
                            client.deleteScene(scene.id)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Delete scene")
                    }
                }
            }

            HStack {
                TextField("Save current as…", text: $newSceneName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveScene)
                Button("Save", action: saveScene)
                    .disabled(newSceneName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Divider()

            HStack {
                Text("Hydra \(Hydra.versionString)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit Hydra") {
                    NSApplication.shared.terminate(nil)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private var statusLine: String {
        guard client.connectionState == .connected else { return "Daemon offline" }
        guard let status = client.status, status.backplaneInstalled else { return "Backplane not installed" }
        return "\(status.engineRunning ? "Engine running" : "Engine stopped") · \(client.connections.count) connection(s)"
    }

    private func saveScene() {
        let name = newSceneName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        client.saveScene(named: name)
        newSceneName = ""
    }
}

/// Replaces the default About item so credits/licensing live in one place.
struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Hydra") {
                openWindow(id: "about")
            }
        }
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


/// App settings (⌘,) — Logic Pro-style preferences: icon tabs in the
/// toolbar, dark like the rest of the app.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            AudioSettingsPane()
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
            ControlSettingsPane()
                .tabItem { Label("Control", systemImage: "dot.radiowaves.left.and.right") }
        }
        .frame(width: 460)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}

private struct GeneralSettingsPane: View {
    @EnvironmentObject private var client: DaemonClient

    var body: some View {
        Form {
            Section("Hydra Soundcard") {
                Text("Channels are managed as virtual interfaces — create them in the sidebar (Devices) or with the \u{201C}+ Interface\u{201D} button above the grid. The 256-channel pool stays invisible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Safety") {
                Toggle("Feedback protection", isOn: Binding(
                    get: { client.config.feedbackProtection },
                    set: { value in client.updateConfig { $0.feedbackProtection = value } }))
                Text("Blocks connections that would create loops on the soundcard. Disable only if you know what you're doing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(red: 0.05, green: 0.06, blue: 0.10))
    }
}

private struct AudioSettingsPane: View {
    @EnvironmentObject private var client: DaemonClient

    var body: some View {
        Form {
            Section("App capture") {
                HStack {
                    Text("Capture makeup gain")
                    Spacer()
                    Text(String(format: "%+.0f dB", client.config.appTapMakeupDB))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(client.config.appTapMakeupDB) },
                    set: { value in client.updateConfig { $0.appTapMakeupDB = Float(value) } }),
                       in: 0...24, step: 1)
                Text("Compensates the level loss of app captures. Raise it if captured apps sound quieter than interface inputs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(red: 0.05, green: 0.06, blue: 0.10))
    }
}

private struct ControlSettingsPane: View {
    @EnvironmentObject private var client: DaemonClient

    var body: some View {
        Form {
            Section("OSC remote control") {
                Toggle("Enable OSC", isOn: Binding(
                    get: { client.config.oscEnabled },
                    set: { value in client.updateConfig { $0.oscEnabled = value } }))
                if client.config.oscEnabled {
                    HStack {
                        Text("UDP port")
                        Spacer()
                        TextField("Port", value: Binding(
                            get: { client.config.oscPort },
                            set: { value in client.updateConfig { $0.oscPort = max(1024, min(65535, value)) } }),
                            format: .number.grouping(.never))
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                    }
                }
                Text("Scenes and recordings from consoles, TouchOSC or Stream Deck (Companion): /hydra/scene/apply \u{201C}name\u{201D}, /hydra/scene/save, /hydra/record/start, /hydra/record/stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(red: 0.05, green: 0.06, blue: 0.10))
    }
}
