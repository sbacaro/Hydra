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
import Observation
import HydraCore

/// Per-connection peaks, 10 Hz. Observe ONLY in small leaf views. @Observable
/// gives per-property tracking, so a view only re-renders when the values it
/// actually reads change — no more app-wide invalidation on every meter tick.
@MainActor
@Observable
final class ConnMeters {
    var peaks: [String: Float] = [:]
}

/// Per-channel signal booleans. Updated only on transitions.
@MainActor
@Observable
final class SignalFlags {
    private(set) var inputs: [Bool] = []
    private(set) var outputs: [Bool] = []
    /// Source-node channels with signal, as "nodeID:channel" keys. Lets a
    /// transmitter's pin light from the source's own audio, with no patch.
    private(set) var sources: Set<String> = []

    func update(inputs newInputs: [Bool], outputs newOutputs: [Bool],
                sources newSources: Set<String>) {
        if newInputs != inputs { inputs = newInputs }
        if newOutputs != outputs { outputs = newOutputs }
        if newSources != sources { sources = newSources }
    }
}

@MainActor
@Observable
final class DaemonClient {

    enum ConnectionState: Equatable {
        case connecting
        case connected
        case disconnected
    }

    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var status: StatusPayload?
    /// Assigned via `setConnections(_:)` so the O(1) index stays in sync without
    /// a `didSet` (which @Observable does not track on stored properties).
    private(set) var connections: [Connection] = []
    private(set) var labels = ChannelLabelsPayload()
    private(set) var scenes: [PatchScene] = []
    private(set) var devices: [PhysicalDeviceInfo] = []
    private(set) var apps: [AppInfo] = []
    private(set) var aes67 = Aes67Payload(devices: [], streams: [])
    private(set) var vst = VSTPayload(available: [])
    private(set) var strips: [StripInfo] = []
    /// Per-strip in/out peak levels (linear). Populated when the daemon sends
    /// strip meter data; zero-initialised until then.
    private(set) var stripMeters: [UUID: StripMeters] = [:]
    /// Event log (latest first) + transient toasts.
    private(set) var events: [HydraEvent] = []
    private(set) var toasts: [HydraEvent] = []
    private(set) var config = ConfigPayload()
    /// User-created virtual interfaces (named slices of the soundcard pool).
    /// LEGACY — being replaced by `bridges` (fixed multi-device set).
    private(set) var interfaces: [VirtualInterfaceInfo] = []
    /// Fixed Hydra Audio Bridges (the new multi-device set). Seeded from the
    /// catalog so the UI has rows before the daemon's first `.bridges` push.
    private(set) var bridges: [BridgeInfo] = Hydra.bridgeCatalog.map {
        BridgeInfo(id: $0.id, name: $0.name, channels: $0.channels,
                   enabled: false, present: false)
    }
    /// NDI runtime state + discovered network sources.
    private(set) var ndi = NdiPayload()
    private(set) var modules = ModulesPayload()
    /// Active disk recordings (keyed by interface).
    private(set) var recordings: [RecordingInfo] = []

    /// High-frequency side channels (see header comment).
    let meters = ConnMeters()
    let signals = SignalFlags()

    /// Fast lookup index for connections.
    private(set) var connectionIndex = ConnectionIndex(connections: [])

    private var task: URLSessionWebSocketTask?
    private var reconnectScheduled = false
    /// Consecutive failed reconnects, for exponential backoff (reset on connect).
    private var reconnectAttempts = 0

    /// -50 dBFS: "there is signal here".
    static let signalThreshold: Float = 0.0032

    func start() {
        connect()
    }

    // MARK: - Grid actions (node-aware: backplane or physical devices)

    func connectionAt(source: PatchPoint, destination: PatchPoint) -> Connection? {
        connectionIndex.byID[Connection(source: source, destination: destination).id]
    }

    /// Backplane convenience (identity patch, menu bar).
    func connectionAt(source: Int, destination: Int) -> Connection? {
        connectionAt(source: PatchPoint(nodeID: Hydra.backplaneNodeID, channelIndex: source),
                     destination: PatchPoint(nodeID: Hydra.backplaneNodeID, channelIndex: destination))
    }

    private func rebuildIndex() {
        connectionIndex = ConnectionIndex(connections: connections)
    }

    /// The single mutation point for `connections`, keeping the O(1)
    /// `connectionIndex` in sync. Replaces the former `didSet` (which the
    /// @Observable macro does not track on stored properties).
    private func setConnections(_ new: [Connection]) {
        connections = new
        rebuildIndex()
    }

