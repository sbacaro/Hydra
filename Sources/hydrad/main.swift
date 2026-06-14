// Hydra Audio — GPL-3.0
// hydrad — the Hydra daemon. Phase 2 scope: real patch matrix applied to
// audio via an IOProc on the backplane, with per-connection gain and meters,
// controlled over the local WebSocket.

import Foundation
import AppKit
import HydraCore

// VST scan worker mode: `hydrad --scan-bundle <bundle> --out <file>` loads ONE
// plugin bundle in this throwaway process, writes its classes as JSON to <file>,
// and exits — BEFORE any daemon setup. This isolates plugin scan hangs/crashes
// (and the objc class collisions some vendor plugins cause when loaded together)
// from the real daemon: the parent kills a hung worker on timeout and treats a
// crashed worker's non-zero exit as "offline".
if let bi = CommandLine.arguments.firstIndex(of: "--scan-bundle"), bi + 1 < CommandLine.arguments.count,
   let oi = CommandLine.arguments.firstIndex(of: "--out"), oi + 1 < CommandLine.arguments.count {
    StripManager.scanBundleWorkerJSON(bundlePath: CommandLine.arguments[bi + 1],
                                      outPath: CommandLine.arguments[oi + 1])
    exit(0)
}

log("Hydra daemon \(Hydra.versionString) starting")

let store = MatrixStore()
store.loadFromDisk()
let labels = LabelStore()
let sceneStore = SceneStore()
let engine = AudioEngine(store: store)
let deviceManager = DeviceManager(store: store)
let tapManager = ProcessTapManager(store: store)
let aes67Manager = Aes67Manager(store: store)
let stripManager = StripManager(store: store)
let ndiManager = NdiManager(store: store)
let moduleManager = ModuleManager(store: store)
let recordingManager = RecordingManager(store: store)
let aes67TxManager = Aes67TxManager(store: store)
let oscServer = OscServer()
let configStore = ConfigStore()
let interfaceStore = InterfaceStore()
// 512-wire split migration: when out slices moved into the receiver pool,
// rebase every persisted patch/scene destination that pointed at them.
if !interfaceStore.migratedOutRanges.isEmpty {
    let ranges = interfaceStore.migratedOutRanges
    func rebase(_ connections: [Connection]) -> [Connection] {
        connections.map { conn in
            guard conn.destination.nodeID == Hydra.backplaneNodeID,
                  ranges.contains(where: { $0.contains(conn.destination.channelIndex) })
            else { return conn }
            let moved = PatchPoint(nodeID: conn.destination.nodeID,
                                   channelIndex: conn.destination.channelIndex + Hydra.poolChannels)
            return Connection(source: conn.source, destination: moved, gain: conn.gain)
        }
    }
    let rebased = rebase(store.allConnections())
    if rebased != store.allConnections() {
        _ = store.replaceAll(rebased)
        log("Patches rebased to the 512-wire layout (\(rebased.count) connections)")
    }
    sceneStore.rebaseDestinations(in: ranges, by: Hydra.poolChannels)
}
store.feedbackProtectionEnabled = configStore.current().feedbackProtection
tapManager.setMakeup(dB: configStore.current().appTapMakeupDB)
oscServer.apply(enabled: configStore.current().oscEnabled,
                port: configStore.current().oscPort)

let initial = BackplaneProbe.currentStatus()
if initial.backplaneInstalled {
    log("Backplane found: \"\(initial.backplaneDeviceName ?? "?")\" — \(initial.inputChannels) in / \(initial.outputChannels) out @ \(Int(initial.sampleRate)) Hz")
    engine.startIfPossible()
} else {
    log("Backplane NOT found. Build dist/ on the host and run Scripts/vm_install.sh")
}

func aes67FullPayload() -> Aes67Payload {
    var payload = aes67Manager.payload()
    payload.txFlows = aes67TxManager.flows()
    let ptp = PtpClock.shared.status()
    payload.ptpLocked = ptp.locked
    payload.ptpGrandmaster = ptp.grandmaster
    payload.ptpDomain = Int(ptp.domain)
    return payload
}

func currentStatus() -> StatusPayload {
    var status = BackplaneProbe.currentStatus(engineRunning: engine.isRunning)
    // Rounded so identical-idle payloads stay identical (broadcast skip).
    status.cpuLoad = (engine.cpuLoad * 100).rounded() / 100
    status.xruns = engine.xruns
    return status
}

