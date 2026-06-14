// Hydra Audio — GPL-3.0
// WebSocket client for the daemon. The app never touches audio directly;
// it renders state owned by hydrad and reconnects automatically.
//
// Rendering performance: high-frequency data (meters, 10 Hz) lives in small
// dedicated ObservableObjects so the grid is NOT invalidated on every tick.
// - ConnMeters: per-connection peaks (observed only by the Inspector's meter)
// - SignalFlags: per-channel booleans (observed only by the header LEDs,
//   published only when a channel crosses the signal threshold)

import Foundation
import SwiftUI
import HydraCore

/// Per-connection peaks, 10 Hz. Observe ONLY in small leaf views.
@MainActor
final class ConnMeters: ObservableObject {
    @Published var peaks: [String: Float] = [:]
}

/// Per-channel signal booleans. Published only on transitions.
@MainActor
final class SignalFlags: ObservableObject {
    @Published private(set) var inputs: [Bool] = []
    @Published private(set) var outputs: [Bool] = []

    func update(inputs newInputs: [Bool], outputs newOutputs: [Bool]) {
        if newInputs != inputs { inputs = newInputs }
        if newOutputs != outputs { outputs = newOutputs }
    }
}

@MainActor
final class DaemonClient: ObservableObject {

    enum ConnectionState: Equatable {
        case connecting
        case connected
        case disconnected
    }

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var status: StatusPayload?
    @Published private(set) var connections: [Connection] = [] {
        didSet { rebuildIndex() }
    }
    @Published private(set) var labels = ChannelLabelsPayload()
    @Published private(set) var scenes: [PatchScene] = []
    @Published private(set) var devices: [PhysicalDeviceInfo] = []
    @Published private(set) var apps: [AppInfo] = []
    @Published private(set) var aes67 = Aes67Payload(devices: [], streams: [])
    @Published private(set) var vst = VSTPayload(available: [])
    @Published private(set) var strips: [StripInfo] = []
    /// Per-strip in/out peak levels (linear). Populated when the daemon sends
    /// strip meter data; zero-initialised until then.
    @Published private(set) var stripMeters: [UUID: StripMeters] = [:]
    /// Event log (latest first) + transient toasts.
    @Published private(set) var events: [HydraEvent] = []
    @Published private(set) var toasts: [HydraEvent] = []
    @Published private(set) var config = ConfigPayload()
    /// User-created virtual interfaces (named slices of the soundcard pool).
    @Published private(set) var interfaces: [VirtualInterfaceInfo] = []
    /// NDI runtime state + discovered network sources.
    @Published private(set) var ndi = NdiPayload()
    @Published private(set) var modules = ModulesPayload()
    /// Active disk recordings (keyed by interface).
    @Published private(set) var recordings: [RecordingInfo] = []

    /// High-frequency side channels (see header comment).
    let meters = ConnMeters()
    let signals = SignalFlags()

    /// O(1) lookup by connection ID ("node:ch->node:ch").
    private var connectionIndex: [String: Connection] = [:]

    private var task: URLSessionWebSocketTask?
    private var reconnectScheduled = false

    /// -50 dBFS: "there is signal here".
    static let signalThreshold: Float = 0.0032

    func start() {
        connect()
    }

    // MARK: - Grid actions (node-aware: backplane or physical devices)

    func connectionAt(source: PatchPoint, destination: PatchPoint) -> Connection? {
        connectionIndex[Connection(source: source, destination: destination).id]
    }

    /// Backplane convenience (identity patch, menu bar).
    func connectionAt(source: Int, destination: Int) -> Connection? {
        connectionAt(source: PatchPoint(nodeID: Hydra.backplaneNodeID, channelIndex: source),
                     destination: PatchPoint(nodeID: Hydra.backplaneNodeID, channelIndex: destination))
    }

    private func rebuildIndex() {
        var index: [String: Connection] = [:]
        index.reserveCapacity(connections.count)
        for c in connections {
            index[c.id] = c
        }
        connectionIndex = index
    }

    /// Create or update (unity gain by default). Optimistic local update;
    /// the daemon's matrix broadcast is the source of truth.
    func setConnection(source: PatchPoint, destination: PatchPoint, gain: Float = 1.0) {
        let conn = Connection(source: source, destination: destination, gain: gain)
        var local = PatchMatrix(connections: connections)
        local.upsert(conn)
        connections = local.connections
        send(.setConnection(conn))
    }

