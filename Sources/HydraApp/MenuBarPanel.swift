// Hydra Audio — GPL-3.0
// Menu bar extra: glanceable status + the few commands worth reaching without
// opening the main window — open/settings, live engine metrics, per-interface
// recording, scene recall, launch-at-login. Deliberately a quick-access surface,
// not a second UI (HIG: "the menu bar provides quick access to status and
// frequently used commands").
//
// Design: one consistent type scale (see `Font` tokens below), translucent
// "Liquid Glass" cards grouping each section, and a single header that carries
// the brand mark, version and live status pill. Every row shares the same
// spacing rhythm so nothing looks ad-hoc.

import SwiftUI
import ServiceManagement
import AppKit
import HydraCore

// MARK: - Menu-bar type scale
// One small, consistent set of fonts. Using these everywhere keeps the panel
// from drifting into the mix of `.caption`, `.system(size: 11/12)` it had before.

private extension Font {
    /// App name in the header.
    static let mbTitle   = Font.system(size: 15, weight: .semibold)
    /// Standard row text (interface names, scene names, toggles).
    static let mbBody    = Font.system(size: 12, weight: .regular)
    /// Section labels ("RECORDING", "SCENES") and secondary captions.
    static let mbCaption = Font.system(size: 11, weight: .medium)
    /// Section headers — uppercased, tracked.
    static let mbSection = Font.system(size: 10, weight: .semibold)
    /// Numeric metric values (monospaced digits so they don't jitter).
    static let mbMetric  = Font.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit()
    /// Tile labels under each metric.
    static let mbTile    = Font.system(size: 9, weight: .semibold)
}

// MARK: - Liquid-Glass card

private extension View {
    /// Wraps a section in a subtle translucent card with a hairline border —
    /// the layered, glassy grouping macOS 26 favours over bare dividers.
    func mbCard() -> some View {
        self
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
            )
    }
}

// MARK: - Section header

private struct MBSectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.mbSection)
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Metric tile

/// One stat in the metrics card: a tinted glyph, a monospaced value and a
/// tracked label. Three of these sit side by side, separated by hairlines.
private struct MBStatTile: View {
    let icon: String
    let value: String
    let label: String
    var tint: Color = .secondary

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.mbMetric)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.mbTile)
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - The panel

/// The menu bar extra's window: status, quick open/settings, live metrics,
/// recording control, scene recall, save-as, and launch-at-login.
struct MenuBarPanel: View {
    @Environment(DaemonClient.self) private var client
    @EnvironmentObject private var updater: Updater
    @Environment(\.openWindow) private var openWindow
    @State private var newSceneName = ""
    @State private var loginTick = 0