var server: WebSocketServer!
do {
    server = try WebSocketServer(
        port: Hydra.daemonPort,
        onConnect: { connection in
            // Push full state so the app renders without asking.
            server.send(.status(currentStatus()), to: connection)
            server.send(.matrix(MatrixPayload(connections: store.allConnections())), to: connection)
            server.send(.labels(labels.all()), to: connection)
            server.send(.scenes(ScenesPayload(scenes: sceneStore.all())), to: connection)
            server.send(.devices(DevicesPayload(devices: deviceManager.infos())), to: connection)
            server.send(.apps(AppsPayload(apps: tapManager.infos())), to: connection)
            server.send(.aes67(aes67FullPayload()), to: connection)
            server.send(.vst(stripManager.vstPayload()), to: connection)
            server.send(.strips(stripManager.stripsPayload()), to: connection)
            server.send(.events(EventsPayload(events: EventCenter.shared.recent())), to: connection)
            server.send(.config(configStore.current()), to: connection)
            server.send(.interfaces(InterfacesPayload(interfaces: interfaceStore.all())), to: connection)
            server.send(.ndi(ndiManager.payload()), to: connection)
            server.send(.modules(moduleManager.payload()), to: connection)
            server.send(.recordings(recordingManager.payload()), to: connection)
        },
        onMessage: { message, connection in
            handleWSMessage(message, from: connection)
        })
} catch {
    log("Could not create server on port \(Hydra.daemonPort): \(error)")
    exit(1)
}

server.start()

// Events: push every new event live to all clients.
EventCenter.shared.onEvent = { event in
    server.broadcast(.event(event))
}

// Physical devices: hot-plug monitoring + initial attach of used devices.
deviceManager.onChange = { infos in
    server.broadcast(.devices(DevicesPayload(devices: infos)))
}
deviceManager.startMonitoring()

// App capture: process-list monitoring + re-attach of captured apps.
tapManager.onChange = { infos in
    server.broadcast(.apps(AppsPayload(apps: infos)))
}
tapManager.startMonitoring()

// AES67: mDNS presence + SAP/SDP stream discovery + RX subscriptions.
aes67Manager.onChange = { payload in
    var full = payload
    full.txFlows = aes67TxManager.flows()
    server.broadcast(.aes67(full))
}
aes67TxManager.onChange = {
    server.broadcast(.aes67(aes67FullPayload()))
}
aes67Manager.start()

// NDI: runtime detection, source discovery, RX subscriptions + interface TX.
ndiManager.onChange = { payload in
    server.broadcast(.ndi(payload))
}
ndiManager.start()
ndiManager.syncTx(interfaces: interfaceStore.all())

// Modules: generic plugin host (loads external .dylibs if present; none ship
// with Hydra). Their network sources appear in the grid like NDI sources.
moduleManager.onChange = { payload in
    server.broadcast(.modules(payload))
}
moduleManager.start()

// Recordings: state pushes for the app's record buttons.
recordingManager.onChange = { payload in
    server.broadcast(.recordings(payload))
}

