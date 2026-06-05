// Hydra Audio — GPL-3.0
// The patch grid — collapsible groups (replaces pagination, by user request):
// every node appears as groups of up to 8 MONO channels, all collapsed by
// default. Expanding a group reveals its channels. The whole grid scrolls
// with headers frozen to the top-left corner (Dante Controller style); the
// cell field is a single Canvas, so even fully expanded it stays fast.
// Interactions: single click selects (opens the channel strip), double-click
// assigns / removes. One font everywhere (SF Pro; monospacedDigit for
// numbers only).

import SwiftUI
import AppKit
import HydraCore

/// One mono lane of some node.
struct GridEntry: Equatable, Hashable, Identifiable {
    let nodeID: String
    let channels: [Int]   // always one entry (mono); kept as array for API stability
    let label: String
    let shortLabel: String

    var channel: Int { channels[0] }
    var isStereo: Bool { false }
    var id: String { "\(nodeID):\(channels.map(String.init).joined(separator: "-"))" }
    var point: PatchPoint { PatchPoint(nodeID: nodeID, channelIndex: channel) }

    init(nodeID: String, channels: [Int], label: String, shortLabel: String) {
        self.nodeID = nodeID
        self.channels = channels
        self.label = label
        self.shortLabel = shortLabel
    }
}

struct GridSelection: Equatable, Hashable {
    var source: GridEntry
    var destination: GridEntry
}

private struct HoverPos: Equatable {
    var row: String
    var col: String
}

/// One slot along an axis: a collapsible group header or a channel lane.
private enum AxisItem {
    case group(id: String, label: String, icon: String, count: Int, expanded: Bool)
    case channel(GridEntry)
}

/// Scroll offset isolated from the grid's render cycle.
private final class ScrollState: ObservableObject {
    @Published var offset: CGPoint = .zero
}

/// Geometry shared by headers and canvas (they can never drift apart).
private struct AxisLayout {
    struct Slot {
        let item: AxisItem
        let origin: CGFloat
        let size: CGFloat
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

    @State private var showAddInterface = false
    /// Multi-selection (⌘/⇧-click adds; ⌫ removes the selected patches).
    @State private var selectedCells: Set<GridSelection> = []
    @AppStorage("patchViewMode") private var viewMode = "grid"
    /// User toggle: bank channels in collapsible groups of 8 (great for big
    /// interfaces) or show every channel flat under one header per node.
    @AppStorage("groupChannels") private var groupChannels = false
    @State private var expandedRows: Set<String> = []
    @State private var expandedCols: Set<String> = []
    @State private var hover: HoverPos?
    @State private var confirmClear = false
    @StateObject private var scroll = ScrollState()

    private let cell: CGFloat = 30
    private let gap: CGFloat = 2
    private let groupSize: CGFloat = 30
    private let labelWidth: CGFloat = 150
    private let headerHeight: CGFloat = 84

    // MARK: Group building (groups of ≤8 mono channels per node)

    typealias GroupDef = (id: String, label: String, icon: String, entries: [GridEntry])

    private func banks(nodeID: String, prefix idPrefix: String, count: Int, base: Int = 0,
                       icon: String,
                       namer: (Int) -> String, groupNamer: (Int, Int) -> String) -> [GroupDef] {
        var defs: [GroupDef] = []
        let bankSize = groupChannels ? 8 : Int.max
        var start = 0
        var bank = 0
        while start < count {
            let end = min(start + bankSize, count)
            let entries = (start..<end).map { ch in
                GridEntry(nodeID: nodeID, channels: [base + ch],
                          label: namer(ch), shortLabel: namer(ch))
            }
            defs.append(("\(idPrefix)-\(bank)", groupNamer(start, end), icon, entries))
            start = end
            bank += 1
        }
        return defs
    }

    /// The soundcard pool is invisible: the grid shows only the interfaces
    /// the user created. In and Out sides are sized (and allocated)
    /// independently — e.g. an AES67 return of 128×2.
    private func interfaceGroups(direction: String) -> [GroupDef] {
        client.interfaces.flatMap { iface -> [GroupDef] in
            let count = direction == "in" ? iface.inChannels : iface.outChannels
            let base = direction == "in" ? iface.inBase : iface.outBase
            guard count > 0 else { return [] }
            return banks(nodeID: Hydra.backplaneNodeID,
                         prefix: "if-\(iface.id.uuidString)-\(direction)",
                         count: count, base: base,
                         icon: "rectangle.connected.to.line.below",
                         namer: { count == 1 ? iface.name : "\(iface.name) \($0 + 1)" },
                         groupNamer: { !groupChannels || count <= 8 ? iface.name : "\(iface.name) \($0 + 1)–\($1)" })
        }
    }

