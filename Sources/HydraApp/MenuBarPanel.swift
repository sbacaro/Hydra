// Hydra Audio — GPL-3.0
// Menu bar extra: glanceable status + the few commands worth reaching without
// opening the main window — open/settings, per-interface recording, scene recall,
// launch-at-login. Deliberately a quick-access surface, not a second UI (HIG:
// "the menu bar provides quick access to status and frequently used commands").

import SwiftUI
import ServiceManagement
import AppKit
import HydraCore

/// The menu bar extra's window: status, quick open/settings, recording control,
/// scene recall, save-as, and launch-at-login.
struct MenuBarPanel: View {
    @EnvironmentObject private var client: DaemonClient
    @State private var newSceneName = ""
    @State private var loginTick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ── Status ────────────────────────────────────────────────
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusLine)
                    .font(.caption)
                Spacer()
            }

            // ── Quick access ──────────────────────────────────────────
            HStack(spacing: 8) {
                Button { openMainWindow() } label: {
                    Label("Open Hydra", systemImage: "macwindow")
                }
                SettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            // ── Recording (per interface) ─────────────────────────────
            if !client.interfaces.isEmpty {
                Divider()
                Text("Recording")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(client.interfaces) { iface in
                    let recording = client.recording(for: iface.id) != nil
                    HStack(spacing: 8) {
                        Image(systemName: recording ? "record.circle.fill" : "record.circle")
                            .foregroundStyle(recording ? .red : .secondary)
                        Text(iface.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Button(recording ? "Stop" : "Record") {
                            if recording { client.stopRecording(iface.id) }
                            else         { client.startRecording(iface.id) }
                        }
                        .controlSize(.mini)
                        .buttonStyle(.bordered)
                        .tint(recording ? .red : .accentColor)
                    }
                }
            }

            Divider()

            // ── Scenes ────────────────────────────────────────────────
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

            // ── Launch at login ───────────────────────────────────────
            Toggle("Launch Hydra at login", isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { enable in
                    do {
                        if enable { try SMAppService.mainApp.register() }
                        else      { try SMAppService.mainApp.unregister() }
                    } catch { /* dev builds may be refused; silent in the menu bar */ }
                    loginTick += 1
                }))
                .id(loginTick)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)

            Divider()

            // ── Footer ────────────────────────────────────────────────
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
        .frame(width: 280)
    }

    private var statusColor: Color {
        guard client.connectionState == .connected else { return .orange }
        return client.status?.backplaneInstalled == true ? .green : .orange
    }

    private var statusLine: String {
        guard client.connectionState == .connected else { return "Daemon offline" }
        guard let status = client.status, status.backplaneInstalled else { return "Backplane not installed" }
        return "\(status.engineRunning ? "Engine running" : "Engine stopped") · \(client.connections.count) connection(s)"
    }

    /// Bring the main window forward (and the app, since the menu bar item may be
    /// clicked while another app is frontmost).
    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.title == "Hydra Soundcard" {
            window.makeKeyAndOrderFront(nil)
            return
        }
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

extension Notification.Name {
    /// Posted by the Help menu to re-open the first-run welcome flow.
    static let showWelcomeSheet = Notification.Name("audio.hydra.showWelcome")
}

/// Adds "Welcome to Hydra…" to the Help menu so the onboarding flow can be
/// reopened after first run.
struct WelcomeCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Welcome to Hydra…") {
                NotificationCenter.default.post(name: .showWelcomeSheet, object: nil)
            }
        }
    }
}
