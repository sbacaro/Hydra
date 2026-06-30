// Hydra Audio — GPL-3.0
// Capture Flows — route a device's input into a bridge or output, continuously
// (an Audio-Hijack-style "session", inside Hydra).
//
// HIG layout: a master–detail split. The sidebar is a clean, scannable list of
// flows (each reads as "source → output", with a live dot and an on/off switch).
// The detail is a native grouped Form whose footer spells out, in one sentence,
// exactly what the selected flow does — so there's never any guessing.

import SwiftUI
import HydraCore

struct FlowsView: View {
    @Environment(DaemonClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?

    /// Devices we can CAPTURE: we tap their OUTPUT (the audio apps play to them),
    /// Audio-Hijack-style — so anything with output channels qualifies.
    private var captureDevices: [PhysicalDeviceInfo] {
        client.devices.filter { $0.outputChannels > 0 }
    }
    private var outputDevices: [PhysicalDeviceInfo] {
        client.devices.filter { $0.outputChannels > 0 }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 500)
    }

    // MARK: Sidebar — the list of flows

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(client.flows) { flow in
                FlowRow(flow: flow).tag(flow.id)
            }
        }
        .overlay {
            if client.flows.isEmpty { emptySidebar }
        }
        .navigationTitle("Capture Flows")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem {
                Button(action: addFlow) {
                    Label("New Flow", systemImage: "plus")
                }
                .disabled(captureDevices.isEmpty)
                .help(captureDevices.isEmpty
                      ? "Enable a device with inputs first (Devices)"
                      : "New capture flow")
            }
        }
    }

    private var emptySidebar: some View {
        VStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No Flows")
                .font(.headline)
            Text("A flow captures a device's audio and sends it somewhere — continuously.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("New Flow", action: addFlow)
                .buttonStyle(.borderedProminent)
                .disabled(captureDevices.isEmpty)
                .padding(.top, 2)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Detail — the editor for the selected flow

    @ViewBuilder private var detail: some View {
        if let id = selection, let flow = client.flows.first(where: { $0.id == id }) {
            FlowDetail(flow: flow, captureDevices: captureDevices, outputDevices: outputDevices)
                .id(flow.id)
        } else {
            ContentUnavailableView {
                Label("No Flow Selected", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text("Select a flow to edit it, or add one with the + button.")
            }
        }
    }

    private func addFlow() {
        guard let src = captureDevices.first else { return }
        let chans = Array(0..<min(2, src.outputChannels))
        let source = FlowEndpoint(kind: .deviceOutput, id: src.uid, name: src.name, channels: chans)
        let output: FlowEndpoint
        if let bridge = client.bridges.first(where: { $0.present }) ?? client.bridges.first {
            output = FlowEndpoint(kind: .bridge, id: bridge.id, name: bridge.name, channels: chans)
        } else if let dev = outputDevices.first {
            output = FlowEndpoint(kind: .device, id: dev.uid, name: dev.name, channels: chans)
        } else {
            output = FlowEndpoint(kind: .bridge, id: "", name: "Choose…", channels: chans)
        }
        let flow = FlowInfo(name: "Flow \(client.flows.count + 1)", source: source, output: output)
        client.setFlow(flow)
        selection = flow.id
    }
}

// MARK: - Sidebar row

private struct FlowRow: View {
    let flow: FlowInfo

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(flow.running ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
                .help(flow.running ? "Live" : (flow.enabled ? "Waiting" : "Off"))
            VStack(alignment: .leading, spacing: 2) {
                Text(flow.name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(flow.source.name).lineLimit(1)
                    Image(systemName: "arrow.right").font(.system(size: 8, weight: .semibold))
                    Text(flow.output.name).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail editor (native grouped Form)

private struct FlowDetail: View {
    @Environment(DaemonClient.self) private var client
    let flow: FlowInfo
    let captureDevices: [PhysicalDeviceInfo]
    let outputDevices: [PhysicalDeviceInfo]

    /// Channels the chosen source device offers.
    private var sourceMax: Int {
        captureDevices.first { $0.uid == flow.source.id }?.outputChannels ?? max(flow.source.count, 1)
    }
    /// Channels the chosen output node offers.
    private var outputMax: Int {
        if flow.output.kind == .bridge {
            return client.bridges.first { $0.id == flow.output.id }?.channels ?? max(flow.output.count, 1)
        }
        return outputDevices.first { $0.uid == flow.output.id }?.outputChannels ?? max(flow.output.count, 1)
    }
    private var outputStart: Int { flow.output.channels.first ?? 0 }

    var body: some View {
        Form {
            // Name + status + the plain-language summary of what this flow does.
            Section {
                TextField("Name", text: bindName)
                Toggle(isOn: bindEnabled) {
                    HStack(spacing: 6) {
                        Text("Run")
                        if flow.running {
                            Label("Live", systemImage: "dot.radiowaves.left.and.right")
                                .labelStyle(.titleAndIcon)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                    }
                }
            } footer: {
                Text(summary)
            }

            Section("Source") {
                Picker("Capture from", selection: bindSource) {
                    ForEach(captureDevices, id: \.uid) { dev in
                        Text(dev.name).tag(dev.uid)
                    }
                }
            }

            // Pick channels by ticking them — no "from/to" arithmetic.
            Section {
                ForEach(0..<sourceMax, id: \.self) { i in
                    Toggle("Channel \(i + 1)", isOn: channelToggle(i))
                }
            } header: {
                Text("Channels to capture")
            } footer: {
                Text("Tick the channels you want from “\(flow.source.name)”.")
            }

            Section("Output") {
                Picker("Send to", selection: bindOutput) {
                    if !client.bridges.isEmpty {
                        Section("Hydra Bridges") {
                            ForEach(client.bridges) { Text($0.name).tag("b:\($0.id)") }
                        }
                    }
                    if !outputDevices.isEmpty {
                        Section("Output Devices") {
                            ForEach(outputDevices, id: \.uid) { Text($0.name).tag("d:\($0.uid)") }
                        }
                    }
                }
                Picker("Land on channel", selection: bindOutputStart) {
                    ForEach(0..<max(1, outputMax - flow.source.count + 1), id: \.self) { s in
                        Text(flow.source.count <= 1
                             ? "Channel \(s + 1)"
                             : "Channels \(s + 1)–\(s + flow.source.count)")
                            .tag(s)
                    }
                }
                .disabled(flow.source.count == 0)
            }

            Section {
                Button("Delete Flow", role: .destructive) { client.removeFlow(flow.id) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(flow.name)
        .navigationSubtitle(flow.running ? "Live" : (flow.enabled ? "Waiting for devices" : "Off"))
    }

    // MARK: Plain-language summary

    private var summary: String {
        guard !flow.source.channels.isEmpty else {
            return "Pick at least one channel to capture from “\(flow.source.name)”."
        }
        let src = flow.source.channels.map { String($0 + 1) }.joined(separator: ", ")
        let out = flow.output.channels.map { String($0 + 1) }.joined(separator: ", ")
        let word = flow.source.count == 1 ? "channel" : "channels"
        return "Continuously captures \(word) \(src) from “\(flow.source.name)” and sends them to “\(flow.output.name)” \(word) \(out)."
    }

    /// Output channels for `count` channels starting at `start`, clamped to the node.
    private func outputChannels(start: Int, count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let s = max(0, min(start, max(0, outputMax - count)))
        return Array(s ..< s + count)
    }

    // MARK: Bindings (each edit pushes the whole flow to the daemon)

    private var bindName: Binding<String> {
        Binding(get: { flow.name }, set: { var f = flow; f.name = $0; client.setFlow(f) })
    }
    private var bindEnabled: Binding<Bool> {
        Binding(get: { flow.enabled }, set: { var f = flow; f.enabled = $0; client.setFlow(f) })
    }
    private var bindSource: Binding<String> {
        Binding(get: { flow.source.id }, set: { uid in
            guard let dev = captureDevices.first(where: { $0.uid == uid }) else { return }
            var f = flow
            let chans = Array(0..<min(2, dev.outputChannels))
            f.source = FlowEndpoint(kind: .deviceOutput, id: dev.uid, name: dev.name, channels: chans)
            f.output.channels = outputChannels(start: outputStart, count: chans.count)
            client.setFlow(f)
        })
    }
    private var bindOutput: Binding<String> {
        Binding(get: { (flow.output.kind == .bridge ? "b:" : "d:") + flow.output.id }, set: { key in
            var f = flow
            let count = f.source.count
            if key.hasPrefix("b:"), let b = client.bridges.first(where: { $0.id == String(key.dropFirst(2)) }) {
                let s = max(0, min(outputStart, max(0, b.channels - count)))
                f.output = FlowEndpoint(kind: .bridge, id: b.id, name: b.name,
                                        channels: count > 0 ? Array(s ..< s + count) : [])
            } else if key.hasPrefix("d:"), let d = outputDevices.first(where: { $0.uid == String(key.dropFirst(2)) }) {
                let s = max(0, min(outputStart, max(0, d.outputChannels - count)))
                f.output = FlowEndpoint(kind: .device, id: d.uid, name: d.name,
                                        channels: count > 0 ? Array(s ..< s + count) : [])
            }
            client.setFlow(f)
        })
    }
    /// One source-channel checkbox. Keeps at least one ticked, and re-lays the
    /// output channels to match the new count.
    private func channelToggle(_ i: Int) -> Binding<Bool> {
        Binding(
            get: { flow.source.channels.contains(i) },
            set: { on in
                var set = Set(flow.source.channels)
                if on { set.insert(i) } else { set.remove(i) }
                if set.isEmpty { set.insert(i) }
                var f = flow
                f.source.channels = set.sorted()
                f.output.channels = outputChannels(start: outputStart, count: f.source.channels.count)
                client.setFlow(f)
            })
    }
    private var bindOutputStart: Binding<Int> {
        Binding(
            get: { outputStart },
            set: { start in
                var f = flow
                f.output.channels = outputChannels(start: start, count: f.source.count)
                client.setFlow(f)
            })
    }
}