    /// Backplane convenience.
    func setConnection(source: Int, destination: Int, gain: Float = 1.0) {
        setConnection(source: PatchPoint(nodeID: Hydra.backplaneNodeID, channelIndex: source),
                      destination: PatchPoint(nodeID: Hydra.backplaneNodeID, channelIndex: destination),
                      gain: gain)
    }

    func removeConnection(_ conn: Connection) {
        var local = PatchMatrix(connections: connections)
        local.remove(source: conn.source, destination: conn.destination)
        connections = local.connections
        send(.removeConnection(conn))
    }

    // MARK: - Labels

    func channelLabel(_ scope: ChannelScope, _ index: Int) -> String? {
        labels.label(scope, index)
    }

    func setLabel(_ scope: ChannelScope, _ index: Int, _ label: String?) {
        send(.setLabel(SetLabelPayload(scope: scope, index: index, label: label)))
    }

    // MARK: - Scenes

    func saveScene(named name: String) {
        send(.saveScene(SaveScenePayload(name: name)))
    }

    func applyScene(_ id: UUID) {
        send(.applyScene(SceneRefPayload(id: id)))
    }

    func deleteScene(_ id: UUID) {
        send(.deleteScene(SceneRefPayload(id: id)))
    }

    // MARK: - Devices

    func setDeviceUse(uid: String, used: Bool) {
        send(.setDeviceUse(SetDeviceUsePayload(uid: uid, used: used)))
    }

    // MARK: - App capture

    func setAppCapture(pid: Int32, captured: Bool) {
        send(.setAppCapture(SetAppCapturePayload(pid: pid, captured: captured)))
    }

    // MARK: - AES67

    func subscribeStream(id: String, subscribed: Bool) {
        send(.subscribeStream(SubscribeStreamPayload(id: id, subscribed: subscribed)))
    }

    // MARK: - Channel strips (Logic-style)

    /// The configured strip covering a source channel, if any
    /// (stereo strips own their base channel and the next one).
    func strip(forNode nodeID: String, channel: Int) -> StripInfo? {
        let base = channel & ~1
        if let stereo = strips.first(where: { $0.nodeID == nodeID && $0.channelIndex == base && $0.stereo }) {
            return stereo
        }
        return strips.first(where: { $0.nodeID == nodeID && $0.channelIndex == channel && !$0.stereo })
    }

    /// The strip to display/edit for a source channel — falls back to an
    /// unsaved default. ALL channels are mono (stereo lanes are disabled).
    func effectiveStrip(forNode nodeID: String, channel: Int, stereo: Bool = false) -> StripInfo {
        let base = stereo ? (channel & ~1) : channel
        if let existing = strips.first(where: { $0.nodeID == nodeID && $0.channelIndex == base && $0.stereo == stereo }) {
            return existing
        }
        return StripInfo(nodeID: nodeID, channelIndex: base, stereo: stereo)
    }

    /// Console-style stereo link: true when `evenChannel` and `evenChannel+1`
    /// are paired as one stereo channel (a stereo strip sits on the even base).
    func stereoLinked(nodeID: String, evenChannel: Int) -> Bool {
        strips.contains { $0.nodeID == nodeID && $0.channelIndex == evenChannel && $0.stereo }
    }

    /// Link / unlink a source channel's console pair (odd+even) as stereo.
    func setStereoLink(nodeID: String, channel: Int, linked: Bool) {
        let base = channel & ~1
        var strip = strips.first { $0.nodeID == nodeID && $0.channelIndex == base }
            ?? StripInfo(nodeID: nodeID, channelIndex: base, stereo: linked)
        strip.channelIndex = base
        strip.stereo = linked
        setStrip(strip)
    }

    func setStrip(_ strip: StripInfo) {
        send(.setStrip(strip))
    }

    /// Asks the daemon to (re)scan the VST3 folders. Progress arrives as
    /// successive .vst payloads (scanning / scanProgress / scanLabel).
    func scanVST() {
        send(.scanVST)
    }

    /// Settings → Plugins: show/hide a plugin in the strip's insert picker.
    func setPluginAvailable(id: String, available: Bool) {
        send(.setPluginAvailable(.init(id: id, available: available)))
    }

