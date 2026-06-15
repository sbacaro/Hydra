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
    @EnvironmentObject private var client: DaemonClient
    @EnvironmentObject private var daemon: DaemonService
    @EnvironmentObject private var updater: Updater
    @StateObject private var installer = InstallManager()
    @State private var selection: GridSelection?
    @State private var channelFocus: ChannelFocus?
    @State private var sidebarTab: SidebarTab = .devices
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showInspector = true
    @State private var showEvents    = false
    @State private var showPalette   = false
    @State private var showWelcome   = false
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(tab: $sidebarTab)
        } detail: {
            GridView(selection: $selection, channelFocus: $channelFocus)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Native macOS inspector panel — system handles resize, collapse chrome,
        // and the keyboard shortcut. Width matches the previous 264-pt strip.
        .inspector(isPresented: $showInspector) {
            InspectorView(selection: $selection, channelFocus: $channelFocus)
                .inspectorColumnWidth(min: 240, ideal: 264, max: 340)
        }
        // Auto-reveal the inspector when a cell is selected; a cell and a single
        // channel are mutually exclusive selections.
        .onChange(of: selection) { _, newValue in
            if newValue != nil { showInspector = true; channelFocus = nil }
        }
        .onChange(of: channelFocus) { _, newValue in
            if newValue != nil { showInspector = true; selection = nil }
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
        // In-app update nudge — appears when Sparkle has found a new release.
        // The actual update flow runs through Sparkle's standard UI.
        .safeAreaInset(edge: .top, spacing: 0) {
            if let version = updater.availableVersion {
                updateBanner(version: version)
            }
        }
        .overlay(alignment: .topTrailing) { toastsOverlay }
        .overlay {
            if showPalette { paletteOverlay }
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
                .environmentObject(client)
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
                help: "Hydra Virtual Soundcard · \(client.status?.inputChannels ?? 0)×\(client.status?.outputChannels ?? 0)"
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
                Text("CPU \(cpu)%")
                    .font(.system(size: 13, design: .monospaced))   // macOS standard 13pt
                    .monospacedDigit()
                    .foregroundStyle(xruns > 0 ? Theme.warning : .secondary)
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

    // MARK: - Toast notifications

    private var toastsOverlay: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(client.toasts) { event in
                HStack(spacing: 8) {
                    Image(systemName: iconName(for: event.kind))
                        .font(.system(size: 13))
                        .foregroundStyle(color(for: event.kind))
                    Text(event.message)
                        .font(.callout)
                        .lineLimit(2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: 340, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.top, 16)
        .padding(.trailing, 14)
        .animation(.easeOut(duration: 0.2), value: client.toasts)
        .allowsHitTesting(false)
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
