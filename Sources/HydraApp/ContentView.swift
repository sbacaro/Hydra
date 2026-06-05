// Hydra Audio — GPL-3.0
// Main window — final shell (user-approved prototype): custom top bar with
// brand mark (status lives in the BOTTOM bar), toolbar tabs driving the
// paginated patch grid in the center, the channel strip on the right, and a
// status bar at the bottom. Honest data only — every dot and number is real.

import SwiftUI
import HydraCore

struct ContentView: View {
    @EnvironmentObject private var client: DaemonClient
    @State private var selection: GridSelection?
    @State private var sidebarTab: SidebarTab = .devices
    @State private var sidebarVisible = true
    @State private var showEvents = false
    @AppStorage("sidebarWidth") private var sidebarWidth = 230.0

    var body: some View {
        VStack(spacing: 0) {
            topBar
            toolbar
            HStack(spacing: 0) {
                if sidebarVisible {
                    SidebarView(tab: sidebarTab, width: sidebarWidth)
                        .transition(.move(edge: .leading))
                    // Resize handle
                    Color.clear
                        .frame(width: 6)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    sidebarWidth = min(380, max(180, sidebarWidth + value.translation.width))
                                }
                        )
                        .help("Drag to resize the sidebar")
                }
                GridView(selection: $selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                InspectorView(selection: $selection)
            }
            .frame(maxHeight: .infinity)
            statusBar
        }
        .background(Theme.backgroundGradient)
        .background(ambientGlow)
        .overlay(alignment: .topTrailing) { toastsOverlay }
        .preferredColorScheme(.dark)
        .frame(minWidth: 1080, minHeight: 660)
        // Hidden-title-bar window: extend under the title-bar zone so the
        // brand row sits ON the traffic lights' line (the 58 pt leading
        // spacer in the top bar clears them), instead of one row below.
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: - Toasts (transient, discreet — full history behind the bell)

    private var toastsOverlay: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(client.toasts) { event in
                HStack(spacing: 7) {
                    Image(systemName: icon(for: event.kind))
                        .font(.system(size: 13))
                        .foregroundStyle(color(for: event.kind))
                    Text(event.message)
                        .font(.caption)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: 340, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 0.5))
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.top, 88)
        .padding(.trailing, 14)
        .animation(.easeOut(duration: 0.2), value: client.toasts)
        .allowsHitTesting(false)
    }

    private func icon(for kind: HydraEvent.Kind) -> String {
        switch kind {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .resourceLost: return "bolt.horizontal.circle"
        case .resourceRestored: return "checkmark.circle.fill"
        case .installed, .info: return "info.circle.fill"
        }
    }

    private func color(for kind: HydraEvent.Kind) -> Color {
        switch kind {
        case .error: return Theme.clip
        case .warning: return Theme.warning
        case .resourceLost: return Theme.warning
        case .resourceRestored: return Theme.live
        case .installed, .info: return Theme.accent
        }
    }

    /// Subtle ambient light blobs from the prototype (blue + green, no violet).
    private var ambientGlow: some View {
        ZStack {
            Circle()
                .fill(Theme.accent.opacity(0.06))
                .frame(width: 600, height: 600)
                .blur(radius: 60)
                .offset(x: -200, y: -260)
            Circle()
                .fill(Theme.live.opacity(0.04))
                .frame(width: 480, height: 320)
                .blur(radius: 60)
                .offset(x: 320, y: 260)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Top bar (brand + event bell only)

    private var topBar: some View {
        HStack(spacing: 10) {
            // Space for the traffic lights (hidden-title-bar window).
            Spacer().frame(width: 58)

            HStack(spacing: 9) {
                BrandMark(size: 26)
                Text("Hydra Soundcard")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }

            Spacer()

            // Event log (bell)
            Button {
                showEvents = true
            } label: {
                Image(systemName: client.events.contains(where: { $0.kind == .error || $0.kind == .warning })
                      ? "bell.badge" : "bell")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Event log — drops, blocks and failures")
            .popover(isPresented: $showEvents) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Events")
                        .font(.headline)
                    if client.events.isEmpty {
                        Text("Nothing yet — drops, feedback blocks and failures show up here.")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(client.events) { event in
                                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                                        Image(systemName: icon(for: event.kind))
                                            .font(.system(size: 12))
                                            .foregroundStyle(color(for: event.kind))
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(event.message)
                                                .font(.caption)
                                                .foregroundStyle(Theme.textPrimary)
                                            Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                                .font(.system(size: 10)).monospacedDigit()
                                                .foregroundStyle(Theme.textTertiary)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 300)
                    }
                }
                .padding(14)
                .frame(width: 320)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(.ultraThinMaterial.opacity(0.6))
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 0.5) }
    }

    // MARK: - Toolbar (sidebar tabs)

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { sidebarVisible.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Show/hide the sidebar")

            HStack(spacing: 2) {
                ForEach(SidebarTab.allCases, id: \.self) { tab in
                    Button {
                        sidebarTab = tab
                        sidebarVisible = true
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(sidebarTab == tab && sidebarVisible
                                             ? Theme.textPrimary : Theme.textTertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(sidebarTab == tab && sidebarVisible
                                          ? Color.white.opacity(0.10) : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline, lineWidth: 0.5))

            Spacer()

            Text("In → Out")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .help("Rows are sources; columns are destinations. Click a cell to subscribe, click again to unsubscribe.")
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Color.black.opacity(0.25))
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 0.5) }
    }

    // MARK: - Status bar — the single home for system status (moved here
    // from the top bar by user request; one type size, consistent casing).

    private var statusBar: some View {
        HStack(spacing: 16) {
            statusDot(ok: client.connectionState == .connected,
                      label: client.connectionState == .connected
                          ? "Daemon \(client.status?.daemonVersion ?? "")"
                          : "Daemon offline — retrying",
                      help: "Connection to hydrad on \(Hydra.daemonHost):\(Hydra.daemonPort)")
            statusDot(ok: client.status?.backplaneInstalled == true,
                      label: client.status?.backplaneInstalled == true
                          ? "Backplane \(client.status?.inputChannels ?? 0)×\(client.status?.outputChannels ?? 0)"
                          : "Backplane not installed",
                      help: "The Hydra Virtual Soundcard (256-channel loopback pool)")
            statusDot(ok: client.status?.engineRunning == true,
                      label: client.status?.engineRunning == true ? "Engine running" : "Engine stopped",
                      help: "The patch matrix engine (IOProc attached to the backplane)")
            Spacer()
            Text("\(client.connections.count) connections · \(Int((client.status?.sampleRate ?? 0) / 1000)) kHz · 32-bit float")
                .font(.system(size: 13)).monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Color.black.opacity(0.45))
        .overlay(alignment: .top) { Theme.hairline.frame(height: 0.5) }
    }

    private func statusDot(ok: Bool, label: String, help: String = "") -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ok ? Theme.live : Theme.warning)
                .frame(width: 6, height: 6)
                .shadow(color: (ok ? Theme.live : Theme.warning).opacity(0.5), radius: 2)
            Text(label)
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
        }
        .help(help)
    }
}