    /// Settings → Plugins: star/unstar a plugin.
    func setPluginFavorite(id: String, favorite: Bool) {
        send(.setPluginFavorite(.init(id: id, favorite: favorite)))
    }

    // MARK: - Grid lanes (mono/stereo cells operate channel GROUPS)

    /// Console patch rules between two lanes:
    /// stereo→stereo: L→L, R→R · stereo→mono: both summed · mono→stereo: duplicated.
    func channelPairs(source: GridEntry, destination: GridEntry) -> [(Int, Int)] {
        switch (source.channels.count, destination.channels.count) {
        case (2, 2):
            return [(source.channels[0], destination.channels[0]),
                    (source.channels[1], destination.channels[1])]
        case (2, 1):
            return [(source.channels[0], destination.channels[0]),
                    (source.channels[1], destination.channels[0])]
        case (1, 2):
            return [(source.channels[0], destination.channels[0]),
                    (source.channels[0], destination.channels[1])]
        default:
            return [(source.channels[0], destination.channels[0])]
        }
    }

    /// All underlying connections of a cell (any present = cell connected).
    func cellConnections(source: GridEntry, destination: GridEntry) -> [Connection] {
        channelPairs(source: source, destination: destination).compactMap { srcCh, dstCh in
            connectionAt(source: PatchPoint(nodeID: source.nodeID, channelIndex: srcCh),
                         destination: PatchPoint(nodeID: destination.nodeID, channelIndex: dstCh))
        }
    }

    /// Subscribe the full lane mapping (unity gain).
    func connectCell(source: GridEntry, destination: GridEntry) {
        for (srcCh, dstCh) in channelPairs(source: source, destination: destination) {
            setConnection(source: PatchPoint(nodeID: source.nodeID, channelIndex: srcCh),
                          destination: PatchPoint(nodeID: destination.nodeID, channelIndex: dstCh))
        }
    }

    func disconnectCell(source: GridEntry, destination: GridEntry) {
        for connection in cellConnections(source: source, destination: destination) {
            removeConnection(connection)
        }
    }

    /// Set the gain of every underlying connection of the cell.
    func setCellGain(source: GridEntry, destination: GridEntry, gain: Float) {
        for (srcCh, dstCh) in channelPairs(source: source, destination: destination) {
            setConnection(source: PatchPoint(nodeID: source.nodeID, channelIndex: srcCh),
                          destination: PatchPoint(nodeID: destination.nodeID, channelIndex: dstCh),
                          gain: gain)
        }
    }

    func openPluginEditor(stripID: UUID, index: Int) {
        send(.openPluginEditor(OpenEditorPayload(stripID: stripID, index: index)))
    }

    // MARK: - Config

    func setConfig(_ newConfig: ConfigPayload) {
        send(.setConfig(newConfig))
    }

    func createInterface(name: String, inChannels: Int, outChannels: Int,
                         ndiTX: Bool = false, aes67TX: Bool = false, stereo: Bool = false) {
        send(.createInterface(CreateInterfacePayload(name: name, inChannels: inChannels,
                                                     outChannels: outChannels,
                                                     ndiTX: ndiTX, aes67TX: aes67TX, stereo: stereo)))
    }

    func setInterfaceNDI(_ id: UUID, enabled: Bool) {
        send(.setInterfaceNDI(InterfaceNDIPayload(id: id, enabled: enabled)))
    }

    func setInterfaceAES67(_ id: UUID, enabled: Bool) {
        send(.setInterfaceAES67(InterfaceNDIPayload(id: id, enabled: enabled)))
    }

    func subscribeNdi(id: String, subscribed: Bool) {
        send(.subscribeNdi(SubscribeNdiPayload(id: id, subscribed: subscribed)))
    }

    func subscribeModuleSource(id: String, subscribed: Bool) {
        send(.subscribeModuleSource(SubscribeModuleSourcePayload(id: id, subscribed: subscribed)))
    }

    func startRecording(_ interfaceID: UUID) {
        send(.startRecording(InterfaceRefPayload(id: interfaceID)))
    }

    func stopRecording(_ interfaceID: UUID) {
        send(.stopRecording(InterfaceRefPayload(id: interfaceID)))
    }

    func recording(for interfaceID: UUID) -> RecordingInfo? {
        recordings.first { $0.interfaceID == interfaceID }
    }

