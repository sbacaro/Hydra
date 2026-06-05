// Hydra Audio — GPL-3.0
// Left sidebar driven by toolbar tabs. Lists show only what matters
// (status dot, name, toggle); clicking an item opens its DEVICE VIEW with
// the full specifications — Dante Controller style.

import SwiftUI
import HydraCore

enum SidebarTab: String, CaseIterable {
    case devices = "Devices"
    case apps = "Apps"
    case network = "Network"
}

private enum SidebarDetail: Equatable {
    case device(String)   // uid
    case app(Int32)       // pid
    case stream(String)   // stream id
}

struct SidebarView: View {
    @EnvironmentObject private var client: DaemonClient
    let tab: SidebarTab
    let width: CGFloat
    @State private var detail: SidebarDetail?
    @State private var showAddInterface = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let detail {
                        detailView(detail)
                    } else {
                        listView
                    }
                }
                .padding(12)
            }
        }
        .frame(width: width)
        .background(Color.black.opacity(0.25))
        .overlay(alignment: .trailing) { Theme.hairline.frame(width: 0.5) }
        .onChange(of: tab) { _, _ in detail = nil }
    }

    // MARK: - Lists (minimal: dot + name + toggle)

    @ViewBuilder
    private var listView: some View {
        switch tab {
        case .devices:
            HStack {
                sectionHeader("Virtual interfaces",
                              info: "Named blocks of the Hydra Soundcard's 256-channel pool — only these appear in the grid. Build the set you want to work with.")
                Spacer()
                Button {
                    showAddInterface = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Create a virtual interface")
                .popover(isPresented: $showAddInterface, arrowEdge: .bottom) {
                    AddInterfaceForm()
                }
            }
            if client.interfaces.isEmpty {
                emptyNote("None yet — Hydra starts with zero channels. Create your first interface to begin patching.")
            }
            ForEach(client.interfaces) { iface in
                HStack(spacing: 8) {
                    Circle().fill(Theme.accent).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(iface.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text("\(iface.inChannels) in × \(iface.outChannels) out")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textTertiary)
                            .help("Pool: in \(iface.inBase + 1)–\(iface.inBase + max(iface.inChannels, 1)) · out \(iface.outBase + 1)–\(iface.outBase + max(iface.outChannels, 1))")
                    }
                    Spacer()
                    Button {
                        if client.recording(for: iface.id) != nil {
                            client.stopRecording(iface.id)
                        } else {
                            client.startRecording(iface.id)
                        }
                    } label: {
                        Image(systemName: client.recording(for: iface.id) != nil
                              ? "stop.circle.fill" : "record.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(client.recording(for: iface.id) != nil
                                             ? Theme.clip : Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help(client.recording(for: iface.id) != nil
                          ? "Stop — saves the WAV in Music \u{2192} Hydra Recordings"
                          : "Record this interface's outputs to WAV")
                    Button {
                        client.setInterfaceAES67(iface.id, enabled: !iface.aes67TX)
                    } label: {
                        Image(systemName: "network")
                            .font(.system(size: 12))
                            .foregroundStyle(iface.aes67TX ? Theme.accent : Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help(iface.aes67TX
                          ? "Announced on the network as AES67 flow \u{201C}\(iface.name)\u{201D} — click to stop"
                          : "Announce this interface's outputs as an AES67 flow (SAP + RTP)")
                    Button {
                        client.setInterfaceNDI(iface.id, enabled: !iface.ndiTX)
                    } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 12))
                            .foregroundStyle(iface.ndiTX ? Theme.accent : Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help(iface.ndiTX
                          ? "Broadcasting as NDI source \u{201C}\(iface.name)\u{201D} — click to stop"
                          : "Broadcast this interface's outputs as an NDI source")
                    Button {
                        client.deleteInterface(iface.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete — frees the channels and removes its patches")
                }
                .padding(.vertical, 2)
            }
            HStack {
                Spacer()
                Text("\(client.allocatedPoolChannels) / \(Hydra.backplaneChannels) pool channels in use")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }

            sectionHeader("Audio interfaces",
                          info: "Devices added to the grid get their own audio path with drift correction (ASRC). Click a device for its specifications.")
            if client.devices.isEmpty { emptyNote("No audio interfaces detected.") }
            ForEach(client.devices) { device in
                listRow(dot: device.present ? Theme.live : Theme.warning,
                        title: device.name,
                        isOn: Binding(get: { device.used },
                                      set: { client.setDeviceUse(uid: device.uid, used: $0) }),
                        open: { detail = .device(device.uid) })
            }
        case .apps:
            sectionHeader("App capture",
                          info: "Captured apps appear as two mono lanes (L/R) while still playing normally. Click an app for details.")
            if client.apps.isEmpty { emptyNote("Apps appear here once they use audio.") }
            ForEach(client.apps) { app in
                listRow(dot: app.isPlaying ? Theme.live : Theme.textTertiary,
                        title: app.name,
                        isOn: Binding(get: { app.captured },
                                      set: { client.setAppCapture(pid: app.pid, captured: $0) }),
                        open: { detail = .app(app.pid) })
            }
        case .network:
            sectionHeader("AES67 devices",
                          info: "Hydra listens passively: devices appear as they announce via mDNS, streams via SAP. \u{201C}Offline\u{201D} means the device is present but AES67 mode is off — enable it in Dante Controller (Hydra cannot do it remotely).")
            if client.aes67.devices.isEmpty { emptyNote("No devices announced yet.") }
            ForEach(client.aes67.devices) { device in
                HStack(spacing: 8) {
                    Circle().fill(device.aes67On ? Theme.live : Theme.warning)
                        .frame(width: 7, height: 7)
                    Text(device.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(device.aes67On ? "AES67 On" : "Offline")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(device.aes67On ? Theme.live : Theme.warning)
                }
            }
            if !client.aes67.streams.isEmpty {
                sectionHeader("Streams", info: "Subscribing joins the multicast group; channels become grid sources. Click a stream for details.")
                ForEach(client.aes67.streams) { stream in
                    listRow(dot: stream.subscribed ? Theme.accent : Theme.textTertiary,
                            title: stream.name,
                            isOn: Binding(get: { stream.subscribed },
                                          set: { client.subscribeStream(id: stream.id, subscribed: $0) }),
                            open: { detail = .stream(stream.id) })
                }
            }

            sectionHeader("NDI sources",
                          info: "NDI audio sources on the network. Subscribing adds their channels to the grid. TX: flag a virtual interface as NDI to broadcast it.")
            if !client.ndi.runtimeAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    emptyNote("NDI runtime not installed — Hydra loads it dynamically (it can't be bundled with a GPL app).")
                    Link("Download NDI Runtime…",
                         destination: URL(string: Hydra.ndiRedistURL)!)
                        .font(.caption2.weight(.semibold))
                }
            } else if client.ndi.sources.isEmpty {
                emptyNote("No NDI sources on the network yet (runtime \(client.ndi.runtimeVersion ?? "") active).")
            } else {
                ForEach(client.ndi.sources) { source in
                    listRow(dot: source.subscribed ? Theme.accent : Theme.textTertiary,
                            title: source.name,
                            isOn: Binding(get: { source.subscribed },
                                          set: { client.subscribeNdi(id: source.id, subscribed: $0) }),
                            open: {})
                }
            }
        }
    }

    // MARK: - Device View (full specifications)

    @ViewBuilder
    private func detailView(_ detail: SidebarDetail) -> some View {
        Button {
            self.detail = nil
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                Text("Back").font(.caption)
            }
            .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)

        switch detail {
        case .device(let uid):
            if let device = client.devices.first(where: { $0.uid == uid }) {
                deviceDetail(device)
            } else {
                emptyNote("Device no longer present.")
            }
        case .app(let pid):
            if let app = client.apps.first(where: { $0.pid == pid }) {
                appDetail(app)
            } else {
                emptyNote("App no longer running.")
            }
        case .stream(let id):
            if let stream = client.aes67.streams.first(where: { $0.id == id }) {
                streamDetail(stream)
            } else {
                emptyNote("Stream no longer announced.")
            }
        }
    }

    private func deviceDetail(_ device: PhysicalDeviceInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            detailHeader(name: device.name,
                         status: device.present ? "Connected" : "Waiting to reconnect",
                         ok: device.present)
            specRow("Inputs", "\(device.inputChannels)")
            specRow("Outputs", "\(device.outputChannels)")
            specRow("Sample rate", device.present ? "\(Int(device.sampleRate)) Hz" : "—")
            specRow("Clock", "ASRC to engine clock")
            specRow("UID", device.uid, monospaced: true)
            toggleRow("Use in grid",
                      isOn: Binding(get: { device.used },
                                    set: { client.setDeviceUse(uid: device.uid, used: $0) }),
                      help: "Adds this device's channels to the patch grid")
        }
    }

    private func appDetail(_ app: AppInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            detailHeader(name: app.name,
                         status: app.isPlaying ? "Playing audio" : "Silent",
                         ok: app.isPlaying)
            specRow("Format", "2 mono lanes (L/R)")
            specRow("Bundle ID", app.bundleID ?? "—", monospaced: true)
            specRow("PID", "\(app.pid)", monospaced: true)
            toggleRow("Capture",
                      isOn: Binding(get: { app.captured },
                                    set: { client.setAppCapture(pid: app.pid, captured: $0) }),
                      help: "The app keeps playing to its normal output; Hydra gets a copy")
        }
    }

    private func streamDetail(_ stream: Aes67Stream) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            detailHeader(name: stream.name,
                         status: stream.subscribed ? "Subscribed" : "Available",
                         ok: stream.subscribed)
            specRow("Channels", "\(stream.channels)")
            specRow("Encoding", stream.encoding)
            specRow("Sample rate", "\(Int(stream.sampleRate)) Hz")
            specRow("Multicast", "\(stream.address):\(stream.port)", monospaced: true)
            specRow("Origin", stream.origin, monospaced: true)
            toggleRow("Subscribe",
                      isOn: Binding(get: { stream.subscribed },
                                    set: { client.subscribeStream(id: stream.id, subscribed: $0) }),
                      help: "Joins the multicast group and adds the channels to the grid")
        }
    }

    // MARK: - Pieces

    private func detailHeader(name: String, status: String, ok: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 5) {
                Circle().fill(ok ? Theme.live : Theme.warning).frame(width: 6, height: 6)
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.bottom, 2)
    }

    private func specRow(_ key: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            Text(value)
                .font(.system(size: monospaced ? 11 : 12)).monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
        }
        .padding(.vertical, 3)
        .overlay(alignment: .bottom) { Theme.hairline.opacity(0.5).frame(height: 0.5) }
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>, help: String) -> some View {
        HStack {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.top, 4)
        .help(help)
    }

    private func sectionHeader(_ title: String, info: String) -> some View {
        HStack(spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .kerning(0.6)
            InfoButton(text: info)
            Spacer()
        }
        .padding(.top, 4)
    }

    private func ndiSubtitle(_ source: NdiSourceInfo) -> String {
        var parts: [String] = []
        if source.channels > 0 {
            parts.append("\(source.channels) ch @ \(Int(source.sampleRate)) Hz")
        }
        if !source.url.isEmpty {
            parts.append(source.url)
        }
        return parts.isEmpty ? "format appears once audio flows" : parts.joined(separator: " · ")
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)
    }

    /// Minimal list row: dot + name (click = Device View) + toggle.
    private func listRow(dot: Color, title: String,
                         isOn: Binding<Bool>, open: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 8) {
                    Circle().fill(dot).frame(width: 7, height: 7)
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open details")
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(Theme.accent)
        }
    }
}


/// Apple-style ⓘ: click opens a balloon with the explanation.
struct InfoButton: View {
    let text: String
    @State private var open = false

    var body: some View {
        Button {
            open = true
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .frame(width: 260, alignment: .leading)
                .padding(12)
        }
    }
}
