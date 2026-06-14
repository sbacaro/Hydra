// Hydra Audio — GPL-3.0
// The patch grid — collapsible groups, frozen panes, Canvas cell field.
//
// Apple HIG changes vs previous version:
//   • Control bar: custom capsule-pill buttons → .bordered / .borderedProminent
//     native button styles. Semantic colors (.secondary, .tertiary) replace the
//     white-opacity text tokens (the control bar sits in the window chrome, not
//     on the dark grid panel).
//   • Empty state: ContentUnavailableView (native macOS 14+ pattern) replaces
//     the hand-rolled VStack.
//   • All Theme.panel / Theme.hairline / Theme.textPrimary etc. in the frozen
//     grid and canvas are updated to use Theme.Grid.* sub-namespace tokens.
//   • The Canvas cell rendering (CellField) is architecturally unchanged — it
//     is fast, correct, and already the right approach for this use case.

import SwiftUI
import AppKit
import HydraCore

/// One mono lane of some node.
struct GridEntry: Equatable, Hashable, Identifiable {
    let nodeID: String
    let channels: [Int]
    let label: String
    let shortLabel: String

    var channel: Int   { channels[0] }
    var isStereo: Bool { channels.count == 2 }
    var id: String     { "\(nodeID):\(channels.map(String.init).joined(separator: "-"))" }
    var point: PatchPoint { PatchPoint(nodeID: nodeID, channelIndex: channel) }

    init(nodeID: String, channels: [Int], label: String, shortLabel: String) {
        self.nodeID     = nodeID
        self.channels   = channels
        self.label      = label
        self.shortLabel = shortLabel
    }
}

struct GridSelection: Equatable, Hashable {
    var source: GridEntry
    var destination: GridEntry
}

/// A single channel focused by clicking its header — opens that channel's strip
/// (rename, stereo link, inserts) without needing a cross-point.
struct ChannelFocus: Equatable {
    var entry: GridEntry
    var scope: ChannelScope
}

private struct HoverPos: Equatable {
    var row: String
    var col: String
}

private enum AxisItem {
    case group(id: String, label: String, icon: String, count: Int, expanded: Bool)
    case channel(GridEntry)
}

private final class ScrollState: ObservableObject {
    @Published var offset: CGPoint = .zero
    /// The cell viewport size, so the frozen panes can render only the labels
    /// that are actually visible (virtualization).
    @Published var viewport: CGSize = .zero
}

private struct AxisLayout {
    struct Slot {
        let item: AxisItem
        let origin: CGFloat
        let size: CGFloat
        /// Stable identity for ForEach when only visible slots are rendered.
        var id: String {
            switch item {
            case .group(let gid, _, _, _, _): return "g:" + gid
            case .channel(let entry):         return "c:" + entry.id
            }
        }
    }
    let slots: [Slot]
    let total: CGFloat

    init(items: [AxisItem], gap: CGFloat, sizeFor: (AxisItem) -> CGFloat) {
        var slots: [Slot] = []
        slots.reserveCapacity(items.count)
        var cursor: CGFloat = 0
        for item in items {
            let size = sizeFor(item)
            slots.append(Slot(item: item, origin: cursor, size: size))
            cursor += size + gap
        }
        self.slots = slots
        self.total = max(cursor - gap, 0)
    }

    func entry(at coordinate: CGFloat) -> GridEntry? {
        for slot in slots {
            if case .channel(let entry) = slot.item,
               coordinate >= slot.origin, coordinate < slot.origin + slot.size {
                return entry
            }
        }
        return nil
    }
}

struct GridView: View {
    @EnvironmentObject private var client: DaemonClient
    @Binding var selection: GridSelection?
    @Binding var channelFocus: ChannelFocus?

    @State private var showAddInterface  = false
    @State private var selectedCells: Set<GridSelection> = []
    @AppStorage("patchViewMode") private var viewMode = "grid"
    @AppStorage("groupChannels") private var groupChannels = false
    @State private var expandedRows: Set<String>        = []
    @State private var expandedCols: Set<String>        = []
    @State private var expandedListDevices: Set<String> = []
    @State private var confirmClear = false
    @StateObject private var scroll = ScrollState()

    private let cell:        CGFloat = 30
    private let gap:         CGFloat = 2
    private let groupSize:   CGFloat = 30
    private let labelWidth:  CGFloat = 150
    private var headerHeight: CGFloat { labelWidth }
    /// Extra px rendered beyond the viewport so labels don't pop in on scroll.
    private let axisMargin:  CGFloat = 120

    // MARK: - Group building

    typealias GroupDef = (id: String, label: String, icon: String, entries: [GridEntry])

