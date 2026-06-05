// Hydra Audio — GPL-3.0
// The side panel as a DAW channel strip (Logic-style), top-to-bottom signal
// flow for the selected source channel:
//   input (name, mono/stereo) → insert slots → trim → output section
//   (the selected connection: gain, meter, remove).
// Insert slots: click an empty slot to search plugins by name; click a loaded
// slot to open the plugin's editor window; ✕ removes it.

import SwiftUI
import AppKit
import HydraCore

struct InspectorView: View {
    @EnvironmentObject private var client: DaemonClient
    @Binding var selection: GridSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Channel")
                .font(.system(size: 14, weight: .semibold))

            if let selection {
                ChannelStrip(selection: selection, clearSelection: { self.selection = nil })
            } else {
                Text("Select a cell in the grid to open its channel strip.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 264)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline, lineWidth: 0.5))
        // Match the grid square's vertical span: its panel sits below the
        // control bar (16 outer + ~26 bar + 10 spacing) and 16 above the
        // status bar.
        .padding(.top, 52)
        .padding(.bottom, 16)
        .padding(.trailing, 16)
    }
}

// MARK: - Channel strip

private struct ChannelStrip: View {
    @EnvironmentObject private var client: DaemonClient
    let selection: GridSelection
    let clearSelection: () -> Void

    @State private var pickerSlotPresented = false

    private var strip: StripInfo {
        client.effectiveStrip(forNode: selection.source.nodeID,
                              channel: selection.source.channel)
    }