    /// Mutate-and-send helper so Settings toggles never clobber other fields.
    func updateConfig(_ mutate: (inout ConfigPayload) -> Void) {
        var copy = config
        mutate(&copy)
        setConfig(copy)
    }

    func deleteInterface(_ id: UUID) {
        send(.deleteInterface(InterfaceRefPayload(id: id)))
    }

    /// Pool channels already taken by interfaces (in + out slices).
    /// The In and Out pools are independent 256-channel slices — report
    /// them separately (256 transmitters and 256 receivers, Dante-style).
    var allocatedInChannels: Int {
        interfaces.reduce(0) { $0 + $1.inChannels }
    }
    var allocatedOutChannels: Int {
        interfaces.reduce(0) { $0 + $1.outChannels }
    }

    // MARK: - Transport

    private func connect() {
        connectionState = .connecting
        let task = URLSession.shared.webSocketTask(with: Hydra.daemonURL)
        self.task = task
        task.resume()
        receiveLoop(task)
        send(.getStatus)
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.task === task else { return }
                switch result {
                case .failure:
                    self.handleDisconnect()
                case .success(let message):
                    self.connectionState = .connected
                    if case .string(let text) = message,
                       let decoded = try? WSMessage.decode(from: text) {
                        self.apply(decoded)
                    }
                    self.receiveLoop(task)
                }
            }
        }
    }

    private func apply(_ message: WSMessage) {
        switch message {
        case .status(let payload):
            if payload != status { status = payload }
        case .matrix(let payload):
            connections = payload.connections
        case .setConnection(let conn):
            // Light gain-only echo from the daemon (no full matrix resend).
            var local = PatchMatrix(connections: connections)
            local.upsert(conn)
            connections = local.connections
        case .levels(let payload):
            meters.peaks = payload.peaks
            signals.update(
                inputs: (payload.sourcePeaks ?? []).map { $0 > Self.signalThreshold },
                outputs: (payload.destinationPeaks ?? []).map { $0 > Self.signalThreshold })
        case .labels(let payload):
            labels = payload
        case .scenes(let payload):
            scenes = payload.scenes
        case .devices(let payload):
            devices = payload.devices
        case .apps(let payload):
            apps = payload.apps
        case .aes67(let payload):
            aes67 = payload
        case .vst(let payload):
            vst = payload
        case .strips(let payload):
            strips = payload.strips
        case .config(let payload):
            config = payload
        case .interfaces(let payload):
            interfaces = payload.interfaces
        case .ndi(let payload):
            ndi = payload
        case .modules(let payload):
            modules = payload
        case .recordings(let payload):
            recordings = payload.active
        case .events(let payload):
            events = payload.events.reversed()
        case .event(let event):
            events.insert(event, at: 0)
            if events.count > 50 { events.removeLast(events.count - 50) }
            showToast(event)
        case .getStatus, .getMatrix, .removeConnection, .scanVST,
             .getLabels, .setLabel, .getScenes, .saveScene, .applyScene, .deleteScene,
             .getDevices, .setDeviceUse, .getApps, .setAppCapture,
             .getAes67, .subscribeStream,
             .getVST, .getStrips, .setStrip, .openPluginEditor,
             .setPluginAvailable, .setPluginFavorite, .setConfig,
             .getInterfaces, .createInterface, .deleteInterface, .setInterfaceNDI, .setInterfaceAES67,
             .getNdi, .subscribeNdi,
             .getModules, .subscribeModuleSource,
             .getRecordings, .startRecording, .stopRecording:
            break // client → daemon only
        }
    }

    private func send(_ message: WSMessage) {
        guard let text = try? message.encodedString() else { return }
        task?.send(.string(text)) { [weak self] error in
            if error != nil {
                Task { @MainActor [weak self] in self?.handleDisconnect() }
            }
        }
    }

    private func handleDisconnect() {
        task?.cancel()
        task = nil
        connectionState = .disconnected
        status = nil
        meters.peaks = [:]
        signals.update(inputs: [], outputs: [])
        scheduleReconnect()
    }

    /// Transient toast: shown for a few seconds, then removed (the full
    /// history stays in `events`, behind the bell).
    private func showToast(_ event: HydraEvent) {
        toasts.append(event)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.toasts.removeAll { $0.id == event.id }
        }
    }

    private func scheduleReconnect() {
        guard !reconnectScheduled else { return }
        reconnectScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.reconnectScheduled = false
            self?.connect()
        }
    }
}