    private func banks(nodeID: String, prefix idPrefix: String, count: Int, base: Int = 0,
                       icon: String, bankSize: Int,
                       namer: (Int) -> String,
                       groupNamer: (Int, Int) -> String) -> [GroupDef] {
        // Build lanes by walking channels. A console-style LINKED pair (ganging —
        // toggled from a channel header's context menu or the Inspector) collapses
        // its two mono channels into ONE stereo lane, so a single grid cell patches
        // L→L / R→R. Unlinked channels stay mono. Pairs are aligned to even pool
        // channels, matching DaemonClient.setStereoLink's odd+even base.
        var lanes: [(channels: [Int], offset: Int)] = []
        var ch = 0
        while ch < count {
            let abs = base + ch
            if abs.isMultiple(of: 2), ch + 1 < count,
               client.stereoLinked(nodeID: nodeID, evenChannel: abs) {
                lanes.append((channels: [abs, abs + 1], offset: ch))
                ch += 2
            } else {
                lanes.append((channels: [abs], offset: ch))
                ch += 1
            }
        }

        var defs: [GroupDef] = []
        var start = 0; var bank = 0
        while start < lanes.count {
            let end = min(start + bankSize, lanes.count)
            let entries = lanes[start..<end].map { lane -> GridEntry in
                let name  = namer(lane.offset)
                let label = lane.channels.count == 2 ? "\(name) ·St" : name
                return GridEntry(nodeID: nodeID, channels: lane.channels,
                                 label: label, shortLabel: label)
            }
            defs.append(("\(idPrefix)-\(bank)", groupNamer(start, end), icon, entries))
            start = end; bank += 1
        }
        return defs
    }

    /// Right-click a channel header to gang (or un-gang) its console stereo pair.
    /// Linking writes a stereo strip on the even base channel; `banks()` then
    /// renders the pair as one stereo lane and routing patches L→L / R→R.
    @ViewBuilder
    private func stereoLinkMenu(_ entry: GridEntry) -> some View {
        if entry.channels.count == 2 {
            Button("Unlink Stereo Pair") {
                client.setStereoLink(nodeID: entry.nodeID, channel: entry.channel, linked: false)
            }
        } else {
            let base = entry.channel & ~1
            Button("Link \(base + 1)–\(base + 2) as Stereo Pair") {
                client.setStereoLink(nodeID: entry.nodeID, channel: entry.channel, linked: true)
            }
        }
    }

    private func interfaceGroups(direction: String, bankSize: Int) -> [GroupDef] {
        client.interfaces.flatMap { iface -> [GroupDef] in
            let count = direction == "in" ? iface.inChannels  : iface.outChannels
            let base  = direction == "in" ? iface.inBase      : iface.outBase
            guard count > 0 else { return [] }
            let scope: ChannelScope = direction == "in" ? .input : .output
            return banks(
                nodeID: Hydra.backplaneNodeID,
                prefix: "if-\(iface.id.uuidString)-\(direction)",
                count: count, base: base,
                icon: "rectangle.connected.to.line.below", bankSize: bankSize,
                namer: { ch in
                    client.labels.label(scope, base + ch)
                        ?? (count == 1 ? iface.name : "\(iface.name) \(ch + 1)")
                },
                groupNamer: { count <= bankSize ? iface.name : "\(iface.name) \($0 + 1)–\($1)" })
        }
    }

