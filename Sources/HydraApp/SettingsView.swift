// Hydra Audio — GPL-3.0
// App settings (⌘,) — macOS 26 Tahoe / Liquid Glass native Settings window.
//
// Apple HIG (Settings, macOS Tahoe):
//   • Native `Settings` scene + `TabView` toolbar tabs — the canonical Settings
//     chrome (Mail/Safari/Xcode). The system draws the Liquid Glass toolbar; we
//     never hand-roll glass or hardcode colors, and never set a color scheme —
//     Settings follows the system appearance.
//   • `Form { Section { } }` with `.formStyle(.grouped)` gives the inset grouped
//     table, automatic label/control alignment, dividers and system typography.
//   • LabeledContent for every label→control row (no manual HStack+Spacer).
//   • Explanations are SURFACED as visible Section footers (HIG: explain
//     non-obvious settings in place), with the same text mirrored in .help()
//     tooltips for discoverability.
//
// Information architecture (reorganized; deduplicated):
//   General  — Startup, Safety
//   Audio    — App capture, Engine (rate/channels/Audio MIDI Setup), NDI status
//   Plug-ins — Library (scan), Locations (extra folder), Available plug-ins list
//   Recording— Format, Destination
//   Control  — OSC remote control
//   Advanced — Folders, Backup, Diagnostics, Reset
//
// The VST scan/folder controls used to be duplicated across Audio and Plugins;
// all plug-in management now lives in the single Plug-ins tab.

import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import AppKit
import HydraCore

