// Hydra Audio — GPL-3.0
// Left sidebar — macOS 26 Liquid Glass native sidebar.
//
// Apple HIG changes vs previous version:
//   • Section tabs (Devices / Apps / Network) live INSIDE the sidebar via
//     .safeAreaInset(edge: .top), not in the main window toolbar. Navigation
//     is the sidebar's responsibility — the toolbar never duplicates it.
//   • txBadge custom capsule pills → .bordered .controlSize(.mini) buttons
//     with .tint() for the active state. Native hit targets, system styling.
//   • Row text uses semantic colors (.primary, .secondary, .tertiary) so the
//     sidebar adapts correctly to both Light and Dark Mode.
//   • List separators and backgrounds follow the .sidebar listStyle defaults.
//   • InfoButton popover unchanged — it's already HIG-correct.

import SwiftUI
import HydraCore

enum SidebarTab: String, CaseIterable {
    case devices = "Devices"
    case apps    = "Apps"
    case network = "Network"
}

struct SidebarView: View {
    @Environment(DaemonClient.self) private var client
    @Binding var tab: SidebarTab
    @State private var showAddInterface = false
    @AppStorage("experimentalModules") private var experimentalModules = false

    var body: some View {
        List {
            switch tab {

                // MARK: Devices
                case .devices:
                    Section {
                        if client.interfaces.isEmpty {
                            emptyHint("None yet — create your first interface to begin patching.")
                        } else {
                            ForEach(client.interfaces) { iface in
                                interfaceRow(iface)
                            }
                        }
                        Button {
                            showAddInterface = true
                        } label: {
                            Label("Add Interface…", systemImage: "plus")
                        }
                        .tint(.accentColor)
                        .sheet(isPresented: $showAddInterface) {
                            AddInterfaceForm()
                        }
                        Text("\(client.allocatedInChannels)/\(Hydra.poolChannels) TX · \(client.allocatedOutChannels)/\(Hydra.poolChannels) RX")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .listRowSeparator(.hidden)
                            .help("Independent TX and RX pools of \(Hydra.poolChannels) channels each.")
                    } header: {
                        sectionHeader("Virtual Interfaces",
                                      info: "Named blocks of the Hydra Soundcard's 256-channel pool — only these appear in the grid.")
                    }

                    Section {
                        if client.devices.isEmpty {
                            emptyHint("No audio interfaces detected.")
                        } else {
                            ForEach(client.devices) { device in
                                deviceRow(device)
                            }
                        }
                    } header: {
                        sectionHeader("Audio Interfaces",
                                      info: "Devices added to the grid get their own audio path with drift correction (ASRC).")
                    }

                // MARK: Apps
                case .apps:
                    Section {
                        if client.apps.isEmpty {
                            emptyHint("Apps appear here once they use audio.")
                        } else {
                            ForEach(client.apps) { app in
                                appRow(app)
                            }
                        }
                    } header: {
                        sectionHeader("App Capture",
                                      info: "Captured apps appear as two mono lanes (L/R) while still playing normally.")
                    }

                // MARK: Network
                case .network:
                    Section {
                        HStack(spacing: 7) {
                            Image(systemName: client.aes67.ptpLocked
                                  ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(client.aes67.ptpLocked ? Theme.live : Theme.warning)
                            Text(client.aes67.ptpLocked
                                 ? "PTP locked · \(client.aes67.ptpGrandmaster)"
                                 : "PTP: no grandmaster")
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .listRowSeparator(.hidden)
                        .help(client.aes67.ptpLocked
                              ? "Following clock — grandmaster \(client.aes67.ptpGrandmaster), domain \(client.aes67.ptpDomain)."
                              : "No PTP grandmaster — TX free-runs.")
                        if client.aes67.streams.isEmpty {
                            emptyHint("No AES67 streams announced yet.")
                        } else {
                            ForEach(client.aes67.streams) { stream in
                                streamRow(stream)
                            }
                        }
                    } header: {
                        sectionHeader("AES67",
                                      info: "Standards-based audio-over-IP. Hydra slaves to PTP and subscribes to SAP-announced multicast streams.")
                    }

                    if experimentalModules {
                        Section {
                            if client.aes67.devices.isEmpty {
                                emptyHint("No devices on the network yet.")
                            } else {
                                ForEach(client.aes67.devices) { device in
                                    HStack(spacing: 8) {
                                        Circle().fill(Theme.live).frame(width: 6, height: 6)
                                        Text(device.name)
                                            .font(.callout.weight(.semibold))
                                            .lineLimit(1)
                                        if device.channels > 0 {
                                            Text("\(device.channels) ch")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text("On network")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .help("Discovered via _netaudio mDNS.")
                                }
                            }
                        } header: {
                            sectionHeader("Inferno Protocol",
                                          info: "Dante-compatible devices on the network via _netaudio mDNS. Reverse-engineered interop for personal use.")
                        }
                    }

                    Section {
                        if !client.ndi.runtimeAvailable {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("NDI runtime not installed — Hydra loads it dynamically (GPL constraint).")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Link("Download NDI Runtime…",
                                     destination: URL(string: Hydra.ndiRedistURL)!)
                                    .font(.callout.weight(.semibold))
                            }
                            .listRowSeparator(.hidden)
                        } else if client.ndi.sources.isEmpty {
                            emptyHint("No NDI sources on the network yet\(client.ndi.runtimeVersion.map { " (runtime \($0))" } ?? "").")
                        } else {
                            ForEach(client.ndi.sources) { source in
                                ndiRow(source)
                            }
                        }
                    } header: {
                        sectionHeader("NDI Sources",
                                      info: "NDI audio sources on the network. Flag a virtual interface as NDI TX to broadcast it.")
                    }

                    if experimentalModules {
                        Section {
                            if client.modules.modules.isEmpty {
                                emptyHint("No modules loaded. Drop a .dylib into ~/Library/Application Support/Hydra/modules/ and restart the daemon.")
                            } else {
                                ForEach(client.modules.modules) { module in
                                    Label("\(module.name) \(module.version)",
                                          systemImage: "puzzlepiece.extension")
                                        .font(.callout.weight(.semibold))
                                }
                                ForEach(client.modules.sources) { source in
                                    moduleSourceRow(source)
                                }
                                if client.modules.sources.isEmpty {
                                    emptyHint("Loaded, but no sources discovered yet.")
                                }
                            }
                        } header: {
                            sectionHeader("Modules",
                                          info: "External plugin host. Modules are separate .dylibs, never shipped with Hydra.")
                        }
                    }
                }
        }
        .listStyle(.sidebar)
        // The bottom status bar (Daemon · Backplane · Engine · CPU) is applied as
        // a safeAreaInset on the NavigationSplitView, but that inset doesn't reach
        // the sidebar column's scrolling list — so its last rows slide under the
        // bar. Reserve matching clearance here so the list ends ABOVE the bar.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 30)
        }
        // Section picker anchored to the top of the sidebar. An opaque .bar
        // background (matching the bottom status bar) occludes the scrolling list
        // so its text never bleeds through behind the picker; a bottom Divider
        // gives the strip a crisp edge.
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(SidebarTab.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String, info: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            InfoButton(text: info)
        }
    }

    // MARK: - Empty hint

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)   // wrap, never truncate
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowSeparator(.hidden)
    }