    /// Everything that can EMIT audio (Dante: transmitters → columns).
    private var sourceGroups: [GroupDef] {
        var defs = interfaceGroups(direction: "in")
        for app in client.apps.filter(\.captured) {
            let name = String(app.name.prefix(12))
            defs.append(("app-\(app.nodeID)", name, "macwindow", [
                GridEntry(nodeID: app.nodeID, channels: [0], label: "\(name) L", shortLabel: "\(name) L"),
                GridEntry(nodeID: app.nodeID, channels: [1], label: "\(name) R", shortLabel: "\(name) R")
            ]))
        }
        for source in client.ndi.sources.filter({ $0.subscribed && $0.channels > 0 }) {
            let name = String(source.name.prefix(12))
            defs.append(contentsOf: banks(nodeID: Hydra.ndiNodeID(sourceID: source.id),
                                          prefix: "ndi-\(source.id)",
                                          count: source.channels,
                                          icon: "antenna.radiowaves.left.and.right",
                                          namer: { source.channels == 1 ? name : "\(name) \($0 + 1)" },
                                          groupNamer: { !groupChannels || source.channels <= 8 ? name : "\(name) \($0 + 1)–\($1)" }))
        }
        for stream in client.aes67.streams.filter(\.subscribed) {
            let name = String(stream.name.prefix(10))
            defs.append(contentsOf: banks(nodeID: stream.nodeID, prefix: "st-\(stream.id)",
                                          count: stream.channels,
                                          icon: "network",
                                          namer: { "\(name) \($0 + 1)" },
                                          groupNamer: { !groupChannels || stream.channels <= 8 ? name : "\(name) \($0 + 1)–\($1)" }))
        }
        for device in client.devices.filter({ $0.used && $0.present && $0.inputChannels > 0 }) {
            let name = String(device.name.prefix(10))
            defs.append(contentsOf: banks(nodeID: device.nodeID, prefix: "dev-in-\(device.uid)",
                                          count: device.inputChannels,
                                          icon: "hifispeaker.fill",
                                          namer: { "\(name) \($0 + 1)" },
                                          groupNamer: { !groupChannels || device.inputChannels <= 8 ? name : "\(name) \($0 + 1)–\($1)" }))
        }
        return defs
    }

    /// Everything that can RECEIVE audio (Dante: receivers → rows).
    private var destinationGroups: [GroupDef] {
        var defs = interfaceGroups(direction: "out")
        for device in client.devices.filter({ $0.used && $0.present && $0.outputChannels > 0 }) {
            let name = String(device.name.prefix(10))
            defs.append(contentsOf: banks(nodeID: device.nodeID, prefix: "dev-out-\(device.uid)",
                                          count: device.outputChannels,
                                          icon: "hifispeaker.fill",
                                          namer: { "\(name) \($0 + 1)" },
                                          groupNamer: { !groupChannels || device.outputChannels <= 8 ? name : "\(name) \($0 + 1)–\($1)" }))
        }
        return defs
    }

    /// Groups mode ON: banks of 8 with collapsible headers (collapsed by
    /// default — ideal for 128-channel interfaces). OFF: flat list with one
    /// static header per node.
    private func axisItems(_ defs: [GroupDef], expanded: Set<String>) -> [AxisItem] {
        var items: [AxisItem] = []
        for def in defs {
            let isExpanded = !groupChannels || expanded.contains(def.id)
            items.append(.group(id: def.id, label: def.label, icon: def.icon,
                                count: def.entries.count, expanded: isExpanded))
            if isExpanded {
                items.append(contentsOf: def.entries.map(AxisItem.channel))
            }
        }
        return items
    }

    private func layout(_ items: [AxisItem]) -> AxisLayout {
        AxisLayout(items: items, gap: gap) { item in
            if case .group = item { return groupSize }
            return cell
        }
    }

    // MARK: Body

