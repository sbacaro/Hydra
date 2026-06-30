// Hydra Audio — GPL-3.0
// Device View patching — exactly the Dante Controller workflow.
//
// LEFT — Receive Channels of ONE device (picker): channel | connected to | signal.
// RIGHT — Available Channels: device tree with filter; click/⇧/⌘ builds a
// multi-selection. "Patch" lands the selection on consecutive receive channels
// starting at the selected row; Unsubscribe clears rows.

import SwiftUI
import HydraCore

struct DeviceViewPatch: View {
    @Environment(DaemonClient.self) private var client
    let sources: [GridView.GroupDef]
    let destinations: [GridView.GroupDef]
    @Binding var selection: GridSelection?
    /// Mirrors the grid's Groups toggle: ON = devices collapse to their
    /// header in Available Channels; OFF = flat tree.
    let collapseByDevice: Bool
    @Binding var expandedDevices: Set<String>

    /// Every source keyed by "nodeID:channel" — stereo lanes are expanded to
    /// BOTH of their channels, so a connection resolves to the friendly lane
    /// label (e.g. "Safari ·St") instead of the raw node id.
    private let sourceByPoint: [String: GridEntry]

    init(sources: [GridView.GroupDef],
         destinations: [GridView.GroupDef],
         selection: Binding<GridSelection?>,
         collapseByDevice: Bool,
         expandedDevices: Binding<Set<String>>) {
        self.sources = sources
        self.destinations = destinations
        self._selection = selection
        self.collapseByDevice = collapseByDevice
        self._expandedDevices = expandedDevices

        self.sourceByPoint = Dictionary(
            sources.flatMap(\.entries).flatMap { entry in
                entry.channels.map { ("\(entry.nodeID):\($0)", entry) }
            },
            uniquingKeysWith: { first, _ in first })
    }

    @State private var deviceID: String = ""
    @State private var selectedReceiveIDs: Set<String> = []
    @State private var receiveAnchorID: String?
    @State private var selectedSourceIDs: Set<String> = []
    @State private var sourceAnchorID: String?
    @State private var filter = ""
    @State private var dropTargetID: String?

    private var device: GridView.GroupDef? {
        destinations.first { $0.id == deviceID } ?? destinations.first
    }

    /// The Picker's selection always resolves to a real device id (the chosen
    /// one, else the first), so it never sits on the empty "" sentinel — which
    /// has no matching tag and made SwiftUI log "selection … is invalid".
    private var deviceSelection: Binding<String> {
        Binding(get: { device?.id ?? "" }, set: { deviceID = $0 })
    }

    // Fixed table columns so the header and every row line up exactly.
    private let channelColWidth: CGFloat = 90
    private let signalColWidth:  CGFloat = 54

