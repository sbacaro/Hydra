// Hydra Audio — GPL-3.0
// Main window — macOS 26 Liquid Glass native shell.
//
// Architecture (Apple HIG, macOS Tahoe):
//   • NavigationSplitView: sidebar (owns its section tabs) + detail (grid).
//   • .inspector() modifier: native trailing channel-strip panel (macOS 14+).
//   • Toolbar: brand mark · status indicators · event bell · inspector toggle.
//     Navigation belongs in the sidebar — the toolbar never duplicates it.
//   • ⌘K command palette overlays the window via a transparent ZStack.

import SwiftUI
import HydraCore

struct ContentView: View {
    @Environment(DaemonClient.self) private var client
    @EnvironmentObject private var daemon: DaemonService
    @EnvironmentObject private var updater: Updater
    @StateObject private var installer = InstallManager()
    @State private var selection: GridSelection?
    @State private var channelFocus: ChannelFocus?
    /// Bridge selected in the sidebar → its config shows in the inspector
    /// (mutually exclusive with a cell/channel selection).
    @State private var selectedBridge: String?
    @State private var sidebarTab: SidebarTab = .devices
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showInspector = true
    @State private var showEvents    = false
    // When the user closes the event popover, new events stop auto-opening it
    // (silenced) until they open the bell again. See the bell `onChange` handlers.
    @State private var eventsSilenced = false
    @State private var showPalette   = false
    @State private var showWelcome   = false
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(tab: $sidebarTab, selectedBridge: $selectedBridge)
        } detail: {
            GridView(selection: $selection, channelFocus: $channelFocus)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Native macOS inspector panel — system handles resize, collapse chrome,
        // and the keyboard shortcut. Width matches the previous 264-pt strip.
        .inspector(isPresented: $showInspector) {
            InspectorView(selection: $selection, channelFocus: $channelFocus,
                          selectedBridge: $selectedBridge)
                .inspectorColumnWidth(min: 240, ideal: 264, max: 340)
        }
        // Cell, channel and bridge selections are mutually exclusive; selecting
        // any of them reveals the inspector and clears the others.
        .onChange(of: selection) { _, newValue in
            if newValue != nil { showInspector = true; channelFocus = nil; selectedBridge = nil }
        }
        .onChange(of: channelFocus) { _, newValue in
            if newValue != nil { showInspector = true; selection = nil; selectedBridge = nil }
        }
        .onChange(of: selectedBridge) { _, newValue in
            if newValue != nil { showInspector = true; selection = nil; channelFocus = nil }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                BrandMark(size: 20)
            }
            // The brand mark is decorative — hide the Liquid Glass container the
            // toolbar draws around custom items by default (macOS 26), so the logo
            // sits cleanly with no capsule/border.
            .sharedBackgroundVisibility(.hidden)
            // Status indicators moved OUT of the toolbar to the bottom status bar
            // (see .safeAreaInset below). The toolbar is for actions, not read-only
            // health readouts — per the Toolbars HIG — so it now carries only the
            // brand mark and the two action buttons.
            ToolbarItemGroup(placement: .automatic) {
                bellButton
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showInspector.toggle() }
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help(showInspector ? "Hide channel strip inspector" : "Show channel strip inspector")
            }
        }
        .navigationTitle("Hydra Soundcard")
        // Bottom status bar — the HIG-correct home for read-only health readouts
        // (Daemon · Backplane · Engine · CPU), like Xcode's status bar. Spans the
        // whole window bottom and stays out of the action-only toolbar.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            statusBar
        }
        // In-app update nudge — appears when the updater finds a newer release.
        // The download + verified install runs automatically (see Updater.swift).
        .safeAreaInset(edge: .top, spacing: 0) {
            if let version = updater.availableVersion {
                updateBanner(version: version)
            }
        }
        .overlay {
            if showPalette { paletteOverlay }
        }
        // Startup loading screen: the app launches the daemon directly, so show a
        // clean "starting up" state until the WebSocket connects (instead of an
        // empty/offline grid). Hidden during first-run onboarding.
        .overlay {
            if client.connectionState != .connected && !showWelcome {
                loadingOverlay
            }
        }
        .animation(.easeInOut(duration: 0.25), value: client.connectionState)
        // Notifications: a new live event pops the event bell open to show it,
        // unless the user has silenced it by closing the popover. Closing silences;
        // opening the bell (or its auto-opening) clears the silence again.
        .onChange(of: client.liveEventTick) {
            if !eventsSilenced { showEvents = true }
        }
        .onChange(of: showEvents) { _, open in
            eventsSilenced = !open
        }
        // ⌘K from anywhere in the window.
        .background(
            Button("") { showPalette.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
        )
        .frame(minWidth: 1080, minHeight: 660)
        // Settings is now a native Settings window (see HydraApp). ⌘, / the
        // Settings… menu item / the command palette's openSettings() all open it.
        // First-run onboarding — auto-present once; reopenable from Help.
        .sheet(isPresented: $showWelcome) {
            WelcomeSheet()
                .environment(client)
                .environmentObject(daemon)
        }
        .onAppear {
            if !hasSeenWelcome {
                showWelcome = true
            } else {
                // Onboarded already: after an app update the bundled driver may be
                // newer than the installed one — reinstall it (prompts admin only
                // when it actually changed).
                installer.refreshDriverIfOutdated()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showWelcomeSheet)) { _ in
            showWelcome = true
        }
    }

    // MARK: - Startup loading

    private var loadingOverlay: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Starting Hydra")
                    .font(.title3.weight(.semibold))
                Text(client.connectionState == .connecting
                     ? "Connecting to the audio engine…"
                     : "Launching the audio engine…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .transition(.opacity)
    }

    // MARK: - Update banner

    private func updateBanner(version: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text("Hydra \(version) is available.")
                .font(.callout.weight(.medium))
            Spacer()
            Button("Update…") { updater.checkForUpdates() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Status indicators

    // MARK: - Bottom status bar

    private var statusBar: some View {
        HStack(spacing: 16) {
            statusDot(
                ok: client.connectionState == .connected,
                label: client.connectionState == .connected ? "Daemon" : "Offline",
                help: "Daemon · \(Hydra.daemonHost):\(Hydra.daemonPort) · \(client.status?.daemonVersion ?? "")"
            )
            statusDot(
                ok: client.status?.backplaneInstalled == true,
                label: "Backplane",
                help: "Hydra Engine · \(client.status?.inputChannels ?? 0)×\(client.status?.outputChannels ?? 0)"
            )
            statusDot(
                ok: client.status?.engineRunning == true,
                label: "Engine",
                help: "Patch matrix IOProc"
            )
            if client.status?.engineRunning == true {
                Divider().frame(height: 14)
                let xruns = client.status?.xruns ?? 0
                let cpu   = Int(((client.status?.cpuLoad ?? 0) * 100).rounded())
                // Colour by CPU load, not by XRUNs: grey when comfortable, amber
                // from 50%, red from 75%. (XRUN count stays in the tooltip.)
                let cpuColor: Color = cpu >= 75 ? Theme.clip
                                    : cpu >= 50 ? Theme.warning
                                    : .secondary
                Text("CPU \(cpu)%")
                    .font(.system(size: 13, design: .monospaced))   // macOS standard 13pt
                    .monospacedDigit()
                    .foregroundStyle(cpuColor)
                    .help("Render load · \(xruns) XRUN\(xruns == 1 ? "" : "s") · \(Int((client.status?.sampleRate ?? 0) / 1_000)) kHz")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // Compact status readout: glyph SHAPE (check vs triangle) carries state in
    // addition to color, so colorblind users can read it — per the Color /
    // Accessibility guidelines' "convey information with more than color alone."
    private func statusDot(ok: Bool, label: String, help: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.body)                       // macOS standard 13pt
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(ok ? Theme.live : Theme.warning)
            Text(label)
                .font(.body)                       // macOS standard 13pt
                .foregroundStyle(.secondary)
        }
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(label): \(ok ? "OK" : "needs attention")"))
    }

    // MARK: - Event bell

    private var bellButton: some View {
        let hasProblem = client.events.contains { $0.kind == .error || $0.kind == .warning }
        return Button { showEvents = true } label: {
            Image(systemName: hasProblem ? "bell.badge" : "bell")
        }
        .help("Event log — drops, blocks and failures")
        .popover(isPresented: $showEvents, arrowEdge: .bottom) { eventsPopover }
    }

    private var eventsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Events")
                .font(.headline)
                .padding(.bottom, 2)
            if client.events.isEmpty {
                Text("Nothing yet — drops, feedback blocks and failures appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(client.events) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: iconName(for: event.kind))
                                    .font(.system(size: 12))
                                    .foregroundStyle(color(for: event.kind))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.message)
                                        .font(.callout)
                                    Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - ⌘K palette

    private var paletteOverlay: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { showPalette = false }
            CommandPalette(
                isPresented: $showPalette,
                sidebarTab: $sidebarTab,
                sidebarVisible: sidebarVisibleBinding
            )
            .padding(.top, 60)
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.15), value: showPalette)
    }

    private var sidebarVisibleBinding: Binding<Bool> {
        Binding(
            get: { columnVisibility != .detailOnly },
            set: { show in columnVisibility = show ? .all : .detailOnly }
        )
    }

    // MARK: - Helpers

    private func iconName(for kind: HydraEvent.Kind) -> String {
        switch kind {
        case .error:            return "xmark.octagon.fill"
        case .warning:          return "exclamationmark.triangle.fill"
        case .resourceLost:     return "bolt.horizontal.circle"
        case .resourceRestored: return "checkmark.circle.fill"
        case .installed, .info: return "info.circle.fill"
        }
    }

    private func color(for kind: HydraEvent.Kind) -> Color {
        switch kind {
        case .error:            return Theme.clip
        case .warning:          return Theme.warning
        case .resourceLost:     return Theme.warning
        case .resourceRestored: return Theme.live
        case .installed, .info: return Theme.accent
        }
    }
}