    private var isApp: Bool {
        Hydra.appKey(fromNodeID: selection.source.nodeID) != nil
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
        VStack(alignment: .leading, spacing: 14) {
            // ── Input ────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 3) {
                Text(selection.source.label)
                    .font(.system(.title3).weight(.semibold))
                    .lineLimit(1)
                Text(nodeName)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Divider().overlay(Color.white.opacity(0.1))

            // ── Inserts (Audio FX) ──────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text("Audio FX")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                ForEach(Array(strip.inserts.enumerated()), id: \.offset) { index, plugin in
                    HStack(spacing: 6) {
                        Button {
                            client.openPluginEditor(stripID: strip.id, index: index)
                        } label: {
                            Text(plugin.name)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Theme.accent.opacity(0.55))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Open \(plugin.name)'s editor")

                        Button {
                            var updated = strip
                            updated.inserts.remove(at: index)
                            client.setStrip(updated)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove insert")
                    }
                }

                // Empty slot
                Button {
                    pickerSlotPresented = true
                } label: {
                    HStack {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("Insert…")
                            .font(.system(size: 13))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4]))
                    )
                }
                .buttonStyle(.plain)
                .disabled(client.vst.available.isEmpty)
                .help(client.vst.available.isEmpty
                      ? "No VST3 plugins found in /Library/Audio/Plug-Ins/VST3"
                      : "Add a plugin to this channel")
                .popover(isPresented: $pickerSlotPresented) {
                    PluginPicker { plugin in
                        var updated = strip
                        updated.inserts.append(plugin)
                        client.setStrip(updated)
                        pickerSlotPresented = false
                    }
                    .environmentObject(client)
                }
            }

            Divider().overlay(Color.white.opacity(0.1))

            // ── Output (the selected cell, possibly a stereo group) ──
            let cellConns = client.cellConnections(source: selection.source,
                                                   destination: selection.destination)
            if !cellConns.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accent)
                        Text(selection.destination.label)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        LogicVUMeter(meters: client.meters, connectionIDs: cellConns.map(\.id))
                            .frame(height: 118)
                        VStack(alignment: .leading, spacing: 10) {
                            CellGainSlider(connections: cellConns, selection: selection)
                        }
                    }

                    Button(role: .destructive) {
                        client.disconnectCell(source: selection.source,
                                              destination: selection.destination)
                        clearSelection()
                    } label: {
                        Label("Remove connection", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            } else {
                Text("No connection at this cross-point.\nClick the cell again to create one.")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Plugin picker (Logic-style searchable list)

private struct PluginPicker: View {
    @EnvironmentObject private var client: DaemonClient
    let onSelect: (VSTPlugin) -> Void
    @State private var search = ""

    private var filtered: [VSTPlugin] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return client.vst.available }
        return client.vst.available.filter {
            $0.name.lowercased().contains(query) || $0.vendor.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                TextField("Search plugins…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))

            if filtered.isEmpty {
                Text("Nothing matches \"\(search)\".")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered) { plugin in
                            Button {
                                onSelect(plugin)
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(plugin.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .lineLimit(1)
                                    Text(plugin.vendor)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(12)
        .frame(width: 240)
    }
}

// MARK: - Logic Pro-style VU meter
// Vertical segmented LED bars — one per channel (two when the cell is a
// stereo group) — with peak-hold lines and clip latches at the top.
// Sole observer of the 10 Hz ConnMeters object.

private struct LogicVUMeter: View {
    @ObservedObject var meters: ConnMeters
    let connectionIDs: [String]

    @State private var holds: [CGFloat] = [0, 0]
    @State private var clips: [Bool] = [false, false]

    private static let floorDB: Float = -60

    private func fraction(_ peak: Float) -> CGFloat {
        let db = Gain.decibels(fromLinear: peak)
        return CGFloat(min(max((db - Self.floorDB) / (0 - Self.floorDB), 0), 1))
    }

    var body: some View {
        VStack(spacing: 3) {
            // Clip LEDs (click to reset)
            HStack(spacing: 3) {
                ForEach(connectionIDs.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(clips[safe: index] == true ? Theme.clip : Color.white.opacity(0.10))
                        .frame(width: 7, height: 4)
                        .shadow(color: clips[safe: index] == true ? Theme.clip.opacity(0.8) : .clear,
                                radius: 2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { clips = [false, false] }
            .help("Clip indicators — light when a channel exceeds 0 dBFS. Click to reset.")

            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(connectionIDs.indices, id: \.self) { index in
                        bar(level: fraction(meters.peaks[connectionIDs[index]] ?? 0),
                            hold: holds[safe: index] ?? 0,
                            height: geo.size.height)
                    }
                }
            }
            .frame(width: connectionIDs.count > 1 ? 17 : 7)
        }
        .onChange(of: meters.peaks) { _, newPeaks in
            for index in connectionIDs.indices where index < 2 {
                let peak = newPeaks[connectionIDs[index]] ?? 0
                let frac = fraction(peak)
                holds[index] = max(frac, holds[index] - 0.035) // peak hold w/ decay
                if Gain.decibels(fromLinear: peak) > 0 { clips[index] = true }
            }
        }
        .help("Post-gain level (Logic-style VU)")
    }

    /// One segmented LED bar.
    private func bar(level: CGFloat, hold: CGFloat, height: CGFloat) -> some View {
        let segmentHeight: CGFloat = 3
        let segmentGap: CGFloat = 1
        let count = max(1, Int(height / (segmentHeight + segmentGap)))
        return ZStack(alignment: .bottom) {
            VStack(spacing: segmentGap) {
                ForEach((0..<count).reversed(), id: \.self) { segment in
                    let segFrac = CGFloat(segment + 1) / CGFloat(count)
                    let lit = segFrac <= level
                    RoundedRectangle(cornerRadius: 0.8)
                        .fill(lit ? segmentColor(segFrac) : Color.white.opacity(0.06))
                        .frame(width: 7, height: segmentHeight)
                }
            }
            // Peak-hold line
            if hold > 0.01 {
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 7, height: 1.5)
                    .offset(y: -(height * hold - 1))
            }
        }
        .frame(height: height, alignment: .bottom)
    }

    private func segmentColor(_ frac: CGFloat) -> Color {
        if frac > 0.92 { return Theme.warning }      // top: amber (near 0 dBFS)
        if frac > 0.72 { return Theme.meterYellow }  // upper: yellow
        return Theme.live                            // body: green
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Gain slider (cell gain — drives every underlying connection)

private struct CellGainSlider: View {
    @EnvironmentObject private var client: DaemonClient
    let connections: [Connection]
    let selection: GridSelection

    @State private var gainDB: Double = 0
    @State private var loadedID: String = ""

    private var cellID: String {
        "\(selection.source.id)>\(selection.destination.id)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Gain")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("0 dB") { gainDB = 0 }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .help("Reset gain to unity")
                Text(String(format: "%+.1f dB", gainDB))
                    .font(.system(size: 13)).monospacedDigit()
                    .frame(width: 60, alignment: .trailing)
            }
            Slider(value: $gainDB, in: -60...12, step: 0.5)
                // Logic behavior: ⌥-click snaps the fader back to 0 dB.
                .simultaneousGesture(TapGesture().onEnded {
                    if NSEvent.modifierFlags.contains(.option) {
                        gainDB = 0
                    }
                })
                .onChange(of: gainDB) { previous, current in
                    // Logic-style trackpad feedback: subtle tick on every
                    // step while dragging, stronger detent crossing 0 dB.
                    if (previous < 0 && current >= 0) || (previous > 0 && current <= 0) {
                        NSHapticFeedbackManager.defaultPerformer
                            .perform(.alignment, performanceTime: .default)
                    } else if previous != current {
                        NSHapticFeedbackManager.defaultPerformer
                            .perform(.levelChange, performanceTime: .default)
                    }
                    push()
                }
        }
        .onAppear { load() }
        .onChange(of: cellID) { _, _ in load() }
    }

    private func load() {
        guard loadedID != cellID else { return }
        loadedID = cellID
        gainDB = Double(Gain.decibels(fromLinear: connections.first?.gain ?? 1.0))
    }

    private func push() {
        client.setCellGain(source: selection.source,
                           destination: selection.destination,
                           gain: Gain.linear(fromDecibels: Float(gainDB)))
    }
}