    var body: some View {
        let rowItems = axisItems(destinationGroups, expanded: expandedRows)
        let colItems = axisItems(sourceGroups, expanded: expandedCols)
        let rows = layout(rowItems)
        let cols = layout(colItems)
        let connected = Set(client.connections.map {
            "\($0.source.nodeID):\($0.source.channelIndex)>\($0.destination.nodeID):\($0.destination.channelIndex)"
        })

        return VStack(alignment: .leading, spacing: 10) {
            controlBar(rows: rowItems, cols: colItems)
            if rowItems.isEmpty && colItems.isEmpty {
                emptyState
            } else if viewMode == "list" {
                ListPatchView(sources: sourceGroups, destinations: destinationGroups,
                              selection: $selection)
            } else {
                GeometryReader { geo in
                    // Explicit size: the inner panes are bounded by the
                    // viewport, so the cell ScrollView actually scrolls
                    // (a rigid 128-row label stack must never set heights).
                    frozenGrid(rowItems: rowItems, colItems: colItems, rows: rows, cols: cols, connected: connected)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                        .clipped()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Control bar

    private func controlBar(rows: [AxisItem], cols: [AxisItem]) -> some View {
        HStack(spacing: 10) {
            Button {
                showAddInterface = true
            } label: {
                Label("Interface", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(Theme.accent.opacity(0.12)))
            .overlay(Capsule().stroke(Theme.accent.opacity(0.35), lineWidth: 0.5))
            .help("Create a virtual interface — a named block of soundcard channels")
            .popover(isPresented: $showAddInterface, arrowEdge: .bottom) {
                AddInterfaceForm()
            }

            Button {
                groupChannels.toggle()
            } label: {
                Label("Groups", systemImage: groupChannels
                      ? "rectangle.grid.1x2.fill" : "rectangle.grid.1x2")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(groupChannels ? Theme.accent : Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(groupChannels ? Theme.accent.opacity(0.12) : Color.white.opacity(0.04)))
            .overlay(Capsule().stroke(groupChannels ? Theme.accent.opacity(0.35) : Theme.hairline, lineWidth: 0.5))
            .help("Bank channels in collapsible groups of 8 — useful for big interfaces. Off = flat list.")

            if groupChannels {
                Button {
                    expandedRows = []
                    expandedCols = []
                } label: {
                    Label("Collapse all", systemImage: "rectangle.compress.vertical")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.04)))
                .overlay(Capsule().stroke(Theme.hairline, lineWidth: 0.5))
                .help("Collapse every group back to its header")
            }

            Picker("View", selection: $viewMode) {
                Image(systemName: "square.grid.3x3").tag("grid")
                    .help("Grid view — every source × destination")
                Image(systemName: "list.bullet").tag("list")
                    .help("List view — pick sources per destination, Dante Controller style")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 76)

            if !selectedCells.isEmpty {
                let patched = selectedCells.filter {
                    !client.cellConnections(source: $0.source, destination: $0.destination).isEmpty
                }
                Button {
                    removeSelectedPatches()
                } label: {
                    Label("Remove patch", systemImage: "delete.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(patched.isEmpty ? Theme.textTertiary : Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.04)))
                .overlay(Capsule().stroke(Theme.hairline, lineWidth: 0.5))
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(patched.isEmpty)
                .help(patched.isEmpty
                      ? "Nothing patched in the selection"
                      : "Removes \(patched.count) patch\(patched.count == 1 ? "" : "es") in the selection — or press ⌫")
            }

            Button {
                confirmClear = true
            } label: {
                Label("Clear visible", systemImage: "eraser")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.04)))
            .overlay(Capsule().stroke(Theme.hairline, lineWidth: 0.5))
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
                    selection = nil
                    selectedCells = []
                }
            } message: {
                Text("Only connections between channels shown in the grid are removed (absent devices keep theirs).")
            }

            Spacer()

            if let hover,
               let row = rows.compactMap({ if case .channel(let e) = $0 { return e }; return nil }).first(where: { $0.id == hover.row }),
               let col = cols.compactMap({ if case .channel(let e) = $0 { return e }; return nil }).first(where: { $0.id == hover.col }) {
                Text("\(row.label) → \(col.label)")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.accent.opacity(0.13)))
            }
        }
    }

    // MARK: Frozen-pane grid