// OSC remote control: scenes + recordings, addressable by name.
oscServer.onMessage = { message in
    switch message.address {
    case "/hydra/scene/apply":
        let scene: PatchScene?
        if let name = message.firstString {
            scene = sceneStore.all().first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        } else if let index = message.firstInt {
            let all = sceneStore.all()
            scene = all.indices.contains(index) ? all[index] : nil
        } else {
            scene = nil
        }
        if let scene, store.replaceAll(scene.connections) {
            server.broadcast(.matrix(MatrixPayload(connections: store.allConnections())))
            log("OSC: scene applied — \"\(scene.name)\"")
        }
    case "/hydra/scene/save":
        if let name = message.firstString, !name.isEmpty {
            sceneStore.save(name: name, connections: store.allConnections())
            server.broadcast(.scenes(ScenesPayload(scenes: sceneStore.all())))
            log("OSC: scene saved — \"\(name)\"")
        }
    case "/hydra/record/start":
        if let name = message.firstString,
           let interface = interfaceStore.all().first(where: {
               $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            recordingManager.start(interface: interface, config: configStore.current())
        }
    case "/hydra/record/stop":
        if let name = message.firstString,
           let interface = interfaceStore.all().first(where: {
               $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            recordingManager.stop(interfaceID: interface.id)
        }
    default:
        log("OSC: unhandled address \(message.address)")
    }
}

// VST3: plugin scan + channel-strip instantiation.
stripManager.onChange = { vstPayload, stripsPayload in
    server.broadcast(.vst(vstPayload))
    server.broadcast(.strips(stripsPayload))
}
stripManager.start()

// PTP slave (Phase 5): disciplines AES67 TX timestamps to the network clock.
PtpClock.shared.onChange = { status in
    aes67TxManager.ptpChanged(locked: status.locked)
    server.broadcast(.aes67(aes67FullPayload()))
}
PtpClock.shared.start()

// Re-probe every 3 s: track backplane presence, manage engine lifecycle,
// broadcast status changes (e.g. backplane installed while app is open).
var lastStatus = initial
let probeTimer = DispatchSource.makeTimerSource(queue: .global())
probeTimer.schedule(deadline: .now() + 3, repeating: 3)
probeTimer.setEventHandler {
    let present = BackplaneProbe.backplaneDeviceID() != nil
    if present && !engine.isRunning {
        engine.startIfPossible()
    } else if !present && engine.isRunning {
        engine.stop()
    }
    let status = currentStatus()
    if status != lastStatus {
        // Log only real state transitions (metrics tick along silently).
        if status.backplaneInstalled != lastStatus.backplaneInstalled
            || status.engineRunning != lastStatus.engineRunning {
            log("State changed — broadcasting (backplane: \(status.backplaneInstalled ? "present" : "absent"), engine: \(status.engineRunning ? "running" : "stopped"))")
        }
        lastStatus = status
        server.broadcast(.status(status))
    }
}
probeTimer.resume()

// Signal presence: poll post-gain peaks while clients are connected and turn
// them into a BINARY on/off (1 = has signal, 0 = silent), with a short release
// hold so a steady source doesn't flicker. The payload then changes only when
// something starts or stops — the dedup below collapses what used to be a 10 Hz
// stream into a couple of messages per audio event, killing the app-side
// re-layout storm. The channel-strip VU is rendered as a local estimated
// animation in the app; it only needs the on/off state, not real levels.
let meterTimer = DispatchSource.makeTimerSource(queue: .global())
meterTimer.schedule(deadline: .now() + Hydra.meterInterval, repeating: Hydra.meterInterval)
var lastLevels: LevelsPayload?
let signalFloor = Hydra.signalFloorLinear
let release     = Hydra.signalReleaseSeconds
var lastOn:    [String: Date] = [:]   // connection ID → last over-threshold time
var lastSrcOn: [Int: Date]    = [:]   // source channel index → last over-threshold
var lastDstOn: [Int: Date]    = [:]   // destination channel index → last over-threshold
meterTimer.setEventHandler {
    let active = engine.isRunning && server.hasClients
    store.channelMeteringEnabled = active
    guard active else { return }
    let now = Date()
    let rawPeaks = store.levels()
    let (inputs, outputs) = store.channelPeaks()

    // Connections → on/off (with release hold).
    var onPeaks: [String: Float] = [:]
    onPeaks.reserveCapacity(rawPeaks.count)
    for (id, v) in rawPeaks {
        if v > signalFloor { lastOn[id] = now }
        let on = lastOn[id].map { now.timeIntervalSince($0) < release } ?? false
        onPeaks[id] = on ? 1 : 0
    }
    lastOn = lastOn.filter { rawPeaks[$0.key] != nil }   // forget removed connections

    // Per-channel source/destination → on/off (drives the grid pins).
    var srcOn = [Float](repeating: 0, count: inputs.count)
    for i in inputs.indices {
        if inputs[i] > signalFloor { lastSrcOn[i] = now }
        srcOn[i] = (lastSrcOn[i].map { now.timeIntervalSince($0) < release } ?? false) ? 1 : 0
    }
    var dstOn = [Float](repeating: 0, count: outputs.count)
    for i in outputs.indices {
        if outputs[i] > signalFloor { lastDstOn[i] = now }
        dstOn[i] = (lastDstOn[i].map { now.timeIntervalSince($0) < release } ?? false) ? 1 : 0
    }

    let payload = LevelsPayload(peaks: onPeaks, sourcePeaks: srcOn, destinationPeaks: dstOn)
    // On/off rarely changes → identical payloads → skip: no JSON encode, no
    // wake-ups in the app, no re-render/re-layout.
    guard payload != lastLevels else { return }
    lastLevels = payload
    server.broadcast(.levels(payload))
}
meterTimer.resume()

// The daemon runs an accessory NSApplication loop (no Dock icon) instead of
// dispatchMain(): VST plugin editor windows live in this process and need a
// real AppKit event loop to receive mouse/keyboard input.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.run()