// MARK: - Root

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General",   systemImage: "gearshape") }
            AudioSettingsPane()
                .tabItem { Label("Audio",     systemImage: "speaker.wave.2") }
            PluginsSettingsPane()
                .tabItem { Label("Plug-ins",  systemImage: "puzzlepiece.extension") }
            RecordingSettingsPane()
                .tabItem { Label("Recording", systemImage: "record.circle") }
            ControlSettingsPane()
                .tabItem { Label("Control",   systemImage: "dot.radiowaves.left.and.right") }
            AdvancedSettingsPane()
                .tabItem { Label("Advanced",  systemImage: "wrench.and.screwdriver") }
        }
        // Fixed size so the window doesn't jump between panes (the Plug-ins pane
        // hosts a scrolling list). Height fits the tallest pane. No
        // preferredColorScheme — follows system appearance.
        .frame(width: 600, height: 620)
        .tint(.accentColor)
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @Environment(DaemonClient.self) private var client
    @EnvironmentObject private var updater: Updater
    @State private var loginToggleTick = 0
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Launch Hydra at login") {
                    Toggle("", isOn: Binding(
                        get: { SMAppService.mainApp.status == .enabled },
                        set: { enable in
                            do {
                                if enable { try SMAppService.mainApp.register() }
                                else      { try SMAppService.mainApp.unregister() }
                                loginError = nil
                            } catch {
                                loginError = error.localizedDescription
                            }
                            loginToggleTick += 1
                        }))
                    .labelsHidden()
                    .id(loginToggleTick)
                }
                .help("Registers Hydra with macOS Login Items. Requires an installed .app — development builds may be refused.")

                if let loginError {
                    LabeledContent("Error", value: loginError)
                        .foregroundStyle(Theme.warning)
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("Adds Hydra to macOS Login Items so it opens automatically. Requires an installed app — development builds may be refused.")
            }

            Section {
                LabeledContent("Feedback protection") {
                    Toggle("", isOn: Binding(
                        get: { client.config.feedbackProtection },
                        set: { value in client.updateConfig { $0.feedbackProtection = value } }))
                    .labelsHidden()
                }
                .help("Blocks connections that would create loops on the soundcard. Disable only if you know what you're doing.")
            } header: {
                Text("Safety")
            } footer: {
                Text("Blocks patches that would create a feedback loop on the soundcard. Disable only if you know what you're doing.")
            }

            Section {
                LabeledContent("Check automatically") {
                    Toggle("", isOn: $updater.automaticallyChecks)
                        .labelsHidden()
                }
                if let version = updater.availableVersion {
                    LabeledContent("Available", value: "Hydra \(version)")
                        .foregroundStyle(.tint)
                }
                Button("Check for Updates…") { updater.checkForUpdates() }
            } header: {
                Text("Updates")
            } footer: {
                Text("Checks GitHub for new releases on launch and every 24 hours. Updates download and install with your confirmation; the audio driver is refreshed automatically when it changes.")
            }

            Section {
                LanguagePicker()
            } header: {
                Text("Language")
            } footer: {
                Text("Overrides the app's language regardless of the system setting. Changing it takes full effect after a relaunch.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Audio

private struct AudioSettingsPane: View {
    @Environment(DaemonClient.self) private var client
    // Continuous control → wrap in the shared optimistic/echo-safe primitive so
    // dragging coalesces into debounced writes instead of one setConfig per step.
    @StateObject private var makeup = SyncedValue<Double>(0)

    var body: some View {
        Form {
            Section {
                LabeledContent("Capture makeup gain") {
                    HStack(spacing: 10) {
                        Slider(value: makeup.binding, in: 0...24, step: 1) { editing in
                            editing ? makeup.beginEditing() : makeup.endEditing()
                        }
                        .frame(width: 220)
                        Text(String(format: "%+.0f dB", makeup.value))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                .help("Compensates the level loss of app captures. Raise if captured apps sound quieter than interface inputs.")
                .onAppear {
                    let client = self.client       // capture the ref only (no retain cycle)
                    makeup.onPush = { db in client.updateConfig { $0.appTapMakeupDB = Float(db) } }
                    makeup.adopt(Double(client.config.appTapMakeupDB))
                }
                .onChange(of: client.config.appTapMakeupDB) { _, newValue in
                    makeup.remote(Double(newValue))
                }
            } header: {
                Text("App Capture")
            } footer: {
                Text("Compensates the level loss of per-app captures. Raise it if captured apps sound quieter than interface inputs.")
            }

            Section {
                LabeledContent("Sample rate", value: "48 kHz · 32-bit float")
                LabeledContent("Soundcard",
                               value: "256-channel pool · used via virtual interfaces")
                LabeledContent("Audio MIDI Setup") {
                    Button("Open") { openAudioMIDISetup() }
                }
            } header: {
                Text("Engine")
            } footer: {
                Text("The engine runs at a fixed 48 kHz, 32-bit float. The virtual soundcard always exposes 256 channels; create named virtual interfaces in the sidebar (+ Interface). Open Audio MIDI Setup to confirm the “Hydra Virtual Soundcard” device.")
            }

            Section {
                LabeledContent("Runtime") {
                    if client.ndi.runtimeAvailable {
                        Label(client.ndi.runtimeVersion.map { "Installed · \($0)" } ?? "Installed",
                              systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.callout)
                            .foregroundStyle(Theme.live)
                    } else {
                        HStack(spacing: 10) {
                            Label("Not installed", systemImage: "xmark.circle")
                                .labelStyle(.titleAndIcon)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Link("Download…", destination: URL(string: Hydra.ndiRedistURL)!)
                        }
                    }
                }
                .help("NDI send/receive needs Vizrt's official runtime. Hydra loads it dynamically and never bundles it (GPL).")
            } header: {
                Text("NDI")
            } footer: {
                Text("NDI send/receive requires Vizrt's official runtime, which Hydra loads dynamically and never bundles (GPL). Without it, NDI stays off and everything else works.")
            }
        }
        .formStyle(.grouped)
    }

    private func openAudioMIDISetup() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app")
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Plug-ins

private struct PluginsSettingsPane: View {
    @Environment(DaemonClient.self) private var client
    @State private var search       = ""
    @State private var typeFilter   = ""
    @State private var vendorFilter = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("VST3 plug-ins") {
                    HStack(spacing: 10) {
                        if client.vst.scanning {
                            ProgressView(value: client.vst.scanProgress)
                                .progressViewStyle(.linear)
                                .frame(width: 150)
                            Text(client.vst.scanLabel)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .frame(width: 110, alignment: .trailing)
                        } else {
                            Text(summary).foregroundStyle(.secondary)
                            Button(client.vst.scannedAt == nil ? "Scan now" : "Rescan") { client.scanVST() }
                        }
                    }
                }
                .help("Hydra never scans automatically. Scan after installing or removing plug-ins.")
            } header: {
                Text("Library")
            } footer: {
                Text("Hydra never scans automatically — scan after installing or removing plug-ins. A disabled plug-in stays installed but won't appear in the insert picker.")
            }

            Section {
                LabeledContent("Extra folder") {
                    HStack(spacing: 8) {
                        Text(client.config.vstFolderPath.isEmpty
                             ? "Standard folders only"
                             : client.config.vstFolderPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 220, alignment: .trailing)
                        Button("Choose…") { chooseVSTFolder() }
                        if !client.config.vstFolderPath.isEmpty {
                            Button("Reset") { client.updateConfig { $0.vstFolderPath = "" } }
                        }
                    }
                }
                .help("Scanned in addition to the standard VST3 folders. Rescan after changing.")
            } header: {
                Text("Locations")
            } footer: {
                Text("The standard /Library/Audio/Plug-Ins/VST3 and ~/Library/Audio/Plug-Ins/VST3 folders are always scanned. Add one more here, then Rescan.")
            }

            Section {
                // Filter bar
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search plugins…", text: $search)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .frame(minWidth: 160, maxWidth: 220)

                    Spacer()

                    Picker("", selection: $typeFilter) {
                        Text("All types").tag("")
                        ForEach(types, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 110)

                    Picker("", selection: $vendorFilter) {
                        Text("All makers").tag("")
                        ForEach(vendors, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                .padding(.vertical, 2)

                // Plug-in list
                if filtered.isEmpty {
                    VStack {
                        Spacer()
                        ContentUnavailableView(
                            client.vst.available.isEmpty ? "No plug-ins scanned" : "No results",
                            systemImage: "puzzlepiece.extension",
                            description: Text(client.vst.available.isEmpty
                                              ? "Press Scan to discover VST3 plug-ins."
                                              : "Try checking your spelling or changing the filters.")
                        )
                        .labelStyle(.titleAndIcon)
                        .controlSize(.small)
                        Spacer()
                    }
                    .frame(height: 240)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered) { plugin in
                                PluginRow(plugin: plugin)
                                if plugin.id != filtered.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(height: 240)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                }
            } header: {
                Text("Available Plug-ins")
            } footer: {
                Text("Toggle a plug-in off to hide it from the insert picker without uninstalling it. Star a plug-in to pin it to the top of the picker.")
            }
        }
        .formStyle(.grouped)
    }

    private func chooseVSTFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles       = false
        panel.prompt               = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            client.updateConfig { $0.vstFolderPath = url.path }
        }
    }

    private var vendors: [String] {
        Array(Set(client.vst.available.map { $0.vendor.isEmpty ? "Unknown" : $0.vendor })).sorted()
    }
    private var types: [String] {
        Array(Set(client.vst.available.map(\.primaryType))).sorted()
    }
    private var filtered: [VSTPlugin] {
        client.vst.available.filter { p in
            (search.isEmpty
                || p.name.localizedCaseInsensitiveContains(search)
                || p.vendor.localizedCaseInsensitiveContains(search))
            && (typeFilter.isEmpty   || p.primaryType == typeFilter)
            && (vendorFilter.isEmpty || (p.vendor.isEmpty ? "Unknown" : p.vendor) == vendorFilter)
        }.sorted { a, b in
            let fa = client.vst.favoriteIDs.contains(a.id)
            let fb = client.vst.favoriteIDs.contains(b.id)
            if fa != fb { return fa }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
    private var summary: String {
        let total  = client.vst.available.count
        let hidden = client.vst.disabledIDs.count
        if total == 0 { return "Never scanned" }
        return hidden == 0 ? "\(total) available" : "\(total - hidden) of \(total) available"
    }
}

private struct PluginRow: View {
    @Environment(DaemonClient.self) private var client
    let plugin: VSTPlugin

    var body: some View {
        let available = !client.vst.disabledIDs.contains(plugin.id)
        let favorite  = client.vst.favoriteIDs.contains(plugin.id)
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { available },
                set: { client.setPluginAvailable(id: plugin.id, available: $0) }))
                .labelsHidden()
                .disabled(plugin.offline)
            Button {
                client.setPluginFavorite(id: plugin.id, favorite: !favorite)
            } label: {
                Image(systemName: favorite ? "star.fill" : "star")
                    .foregroundStyle(favorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(plugin.offline)
            .help(favorite ? "Unstar" : "Star — shown first in the insert picker")
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                    .foregroundStyle(plugin.offline ? .secondary : (available ? .primary : .secondary))
                Text(plugin.vendor.isEmpty ? "Unknown" : plugin.vendor)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if plugin.offline {
                Text("Offline")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(.orange)
                    .help("This plug-in hung or crashed during scanning. Fix or remove it, then Rescan.")
            } else {
                Text(plugin.primaryType)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.12), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .opacity(plugin.offline ? 0.7 : (available ? 1 : 0.55))
    }
}

// MARK: - Recording

private struct RecordingSettingsPane: View {
    @Environment(DaemonClient.self) private var client

    var body: some View {
        Form {
            Section {
                LabeledContent("File format") {
                    Picker("", selection: Binding(
                        get: { client.config.recordingFormat },
                        set: { value in client.updateConfig { $0.recordingFormat = value } })) {
                        Text("WAV · 32-bit float").tag("float32")
                        Text("WAV · 24-bit PCM").tag("pcm24")
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                .help("32-bit float preserves headroom exactly; 24-bit PCM is smaller and what studios usually exchange.")

                LabeledContent("Destination") {
                    HStack(spacing: 8) {
                        Text(client.config.recordingFolderPath.isEmpty
                             ? "Music → Hydra Recordings"
                             : client.config.recordingFolderPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 240, alignment: .trailing)
                        Button("Choose…") { chooseFolder() }
                        if !client.config.recordingFolderPath.isEmpty {
                            Button("Reset") { client.updateConfig { $0.recordingFolderPath = "" } }
                        }
                    }
                }
                .help("Where recordings land. Default: Music → Hydra Recordings.")
            } header: {
                Text("Recording")
            } footer: {
                Text("32-bit float preserves headroom exactly; 24-bit PCM is smaller and what studios usually exchange. Recordings are written to Music → Hydra Recordings unless you choose another folder.")
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories  = true
        panel.canChooseFiles        = false
        panel.canCreateDirectories  = true
        panel.prompt                = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            client.updateConfig { $0.recordingFolderPath = url.path }
        }
    }
}

// MARK: - Control

private struct ControlSettingsPane: View {
    @Environment(DaemonClient.self) private var client

    var body: some View {
        Form {
            Section {
                LabeledContent("Enable OSC") {
                    Toggle("", isOn: Binding(
                        get: { client.config.oscEnabled },
                        set: { value in client.updateConfig { $0.oscEnabled = value } }))
                    .labelsHidden()
                }
                .help("UDP server for consoles, TouchOSC and Stream Deck.")

                if client.config.oscEnabled {
                    LabeledContent("UDP port") {
                        TextField("Port", value: Binding(
                            get: { client.config.oscPort },
                            set: { value in client.updateConfig { $0.oscPort = max(1024, min(65535, value)) } }),
                                  format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("OSC Remote Control")
            } footer: {
                Text("A UDP server for consoles, TouchOSC and Stream Deck. Addresses: /hydra/scene/apply, /hydra/scene/save, /hydra/record/start, /hydra/record/stop.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced

private struct AdvancedSettingsPane: View {
    @Environment(DaemonClient.self) private var client
    @State private var confirmReset   = false
    @State private var exportResult: String?
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var welcomeReset = false

    private var dataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hydra", isDirectory: true)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Hydra data") {
                    Button("Open") { NSWorkspace.shared.open(dataFolder) }
                }
                LabeledContent("Recordings") {
                    Button("Open") {
                        let folder = client.config.recordingFolderPath.isEmpty
                            ? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
                                .appendingPathComponent("Hydra Recordings", isDirectory: true)
                            : URL(fileURLWithPath: client.config.recordingFolderPath, isDirectory: true)
                        NSWorkspace.shared.open(folder)
                    }
                }
            } header: {
                Text("Folders")
            } footer: {
                Text("Hydra data holds the matrix, scenes, interfaces and settings (JSON files the daemon reads).")
            }

            Section {
                LabeledContent(exportResult ?? "Export the whole setup as JSON") {
                    Button("Export…") { exportSetup() }
                }
                .help("Interfaces, patches, scenes, labels, strips and settings in one file.")
            } header: {
                Text("Backup")
            } footer: {
                Text("Saves interfaces, patches, scenes, labels, strips and settings together in a single JSON file.")
            }

            Section {
                LabeledContent("Daemon") {
                    Text("\(Hydra.daemonHost):\(Hydra.daemonPort) · \(client.status?.daemonVersion ?? "offline")")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LabeledContent("App version") {
                    Text(Hydra.versionString)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Soundcard") {
                    Text(client.status?.backplaneDeviceName ?? "not installed")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Logs") {
                    Button("Export Diagnostics…") {
                        Diagnostics.export(statusSummary: diagnosticsStatusSummary())
                    }
                }
                .help("Collects the last 2h of app + daemon logs, environment and status into one file for support.")
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Export Diagnostics gathers recent logs from both the app and the daemon. Attach the file when reporting an issue.")
            }

            Section {
                LabeledContent("Welcome screen") {
                    HStack(spacing: 8) {
                        Button("Show Now") {
                            NotificationCenter.default.post(name: .showWelcomeSheet, object: nil)
                        }
                        Button("Show on Next Launch") {
                            hasSeenWelcome = false
                            welcomeReset = true
                        }
                        .disabled(welcomeReset)
                    }
                }
            } header: {
                Text("Welcome")
            } footer: {
                Text(welcomeReset
                     ? "The welcome screen will appear the next time Hydra starts."
                     : "Replay the first-run welcome and installation flow.")
            }

            Section {
                LabeledContent("Restore default settings") {
                    Button("Reset…", role: .destructive) { confirmReset = true }
                        .confirmationDialog("Reset all Hydra settings?",
                                            isPresented: $confirmReset) {
                            Button("Reset settings", role: .destructive) {
                                client.setConfig(ConfigPayload())
                                for key in ["patchViewMode", "groupChannels",
                                            "sidebarWidth", "soundcardChannels"] {
                                    UserDefaults.standard.removeObject(forKey: key)
                                }
                            }
                        } message: {
                            Text("Settings return to defaults. Patches, interfaces and scenes are NOT touched.")
                        }
                }
                .help("Preferences return to defaults. Patches, interfaces and scenes are NOT touched.")
            } header: {
                Text("Reset")
            } footer: {
                Text("Preferences return to defaults. Patches, interfaces and scenes are NOT touched.")
            }
        }
        .formStyle(.grouped)
    }

    /// Human-readable snapshot of the live daemon state, embedded at the top of
    /// an exported diagnostics file.
    private func diagnosticsStatusSummary() -> String {
        let s = client.status
        return """
        Connection:  \(client.connectionState)
        Daemon:      \(s?.daemonVersion ?? "offline") @ \(Hydra.daemonHost):\(Hydra.daemonPort)
        Soundcard:   \(s?.backplaneDeviceName ?? "not installed")
        Engine:      \(s?.engineRunning == true ? "running" : "stopped")
        CPU load:    \(s.map { String(format: "%.0f%%", $0.cpuLoad * 100) } ?? "—")
        XRUNs:       \(s?.xruns ?? 0)
        Connections: \(client.connections.count)
        Interfaces:  \(client.interfaces.count)
        Strips:      \(client.strips.count)
        """
    }

    // MARK: Export

    private struct SetupExport: Codable {
        let exportedAt:  Date
        let appVersion:  String
        let interfaces:  [VirtualInterfaceInfo]
        let connections: [Connection]
        let scenes:      [PatchScene]
        let labels:      ChannelLabelsPayload
        let strips:      [StripInfo]
        let config:      ConfigPayload
    }

    private func exportSetup() {
        let export = SetupExport(
            exportedAt:  Date(),
            appVersion:  Hydra.versionString,
            interfaces:  client.interfaces,
            connections: client.connections,
            scenes:      client.scenes,
            labels:      client.labels,
            strips:      client.strips,
            config:      client.config)
        let panel = NSSavePanel()
        panel.allowedContentTypes  = [.json]
        panel.nameFieldStringValue = "Hydra Setup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting   = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(export).write(to: url, options: .atomic)
            exportResult = "Saved: \(url.lastPathComponent)"
        } catch {
            exportResult = "Export failed: \(error.localizedDescription)"
        }
    }
}
