// Hydra Audio — GPL-3.0
// Channel strip inspector — DAW-style Logic signal flow:
//   input → insert slots → trim → output section (gain, meter, remove).
//
// Apple HIG changes vs previous version:
//   • No longer laid out in a manual HStack — the .inspector() modifier in
//     ContentView gives us a proper macOS trailing panel with system chrome.
//   • Removed .padding(.top, 52) alignment hack (inspector handles its own insets).
//   • Background is now .regularMaterial (or omitted — the system inspector
//     panel already has the correct material behind it on macOS 26).
//   • Dividers are native Divider() — no manual Color.white.opacity overlay.
//   • Text uses semantic colors (.primary, .secondary, .tertiary) everywhere.
//   • .buttonStyle(.bordered) for destructive action; .borderedProminent for primary.

import SwiftUI
import AppKit
import HydraCore

struct InspectorView: View {
    @Environment(DaemonClient.self) private var client
    @Binding var selection: GridSelection?
    @Binding var channelFocus: ChannelFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — flush with the inspector chrome.
            HStack {
                Text("Channel")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Content — a selected cross-point shows both ends; a clicked channel
            // name shows that single channel's strip.
            if let sel = selection {
                ScrollView {
                    ChannelStrip(selection: sel, clearSelection: { selection = nil })
                        .padding(16)
                }
            } else if let focus = channelFocus {
                ScrollView {
                    SingleChannelStrip(focus: focus)
                        .padding(16)
                }
            } else {
                ContentUnavailableView {
                    Label("No Selection", systemImage: "rectangle.dashed")
                } description: {
                    Text("Click a cell, or a channel's name, to open its channel strip.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Channel name → node display name (interface / device / app / stream).
@MainActor
private func channelNodeName(_ nodeID: String, client: DaemonClient) -> String {
    if nodeID == Hydra.backplaneNodeID {
        return client.status?.backplaneDeviceName ?? Hydra.backplaneDeviceName
    }
    if let uid = Hydra.deviceUID(fromNodeID: nodeID),
       let device = client.devices.first(where: { $0.uid == uid }) {
        return device.name
    }
    if let app = client.apps.first(where: { $0.nodeID == nodeID }) {
        return app.name
    }
    if let stream = client.aes67.streams.first(where: { $0.nodeID == nodeID }) {
        return stream.name
    }
    return nodeID
}

// MARK: - Single channel strip (opened by clicking a channel name)

private struct SingleChannelStrip: View {
    @Environment(DaemonClient.self) private var client
    let focus: ChannelFocus

    private var entry: GridEntry { focus.entry }
    private var base: Int { entry.channel & ~1 }
    private var isStereoLinked: Bool {
        client.stereoLinked(nodeID: entry.nodeID, evenChannel: base)
    }
    private var strip: StripInfo {
        client.effectiveStrip(forNode: entry.nodeID, channel: entry.channel, stereo: isStereoLinked)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(focus.scope == .input ? "Transmitter" : "Receiver")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                RenameableChannelLabel(entry: entry, scope: focus.scope,
                                       font: .title3.weight(.semibold))
                Text(channelNodeName(entry.nodeID, client: client))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Toggle("Stereo (\(base + 1)–\(base + 2))", isOn: Binding(
                get: { isStereoLinked },
                set: { client.setStereoLink(nodeID: entry.nodeID, channel: entry.channel, linked: $0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.callout)
                .help("Links these two channels as one stereo pair (L/R) — they patch and unpatch together.")

            // Inserts (Audio FX) live on the transmitter (source) side only.
            if focus.scope == .input {
                Divider()
                InsertsSection(strip: strip)
            }
        }
    }
}

// MARK: - Inserts (Audio FX) — shared by the cell strip and the single-channel strip

private struct InsertsSection: View {
    @Environment(DaemonClient.self) private var client
    let strip: StripInfo
    @State private var pickerPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audio FX")
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach(Array(strip.inserts.enumerated()), id: \.offset) { index, plugin in
                HStack(spacing: 6) {
                    Button {
                        client.openPluginEditor(stripID: strip.id, index: index)
                    } label: {
                        Text(plugin.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Open \(plugin.name)'s editor")

                    Button {
                        var updated = strip
                        guard updated.inserts.indices.contains(index) else { return }
                        updated.inserts.remove(at: index)
                        client.setStrip(updated)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove insert")
                }
            }

            Button {
                pickerPresented = true
            } label: {
                Label("Insert…", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Add a plugin to this channel")
            .popover(isPresented: $pickerPresented) {
                PluginPicker { plugin in
                    var updated = strip
                    updated.inserts.append(plugin)
                    client.setStrip(updated)
                    pickerPresented = false
                }
                .environment(client)
            }

            if !strip.inserts.isEmpty {
                Divider().padding(.vertical, 2)
                Toggle("Crash protection", isOn: Binding(
                    get: { strip.isolated },
                    set: { var s = strip; s.isolated = $0; client.setStrip(s) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.caption)
                    .help("Runs this strip's plugins in a separate process so a crashing plugin can't take down Hydra. Turn off for trusted plugins to remove the small added latency.")
            }
        }
    }
}

// MARK: - Channel strip

private struct ChannelStrip: View {
    @Environment(DaemonClient.self) private var client
    let selection: GridSelection
    let clearSelection: () -> Void

    @State private var pickerSlotPresented = false

    private var sourceBase: Int { selection.source.channel & ~1 }
    private var isStereoLinked: Bool {
        client.stereoLinked(nodeID: selection.source.nodeID, evenChannel: sourceBase)
    }
    private var strip: StripInfo {
        client.effectiveStrip(forNode: selection.source.nodeID,
                              channel: selection.source.channel,
                              stereo: isStereoLinked)
    }

    private var destBase: Int { selection.destination.channel & ~1 }
    private var destStereoLinked: Bool {
        client.stereoLinked(nodeID: selection.destination.nodeID, evenChannel: destBase)
    }

    /// Small uppercase caption that labels each end of the patch (Transmitter /
    /// Receiver), so it's always clear which side you're configuring.
    private func sectionCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }

    /// A labeled stereo switch for one end of the patch. Linking pairs the even+odd
    /// channels into one stereo lane (·St) so they patch/unpatch together (L/R).
    private func stereoToggle(nodeID: String, channel: Int, base: Int,
                              linked: Bool, hint: String) -> some View {
        Toggle("Stereo (\(base + 1)–\(base + 2))", isOn: Binding(
            get: { linked },
            set: { client.setStereoLink(nodeID: nodeID, channel: channel, linked: $0) }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.callout)
            .help(hint)
    }

    private var nodeName: String {
        let nodeID = selection.source.nodeID
        if nodeID == Hydra.backplaneNodeID {
            return client.status?.backplaneDeviceName ?? Hydra.backplaneDeviceName
        }
        if let uid = Hydra.deviceUID(fromNodeID: nodeID),
           let device = client.devices.first(where: { $0.uid == uid }) {
            return device.name
        }
        if let app = client.apps.first(where: { $0.nodeID == nodeID }) {
            return app.name
        }
        if let stream = client.aes67.streams.first(where: { $0.nodeID == nodeID }) {
            return stream.name
        }
        return nodeID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // ── Transmitter (source of the selected cell) ───────────────
            VStack(alignment: .leading, spacing: 3) {
                sectionCaption("Transmitter")
                RenameableChannelLabel(entry: selection.source, scope: .input,
                                       font: .title3.weight(.semibold))
                Text(nodeName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Stereo pairing for the transmitter (odd+even). A linked pair becomes
            // one stereo lane in the grid and feeds stereo inserts L/R.
            stereoToggle(nodeID: selection.source.nodeID,
                         channel: selection.source.channel,
                         base: sourceBase,
                         linked: isStereoLinked,
                         hint: "Links these two transmitter channels as one stereo pair (L/R) — they patch and unpatch together, and stereo inserts process both.")

            Divider()

            // ── Inserts (Audio FX) ──────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                Text("Audio FX")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach(Array(strip.inserts.enumerated()), id: \.offset) { index, plugin in
                    HStack(spacing: 6) {
                        Button {
                            client.openPluginEditor(stripID: strip.id, index: index)
                        } label: {
                            Text(plugin.name)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Open \(plugin.name)'s editor")

                        Button {
                            var updated = strip
                            guard updated.inserts.indices.contains(index) else { return }
                            updated.inserts.remove(at: index)
                            client.setStrip(updated)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove insert")
                    }
                }

                // Empty slot — dashed outline follows the system's bordered style.
                Button {
                    pickerSlotPresented = true
                } label: {
                    Label("Insert…", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Add a plugin to this channel")
                .popover(isPresented: $pickerSlotPresented) {
                    PluginPicker { plugin in
                        var updated = strip
                        updated.inserts.append(plugin)
                        client.setStrip(updated)
                        pickerSlotPresented = false
                    }
                    .environment(client)
                }
            }

            Divider()

            // ── Receiver (destination of the selected cell) ─────────────
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    sectionCaption("Receiver")
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                        RenameableChannelLabel(entry: selection.destination, scope: .output,
                                               font: .callout.weight(.semibold))
                    }
                }

                // The other half of a true stereo patch. Turn Stereo on at BOTH
                // ends and the cross-point routes L→L / R→R as one linked pair.
                stereoToggle(nodeID: selection.destination.nodeID,
                             channel: selection.destination.channel,
                             base: destBase,
                             linked: destStereoLinked,
                             hint: "Links these two receiver channels as one stereo pair — they patch and unpatch together (L→L, R→R).")

                let cellConns = client.cellConnections(source: selection.source,
                                                       destination: selection.destination)
                if !cellConns.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        CellGainSlider(connections: cellConns, selection: selection)
                        SignalIndicator(meters: client.meters, connectionIDs: cellConns.map(\.id))
                            .frame(maxWidth: .infinity)
                    }

                    Button(role: .destructive) {
                        client.disconnectCell(source: selection.source,
                                              destination: selection.destination)
                        clearSelection()
                    } label: {
                        Label("Remove connection", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No connection at this cross-point yet.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                        Button {
                            client.connectCell(source: selection.source,
                                               destination: selection.destination)
                        } label: {
                            Label("Connect", systemImage: "cable.connector")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .help("Patch \(selection.source.label) → \(selection.destination.label)\(selection.source.isStereo || selection.destination.isStereo ? " (stereo)" : "").")
                    }
                }
            }
        }
    }
}

// MARK: - Renameable channel label

private struct RenameableChannelLabel: View {
    @Environment(DaemonClient.self) private var client
    let entry: GridEntry
    let scope: ChannelScope
    let font: Font

    @State private var editing = false
    @State private var draft   = ""

    private var isRenameable: Bool { entry.nodeID == Hydra.backplaneNodeID }
    private var displayed: String {
        client.labels.label(scope, entry.channel) ?? entry.label
    }

    var body: some View {
        if editing {
            TextField("Channel name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .onSubmit {
                    let trimmed = draft.trimmingCharacters(in: .whitespaces)
                    client.setLabel(scope, entry.channel, trimmed.isEmpty ? nil : trimmed)
                    editing = false
                }
                .onExitCommand { editing = false }
        } else {
            HStack(spacing: 5) {
                Text(displayed).font(font).lineLimit(1)
                if isRenameable {
                    Button {
                        draft   = client.labels.label(scope, entry.channel) ?? ""
                        editing = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Rename this channel (empty = back to the interface name)")
                }
            }
        }
    }
}

// MARK: - Plugin picker

private struct PluginPicker: View {
    @Environment(DaemonClient.self) private var client
    let onSelect: (VSTPlugin) -> Void
    @State private var search = ""

    private var filtered: [VSTPlugin] {
        let base  = client.vst.pickerPlugins()
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.name.lowercased().contains(query) || $0.vendor.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if client.vst.scanning {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Scanning VST3 plugins…")
                        .font(.callout.weight(.semibold))
                    ProgressView(value: client.vst.scanProgress)
                        .progressViewStyle(.linear)
                    Text(client.vst.scanLabel)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
            } else if client.vst.available.isEmpty && client.vst.scannedAt == nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Hydra hasn't scanned your plugins yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button {
                        client.scanVST()
                    } label: {
                        Label("Scan VST3 plugins", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Text("Looks in /Library/Audio/Plug-Ins/VST3 and ~/Library/Audio/Plug-Ins/VST3.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if client.vst.available.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No VST3 plugins found.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button {
                        client.scanVST()
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Text("Install plugins into /Library/Audio/Plug-Ins/VST3 and rescan.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // Search field — uses the native .roundedBorder style.
                TextField("Search plugins…", text: $search)
                    .textFieldStyle(.roundedBorder)

                if filtered.isEmpty {
                    Text("Nothing matches \"\(search)\".")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(filtered) { plugin in
                                Button {
                                    onSelect(plugin)
                                } label: {
                                    Text(plugin.name)
                                        .font(.callout)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 3)
                                        .padding(.horizontal, 6)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(plugin.vendor)
                            }
                        }
                    }
                    .frame(maxHeight: 380)
                }
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}

// MARK: - Logic VU meter

/// Channel-strip signal indicator — a copy of the grid pin's on/off state shown
/// as a speaker symbol: lit when audio is flowing through the connection, dimmed
/// when silent. No metering, no animation; it only changes when on/off flips
/// (rare), so it costs nothing while the audio plays.
private struct SignalIndicator: View {
    var meters: ConnMeters
    let connectionIDs: [String]

    private var on: Bool { connectionIDs.contains { (meters.peaks[$0] ?? 0) > 0 } }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: on ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 13))
                .foregroundStyle(on ? Theme.live : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 18, alignment: .leading)
            Text(on ? "Signal present" : "No signal")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: 0.15), value: on)
        .help("Signal indicator — lit when audio is passing through this connection")
    }
}

// MARK: - Gain slider

private struct CellGainSlider: View {
    @Environment(DaemonClient.self) private var client
    let connections: [Connection]
    let selection: GridSelection

    // Gain in dB, wrapped in the shared optimistic/echo-safe primitive. A 0.05 dB
    // tolerance recognises the daemon's round-tripped echo of our own write.
    @StateObject private var gain = SyncedValue<Double>(0, equal: { abs($0 - $1) < 0.05 })
    @State private var loadedID = ""

    private var cellID: String {
        "\(selection.source.id)>\(selection.destination.id)"
    }
    private var serverDB: Double {
        Double(Gain.decibels(fromLinear: connections.first?.gain ?? 1.0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Gain")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("0 dB") {
                    gain.userSet(0)
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Reset gain to unity")
                Text(String(format: "%+.1f dB", gain.value))
                    .font(.callout)
                    .monospacedDigit()
                    .frame(width: 60, alignment: .trailing)
            }
            Slider(value: gain.binding, in: -60...12, step: 0.5) { editing in
                editing ? gain.beginEditing() : gain.endEditing()
            }
                .simultaneousGesture(TapGesture().onEnded {
                    if NSEvent.modifierFlags.contains(.option) {
                        gain.userSet(0)
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                    }
                })
                // Haptics only while the user is dragging (never on remote echoes).
                .onChange(of: gain.value) { previous, current in
                    guard gain.isEditing else { return }
                    if (previous < 0 && current >= 0) || (previous > 0 && current <= 0) {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                    } else {
                        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
                    }
                }
        }
        .onAppear {
            bindPush()
            loadedID = cellID
            gain.adopt(serverDB)
        }
        // Retargeted to a different cell — re-point the push and hard-adopt its gain.
        .onChange(of: cellID) { _, _ in
            bindPush()
            loadedID = cellID
            gain.adopt(serverDB)
        }
        // Daemon echo / external change — reconciled by SyncedValue.
        .onChange(of: connections.first?.gain) { _, _ in
            gain.remote(serverDB)
        }
    }

    /// (Re)bind the push target to the CURRENT cell. Captures only the daemon
    /// reference and the two endpoints — never `self` or `gain` — so the closure
    /// stored on `gain` can't create a retain cycle.
    private func bindPush() {
        let client = self.client
        let src    = selection.source
        let dst    = selection.destination
        gain.onPush = { db in
            client.setCellGain(source: src, destination: dst,
                               gain: Gain.linear(fromDecibels: Float(db)))
        }
    }
}