    private func frozenGrid(rowItems: [AxisItem], colItems: [AxisItem],
                            rows: AxisLayout, cols: AxisLayout,
                            connected: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            HStack(alignment: .top, spacing: gap) {
                Text("RX ▼ · TX ▶")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: labelWidth, height: headerHeight, alignment: .bottomTrailing)
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
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline, lineWidth: 0.5))
    }

    private func columnHeaders(_ items: [AxisItem], layout: AxisLayout) -> some View {
        HStack(spacing: gap) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                switch item {
                case .group(let id, let label, let icon, let count, let expanded):
                    // Device bar (Dante style): solid vertical tab with the name.
                    Button {
                        if groupChannels { toggleGroup(id, in: &expandedCols) }
                    } label: {
                        VStack(spacing: 3) {
                            Text(label)
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(expanded && groupChannels ? Theme.accent : Theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(width: headerHeight - 26)
                                .rotationEffect(.degrees(-90))
                                .frame(width: groupSize, height: headerHeight - 22)
                            Image(systemName: groupChannels ? (expanded ? "chevron.down" : "chevron.right") : icon)
                                .font(.system(size: 8.5, weight: groupChannels ? .bold : .regular))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .frame(width: groupSize, height: headerHeight)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(groupChannels
                          ? "\(kindName(icon)) \u{201C}\(label)\u{201D} — \(count) channels. Click to \(expanded ? "collapse" : "expand")."
                          : "\(kindName(icon)) \u{201C}\(label)\u{201D} — \(count) channels")
                case .channel(let entry):
                    let active = hover?.col == entry.id || selection?.source.id == entry.id
                    VStack(spacing: 2) {
                        Text(entry.shortLabel)
                            .font(.system(size: 11, weight: active ? .bold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(active ? Theme.accent : Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: headerHeight - 24)
                            .rotationEffect(.degrees(-90))
                            .frame(width: cell, height: headerHeight - 14)
                        SignalDot(nodeID: entry.nodeID, channel: entry.channel, output: false)
                    }
                    .frame(width: cell, height: headerHeight)
                    .help(entry.label)
                }
            }
        }
    }

    private func rowLabels(_ items: [AxisItem], layout: AxisLayout) -> some View {
        VStack(spacing: gap) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                switch item {
                case .group(let id, let label, let icon, let count, let expanded):
                    // Device bar spanning the label column (Dante style).
                    Button {
                        if groupChannels { toggleGroup(id, in: &expandedRows) }
                    } label: {
                        HStack(spacing: 6) {
                            if groupChannels {
                                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Image(systemName: icon)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textTertiary)
                            Text(label)
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(expanded && groupChannels ? Theme.accent : Theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(width: labelWidth, height: groupSize)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(groupChannels
                          ? "\(kindName(icon)) \u{201C}\(label)\u{201D} — \(count) channels. Click to \(expanded ? "collapse" : "expand")."
                          : "\(kindName(icon)) \u{201C}\(label)\u{201D} — \(count) channels")
                case .channel(let entry):
                    let active = hover?.row == entry.id || selection?.destination.id == entry.id
                    HStack(spacing: 4) {
                        SignalDot(nodeID: entry.nodeID, channel: entry.channel, output: true)
                        Text(entry.label)
                            .font(.system(size: 12, weight: active ? .bold : .medium))
                            .monospacedDigit()
                            .foregroundStyle(active ? Theme.textPrimary : Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(width: labelWidth, height: cell, alignment: .trailing)
                    .help(entry.label)
                }
            }
        }
    }



    private func kindName(_ icon: String) -> String {
        switch icon {
        case "macwindow": return "App capture"
        case "antenna.radiowaves.left.and.right": return "NDI source"
        case "network": return "AES67 stream"
        case "hifispeaker.fill": return "Audio interface"
        default: return "Virtual interface"
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
        selection = nil
    }

    // MARK: Cell canvas

    private func cellCanvas(rows: AxisLayout, cols: AxisLayout, connected: Set<String>) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Canvas { context, _ in
                drawCells(context: context, rows: rows, cols: cols, connected: connected)
            }
            .frame(width: max(cols.total, 1), height: max(rows.total, 1))
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    if let row = rows.entry(at: point.y), let col = cols.entry(at: point.x) {
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
                ExclusiveGesture(
                    SpatialTapGesture(count: 2),
                    SpatialTapGesture()
                )
                .onEnded { value in
                    switch value {
                    case .first(let tap):   // double-click: assign / remove
                        guard let row = rows.entry(at: tap.location.y),
                              let col = cols.entry(at: tap.location.x) else { return }
                        let cell = GridSelection(source: col, destination: row)
                        if client.cellConnections(source: col, destination: row).isEmpty {
                            client.connectCell(source: col, destination: row)
                            selection = cell
                            selectedCells = [cell]
                        } else {
                            client.disconnectCell(source: col, destination: row)
                            selectedCells.remove(cell)
                            if selection == cell { selection = nil }
                        }
                    case .second(let tap):  // single click: select (⌘/⇧ adds)
                        guard let row = rows.entry(at: tap.location.y),
                              let col = cols.entry(at: tap.location.x) else { return }
                        let cell = GridSelection(source: col, destination: row)
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
                            selection = cell
                        }
                    }
                }
            )
        }
        // Two-axis ScrollViews CENTER undersized content, drifting the cell
        // field away from the frozen headers (and the drift tracks the
        // viewport width — hence "moving the sidebar bugs the grid").
        // Anchor the content to the top-leading corner instead.
        .defaultScrollAnchor(.topLeading)
        .onScrollGeometryChange(for: CGPoint.self) { geometry in
            geometry.contentOffset
        } action: { _, newOffset in
            scroll.offset = newOffset
        }
        .help("Double-click: connect / disconnect · click: open the channel strip")
    }

    private func drawCells(context: GraphicsContext, rows: AxisLayout, cols: AxisLayout,
                           connected: Set<String>) {
        // Device boundaries: thin separator lines where a group starts
        // (Dante Controller clarity without fake-cell bands).
        for rowSlot in rows.slots {
            if case .group = rowSlot.item, rowSlot.origin > 0 {
                let line = CGRect(x: 0, y: rowSlot.origin - gap / 2 - 0.5,
                                  width: cols.total, height: 1)
                context.fill(Path(line), with: .color(.white.opacity(0.10)))
            }
        }
        for colSlot in cols.slots {
            if case .group = colSlot.item, colSlot.origin > 0 {
                let line = CGRect(x: colSlot.origin - gap / 2 - 0.5, y: 0,
                                  width: 1, height: rows.total)
                context.fill(Path(line), with: .color(.white.opacity(0.10)))
            }
        }

        for rowSlot in rows.slots {
            guard case .channel(let destination) = rowSlot.item else {
                // Group lane: barely-there tint (it's a header, not cells)
                let rect = CGRect(x: 0, y: rowSlot.origin, width: cols.total, height: rowSlot.size)
                context.fill(Path(rect), with: .color(.white.opacity(0.015)))
                continue
            }
            for colSlot in cols.slots {
                guard case .channel(let source) = colSlot.item else { continue }
                let rect = CGRect(x: colSlot.origin, y: rowSlot.origin,
                                  width: colSlot.size, height: rowSlot.size)
                let path = Path(roundedRect: rect, cornerRadius: 5)

                let isConnected = connected.contains(
                    "\(source.nodeID):\(source.channel)>\(destination.nodeID):\(destination.channel)")
                let pos = HoverPos(row: destination.id, col: source.id)
                let isHovered = hover == pos
                let inCrosshair = hover.map { $0.row == destination.id || $0.col == source.id } ?? false
                let cellSel = GridSelection(source: source, destination: destination)
                let isSelected = selection == cellSel || selectedCells.contains(cellSel)

                let fill: Color = isSelected ? Theme.accent.opacity(0.22)
                    : isHovered ? .white.opacity(0.08)
                    : inCrosshair ? .white.opacity(0.05)
                    : .white.opacity(0.02)
                context.fill(path, with: .color(fill))
                // Lattice: every cell shows its edge (the field reads as a
                // patch matrix even when empty).
                context.stroke(path, with: .color(.white.opacity(isSelected ? 0 : 0.05)), lineWidth: 0.5)
                if isSelected {
                    context.stroke(path, with: .color(Theme.accent.opacity(0.55)), lineWidth: 1)
                }
                if isConnected {
                    let size: CGFloat = isSelected ? 14 : 12
                    let dot = CGRect(x: rect.midX - size / 2, y: rect.midY - size / 2,
                                     width: size, height: size)
                    context.fill(Path(roundedRect: dot, cornerRadius: 3),
                                 with: .color(Theme.accent))
                } else if isHovered {
                    let ghost = CGRect(x: rect.midX - 4.5, y: rect.midY - 4.5, width: 9, height: 9)
                    context.stroke(Path(roundedRect: ghost, cornerRadius: 2),
                                   with: .color(.white.opacity(0.25)), lineWidth: 1)
                }
            }
        }
    }
}

// MARK: - Pinned pane offset (observes ScrollState only)

private struct OffsetPane<Content: View>: View {
    @ObservedObject var scroll: ScrollState
    let axis: Axis
    @ViewBuilder let content: Content

    var body: some View {
        content.offset(
            x: axis == .horizontal ? -scroll.offset.x : 0,
            y: axis == .vertical ? -scroll.offset.y : 0)
    }
}


// MARK: - Empty state & interface creation

extension GridView {
    /// Shown when the user hasn't built their set yet (zero channels).
    var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("Your set is empty")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("Hydra starts with zero channels — you build your own set.\nCreate a virtual interface (e.g. “AES67 32×32”, “OBS 2”), capture an app, or enable a physical device in the sidebar.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Button {
                showAddInterface = true
            } label: {
                Label("Create interface", systemImage: "plus")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline, lineWidth: 0.5))
    }
}

/// Type-first creation: picking a template pre-fills name, channels and
/// NDI TX (all still editable). In and Out are sized independently —
/// e.g. an AES67 return of 128 in × 2 out.
struct AddInterfaceForm: View {
    @EnvironmentObject private var client: DaemonClient
    @Environment(\.dismiss) private var dismiss

    private struct Template: Identifiable {
        let id: String
        let icon: String
        let name: String
        let inCh: Int
        let outCh: Int
        let ndiTX: Bool
        let aesTX: Bool
        let hint: String
    }

    private static let templates: [Template] = [
        Template(id: "custom", icon: "slider.horizontal.3", name: "",
                 inCh: 2, outCh: 2, ndiTX: false, aesTX: false,
                 hint: "Blank — name it and size each side yourself."),
        Template(id: "daw", icon: "pianokeys", name: "DAW",
                 inCh: 32, outCh: 32, ndiTX: false, aesTX: false,
                 hint: "A DAW playing into Hydra and recording stems back."),
        Template(id: "obs", icon: "record.circle", name: "OBS",
                 inCh: 2, outCh: 2, ndiTX: false, aesTX: false,
                 hint: "Stream/recording app: monitor in, mixed program out."),
        Template(id: "aes67", icon: "network", name: "AES67 Stage",
                 inCh: 64, outCh: 2, ndiTX: false, aesTX: true,
                 hint: "Network audio: receive many channels, send a return — announced on the network from the start."),
        Template(id: "ndi", icon: "antenna.radiowaves.left.and.right", name: "NDI Feed",
                 inCh: 0, outCh: 2, ndiTX: true, aesTX: false,
                 hint: "Broadcasts what you route into it as an NDI source.")
    ]

    @State private var templateID = "custom"
    @State private var name = ""
    @State private var inChannels = 2
    @State private var outChannels = 2
    @State private var ndiTX = false
    @State private var aes67TX = false

    private let options = [0, 1, 2, 4, 6, 8, 16, 32, 64, 128]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New virtual interface")
                .font(.system(size: 14, weight: .semibold))

            // 1. Type first — pre-fills everything below.
            HStack(spacing: 6) {
                ForEach(Self.templates) { template in
                    Button {
                        templateID = template.id
                        name = template.name
                        inChannels = template.inCh
                        outChannels = template.outCh
                        ndiTX = template.ndiTX && client.ndi.runtimeAvailable
                        aes67TX = template.aesTX
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: template.icon)
                                .font(.system(size: 13))
                            Text(template.id == "custom" ? "Custom" : template.name.components(separatedBy: " ")[0])
                                .font(.system(size: 10))
                        }
                        .frame(width: 52, height: 40)
                        .foregroundStyle(templateID == template.id ? Theme.accent : Theme.textSecondary)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(templateID == template.id ? Theme.accent.opacity(0.14) : Color.white.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(templateID == template.id ? Theme.accent.opacity(0.4) : Theme.hairline,
                                    lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help(template.hint)
                }
            }

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 286)
                .onSubmit(create)

            // 2. Independent sides: what software PLAYS into Hydra (In) vs
            //    what it RECORDS from Hydra (Out).
            HStack(spacing: 14) {
                channelPicker("Inputs", selection: $inChannels,
                              help: "Lanes other software plays INTO (grid rows)")
                channelPicker("Outputs", selection: $outChannels,
                              help: "Lanes other software records FROM (grid columns)")
            }

            Toggle("Announce on the network (AES67 TX)", isOn: $aes67TX)
                .font(.caption)
                .disabled(outChannels == 0)
                .help("The Out side is announced via SAP and sent as multicast RTP — appears in Dante Controller. Experimental until PTP sync lands.")
            Toggle("Broadcast as NDI source (TX)", isOn: $ndiTX)
                .font(.caption)
                .disabled(!client.ndi.runtimeAvailable || outChannels == 0)
                .help(client.ndi.runtimeAvailable
                      ? "What you route to this interface's Out channels goes out on the network as NDI"
                      : "Requires the NDI runtime — see the Network tab")

            HStack {
                Text("\(client.allocatedPoolChannels + inChannels + outChannels) / \(Hydra.backplaneChannels) channels in use")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty ||
                              inChannels + outChannels == 0 ||
                              client.allocatedPoolChannels + inChannels + outChannels > Hydra.backplaneChannels)
            }
        }
        .padding(14)
    }

    private func channelPicker(_ label: String, selection: Binding<Int>, help: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
            Picker(label, selection: selection) {
                ForEach(options, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 64)
        }
        .help(help)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, inChannels + outChannels > 0 else { return }
        client.createInterface(name: trimmed, inChannels: inChannels,
                               outChannels: outChannels, ndiTX: ndiTX, aes67TX: aes67TX)
        dismiss()
    }
}