    // MARK: - Interface row

    private func interfaceRow(_ iface: VirtualInterfaceInfo) -> some View {
        let recording = client.recording(for: iface.id) != nil
        // Source-list row: icon + name + directional I/O badges. The most common
        // actions (record / TX / delete) are reachable from BOTH a visible ⋯ menu
        // (discoverable) and the right-click context menu (power users).
        return HStack(spacing: 8) {
            Image(systemName: "rectangle.3.group")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(iface.name)
                    .lineLimit(1)
                ioBadges(inputs: iface.inChannels, outputs: iface.outChannels, stereo: iface.stereo)
            }
            Spacer(minLength: 6)
            if recording {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(Theme.clip)
                    .help("Recording to disk")
            }
            if iface.aes67TX { statusTag("AES") }
            if iface.ndiTX   { statusTag("NDI") }
            interfaceMenu(iface, recording: recording)
        }
        .contentShape(Rectangle())
        .help("Pool: TX \(iface.inBase + 1)–\(iface.inBase + max(iface.inChannels, 1)) · RX \(iface.outBase + 1)–\(iface.outBase + max(iface.outChannels, 1))")
        .contextMenu { interfaceMenuItems(iface, recording: recording) }
    }

    /// Actions shared by the visible ⋯ menu and the right-click context menu.
    @ViewBuilder
    private func interfaceMenuItems(_ iface: VirtualInterfaceInfo, recording: Bool) -> some View {
        Button(recording ? "Stop Recording" : "Record Output…") {
            if recording { client.stopRecording(iface.id) }
            else         { client.startRecording(iface.id) }
        }
        Toggle("Announce on the network (AES67 TX)", isOn: Binding(
            get: { iface.aes67TX },
            set: { client.setInterfaceAES67(iface.id, enabled: $0) }))
        Toggle("Broadcast as NDI source (TX)", isOn: Binding(
            get: { iface.ndiTX },
            set: { client.setInterfaceNDI(iface.id, enabled: $0) }))
            .disabled(!client.ndi.runtimeAvailable)
        Divider()
        Button("Delete Interface", role: .destructive) {
            client.deleteInterface(iface.id)
        }
    }

    /// Always-visible ⋯ button so the row's actions aren't hidden behind a
    /// right-click (the System Settings / Music pattern for list rows).
    private func interfaceMenu(_ iface: VirtualInterfaceInfo, recording: Bool) -> some View {
        Menu {
            interfaceMenuItems(iface, recording: recording)
        } label: {
            Image(systemName: "ellipsis.circle")
                .imageScale(.medium)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)        // .borderless dims the label further → near-black in Dark Mode
        .fixedSize()
        .help("Interface actions")
    }

    private func statusTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
            .help("\(text) TX on")
    }

    // MARK: - Directional I/O badges
    //
    // The person's request: read input vs output at a glance. Each badge pairs a
    // directional arrow with a written "in"/"out" label and the channel count —
    // meaning is carried by icon + text, never color alone (HIG: Accessibility).

    @ViewBuilder
    private func ioBadges(inputs inCh: Int, outputs outCh: Int, stereo: Bool = false) -> some View {
        HStack(spacing: 9) {
            if inCh > 0 {
                ioBadge(arrow: "arrow.down", count: inCh, label: "in")
                    .help("\(inCh) input channel\(inCh == 1 ? "" : "s") — what plays INTO this")
            }
            if outCh > 0 {
                ioBadge(arrow: "arrow.up", count: outCh, label: "out")
                    .help("\(outCh) output channel\(outCh == 1 ? "" : "s") — what is recorded/sent FROM this")
            }
            if inCh == 0 && outCh == 0 {
                Text("no channels")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if stereo {
                Text("stereo")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func ioBadge(arrow: String, count: Int, label: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: arrow)
                .font(.system(size: 9, weight: .bold))
            Text("\(count) \(label)")
                .font(.caption)
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - Device row

    private func deviceRow(_ device: PhysicalDeviceInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: deviceIcon(device))
                .foregroundStyle(device.present ? Theme.live : .secondary)
                .frame(width: 20)
                .help(device.present ? "Connected"
                                     : "Offline — patches kept, re-binds on return")
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .foregroundStyle(device.present ? .primary : .secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(deviceKind(device))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    ioBadges(inputs: device.inputChannels, outputs: device.outputChannels)
                }
            }
            Spacer(minLength: 6)
            InfoPopoverButton { DeviceDetailView(device: device).environment(client) }
            Toggle("", isOn: Binding(
                get: { device.used },
                set: { client.setDeviceUse(uid: device.uid, used: $0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(.accentColor)
                .help("Add this device's channels to the patch grid")
        }
    }

    private func deviceIcon(_ device: PhysicalDeviceInfo) -> String {
        if device.inputChannels > 0 && device.outputChannels == 0 { return "mic" }
        if device.outputChannels > 0 && device.inputChannels == 0 { return "hifispeaker" }
        return "pianokeys"
    }

    /// A plain-language direction label, complementing the icon and I/O badges.
    private func deviceKind(_ device: PhysicalDeviceInfo) -> String {
        if device.inputChannels > 0 && device.outputChannels == 0 { return "Input" }
        if device.outputChannels > 0 && device.inputChannels == 0 { return "Output" }
        return "In/Out"
    }

    // MARK: - App row

    private func appRow(_ app: AppInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "macwindow")
                .foregroundStyle(app.isPlaying ? Theme.live : .secondary)
                .frame(width: 18)
                .help(app.isPlaying ? "Playing audio" : "Silent")
            Text(app.name)
                .foregroundStyle(app.isPlaying ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            InfoPopoverButton { AppCaptureDetailView(app: app).environment(client) }
            Toggle("", isOn: Binding(
                get: { app.captured },
                set: { client.setAppCapture(pid: app.pid, captured: $0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(.accentColor)
                .help("Capture — the app keeps playing normally, Hydra gets a tap copy")
        }
    }

    // MARK: - AES67 stream row

    private func streamRow(_ stream: Aes67Stream) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .foregroundStyle(stream.subscribed ? Theme.live : .secondary)
                .frame(width: 18)
                .help(stream.subscribed ? "Subscribed" : "Available")
            Text(stream.name)
                .foregroundStyle(stream.subscribed ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            InfoPopoverButton { StreamDetailView(stream: stream).environment(client) }
            Toggle("", isOn: Binding(
                get: { stream.subscribed },
                set: { client.subscribeStream(id: stream.id, subscribed: $0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(.accentColor)
                .help("Subscribe — joins the multicast group, adds channels to the grid")
        }
    }

    // MARK: - NDI source row

    private func ndiRow(_ source: NdiSourceInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(source.subscribed ? Theme.live : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name)
                    .foregroundStyle(source.subscribed ? .primary : .secondary)
                    .lineLimit(1)
                if source.channels > 0 {
                    Text("\(source.channels) ch @ \(Int(source.sampleRate)) Hz")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            Toggle("", isOn: Binding(
                get: { source.subscribed },
                set: { client.subscribeNdi(id: source.id, subscribed: $0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(.accentColor)
        }
    }

    // MARK: - Module source row

    private func moduleSourceRow(_ source: ModuleSourceInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(source.subscribed ? Theme.live : .secondary)
                .frame(width: 18)
            Text(source.channels > 0 ? "\(source.name) · \(source.channels)ch" : source.name)
                .foregroundStyle(source.subscribed ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Toggle("", isOn: Binding(
                get: { source.subscribed },
                set: { client.subscribeModuleSource(id: source.id, subscribed: $0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(.accentColor)
        }
    }

}

// MARK: - Detail scaffolding
//
// Shown in a popover from each row's ⓘ button (macOS System Settings pattern),
// so details never push into the sidebar or cover the grid. A ScrollView + VStack
// (not a grouped Form, which lays out empty in this context) with SEMANTIC colors
// (.primary/.secondary) so nothing turns invisible in either appearance.

private struct DetailHeader: View {
    let icon: String
    let title: String
    let online: Bool
    let onlineLabel: String
    let offlineLabel: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Circle().fill(online ? Theme.live : Theme.warning).frame(width: 7, height: 7)
                    Text(online ? onlineLabel : offlineLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private func detailRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
        Text(label).foregroundStyle(.secondary)
        Spacer(minLength: 12)
        Text(value).foregroundStyle(.primary).monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
    .font(.callout)
}

private func detailMono(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(label).font(.callout).foregroundStyle(.secondary)
        Text(value)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(2).truncationMode(.middle)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}

// MARK: - Device detail

private struct DeviceDetailView: View {
    @Environment(DaemonClient.self) private var client
    let device: PhysicalDeviceInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DetailHeader(icon: "hifispeaker.fill", title: device.name,
                             online: device.present,
                             onlineLabel: "Connected", offlineLabel: "Waiting to reconnect")
                Divider()
                detailRow("Inputs",  "\(device.inputChannels) ch")
                detailRow("Outputs", "\(device.outputChannels) ch")
                detailRow("Sample rate", device.present ? "\(Int(device.sampleRate)) Hz" : "—")
                detailRow("Format", "32-bit float")
                detailRow("Clock", "ASRC to engine")
                detailRow("In grid", device.used ? "Yes" : "No")
                detailMono("UID", device.uid)
                Divider()
                Toggle("Use in grid", isOn: Binding(
                    get: { device.used },
                    set: { client.setDeviceUse(uid: device.uid, used: $0) }))
                    .tint(.accentColor)
                    .help("Adds this device's channels to the patch grid")
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - App capture detail

private struct AppCaptureDetailView: View {
    @Environment(DaemonClient.self) private var client
    let app: AppInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DetailHeader(icon: "macwindow", title: app.name,
                             online: app.isPlaying,
                             onlineLabel: "Playing audio", offlineLabel: "Silent")
                Divider()
                detailRow("Format", "2 mono lanes (L/R)")
                detailRow("Captured", app.captured ? "Yes" : "No")
                detailRow("PID", "\(app.pid)")
                if let bid = app.bundleID { detailMono("Bundle ID", bid) }
                Divider()
                Toggle("Capture", isOn: Binding(
                    get: { app.captured },
                    set: { client.setAppCapture(pid: app.pid, captured: $0) }))
                    .tint(.accentColor)
                    .help("The app keeps playing to its normal output; Hydra gets a tap copy")
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - AES67 stream detail

private struct StreamDetailView: View {
    @Environment(DaemonClient.self) private var client
    let stream: Aes67Stream

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DetailHeader(icon: "network", title: stream.name,
                             online: stream.subscribed,
                             onlineLabel: "Subscribed", offlineLabel: "Available")
                Divider()
                detailRow("Channels", "\(stream.channels)")
                detailRow("Encoding", stream.encoding)
                detailRow("Sample rate", "\(Int(stream.sampleRate)) Hz")
                detailMono("Multicast", "\(stream.address):\(stream.port)")
                detailMono("Origin", stream.origin)
                Divider()
                Toggle("Subscribe", isOn: Binding(
                    get: { stream.subscribed },
                    set: { client.subscribeStream(id: stream.id, subscribed: $0) }))
                    .tint(.accentColor)
                    .help("Joins the multicast group and adds channels to the grid")
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Info balloon

struct InfoButton: View {
    let text: String
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Image(systemName: "info.circle")
                .font(.callout)
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .frame(width: 260, alignment: .leading)
                .padding(14)
        }
    }
}

// MARK: - Row detail popover

/// A trailing ⓘ that reveals an item's details in a popover — the macOS System
/// Settings pattern (Wi-Fi / network rows). Details never push into the sidebar
/// or cover the grid.
struct InfoPopoverButton<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .imageScale(.medium)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Details")
        .popover(isPresented: $open, arrowEdge: .trailing) {
            content().frame(width: 300, height: 340)
        }
    }
}