    /// Create or update (unity gain by default). Optimistic local update;
    /// the daemon's matrix broadcast is the source of truth.
    func setConnection(source: PatchPoint, destination: PatchPoint, gain: Float = 1.0) {
        let conn = Connection(source: source, destination: destination, gain: gain)
        var local = PatchMatrix(connections: connections)
        local.upsert(conn)
        setConnections(local.connections)
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
        setConnections(local.connections)
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
        ChannelPairing.pairs(source: source.channels, destination: destination.channels)
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

    /// Turn a fixed bridge on/off (acquires/releases its CoreAudio device box).
    func setBridgeEnabled(_ id: String, enabled: Bool) {
        // Optimistic local update; the daemon's .bridges broadcast is the truth.
        if let i = bridges.firstIndex(where: { $0.id == id }) {
            bridges[i].enabled = enabled
        }
        send(.setBridgeEnabled(SetBridgeEnabledPayload(id: id, enabled: enabled)))
    }

    /// Set which direction(s) of a bridge show in the grid (in/out/both).
    func setBridgeRole(_ id: String, role: BridgeRole) {
        if let i = bridges.firstIndex(where: { $0.id == id }) {
            bridges[i].role = role
        }
        send(.setBridgeRole(SetBridgeRolePayload(id: id, role: role)))
    }

    /// Enable/disable NDI or AES67 transmit of a bridge's output.
    func setBridgeNetworkTX(_ id: String, ndiTX: Bool, aes67TX: Bool) {
        if let i = bridges.firstIndex(where: { $0.id == id }) {
            bridges[i].ndiTX = ndiTX
            bridges[i].aes67TX = aes67TX
        }
        send(.setBridgeNetworkTX(SetBridgeNetworkTXPayload(id: id, ndiTX: ndiTX, aes67TX: aes67TX)))
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
        // Tear down any prior task before replacing it, so a stale callback
        // from the old socket can't cancel the new one (it's matched by
        // identity in handleDisconnect).
        task?.cancel()
        connectionState = .connecting
        let task = URLSession.shared.webSocketTask(with: Hydra.daemonURL)
        self.task = task
        task.resume()
        receiveLoop(task)
        send(.getStatus)
        send(.getBridges)
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.task === task else { return }
                switch result {
                case .failure:
                    self.handleDisconnect(task)
                case .success(let message):
                    self.connectionState = .connected
                    self.reconnectAttempts = 0
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
            setConnections(payload.connections)
        case .setConnection(let conn):
            // Light gain-only echo from the daemon (no full matrix resend).
            var local = PatchMatrix(connections: connections)
            local.upsert(conn)
            setConnections(local.connections)
        case .levels(let payload):
            meters.peaks = payload.peaks
            signals.update(
                inputs: (payload.sourcePeaks ?? []).map { $0 > Self.signalThreshold },
                outputs: (payload.destinationPeaks ?? []).map { $0 > Self.signalThreshold },
                sources: Set(payload.activeSources ?? []))
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
        case .bridges(let payload):
            bridges = payload.bridges
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
             .getBridges, .setBridgeEnabled, .setBridgeRole, .setBridgeNetworkTX,
             .getNdi, .subscribeNdi,
             .getModules, .subscribeModuleSource,
             .getRecordings, .startRecording, .stopRecording:
            break // client → daemon only
        }
    }

    private func send(_ message: WSMessage) {
        guard let text = try? message.encodedString() else { return }
        guard let task else { return }
        task.send(.string(text)) { [weak self] error in
            if error != nil {
                Task { @MainActor [weak self] in self?.handleDisconnect(task) }
            }
        }
    }

    /// Tear down the connection. `failedTask`, when given, scopes the teardown
    /// to a specific socket: a late failure callback from a task we've already
    /// replaced is ignored, so it can't kill a freshly reconnected socket.
    private func handleDisconnect(_ failedTask: URLSessionWebSocketTask? = nil) {
        if let failedTask, failedTask !== task { return }
        task?.cancel()
        task = nil
        connectionState = .disconnected
        status = nil
        meters.peaks = [:]
        signals.update(inputs: [], outputs: [], sources: [])
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
        // Exponential backoff capped at 30s, so a daemon that stays down does
        // not get hammered with a wakeup every 2s indefinitely.
        let delay = min(30.0, 2.0 * pow(2.0, Double(reconnectAttempts)))
        reconnectAttempts += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.reconnectScheduled = false
            self?.connect()
        }
    }
}