    private func sourceGroups(bankSize: Int) -> [GroupDef] {
        var defs = interfaceGroups(direction: "in", bankSize: bankSize)
        for app in client.apps.filter(\.captured) {
            let name = String(app.name.prefix(12))
            // App captures are 2 mono lanes (L/R), but collapse into ONE stereo
            // lane when the user links them (same ganging as interfaces/devices).
            let entries: [GridEntry]
            if client.stereoLinked(nodeID: app.nodeID, evenChannel: 0) {
                entries = [GridEntry(nodeID: app.nodeID, channels: [0, 1],
                                     label: "\(name) ·St", shortLabel: "\(name) ·St")]
            } else {
                entries = [
                    GridEntry(nodeID: app.nodeID, channels: [0], label: "\(name) L", shortLabel: "\(name) L"),
                    GridEntry(nodeID: app.nodeID, channels: [1], label: "\(name) R", shortLabel: "\(name) R"),
                ]
            }
            defs.append(("app-\(app.nodeID)", name, "macwindow", entries))
        }
        for source in client.ndi.sources.filter({ $0.subscribed && $0.channels > 0 }) {
            let name = String(source.name.prefix(12))
            defs.append(contentsOf: banks(
                nodeID: Hydra.ndiNodeID(sourceID: source.id),
                prefix: "ndi-\(source.id)", count: source.channels,
                icon: "antenna.radiowaves.left.and.right", bankSize: bankSize,
                namer: { source.channels == 1 ? name : "\(name) \($0 + 1)" },
                groupNamer: { source.channels <= bankSize ? name : "\(name) \($0 + 1)–\($1)" }))
        }
        for stream in client.aes67.streams.filter(\.subscribed) {
            let name = String(stream.name.prefix(10))
            defs.append(contentsOf: banks(
                nodeID: stream.nodeID, prefix: "st-\(stream.id)", count: stream.channels,
                icon: "network", bankSize: bankSize,
                namer: { "\(name) \($0 + 1)" },
                groupNamer: { stream.channels <= bankSize ? name : "\(name) \($0 + 1)–\($1)" }))
        }
        for source in client.modules.sources.filter({ $0.subscribed && $0.channels > 0 }) {
            let name = String(source.name.prefix(12))
            defs.append(contentsOf: banks(
                nodeID: Hydra.moduleNodeID(sourceID: source.id),
                prefix: "mod-\(source.id)", count: source.channels,
                icon: "puzzlepiece.extension", bankSize: bankSize,
                namer: { source.channels == 1 ? name : "\(name) \($0 + 1)" },
                groupNamer: { source.channels <= bankSize ? name : "\(name) \($0 + 1)–\($1)" }))
        }
        for device in client.devices.filter({ $0.used && $0.present && $0.inputChannels > 0 }) {
            let name = String(device.name.prefix(10))
            defs.append(contentsOf: banks(
                nodeID: device.nodeID, prefix: "dev-in-\(device.uid)",
                count: device.inputChannels, icon: "hifispeaker.fill", bankSize: bankSize,
                namer: { "\(name) \($0 + 1)" },
                groupNamer: { device.inputChannels <= bankSize ? name : "\(name) \($0 + 1)–\($1)" }))
        }
        return defs
    }

    private func destinationGroups(bankSize: Int) -> [GroupDef] {
        var defs = interfaceGroups(direction: "out", bankSize: bankSize)
        for device in client.devices.filter({ $0.used && $0.present && $0.outputChannels > 0 }) {
            let name = String(device.name.prefix(10))
            defs.append(contentsOf: banks(
                nodeID: device.nodeID, prefix: "dev-out-\(device.uid)",
                count: device.outputChannels, icon: "hifispeaker.fill", bankSize: bankSize,
                namer: { "\(name) \($0 + 1)" },
                groupNamer: { device.outputChannels <= bankSize ? name : "\(name) \($0 + 1)–\($1)" }))
        }
        for sink in client.modules.sinks.filter({ $0.channels > 0 }) {
            let name = String(sink.name.prefix(12))
            defs.append(contentsOf: banks(
                nodeID: Hydra.moduleSinkNodeID(sinkID: sink.id),
                prefix: "modtx-\(sink.id)", count: sink.channels,
                icon: "puzzlepiece.extension", bankSize: bankSize,
                namer: { sink.channels == 1 ? name : "\(name) \($0 + 1)" },
                groupNamer: { sink.channels <= bankSize ? name : "\(name) \($0 + 1)–\($1)" }))
        }
        return defs
    }

    private func axisItems(_ defs: [GroupDef], expanded: Set<String>) -> [AxisItem] {
        var items: [AxisItem] = []
        for def in defs {
            let isExpanded = !groupChannels || expanded.contains(def.id)
            items.append(.group(id: def.id, label: def.label, icon: def.icon,
                                count: def.entries.count, expanded: isExpanded))
            if isExpanded { items.append(contentsOf: def.entries.map(AxisItem.channel)) }
        }
        return items
    }

    private func layout(_ items: [AxisItem]) -> AxisLayout {
        AxisLayout(items: items, gap: gap) { item in
            if case .group = item { return groupSize }
            return cell
        }
    }

    // MARK: - Body