// MARK: - List patching (Dante Controller Device-View style)

/// Per-destination assignment: each visible destination channel is a row;
/// "+" opens a searchable source picker; current sources are chips with ✕.
struct ListPatchView: View {
    @EnvironmentObject private var client: DaemonClient
    let sources: [GridView.GroupDef]
    let destinations: [GridView.GroupDef]
    @Binding var selection: GridSelection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(destinations.indices, id: \.self) { index in
                    let group = destinations[index]
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Image(systemName: group.icon)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textTertiary)
                            Text(group.label)
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.bottom, 2)
                        ForEach(group.entries) { destination in
                            destinationRow(destination, within: group.entries)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline, lineWidth: 0.5))
    }

    private func destinationRow(_ destination: GridEntry, within groupEntries: [GridEntry]) -> some View {
        let connected = sourcesConnected(to: destination)
        return HStack(spacing: 8) {
            Text(destination.label)
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 165, alignment: .trailing)
                .lineLimit(1)

            if connected.isEmpty {
                Text("—")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(connected) { source in
                HStack(spacing: 5) {
                    Text(source.label)
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                    Button {
                        client.disconnectCell(source: source, destination: destination)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(source.label) → \(destination.label)")
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Theme.accent.opacity(0.12)))
                .overlay(Capsule().stroke(Theme.accent.opacity(0.35), lineWidth: 0.5))
                .onTapGesture {
                    selection = GridSelection(source: source, destination: destination)
                }
            }

            SourcePickerButton(sources: sources) { picked in
                assign(picked, startingAt: destination, within: groupEntries)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 30)
    }

    /// Dante-style batch patch: the picked sources land on consecutive
    /// receiver channels starting at `destination` (bounded by its group —
    /// a batch never spills into another interface/device).
    private func assign(_ picked: [GridEntry], startingAt destination: GridEntry,
                        within groupEntries: [GridEntry]) {
        guard let start = groupEntries.firstIndex(of: destination) else { return }
        var last: GridSelection?
        for (offset, source) in picked.enumerated() {
            let index = start + offset
            guard index < groupEntries.count else { break }
            client.connectCell(source: source, destination: groupEntries[index])
            last = GridSelection(source: source, destination: groupEntries[index])
        }
        if let last {
            selection = last
        }
    }

    /// GridEntries of every source currently patched into `destination`.
    private func sourcesConnected(to destination: GridEntry) -> [GridEntry] {
        let bySourceID = Dictionary(uniqueKeysWithValues:
            sources.flatMap(\.entries).map { ($0.id, $0) })
        return client.connections
            .filter { $0.destination == destination.point }
            .compactMap { conn -> GridEntry? in
                let id = "\(conn.source.nodeID):\(conn.source.channelIndex)"
                if let entry = bySourceID[id] { return entry }
                // Source exists but isn't visible (absent device etc.).
                return GridEntry(nodeID: conn.source.nodeID,
                                 channels: [conn.source.channelIndex],
                                 label: "\(conn.source.nodeID) \(conn.source.channelIndex + 1)",
                                 shortLabel: "\(conn.source.channelIndex + 1)")
            }
            .sorted { $0.label < $1.label }
    }
}

