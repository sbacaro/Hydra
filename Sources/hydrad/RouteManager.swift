// Hydra Audio — GPL-3.0
// RouteManager — Audio-Hijack-style "flows". A flow is one continuous route:
// capture a SOURCE (a device's input, or an app) and send it to an OUTPUT
// (a Hydra bridge, an output device/interface). Flows are persisted and applied
// by enabling the two endpoints and wiring matrix connections between them —
// reusing the engine's proven routing, so no separate real-time path exists.
//
// v1 endpoints:
//   source: .deviceInput (a CoreAudio device's input channels)
//   output: .bridge, .device  (any output node)
// (.app source and .deviceOutput capture come in a later stage.)

import Foundation
import HydraCore

final class RouteManager: @unchecked Sendable {

    private let store: MatrixStore
    private let devices: DeviceManager
    private let bridges: BridgeManager
    private let queue = DispatchQueue(label: "hydra.flows")
    private var flows: [UUID: FlowInfo] = [:]
    /// Live device-output capture taps, keyed by device UID (Audio-Hijack-style).
    private var captureTaps: [String: DeviceOutputTap] = [:]
    /// Called on the manager queue after any change, with the fresh list.
    var onChange: (([FlowInfo]) -> Void)?

    private static let persistURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hydra", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("flows.json")
    }()

    init(store: MatrixStore, devices: DeviceManager, bridges: BridgeManager) {
        self.store = store
        self.devices = devices
        self.bridges = bridges
        if let data = try? Data(contentsOf: Self.persistURL),
           let loaded = try? JSONDecoder().decode([FlowInfo].self, from: data) {
            flows = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        }
        // Migrate legacy flows: capturing a device's INPUT is always silent on
        // loopback/bridge devices, so switch them to OUTPUT capture (the working
        // Audio-Hijack-style tap path).
        flows = flows.mapValues { flow in
            guard flow.source.kind == .deviceInput else { return flow }
            var migrated = flow
            migrated.source.kind = .deviceOutput
            return migrated
        }
    }

    /// Apply every persisted flow at startup (after the device/bridge managers
    /// have started, so enabling endpoints sticks).
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            for flow in self.flows.values { self.apply(flow) }
            self.syncCaptureOnly()
            self.syncCaptureTaps()
            self.broadcast()
        }
    }

    /// Tell DeviceManager which devices are read as a flow SOURCE, so it opens them
    /// input-only (a pure capture client) — what makes loopback/bridge devices like
    /// "Pro Tools Audio Bridge" actually capture, exactly like Audio Hijack.
    private func syncCaptureOnly() {
        let uids = Set(flows.values
            .filter { $0.enabled && $0.source.kind == .deviceInput }
            .map(\.source.id))
        devices.setCaptureOnly(uids)
    }

    /// Create/destroy the device-output capture taps that flows need (Audio-Hijack
    /// style: tap what apps PLAY TO a device), and register them as source nodes.
    private func syncCaptureTaps() {
        let wanted = Set(flows.values
            .filter { $0.enabled && $0.source.kind == .deviceOutput }
            .map(\.source.id))
        for (uid, tap) in captureTaps where !wanted.contains(uid) {
            tap.stop()
            captureTaps.removeValue(forKey: uid)
        }
        let engineRate = BackplaneProbe.backplaneDeviceID()
            .map(BackplaneProbe.nominalSampleRate) ?? Hydra.defaultSampleRate
        for uid in wanted where captureTaps[uid] == nil {
            let name = flows.values.first { $0.source.id == uid }?.source.name ?? uid
            if let tap = DeviceOutputTap(deviceUID: uid, deviceName: name, engineRate: engineRate),
               tap.start() {
                captureTaps[uid] = tap
            }
        }
        store.setCaptureTaps(captureTaps.values.sorted { $0.deviceUID < $1.deviceUID })
    }

    func payload() -> FlowsPayload {
        queue.sync { FlowsPayload(flows: flowsWithStatus()) }
    }

    /// Create or update a flow (the app sends the whole flow on each edit). Only
    /// re-wires audio when the ROUTE changed — a rename doesn't churn the matrix.
    func setFlow(_ incoming: FlowInfo) {
        queue.sync {
            let old = flows[incoming.id]
            flows[incoming.id] = incoming
            persist()
            if old.map({ routingKey($0) != routingKey(incoming) }) ?? true {
                if let old { unapply(old) }
                apply(incoming)
                syncCaptureOnly()
                syncCaptureTaps()
            }
            broadcast()
        }
    }

    /// Identity of a flow's audio route — changes here (but not a rename) trigger a re-wire.
    private func routingKey(_ f: FlowInfo) -> String {
        func e(_ p: FlowEndpoint) -> String { "\(p.kind.rawValue):\(p.id):\(p.channels.map(String.init).joined(separator: ","))" }
        return "\(f.enabled)|\(e(f.source))|\(e(f.output))"
    }

    func removeFlow(id: UUID) {
        queue.sync {
            guard let flow = flows.removeValue(forKey: id) else { return }
            unapply(flow)
            persist()
            syncCaptureOnly()
            syncCaptureTaps()
            broadcast()
        }
    }

    // MARK: - Internals (manager queue only)

    private func sortedFlows() -> [FlowInfo] {
        flows.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Sorted flows with the live `running` flag computed (used by both the
    /// getFlows reply and the change broadcast, so they never disagree).
    private func flowsWithStatus() -> [FlowInfo] {
        sortedFlows().map { var f = $0; f.running = isRunning($0); return f }
    }

    /// Bring a flow live: enable both endpoints, then wire source → output.
    private func apply(_ flow: FlowInfo) {
        guard flow.enabled else {
            log("Flow \"\(flow.name)\": disabled — removing its routing")
            unapply(flow); return
        }
        enable(flow.source)
        enable(flow.output)
        let sNode = nodeID(flow.source)
        let dNode = nodeID(flow.output)
        let pairs = connections(of: flow)
        let before = store.allConnections()
        var live = 0
        for (src, dst) in pairs {
            // Keep the gain of a connection that already exists (the user sets it in
            // the inspector's Connection section, like any patch) — but HEAL a
            // silent one (gain ~0) back to unity so a flow is never stuck muted.
            // Missing connections are created at unity.
            if let existing = before.first(where: { $0.source == src && $0.destination == dst }) {
                if abs(existing.gain) < 0.0001 {
                    _ = store.upsert(Connection(source: src, destination: dst, gain: 1.0))
                }
                live += 1
            } else if store.upsert(Connection(source: src, destination: dst, gain: 1.0)) {
                live += 1
            }
        }
        log("Flow \"\(flow.name)\": apply — source node=\(sNode ?? "nil") output node=\(dNode ?? "nil"), "
            + "\(live)/\(pairs.count) connection(s) live "
            + "(src ch \(flow.source.channels) → out ch \(flow.output.channels))")
    }

    /// Tear a flow's wiring down (leaves the endpoints enabled — the user manages
    /// devices/bridges independently; we only own the connections we made).
    private func unapply(_ flow: FlowInfo) {
        for (src, dst) in connections(of: flow) {
            _ = store.remove(Connection(source: src, destination: dst, gain: 1.0))
        }
    }

    /// Make sure an endpoint's node exists in the grid (acquire device / bridge).
    private func enable(_ e: FlowEndpoint) {
        switch e.kind {
        case .deviceInput, .device:
            devices.setUse(uid: e.id, used: true)
        case .deviceOutput:
            break   // a capture tap, created by syncCaptureTaps() — not a "used" device
        case .bridge:
            bridges.setEnabled(id: e.id, enabled: true)
        case .app:
            break   // app-source capture lands in a later stage
        }
    }

    /// The matrix connections that realise a flow: source.channels[i] → output.channels[i].
    private func connections(of flow: FlowInfo) -> [(PatchPoint, PatchPoint)] {
        guard let sNode = nodeID(flow.source), let dNode = nodeID(flow.output) else { return [] }
        return zip(flow.source.channels, flow.output.channels).map { s, d in
            (PatchPoint(nodeID: sNode, channelIndex: s),
             PatchPoint(nodeID: dNode, channelIndex: d))
        }
    }

    private func nodeID(_ e: FlowEndpoint) -> String? {
        switch e.kind {
        case .deviceInput, .device: return Hydra.deviceNodeID(uid: e.id)
        case .deviceOutput: return Hydra.captureTapNodeID(uid: e.id)
        case .bridge: return Hydra.bridgeNodeID(id: e.id)
        case .app: return nil   // not wired yet
        }
    }

    /// A flow is "running" when both endpoints are resolvable (v1: not .app).
    private func isRunning(_ flow: FlowInfo) -> Bool {
        flow.enabled && nodeID(flow.source) != nil && nodeID(flow.output) != nil
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(sortedFlows()) {
            try? data.write(to: Self.persistURL, options: .atomic)
        }
    }

    private func broadcast() {
        onChange?(flowsWithStatus())
    }
}