    var body: some View {
        let gridBank = groupChannels ? 8 : Int.max
        let rowItems = axisItems(destinationGroups(bankSize: gridBank), expanded: expandedRows)
        let colItems = axisItems(sourceGroups(bankSize: gridBank), expanded: expandedCols)
        let rows     = layout(rowItems)
        let cols     = layout(colItems)
        let connected = Set(client.connections.map {
            "\($0.source.nodeID):\($0.source.channelIndex)>\($0.destination.nodeID):\($0.destination.channelIndex)"
        })

        return VStack(alignment: .leading, spacing: 0) {
            // Control bar anchored in a bar-material strip — same treatment as
            // the sidebar section picker. Separated from content by a Divider.
            controlBar(rows: rowItems, cols: colItems)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)

            Divider()

            if rowItems.isEmpty && colItems.isEmpty {
                emptyState
            } else if viewMode == "list" {
                DeviceViewPatch(
                    sources: sourceGroups(bankSize: Int.max),
                    destinations: destinationGroups(bankSize: Int.max),
                    selection: $selection,
                    collapseByDevice: groupChannels,
                    expandedDevices: $expandedListDevices)
                .padding(16)
            } else {
                GeometryReader { geo in
                    frozenGrid(rowItems: rowItems, colItems: colItems,
                               rows: rows, cols: cols, connected: connected)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.Grid.hairline, lineWidth: 0.5))
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Control bar
    // Sits in a .bar-material strip (same as the sidebar section picker), so
    // semantic foreground colors apply correctly and it looks anchored at the top.

    private func controlBar(rows: [AxisItem], cols: [AxisItem]) -> some View {
        HStack(spacing: 8) {
            // Groups toggle
            Button {
                groupChannels.toggle()
            } label: {
                Label("Groups",
                      systemImage: groupChannels ? "rectangle.grid.1x2.fill" : "rectangle.grid.1x2")
            }
            .buttonStyle(.bordered)
            .tint(groupChannels ? .accentColor : nil)
            .help("Bank channels in collapsible groups of 8 — useful for big interfaces. Off = flat list.")

            // Collapse / expand all (only when groups mode is ON)
            if groupChannels {
                let allCollapsed = expandedRows.isEmpty && expandedCols.isEmpty && expandedListDevices.isEmpty
                Button {
                    if allCollapsed {
                        expandedRows         = Set(rows.compactMap         { if case .group(let id, _, _, _, _) = $0 { return id }; return nil })
                        expandedCols         = Set(cols.compactMap         { if case .group(let id, _, _, _, _) = $0 { return id }; return nil })
                        expandedListDevices  = Set(sourceGroups(bankSize: Int.max).map(\.id))
                    } else {
                        expandedRows        = []
                        expandedCols        = []
                        expandedListDevices = []
                    }
                } label: {
                    Label(allCollapsed ? "Expand all" : "Collapse all",
                          systemImage: "rectangle.compress.vertical")
                }
                .buttonStyle(.bordered)
                .help(allCollapsed ? "Expand every device/group" : "Collapse every device/group back to its header")
            }

            // View mode picker
            Picker("View", selection: $viewMode) {
                Image(systemName: "square.grid.3x3").tag("grid")
                    .help("Grid — every source × destination")
                Image(systemName: "list.bullet").tag("list")
                    .help("List — pick sources per destination, Dante Controller style")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 72)

            // Remove selection
            if !selectedCells.isEmpty {
                let patched = selectedCells.filter {
                    !client.cellConnections(source: $0.source, destination: $0.destination).isEmpty
                }
                Button {
                    removeSelectedPatches()
                } label: {
                    Label("Remove patch", systemImage: "delete.left")
                }
                .buttonStyle(.bordered)
                .disabled(patched.isEmpty)
                .keyboardShortcut(.delete, modifiers: [])
                .help(patched.isEmpty
                      ? "Nothing patched in the selection"
                      : "Removes \(patched.count) patch\(patched.count == 1 ? "" : "es") — or press ⌫")
            }

            // Clear visible
            Button {
                confirmClear = true
            } label: {
                Label("Clear visible", systemImage: "eraser")
            }
            .buttonStyle(.bordered)
            .help("Removes every connection between the channels shown in the grid")
            .confirmationDialog("Clear all connections between the visible channels?",
                                isPresented: $confirmClear) {
                Button("Clear visible", role: .destructive) {
                    let rowEntries = rows.compactMap { if case .channel(let e) = $0 { return e }; return nil }
                    let colEntries = cols.compactMap { if case .channel(let e) = $0 { return e }; return nil }
                    for row in rowEntries {
                        for col in colEntries
                        where !client.cellConnections(source: col, destination: row).isEmpty {
                            client.disconnectCell(source: col, destination: row)
                        }
                    }
                    selection     = nil
                    selectedCells = []
                }
            } message: {
                Text("Only connections between channels currently visible in the grid are removed.")
            }

            Spacer()
        }
    }

    // MARK: - Frozen pane grid

    private func frozenGrid(rowItems: [AxisItem], colItems: [AxisItem],
                            rows: AxisLayout, cols: AxisLayout,
                            connected: Set<String>) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("RECEIVERS")
                .font(.system(size: 10, weight: .semibold))
                .kerning(1.4)
                .foregroundStyle(Theme.Grid.textTertiary)
                .fixedSize()
                .rotationEffect(.degrees(-90))
                .frame(width: 16)
                .frame(maxHeight: .infinity, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                Text("TRANSMITTERS")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(1.4)
                    .foregroundStyle(Theme.Grid.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 14)

                VStack(alignment: .leading, spacing: gap) {
                    HStack(alignment: .top, spacing: gap) {
                        Color.clear.frame(width: labelWidth, height: headerHeight)
                        OffsetPane(scroll: scroll, axis: .horizontal) {
                            columnHeaders(colItems, layout: cols)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: headerHeight)
                        .clipped()
                    }
                    HStack(alignment: .top, spacing: gap) {
                        OffsetPane(scroll: scroll, axis: .vertical) {
                            rowLabels(rowItems, layout: rows)
                        }
                        .frame(width: labelWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .clipped()
                        cellCanvas(rows: rows, cols: cols, connected: connected)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.Grid.panel))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func columnHeaders(_ items: [AxisItem], layout: AxisLayout) -> some View {
        // Virtualized: render only the slots inside the viewport (+ margin),
        // positioned absolutely. At 128 channels that's ~20 views instead of 128,
        // and only those few SignalDots observe the 10 Hz meters.
        let vw   = scroll.viewport.width
        let minX = vw > 0 ? scroll.offset.x - axisMargin : -.greatestFiniteMagnitude
        let maxX = vw > 0 ? scroll.offset.x + vw + axisMargin :  .greatestFiniteMagnitude
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(width: max(layout.total, 1), height: headerHeight)
            SignalStripCanvas(marks: signalMarks(layout, output: false), output: false,
                              axis: .horizontal, crossExtent: headerHeight)
                .frame(width: max(layout.total, 1), height: headerHeight)
            ForEach(layout.slots.filter { $0.origin + $0.size >= minX && $0.origin <= maxX },
                    id: \.id) { slot in
                columnHeaderItem(slot.item).offset(x: slot.origin)
            }
        }
        .frame(width: max(layout.total, 1), height: headerHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private func columnHeaderItem(_ item: AxisItem) -> some View {
        switch item {
        case .group(let id, let label, let icon, let count, let expanded):
            Button {
                if groupChannels { toggleGroup(id, in: &expandedCols) }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Grid.textTertiary)
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(expanded && groupChannels
                                         ? Theme.accent : Theme.Grid.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: headerHeight - 44, alignment: .leading)
                        .rotationEffect(.degrees(-90))
                        .frame(width: groupSize, height: headerHeight - 40)
                    if groupChannels {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.Grid.textTertiary)
                    }
                }
                .frame(width: groupSize, height: headerHeight)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.Grid.groupHeader))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(groupChannels
                  ? "\(kindName(icon)) \"\(label)\" — \(count) channels. Click to \(expanded ? "collapse" : "expand")."
                  : "\(kindName(icon)) \"\(label)\" — \(count) channels")

        case .channel(let entry):
            let active = selection?.source.id == entry.id
                || (channelFocus?.scope == .input && channelFocus?.entry.id == entry.id)
            VStack(spacing: 2) {
                Text(entry.shortLabel)
                    .font(.system(size: 12, weight: active ? .bold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(active ? Theme.accent : Theme.Grid.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: headerHeight - 24, alignment: .leading)
                    .rotationEffect(.degrees(-90))
                    .frame(width: cell, height: headerHeight - 14)
                Color.clear.frame(width: 4, height: 4)   // signal dot drawn by SignalStripCanvas
            }
            .frame(width: cell, height: headerHeight)
            .contentShape(Rectangle())
            .help(entry.label)
            // Click the transmitter's name to open its channel strip.
            .onTapGesture { channelFocus = ChannelFocus(entry: entry, scope: .input) }
            .contextMenu { stereoLinkMenu(entry) }
        }
    }

    private func rowLabels(_ items: [AxisItem], layout: AxisLayout) -> some View {
        // Virtualized like columnHeaders — only visible row labels are rendered.
        let vh   = scroll.viewport.height
        let minY = vh > 0 ? scroll.offset.y - axisMargin : -.greatestFiniteMagnitude
        let maxY = vh > 0 ? scroll.offset.y + vh + axisMargin :  .greatestFiniteMagnitude
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(width: labelWidth, height: max(layout.total, 1))
            SignalStripCanvas(marks: signalMarks(layout, output: true), output: true,
                              axis: .vertical, crossExtent: labelWidth)
                .frame(width: labelWidth, height: max(layout.total, 1))
            ForEach(layout.slots.filter { $0.origin + $0.size >= minY && $0.origin <= maxY },
                    id: \.id) { slot in
                rowLabelItem(slot.item).offset(y: slot.origin)
            }
        }
        .frame(width: labelWidth, height: max(layout.total, 1), alignment: .topLeading)
    }

    @ViewBuilder
    private func rowLabelItem(_ item: AxisItem) -> some View {
        switch item {
        case .group(let id, let label, let icon, let count, let expanded):
            Button {
                if groupChannels { toggleGroup(id, in: &expandedRows) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Grid.textTertiary)
                    Spacer(minLength: 0)
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(expanded && groupChannels
                                         ? Theme.accent : Theme.Grid.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if groupChannels {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.Grid.textTertiary)
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: labelWidth, height: groupSize)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.Grid.groupHeader))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(groupChannels
                  ? "\(kindName(icon)) \"\(label)\" — \(count) channels. Click to \(expanded ? "collapse" : "expand")."
                  : "\(kindName(icon)) \"\(label)\" — \(count) channels")

        case .channel(let entry):
            let active = selection?.destination.id == entry.id
                || (channelFocus?.scope == .output && channelFocus?.entry.id == entry.id)
            HStack(spacing: 4) {
                Text(entry.label)
                    .font(.system(size: 12, weight: active ? .bold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(active ? Theme.Grid.textPrimary : Theme.Grid.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Reserve space for the signal dot (drawn by SignalStripCanvas at
                // labelWidth − 6) so the pin gets the same gap from the name that
                // the transmitter columns have.
                Color.clear.frame(width: 10, height: 4)
            }
            .frame(width: labelWidth, height: cell, alignment: .trailing)
            .contentShape(Rectangle())
            .help(entry.label)
            // Click the receiver's name to open its channel strip.
            .onTapGesture { channelFocus = ChannelFocus(entry: entry, scope: .output) }
            .contextMenu { stereoLinkMenu(entry) }
        }
    }

    private func kindName(_ icon: String) -> String {
        switch icon {
        case "macwindow":                           return "App capture"
        case "antenna.radiowaves.left.and.right":   return "NDI source"
        case "network":                             return "AES67 stream"
        case "hifispeaker.fill":                    return "Audio interface"
        default:                                    return "Virtual interface"
        }
    }

    private func toggleGroup(_ id: String, in set: inout Set<String>) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    private func removeSelectedPatches() {
        for cell in selectedCells
        where !client.cellConnections(source: cell.source, destination: cell.destination).isEmpty {
            client.disconnectCell(source: cell.source, destination: cell.destination)
        }
        selectedCells = []
        selection     = nil
    }

    private func connIDs(source entry: GridEntry) -> [String] {
        guard entry.nodeID != Hydra.backplaneNodeID else { return [] }
        return client.connections.filter {
            $0.source.nodeID == entry.nodeID && $0.source.channelIndex == entry.channel
        }.map(\.id)
    }

    private func connIDs(destination entry: GridEntry) -> [String] {
        guard entry.nodeID != Hydra.backplaneNodeID else { return [] }
        return client.connections.filter {
            $0.destination.nodeID == entry.nodeID && $0.destination.channelIndex == entry.channel
        }.map(\.id)
    }

    /// One mark per channel lane (position + what to read for its signal state).
    /// Built here (re-runs on connection/scroll changes, NOT on 10 Hz meters) and
    /// fed to a single SignalStripCanvas that observes the meter stream.
    private func signalMarks(_ layout: AxisLayout, output: Bool) -> [SignalMark] {
        layout.slots.compactMap { slot in
            guard case .channel(let e) = slot.item else { return nil }
            return SignalMark(position: slot.origin + slot.size / 2,
                              nodeID: e.nodeID, channel: e.channel,
                              connIDs: e.nodeID == Hydra.backplaneNodeID ? []
                                       : (output ? connIDs(destination: e) : connIDs(source: e)))
        }
    }

    // MARK: - Cell canvas

    private func cellCanvas(rows: AxisLayout, cols: AxisLayout, connected: Set<String>) -> some View {
        CellField(
            rows: rows, cols: cols, connected: connected,
            selection: selection, selectedCells: selectedCells,
            onScroll: { [weak scroll] rect in
                scroll?.offset = rect.origin
                scroll?.viewport = rect.size
            },
            onViewport: { [weak scroll] size in scroll?.viewport = size },
            onSingleTap: { row, col in
                let cell   = GridSelection(source: col, destination: row)
                let additive = NSEvent.modifierFlags.contains(.command)
                    || NSEvent.modifierFlags.contains(.shift)
                if additive {
                    if selectedCells.contains(cell) {
                        selectedCells.remove(cell)
                        if selection == cell { selection = selectedCells.first }
                    } else {
                        selectedCells.insert(cell)
                        selection = cell
                    }
                } else {
                    selectedCells = [cell]
                    selection     = cell
                }
            },
            onDoubleTap: { row, col in
                let cell = GridSelection(source: col, destination: row)
                if client.cellConnections(source: col, destination: row).isEmpty {
                    client.connectCell(source: col, destination: row)
                    selection     = cell
                    selectedCells = [cell]
                } else {
                    client.disconnectCell(source: col, destination: row)
                    selectedCells.remove(cell)
                    if selection == cell { selection = nil }
                }
            })
    }
}

// MARK: - Offset pane

private struct OffsetPane<Content: View>: View {
    @ObservedObject var scroll: ScrollState
    let axis: Axis
    @ViewBuilder let content: Content

    var body: some View {
        content.offset(
            x: axis == .horizontal ? -scroll.offset.x : 0,
            y: axis == .vertical   ? -scroll.offset.y : 0)
    }
}

// MARK: - Empty state

extension GridView {
    /// Native ContentUnavailableView — adapts to light/dark, matches system language.
    var emptyState: some View {
        ContentUnavailableView {
            Label("Your Set is Empty", systemImage: "rectangle.connected.to.line.below")
        } description: {
            Text("Hydra starts with zero channels — you build your own set.\nCreate a virtual interface (e.g. \"AES67 32×32\", \"OBS 2\"), capture an app, or enable a physical device in the sidebar.")
        } actions: {
            Button {
                showAddInterface = true
            } label: {
                Label("Add Interface…", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .sheet(isPresented: $showAddInterface) {
                AddInterfaceForm()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Signal strip (all of one axis' signal dots in ONE Canvas)

/// One channel's signal indicator placement + how to read its state.
private struct SignalMark {
    let position: CGFloat   // center along the axis
    let nodeID:   String
    let channel:  Int
    let connIDs:  [String]
}

/// Draws every channel's signal dot for one axis in a single Canvas. This is the
/// ONLY axis element observing the 10 Hz meter/signal stream — replacing N
/// per-channel SignalDot views, which churned the SwiftUI AttributeGraph. A meter
/// tick now re-renders one node and redraws one (thin) Canvas.
private struct SignalStripCanvas: View {
    @EnvironmentObject private var signals: SignalFlags
    @EnvironmentObject private var meters:  ConnMeters
    let marks: [SignalMark]
    let output: Bool
    let axis: Axis
    let crossExtent: CGFloat   // headerHeight (columns) or labelWidth (rows)

    var body: some View {
        Canvas { ctx, _ in
            let inset: CGFloat = 6, r: CGFloat = 2
            for m in marks {
                let on: Bool
                if m.nodeID == Hydra.backplaneNodeID {
                    let flags = output ? signals.outputs : signals.inputs
                    on = m.channel < flags.count && flags[m.channel]
                } else {
                    on = m.connIDs.contains { (meters.peaks[$0] ?? 0) > DaemonClient.signalThreshold }
                }
                let p: CGPoint = axis == .horizontal
                    ? CGPoint(x: m.position, y: crossExtent - inset)
                    : CGPoint(x: crossExtent - inset, y: m.position)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                         with: .color(on ? Theme.Grid.signal : Theme.Grid.noSignal))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Cell field (owns hover so the grid body never re-evaluates on it)

private struct CellField: View {
    let rows:       AxisLayout
    let cols:       AxisLayout
    let connected:  Set<String>
    let selection:  GridSelection?
    let selectedCells: Set<GridSelection>
    let onScroll:   (CGRect) -> Void
    let onViewport: (CGSize) -> Void
    let onSingleTap: (GridEntry, GridEntry) -> Void
    let onDoubleTap: (GridEntry, GridEntry) -> Void

    @State private var hover: HoverPos?
    @State private var visibleRect: CGRect = .zero

    private let gap: CGFloat = 2

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Canvas { context, _ in draw(context: context, visible: visibleRect) }
                .frame(width: max(cols.total, 1), height: max(rows.total, 1))
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let point):
                        if let row = rows.entry(at: point.y),
                           let col = cols.entry(at: point.x) {
                            let pos = HoverPos(row: row.id, col: col.id)
                            if hover != pos { hover = pos }
                        } else if hover != nil {
                            hover = nil
                        }
                    case .ended:
                        hover = nil
                    }
                }
                .gesture(
                    ExclusiveGesture(SpatialTapGesture(count: 2), SpatialTapGesture())
                        .onEnded { value in
                            switch value {
                            case .first(let tap):
                                guard let row = rows.entry(at: tap.location.y),
                                      let col = cols.entry(at: tap.location.x) else { return }
                                onDoubleTap(row, col)
                            case .second(let tap):
                                guard let row = rows.entry(at: tap.location.y),
                                      let col = cols.entry(at: tap.location.x) else { return }
                                onSingleTap(row, col)
                            }
                        }
                )
        }
        .defaultScrollAnchor(.topLeading)
        .onScrollGeometryChange(for: CGRect.self) { geo in
            CGRect(origin: geo.contentOffset, size: geo.containerSize)
        } action: { _, rect in
            visibleRect = rect
            onScroll(rect)
        }
        .help("Double-click: connect / disconnect · click: open the channel strip")
        // onScrollGeometryChange only fires on an actual scroll, so the viewport
        // would stay .zero until the user scrolls — disabling virtualization and
        // rendering every label/SignalDot. Measure it on appear too.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        visibleRect = CGRect(origin: visibleRect.origin, size: geo.size)
                        onViewport(geo.size)
                    }
                    .onChange(of: geo.size) { _, s in
                        visibleRect = CGRect(origin: visibleRect.origin, size: s)
                        onViewport(s)
                    }
            }
        )
    }

    private func draw(context: GraphicsContext, visible: CGRect) {
        // Viewport culling: at 128×128 there are 16k cells — only draw the ones
        // inside the visible rect (+ margin), so each redraw stays cheap.
        let cull   = visible.width > 0 && visible.height > 0
        let margin: CGFloat = 96
        let top    = visible.minY - margin, bottom = visible.maxY + margin
        let left   = visible.minX - margin, right  = visible.maxX + margin
        // Group separator lines
        for rowSlot in rows.slots {
            if case .group = rowSlot.item, rowSlot.origin > 0 {
                let line = CGRect(x: 0, y: rowSlot.origin - gap / 2 - 0.5,
                                  width: cols.total, height: 1)
                context.fill(Path(line), with: .color(Theme.Grid.separator))
            }
        }
        for colSlot in cols.slots {
            if case .group = colSlot.item, colSlot.origin > 0 {
                let line = CGRect(x: colSlot.origin - gap / 2 - 0.5, y: 0,
                                  width: 1, height: rows.total)
                context.fill(Path(line), with: .color(Theme.Grid.separator))
            }
        }

        // Group COLUMN bands — mirror the group ROW bands below, so transmitter
        // (column) and receiver (row) group lanes get the SAME filled treatment
        // instead of empty gaps on one axis and bands on the other.
        for colSlot in cols.slots {
            guard case .group = colSlot.item else { continue }
            if cull, colSlot.origin + colSlot.size < left || colSlot.origin > right { continue }
            let rect = CGRect(x: colSlot.origin, y: 0, width: colSlot.size, height: rows.total)
            context.fill(Path(rect), with: .color(Theme.Grid.groupHeader.opacity(0.25)))
        }

        for rowSlot in rows.slots {
            if cull, rowSlot.origin + rowSlot.size < top || rowSlot.origin > bottom { continue }
            guard case .channel(let destination) = rowSlot.item else {
                let rect = CGRect(x: 0, y: rowSlot.origin, width: cols.total, height: rowSlot.size)
                context.fill(Path(rect), with: .color(Theme.Grid.groupHeader.opacity(0.25)))
                continue
            }
            for colSlot in cols.slots {
                if cull, colSlot.origin + colSlot.size < left || colSlot.origin > right { continue }
                guard case .channel(let source) = colSlot.item else { continue }
                let rect = CGRect(x: colSlot.origin, y: rowSlot.origin,
                                  width: colSlot.size, height: rowSlot.size)
                let path = Path(roundedRect: rect, cornerRadius: 5)

                let key        = "\(source.nodeID):\(source.channel)>\(destination.nodeID):\(destination.channel)"
                let isConnected = connected.contains(key)
                let pos        = HoverPos(row: destination.id, col: source.id)
                let isHovered  = hover == pos
                let inCrosshair = hover.map { $0.row == destination.id || $0.col == source.id } ?? false
                let cellSel    = GridSelection(source: source, destination: destination)
                let isSelected = selection == cellSel || selectedCells.contains(cellSel)

                let fill: Color = isSelected  ? Theme.Grid.cellSelected
                    : isHovered              ? Theme.Grid.cellHover
                    : inCrosshair            ? Theme.Grid.cellCrosshair
                    : Theme.Grid.cellRest

                context.fill(path, with: .color(fill))
                if !isSelected {
                    context.stroke(path, with: .color(Theme.Grid.hairline.opacity(0.6)), lineWidth: 0.5)
                } else {
                    context.stroke(path, with: .color(Theme.Grid.cellSelectedBorder), lineWidth: 1)
                }

                if isConnected {
                    let size: CGFloat = isSelected ? 14 : 12
                    let dot = CGRect(x: rect.midX - size / 2, y: rect.midY - size / 2,
                                     width: size, height: size)
                    context.fill(Path(roundedRect: dot, cornerRadius: 3),
                                 with: .color(Theme.Grid.patchDot))
                } else if isHovered {
                    let ghost = CGRect(x: rect.midX - 4.5, y: rect.midY - 4.5, width: 9, height: 9)
                    context.stroke(Path(roundedRect: ghost, cornerRadius: 2),
                                   with: .color(Theme.Grid.patchGhost), lineWidth: 1)
                }
            }
        }
    }
}
