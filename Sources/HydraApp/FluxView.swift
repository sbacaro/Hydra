// Hydra Audio — GPL-3.0
// Flux — a first-class view mode (alongside Grid and List) for Audio-Hijack-style
// capture flows. Each flow is a SIGNAL-CHAIN CARD: Capture ──▸ Output, edited in
// place (inline device menus + channel chips). Selecting either node selects the
// flow's connection — exactly like clicking a grid cell — so the trailing
// inspector shows the Transmitter + Receiver strips (inserts) and the Connection
// (gain, remove). No bespoke FX buttons or volume: it all reuses the strip UI.

import SwiftUI
import HydraCore

struct FluxView: View {
    @Environment(DaemonClient.self) private var client
    @Binding var selection: GridSelection?

    private var captureDevices: [PhysicalDeviceInfo] { client.devices.filter { $0.outputChannels > 0 } }
    private var outputDevices: [PhysicalDeviceInfo] { client.devices.filter { $0.outputChannels > 0 } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if client.flows.isEmpty {
                    emptyState
                } else {
                    ForEach(client.flows) { flow in
                        FlowChainCard(flow: flow,
                                      captureDevices: captureDevices,
                                      outputDevices: outputDevices,
                                      selection: $selection)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Capture Flows").font(.title2.weight(.semibold))
                Text("Tap a device's output and route it into Hydra — continuously.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: addFlow) {
                Label("New Flow", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(captureDevices.isEmpty)
            .help(captureDevices.isEmpty ? "Enable a device with outputs first" : "Create a capture flow")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 42, weight: .light)).foregroundStyle(.tertiary)
            Text("No Flows Yet").font(.title3.weight(.semibold))
            Text("A flow taps a device's output (like a Pro Tools bus) and sends it to an interface, the speakers, or a bridge.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 400)
            Button(action: addFlow) { Label("New Flow", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .disabled(captureDevices.isEmpty)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(.top, 50)
    }

    private func addFlow() {
        guard let src = captureDevices.first else { return }
        let chans = Array(0..<min(2, src.outputChannels))
        let source = FlowEndpoint(kind: .deviceOutput, id: src.uid, name: src.name, channels: chans)
        let output: FlowEndpoint
        if let dev = outputDevices.first {
            output = FlowEndpoint(kind: .device, id: dev.uid, name: dev.name, channels: chans)
        } else if let bridge = client.bridges.first {
            output = FlowEndpoint(kind: .bridge, id: bridge.id, name: bridge.name, channels: chans)
        } else {
            output = FlowEndpoint(kind: .device, id: "", name: "Choose…", channels: chans)
        }
        client.setFlow(FlowInfo(name: "Flow \(client.flows.count + 1)", source: source, output: output))
    }
}

// MARK: - One flow as a signal-chain card

private struct FlowChainCard: View {
    @Environment(DaemonClient.self) private var client
    let flow: FlowInfo
    let captureDevices: [PhysicalDeviceInfo]
    let outputDevices: [PhysicalDeviceInfo]
    @Binding var selection: GridSelection?

    private var sourceMax: Int {
        captureDevices.first { $0.uid == flow.source.id }?.outputChannels ?? max(flow.source.count, 1)
    }
    private var outputMax: Int {
        if flow.output.kind == .bridge {
            return client.bridges.first { $0.id == flow.output.id }?.channels ?? max(flow.output.count, 1)
        }
        return outputDevices.first { $0.uid == flow.output.id }?.outputChannels ?? max(flow.output.count, 1)
    }
    private var outputStart: Int { flow.output.channels.first ?? 0 }
    private var sourceNodeID: String { Hydra.captureTapNodeID(uid: flow.source.id) }
    private var outputNodeID: String {
        flow.output.kind == .bridge ? Hydra.bridgeNodeID(id: flow.output.id)
                                    : Hydra.deviceNodeID(uid: flow.output.id)
    }
    private var isSelected: Bool {
        selection?.source.nodeID == sourceNodeID && selection?.destination.nodeID == outputNodeID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader
            Divider().padding(.vertical, 12)
            HStack(alignment: .center, spacing: 14) {
                captureNode
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)
                outputNode
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                    lineWidth: isSelected ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { select() }
        .help("Select this flow to edit its inserts and level in the inspector")
    }

    // MARK: Header

    private var cardHeader: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(flow.running ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)
                .help(flow.running ? "Live" : (flow.enabled ? "Waiting" : "Off"))
            TextField("Flow name", text: bindName)
                .textFieldStyle(.plain)
                .font(.headline)
            Spacer()
            Toggle("", isOn: bindEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .help(flow.enabled ? "Running — turn off to stop" : "Stopped — turn on to run")
            Menu {
                Button("Delete Flow", role: .destructive) {
                    if isSelected { selection = nil }
                    client.removeFlow(flow.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 22)
            .menuIndicator(.hidden)
        }
    }

    // MARK: Capture node (transmitter) — tap to select the flow

    private var captureNode: some View {
        nodeBox(tag: "CAPTURE", tint: Theme.live) {
            Menu {
                ForEach(captureDevices, id: \.uid) { d in
                    Button(d.name) { selectSource(d) }
                }
            } label: {
                deviceLabel(flow.source.name, system: "rectangle.connected.to.line.below")
            }
            .menuStyle(.borderlessButton)

            HStack(spacing: 5) {
                Text("Channels").font(.caption2).foregroundStyle(.secondary)
                ForEach(0..<max(sourceMax, 1), id: \.self) { i in
                    let on = flow.source.channels.contains(i)
                    Button("\(i + 1)") { toggleChannel(i) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(on ? .accentColor : nil)
                }
            }
        }
    }

    // MARK: Output node (receiver) — tap to select the flow

    private var outputNode: some View {
        nodeBox(tag: "OUTPUT", tint: Theme.accent) {
            Menu {
                if !outputDevices.isEmpty {
                    Section("Output Devices") {
                        ForEach(outputDevices, id: \.uid) { d in
                            Button(d.name) { selectOutputDevice(d) }
                        }
                    }
                }
                if !client.bridges.isEmpty {
                    Section("Hydra Bridges") {
                        ForEach(client.bridges) { b in
                            Button(b.name) { selectOutputBridge(b) }
                        }
                    }
                }
            } label: {
                deviceLabel(flow.output.name, system: "hifispeaker")
            }
            .menuStyle(.borderlessButton)

            if outputMax > flow.source.count {
                Menu {
                    ForEach(0..<max(1, outputMax - flow.source.count + 1), id: \.self) { s in
                        Button(flow.source.count <= 1 ? "Channel \(s + 1)" : "Channels \(s + 1)–\(s + flow.source.count)") {
                            setOutputStart(s)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Lands on").font(.caption2).foregroundStyle(.secondary)
                        Text(flow.source.count <= 1 ? "ch \(outputStart + 1)" : "ch \(outputStart + 1)–\(outputStart + flow.source.count)")
                            .font(.caption2)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                    }
                }
                .menuStyle(.borderlessButton)
            }
        }
    }

    // MARK: Node container — tappable to select; inner menus/chips stay live

    @ViewBuilder
    private func nodeBox<Content: View>(tag: String, tint: Color,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(tag)
                    .font(.system(size: 10, weight: .bold)).tracking(0.6)
                    .foregroundStyle(tint)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(tint)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3).padding(.vertical, 8)
        }
    }

    private func deviceLabel(_ name: String, system: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: system).font(.callout).foregroundStyle(.secondary)
            Text(name).font(.callout.weight(.semibold)).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    // MARK: Selection → inspector (Transmitter + Receiver + Connection)

    private func select() {
        selection = GridSelection(
            source: GridEntry(nodeID: sourceNodeID, channels: flow.source.channels,
                              label: flow.source.name, shortLabel: flow.source.name),
            destination: GridEntry(nodeID: outputNodeID, channels: flow.output.channels,
                                   label: flow.output.name, shortLabel: flow.output.name))
    }

    // MARK: Mutations (each pushes the whole flow to the daemon)

    private func push(_ mutate: (inout FlowInfo) -> Void) {
        var f = flow; mutate(&f); client.setFlow(f)
    }
    private func outputChannels(start: Int, count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let s = max(0, min(start, max(0, outputMax - count)))
        return Array(s ..< s + count)
    }
    private func selectSource(_ d: PhysicalDeviceInfo) {
        let chans = Array(0..<min(2, d.outputChannels))
        push {
            $0.source = FlowEndpoint(kind: .deviceOutput, id: d.uid, name: d.name, channels: chans)
            $0.output.channels = outputChannels(start: outputStart, count: chans.count)
        }
    }
    private func selectOutputDevice(_ d: PhysicalDeviceInfo) {
        let count = flow.source.count
        let s = max(0, min(outputStart, max(0, d.outputChannels - count)))
        push { $0.output = FlowEndpoint(kind: .device, id: d.uid, name: d.name,
                                        channels: count > 0 ? Array(s ..< s + count) : []) }
    }
    private func selectOutputBridge(_ b: BridgeInfo) {
        let count = flow.source.count
        let s = max(0, min(outputStart, max(0, b.channels - count)))
        push { $0.output = FlowEndpoint(kind: .bridge, id: b.id, name: b.name,
                                        channels: count > 0 ? Array(s ..< s + count) : []) }
    }
    private func toggleChannel(_ i: Int) {
        var set = Set(flow.source.channels)
        if set.contains(i) { set.remove(i) } else { set.insert(i) }
        if set.isEmpty { set.insert(i) }
        push {
            $0.source.channels = set.sorted()
            $0.output.channels = outputChannels(start: outputStart, count: set.count)
        }
    }
    private func setOutputStart(_ s: Int) {
        push { $0.output.channels = outputChannels(start: s, count: flow.source.count) }
    }

    private var bindName: Binding<String> {
        Binding(get: { flow.name }, set: { n in push { $0.name = n } })
    }
    private var bindEnabled: Binding<Bool> {
        Binding(get: { flow.enabled }, set: { e in push { $0.enabled = e } })
    }
}