    // Minimalist: brand + online/offline + engine load, then Open / Settings.
    // Everything else (scenes, recording, updates, login) lives inside the app.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let status = client.status, client.connectionState == .connected,
               status.backplaneInstalled {
                HStack {
                    Label("Engine load", systemImage: "cpu")
                        .font(.mbBody)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((status.cpuLoad * 100).rounded()))%")
                        .font(.mbMetric)
                        .foregroundStyle(loadTint(LoadSeverity(load: status.cpuLoad)))
                }
                .mbCard()
            }
            VStack(spacing: 8) {
                Button { openMainWindow() } label: {
                    Label("Open Hydra", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                SettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    // ── Header ────────────────────────────────────────────────────────────
    private var header: some View {
        HStack(spacing: 10) {
            BrandMark(size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Hydra")
                    .font(.mbTitle)
                Text("v\(Hydra.versionString)")
                    .font(.mbCaption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            statusPill
        }
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusShort)
                .font(.mbCaption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.primary.opacity(0.06), in: Capsule())
        .help(statusLine)
    }

    // ── Live metrics ────────────────────────────────────────────────────────
    @ViewBuilder
    private var metrics: some View {
        if let status = client.status, status.backplaneInstalled,
           client.connectionState == .connected {
            HStack(spacing: 0) {
                MBStatTile(icon: "cpu",
                           value: "\(Int((status.cpuLoad * 100).rounded()))%",
                           label: "Load",
                           tint: loadTint(LoadSeverity(load: status.cpuLoad)))
                tileDivider
                MBStatTile(icon: status.xruns == 0 ? "checkmark.circle" : "exclamationmark.triangle.fill",
                           value: "\(status.xruns)",
                           label: "XRUNs",
                           tint: status.xruns == 0 ? .green : .red)
                tileDivider
                MBStatTile(icon: "arrow.left.arrow.right",
                           value: "\(status.inputChannels)/\(status.outputChannels)",
                           label: "In / Out",
                           tint: .secondary)
            }
            .mbCard()
        }
    }

    private var tileDivider: some View {
        Rectangle()
            .fill(.primary.opacity(0.08))
            .frame(width: 0.5, height: 30)
    }

    // ── Quick access ──────────────────────────────────────────────────────
    private var quickActions: some View {
        HStack(spacing: 8) {
            Button { openMainWindow() } label: {
                Label("Open Hydra", systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .font(.mbBody)
    }

    // ── Updates ───────────────────────────────────────────────────────────
    @ViewBuilder
    private var updates: some View {
        if let version = updater.availableVersion {
            Button { updater.checkForUpdates() } label: {
                Label("Update to \(version)", systemImage: "arrow.down.circle.fill")
                    .font(.mbBody)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .help("A new version of Hydra is available")
        } else {
            Button { updater.checkForUpdates() } label: {
                Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                    .font(.mbCaption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
    }

    // ── Recording (per interface) ───────────────────────────────────────────
    @ViewBuilder
    private var recording: some View {
        if !client.interfaces.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                MBSectionHeader(title: "Recording")
                VStack(spacing: 8) {
                    ForEach(client.interfaces) { iface in
                        recordingRow(iface)
                    }
                }
                .mbCard()
            }
        }
    }

    @ViewBuilder
    private func recordingRow(_ iface: VirtualInterfaceInfo) -> some View {
        let rec = client.recording(for: iface.id)
        let isRecording = rec != nil
        HStack(spacing: 8) {
            Image(systemName: isRecording ? "record.circle.fill" : "record.circle")
                .font(.system(size: 12))
                .foregroundStyle(isRecording ? .red : .secondary)
                .symbolEffect(.pulse, isActive: isRecording)
            Text(iface.name)
                .font(.mbBody)
                .lineLimit(1)
            Spacer(minLength: 6)
            if isRecording, let rec {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(elapsed(since: rec.startedAt, now: ctx.date))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.red)
                }
            }
            Button(isRecording ? "Stop" : "Record") {
                if isRecording { client.stopRecording(iface.id) }
                else           { client.startRecording(iface.id) }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .font(.mbCaption)
            .tint(isRecording ? .red : .accentColor)
        }
    }

    // ── Scenes ──────────────────────────────────────────────────────────────
    private var scenes: some View {
        VStack(alignment: .leading, spacing: 8) {
            MBSectionHeader(title: "Scenes")
            VStack(spacing: 8) {
                if client.scenes.isEmpty {
                    Text("No scenes yet — patch the grid, then save the snapshot below.")
                        .font(.mbCaption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 4) {
                        ForEach(client.scenes) { scene in
                            sceneRow(scene)
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("Save current as…", text: $newSceneName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.mbBody)
                        .onSubmit(saveScene)
                    Button("Save", action: saveScene)
                        .controlSize(.small)
                        .font(.mbCaption)
                        .disabled(newSceneName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .mbCard()
        }
    }

    private func sceneRow(_ scene: PatchScene) -> some View {
        HStack(spacing: 6) {
            Button {
                client.applyScene(scene.id)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.grid.3x3.topleft.filled")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(scene.name)
                        .font(.mbBody)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(scene.connections.count)")
                        .font(.mbCaption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Apply \"\(scene.name)\" — replaces the whole matrix atomically")

            Button {
                client.deleteScene(scene.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Delete scene")
        }
    }

    // ── Footer ──────────────────────────────────────────────────────────────
    private var footer: some View {
        VStack(spacing: 10) {
            Divider()
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
                .font(.mbBody)

            HStack {
                Spacer()
                Button("Quit Hydra") {
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.small)
                .font(.mbCaption)
            }
        }
    }

    // MARK: - Derived state

    /// The four glanceable states, derived from connection + daemon status.
    private var presence: EnginePresence {
        EnginePresence(connected: client.connectionState == .connected,
                       backplaneInstalled: client.status?.backplaneInstalled == true,
                       engineRunning: client.status?.engineRunning == true)
    }

    private var statusColor: Color {
        switch presence {
        case .offline, .noBackplane: return .orange
        case .stopped:               return .yellow
        case .running:               return .green
        }
    }

    /// Short label for the header pill.
    private var statusShort: String { presence.shortLabel }

    /// Long label (tooltip): engine state + sample rate + live connection count.
    private var statusLine: String {
        guard client.connectionState == .connected else { return "Daemon offline" }
        guard let status = client.status, status.backplaneInstalled else { return "Backplane not installed" }
        let rate = String(format: "%.0f kHz", status.sampleRate / 1000)
        let engine = status.engineRunning ? "Engine running" : "Engine stopped"
        return "\(engine) · \(rate) · \(client.connections.count) connection(s)"
    }

    private func loadTint(_ severity: LoadSeverity) -> Color {
        switch severity {
        case .normal:   return .green
        case .elevated: return .orange
        case .critical: return .red
        }
    }

    /// mm:ss (or h:mm:ss) since a recording started.
    private func elapsed(since start: Date, now: Date) -> String {
        formatElapsed(seconds: Int(now.timeIntervalSince(start)))
    }

    // MARK: - Actions

    /// Bring the main window forward (and the app, since the menu bar item may be
    /// clicked while another app is frontmost). Hydra launches as a menu-bar
    /// accessory with the window suppressed, so create it on first open; the Dock
    /// icon + app menu come up here (and the AppDelegate keeps them in sync).
    private func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "Hydra Soundcard" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
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