/// "+" button with a searchable, grouped source list. Click patches one
/// source; ⇧-click selects a contiguous range (⌘-click toggles single
/// channels) and "Patch N" assigns them to consecutive receiver channels —
/// the Dante Controller Device-View workflow.
private struct SourcePickerButton: View {
    let sources: [GridView.GroupDef]
    let onPick: ([GridEntry]) -> Void
    @State private var open = false
    @State private var query = ""
    @State private var selectedIDs: Set<String> = []
    @State private var anchorID: String?

    var body: some View {
        Button {
            query = ""
            selectedIDs = []
            anchorID = nil
            open = true
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .help("Patch sources into this channel — ⇧-click to select a range")
        .popover(isPresented: $open, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Search sources…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(filtered.indices, id: \.self) { index in
                            let group = filtered[index]
                            HStack(spacing: 4) {
                                Image(systemName: group.icon)
                                    .font(.system(size: 9))
                                Text(group.label)
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(Theme.textTertiary)
                            ForEach(group.entries) { entry in
                                sourceRow(entry)
                            }
                        }
                    }
                }
                .frame(width: 240, height: 240)

                if !selectedIDs.isEmpty {
                    HStack {
                        Button("Patch \(selectedIDs.count) channel\(selectedIDs.count == 1 ? "" : "s")") {
                            onPick(orderedSelection)
                            open = false
                        }
                        .keyboardShortcut(.defaultAction)
                        Button("Clear") {
                            selectedIDs = []
                            anchorID = nil
                        }
                    }
                    Text("Lands on consecutive receiver channels, starting at this one.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Click patches one source · \u{21E7}-click selects a range")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
        }
    }

    private func sourceRow(_ entry: GridEntry) -> some View {
        let isSelected = selectedIDs.contains(entry.id)
        return Button {
            handleClick(entry)
        } label: {
            HStack(spacing: 6) {
                Text(entry.label)
                    .font(.system(size: 13))
                    .monospacedDigit()
                if isSelected {
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Theme.accent.opacity(0.16) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func handleClick(_ entry: GridEntry) {
        let flags = NSEvent.modifierFlags
        let flat = flatEntries
        if flags.contains(.shift),
           let anchorID,
           let a = flat.firstIndex(where: { $0.id == anchorID }),
           let b = flat.firstIndex(where: { $0.id == entry.id }) {
            selectedIDs.formUnion(flat[min(a, b)...max(a, b)].map(\.id))
        } else if flags.contains(.command) {
            if selectedIDs.contains(entry.id) {
                selectedIDs.remove(entry.id)
            } else {
                selectedIDs.insert(entry.id)
            }
            anchorID = entry.id
        } else if selectedIDs.isEmpty {
            // Fast path: plain click with no pending selection patches one.
            onPick([entry])
            open = false
        } else {
            selectedIDs = [entry.id]
            anchorID = entry.id
        }
        if anchorID == nil {
            anchorID = entry.id
        }
    }

    /// Selection in channel order (flat list order).
    private var orderedSelection: [GridEntry] {
        flatEntries.filter { selectedIDs.contains($0.id) }
    }

    private var flatEntries: [GridEntry] {
        filtered.flatMap(\.entries)
    }

    private var filtered: [GridView.GroupDef] {
        guard !query.isEmpty else { return sources }
        return sources.compactMap { group in
            let entries = group.entries.filter {
                $0.label.localizedCaseInsensitiveContains(query)
            }
            return entries.isEmpty ? nil : (group.id, group.label, group.icon, entries)
        }
    }
}



/// Tiny leaf view: the ONLY grid element observing the 10 Hz signal flags,
/// so meter ticks re-render four-point dots — never the grid itself.
private struct SignalDot: View {
    @EnvironmentObject private var signals: SignalFlags
    let nodeID: String
    let channel: Int
    let output: Bool

    var body: some View {
        let flags = output ? signals.outputs : signals.inputs
        let hasSignal = nodeID == Hydra.backplaneNodeID
            && channel < flags.count && flags[channel]
        return Circle()
            .fill(hasSignal ? Theme.live : Color.white.opacity(0.10))
            .frame(width: 4, height: 4)
            .shadow(color: hasSignal ? Theme.live.opacity(0.7) : .clear, radius: 2)
    }
}