    /// Strips the redundant device name from a channel's full label. The device
    /// is already named once — in the picker (left) or the group header (right) —
    /// so each row only needs what's left: "1", "20", "L"… Apple doesn't repeat
    /// the same context on every row. Falls back to the full label if absent.
    private func channelTag(_ label: String, within groupLabel: String) -> String {
        guard !groupLabel.isEmpty, label.hasPrefix(groupLabel) else { return label }
        let rest = label.dropFirst(groupLabel.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? label : rest
    }

    /// Row background: drop target → selection → faint zebra band on odd rows
    /// (Finder/Numbers scannability) → clear. One source of truth so the states
    /// compose instead of stacking translucent fills.
    private func rowFill(row: Int, selected: Bool, drop: Bool) -> Color {
        if drop { return Color.accentColor.opacity(0.22) }
        if selected { return Color.accentColor.opacity(0.16) }
        return row.isMultiple(of: 2) ? .clear : Theme.Grid.rowBand
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            receivePane
            availablePane
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.Grid.panel))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.Grid.hairline, lineWidth: 0.5))
        .onAppear {
            if deviceID.isEmpty, let first = destinations.first {
                deviceID = first.id
            }
        }
    }

    // MARK: Left — Receive Channels

    private var receivePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Receive channels")
                    .font(.headline)
                Spacer()
                Picker("Device", selection: deviceSelection) {
                    ForEach(destinations.indices, id: \.self) { index in
                        let group = destinations[index]
                        Label(group.label, systemImage: group.icon).tag(group.id)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }

            HStack(spacing: 0) {
                Text("Channel")
                    .frame(width: channelColWidth, alignment: .leading)
                    .padding(.leading, 10)
                Divider()
                Text("Connected to")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                Text("Signal").frame(width: signalColWidth)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: 22)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if let device {
                        ForEach(Array(device.entries.enumerated()), id: \.element.id) { row, entry in
                            receiveRow(entry, in: device.entries, row: row)
                        }
                    }
                }
            }

            HStack {
                Button("Unsubscribe") {
                    unsubscribeSelected()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!selectedReceiveHasConnections)
                .help("Removes the patches of the selected receive channels (\u{2318}/\u{21E7}-click selects several) — or press \u{232B}")
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func receiveRow(_ entry: GridEntry, in channels: [GridEntry], row: Int) -> some View {
        let isSelected = selectedReceiveIDs.contains(entry.id)
        let connectedSources = sourcesConnected(to: entry)
        let tag = channelTag(entry.label, within: device?.label ?? "")
        return Button {
            handleRowClick(entry, in: channels)
        } label: {
            HStack(spacing: 0) {
                Text(tag)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(width: channelColWidth, alignment: .leading)
                    .padding(.leading, 10)

                Divider()

                Group {
                    if connectedSources.isEmpty {
                        Text("—").foregroundStyle(.quaternary)
                    } else {
                        Text(connectedSources.map(\.label).joined(separator: ", "))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .font(.subheadline)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)

                SignalDotPublic(nodeID: entry.nodeID, channel: entry.channel, output: true)
                    .frame(width: signalColWidth)
            }
            .frame(height: 28)
            .background(rowFill(row: row, selected: isSelected, drop: dropTargetID == entry.id))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(connectedSources.isEmpty ? "No subscription — drag transmitter channels here"
                                       : connectedSources.map(\.label).joined(separator: ", "))
        // Dante Controller gesture: drop the dragged transmitter selection
        // here — channels land on consecutive rows starting at this one.
        .dropDestination(for: String.self) { items, _ in
            let ids = items.flatMap { $0.split(separator: "\n").map(String.init) }
            let flat = filteredSources.flatMap(\.entries)
            let picked = flat.filter { ids.contains($0.id) }
            guard !picked.isEmpty else { return false }
            assign(picked, startingAt: entry)
            selectedSourceIDs = []
            return true
        } isTargeted: { targeted in
            dropTargetID = targeted ? entry.id : (dropTargetID == entry.id ? nil : dropTargetID)
        }
    }

    private func handleRowClick(_ entry: GridEntry, in channels: [GridEntry]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift),
           let anchor = receiveAnchorID,
           let a = channels.firstIndex(where: { $0.id == anchor }),
           let b = channels.firstIndex(where: { $0.id == entry.id }) {
            selectedReceiveIDs.formUnion(channels[min(a, b)...max(a, b)].map(\.id))
        } else if flags.contains(.command) {
            if selectedReceiveIDs.contains(entry.id) {
                selectedReceiveIDs.remove(entry.id)
            } else {
                selectedReceiveIDs.insert(entry.id)
            }
            receiveAnchorID = entry.id
        } else {
            selectedReceiveIDs = [entry.id]
            receiveAnchorID = entry.id
        }
        // Feed the channel strip with the first patch of this row.
        if let source = sourcesConnected(to: entry).first {
            selection = GridSelection(source: source, destination: entry)
        }
    }

    private var selectedReceiveHasConnections: Bool {
        guard let device else { return false }
        return device.entries.contains { entry in
            selectedReceiveIDs.contains(entry.id) && !sourcesConnected(to: entry).isEmpty
        }
    }

    private func unsubscribeSelected() {
        guard let device else { return }
        for entry in device.entries where selectedReceiveIDs.contains(entry.id) {
            for source in sourcesConnected(to: entry) {
                client.disconnectCell(source: source, destination: entry)
            }
        }
    }

    // MARK: Right — Available Channels

    private var availablePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Available channels")
                .font(.headline)
            SearchField(text: $filter, prompt: "Filter")

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredSources.indices, id: \.self) { index in
                        let group = filteredSources[index]
                        let isExpanded = !collapseByDevice
                            || expandedDevices.contains(group.id)
                            || !filter.isEmpty
                        Button {
                            guard collapseByDevice else { return }
                            if expandedDevices.contains(group.id) {
                                expandedDevices.remove(group.id)
                            } else {
                                expandedDevices.insert(group.id)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                if collapseByDevice {
                                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                Image(systemName: group.icon)
                                    .font(.caption)
                                Text(group.label)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if isExpanded {
                            ForEach(group.entries) { entry in
                                sourceRow(entry, within: group.label)
                            }
                        }
                    }
                }
            }

            if !selectedSourceIDs.isEmpty {
                Text("\(selectedSourceIDs.count) selected — drag onto a receive channel; they land in sequence")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("Select channels (\u{21E7} for a range) and DRAG them onto a receive channel — they land in sequence. \u{232B} removes the selected rows' patches.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 250)
    }

    private func sourceRow(_ entry: GridEntry, within groupLabel: String) -> some View {
        let isSelected = selectedSourceIDs.contains(entry.id)
        let tag = channelTag(entry.label, within: groupLabel)
        return Button {
            handleSourceClick(entry)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, collapseByDevice ? 14 : 0)
                Text(tag)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .draggable(dragPayload(for: entry))
    }

    private func dragPayload(for entry: GridEntry) -> String {
        if selectedSourceIDs.contains(entry.id) {
            return orderedSelection.map(\.id).joined(separator: "\n")
        }
        return entry.id
    }

    private var orderedSelection: [GridEntry] {
        filteredSources.flatMap(\.entries).filter { selectedSourceIDs.contains($0.id) }
    }

    private func handleSourceClick(_ entry: GridEntry) {
        let flags = NSEvent.modifierFlags
        let flat = filteredSources.flatMap(\.entries)
        if flags.contains(.shift),
           let anchor = sourceAnchorID,
           let a = flat.firstIndex(where: { $0.id == anchor }),
           let b = flat.firstIndex(where: { $0.id == entry.id }) {
            selectedSourceIDs.formUnion(flat[min(a, b)...max(a, b)].map(\.id))
        } else if flags.contains(.command) {
            if selectedSourceIDs.contains(entry.id) {
                selectedSourceIDs.remove(entry.id)
            } else {
                selectedSourceIDs.insert(entry.id)
            }
            sourceAnchorID = entry.id
        } else {
            selectedSourceIDs = [entry.id]
            sourceAnchorID = entry.id
        }
        if sourceAnchorID == nil {
            sourceAnchorID = entry.id
        }
    }

    // MARK: Batch patch

    /// Lands `picked` on consecutive receive channels starting at `first`.
    private func assign(_ picked: [GridEntry], startingAt first: GridEntry) {
        guard let device,
              let startIndex = device.entries.firstIndex(of: first) else { return }
        var last: GridSelection?
        for (offset, source) in picked.enumerated() {
            let index = startIndex + offset
            guard index < device.entries.count else { break }
            client.connectCell(source: source, destination: device.entries[index])
            last = GridSelection(source: source, destination: device.entries[index])
        }
        if let last {
            selection = last
        }
    }

    // MARK: Lookups

    private func sourcesConnected(to destination: GridEntry) -> [GridEntry] {
        var seen = Set<String>()
        return client.connections
            .filter { $0.destination == destination.point }
            // Capture-flow sources (captap:…) belong to Flux, not the channel grid —
            // hide them here so flux routes don't leak into the Grid/List views.
            .filter { Hydra.captureTapUID(fromNodeID: $0.source.nodeID) == nil }
            .compactMap { conn -> GridEntry? in
                let key = "\(conn.source.nodeID):\(conn.source.channelIndex)"
                // Resolve to the visible lane (handles stereo lanes), else a
                // friendly fallback. Dedupe so a stereo L→L / R→R pair shows the
                // lane once rather than twice.
                let entry = sourceByPoint[key] ?? fallbackEntry(for: conn.source)
                guard seen.insert(entry.id).inserted else { return nil }
                return entry
            }
            .sorted { $0.label < $1.label }
    }

    /// A readable entry for a source that isn't in the visible source list,
    /// resolving the node's human name from the daemon's collections.
    private func fallbackEntry(for point: PatchPoint) -> GridEntry {
        let name = nodeDisplayName(point.nodeID)
        return GridEntry(nodeID: point.nodeID,
                         channels: [point.channelIndex],
                         label: "\(name) \(point.channelIndex + 1)",
                         shortLabel: "\(point.channelIndex + 1)")
    }

    private func nodeDisplayName(_ nodeID: String) -> String {
        if let app = client.apps.first(where: { $0.nodeID == nodeID }) {
            return String(app.name.prefix(12))
        }
        if let dev = client.devices.first(where: { $0.nodeID == nodeID }) {
            return String(dev.name.prefix(10))
        }
        if let stream = client.aes67.streams.first(where: { $0.nodeID == nodeID }) {
            return String(stream.name.prefix(10))
        }
        if let ndi = client.ndi.sources.first(where: { Hydra.ndiNodeID(sourceID: $0.id) == nodeID }) {
            return String(ndi.name.prefix(12))
        }
        if let mod = client.modules.sources.first(where: { Hydra.moduleNodeID(sourceID: $0.id) == nodeID }) {
            return String(mod.name.prefix(12))
        }
        // Last resort: a bundle id like "app:com.apple.Safari" → "Safari".
        if let key = Hydra.appKey(fromNodeID: nodeID) {
            return String(key.split(separator: ".").last ?? Substring(key))
        }
        return nodeID
    }

    private var filteredSources: [GridView.GroupDef] {
        guard !filter.isEmpty else { return sources }
        return sources.compactMap { group in
            let entries = group.entries.filter {
                $0.label.localizedCaseInsensitiveContains(filter)
            }
            return entries.isEmpty ? nil : (group.id, group.label, group.icon, entries)
        }
    }
}

// MARK: - Signal dot (usable outside GridView)

/// Signal dot — observes the 10 Hz flags + meter peaks directly.
/// Used by DeviceViewPatch rows and anywhere else a live signal indicator is needed.
struct SignalDotPublic: View {
    @Environment(SignalFlags.self) private var signals
    @Environment(ConnMeters.self) private var meters
    let nodeID: String
    let channel: Int
    let output: Bool
    /// Non-backplane lanes (apps, NDI, AES67) have no channel meter — their
    /// dot lights from the post-gain peaks of their connections instead.
    var connIDs: [String] = []

    var body: some View {
        let hasSignal: Bool
        if nodeID == Hydra.backplaneNodeID {
            let flags = output ? signals.outputs : signals.inputs
            hasSignal = channel < flags.count && flags[channel]
        } else if !output {
            // Source pin: light from the source's own audio, no patch required.
            hasSignal = signals.sources.contains("\(nodeID):\(channel)")
        } else {
            hasSignal = connIDs.contains { (meters.peaks[$0] ?? 0) > DaemonClient.signalThreshold }
        }
        return Circle()
            .fill(hasSignal ? Theme.live : Theme.Grid.noSignal)
            .frame(width: 5, height: 5)
            .shadow(color: hasSignal ? Theme.live.opacity(0.7) : .clear, radius: 2)
            .help(hasSignal ? "Signal present" : "No signal")
    }
}
