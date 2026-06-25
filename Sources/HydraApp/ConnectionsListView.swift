// Hydra Audio — GPL-3.0
// Connections list — the calm, Apple-style default for the common case: just the
// routes that exist (source → destination), grouped by source, with remove and
// add. The full matrix stays as the "power" view for building many at once.
//
// Master/detail: tapping a route sets the grid selection, so the inspector shows
// that cross-point's channel strip (gain, inserts) — no gain control duplicated
// here.

import SwiftUI
import HydraCore

struct ConnectionsListView: View {
    @Environment(DaemonClient.self) private var client
    let sources: [GridView.GroupDef]
    let destinations: [GridView.GroupDef]
    @Binding var selection: GridSelection?

    @State private var showAdd = false

    /// "nodeID:channel" → the lane (GridEntry) it belongs to, for friendly labels.
    private let srcEntryByPoint: [String: GridEntry]
    private let dstEntryByPoint: [String: GridEntry]

    init(sources: [GridView.GroupDef], destinations: [GridView.GroupDef],
         selection: Binding<GridSelection?>) {
        self.sources = sources
        self.destinations = destinations
        self._selection = selection
        self.srcEntryByPoint = Self.pointMap(sources)
        self.dstEntryByPoint = Self.pointMap(destinations)
    }

    private static func pointMap(_ groups: [GridView.GroupDef]) -> [String: GridEntry] {
        Dictionary(groups.flatMap(\.entries).flatMap { entry in
            entry.channels.map { ("\(entry.nodeID):\($0)", entry) }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// One row = a source lane patched to a destination lane (the underlying
    /// per-channel connections collapsed into a single, readable route).
    private struct Route: Identifiable {
        let source: GridEntry
        let destination: GridEntry
        let connections: [Connection]
        var id: String { "\(source.id)>\(destination.id)" }
    }

    private var routes: [Route] {
        var groups: [String: (src: GridEntry, dst: GridEntry, conns: [Connection])] = [:]
        for c in client.connections {
            guard let src = srcEntryByPoint["\(c.source.nodeID):\(c.source.channelIndex)"],
                  let dst = dstEntryByPoint["\(c.destination.nodeID):\(c.destination.channelIndex)"]
            else { continue }
            let key = "\(src.id)>\(dst.id)"
            groups[key, default: (src, dst, [])].conns.append(c)
        }
        return groups.values
            .map { Route(source: $0.src, destination: $0.dst, connections: $0.conns) }
            .sorted { ($0.source.label, $0.destination.label) < ($1.source.label, $1.destination.label) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(routes.isEmpty ? "No connections"
                     : "\(routes.count) connection\(routes.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { showAdd = true } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .sheet(isPresented: $showAdd) {
                    AddConnectionSheet(sources: sources, destinations: destinations)
                        .environment(client)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if routes.isEmpty {
                ContentUnavailableView {
                    Label("No connections yet", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                } description: {
                    Text("Tap Add to route a source to a destination, or switch to the grid.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(routes) { route in
                        routeRow(route)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.Grid.panel))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.Grid.hairline, lineWidth: 0.5))
    }

    private func routeRow(_ route: Route) -> some View {
        let isSel = selection.map { $0.source == route.source && $0.destination == route.destination } ?? false
        let gainDB = route.connections.first.map { 20 * log10(max($0.gain, 0.0001)) } ?? 0

        return Button {
            // Select the cross-point → inspector shows its channel strip (gain).
            selection = GridSelection(source: route.source, destination: route.destination)
        } label: {
            HStack(spacing: 10) {
                Text(route.source.label)
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(route.destination.label)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if abs(gainDB) > 0.1 {
                    Text("\(gainDB > 0 ? "+" : "")\(gainDB, specifier: "%.0f") dB")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    for c in route.connections { client.removeConnection(c) }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this connection")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSel ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}

// MARK: - Add connection sheet

private struct AddConnectionSheet: View {
    @Environment(DaemonClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    let sources: [GridView.GroupDef]
    let destinations: [GridView.GroupDef]

    @State private var sourceID: String = ""
    @State private var destID: String = ""

    private var sourceEntries: [GridEntry] { sources.flatMap(\.entries) }
    private var destEntries: [GridEntry] { destinations.flatMap(\.entries) }

    var body: some View {
        VStack(spacing: 16) {
            Text("New connection")
                .font(.headline)

            Picker("Source", selection: $sourceID) {
                Text("Choose…").tag("")
                ForEach(sourceEntries) { e in Text(e.label).tag(e.id) }
            }
            Picker("Destination", selection: $destID) {
                Text("Choose…").tag("")
                ForEach(destEntries) { e in Text(e.label).tag(e.id) }
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Connect") {
                    if let s = sourceEntries.first(where: { $0.id == sourceID }),
                       let d = destEntries.first(where: { $0.id == destID }) {
                        client.connectCell(source: s, destination: d)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sourceID.isEmpty || destID.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
