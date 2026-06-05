// Hydra Audio — GPL-3.0
// hydrad — the Hydra daemon. Phase 2 scope: real patch matrix applied to
// audio via an IOProc on the backplane, with per-connection gain and meters,
// controlled over the local WebSocket.

import Foundation
import AppKit
import HydraCore

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
let recordingManager = RecordingManager(store: store)
let aes67TxManager = Aes67TxManager(store: store)
let oscServer = OscServer()
let configStore = ConfigStore()
let interfaceStore = InterfaceStore()
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
    return payload
}

func currentStatus() -> StatusPayload {
    BackplaneProbe.currentStatus(engineRunning: engine.isRunning)
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
            server.send(.recordings(recordingManager.payload()), to: connection)
        },
        onMessage: { message, connection in
            switch message {
            case .getStatus:
                server.send(.status(currentStatus()), to: connection)
            case .getMatrix:
                server.send(.matrix(MatrixPayload(connections: store.allConnections())), to: connection)
            case .setConnection(let conn):
                if store.upsert(conn) {
                    server.broadcast(.matrix(MatrixPayload(connections: store.allConnections())))
                } else {
                    // Rejected (e.g. feedback guard): resync the sender so its
                    // optimistic local update rolls back.
                    server.send(.matrix(MatrixPayload(connections: store.allConnections())), to: connection)
                }
            case .removeConnection(let conn):
                if store.remove(conn) {
                    server.broadcast(.matrix(MatrixPayload(connections: store.allConnections())))
                }
            case .getLabels:
                server.send(.labels(labels.all()), to: connection)
            case .setLabel(let change):
                if labels.set(change) {
                    server.broadcast(.labels(labels.all()))
                }
            case .getScenes:
                server.send(.scenes(ScenesPayload(scenes: sceneStore.all())), to: connection)
            case .saveScene(let payload):
                sceneStore.save(name: payload.name, connections: store.allConnections())
                server.broadcast(.scenes(ScenesPayload(scenes: sceneStore.all())))
                log("Scene saved: \"\(payload.name)\"")
            case .applyScene(let ref):
                if let scene = sceneStore.scene(id: ref.id), store.replaceAll(scene.connections) {
                    server.broadcast(.matrix(MatrixPayload(connections: store.allConnections())))
                    log("Scene applied: \"\(scene.name)\" (\(scene.connections.count) connections)")
                }
            case .deleteScene(let ref):
                if sceneStore.delete(id: ref.id) {
                    server.broadcast(.scenes(ScenesPayload(scenes: sceneStore.all())))
                }
            case .getDevices:
                server.send(.devices(DevicesPayload(devices: deviceManager.infos())), to: connection)
            case .setDeviceUse(let payload):
                deviceManager.setUse(uid: payload.uid, used: payload.used)
                // onChange broadcasts the refreshed device list.
            case .getApps:
                server.send(.apps(AppsPayload(apps: tapManager.infos())), to: connection)
            case .setAppCapture(let payload):
                tapManager.setCapture(pid: payload.pid, captured: payload.captured)
                // onChange broadcasts the refreshed app list.
            case .getAes67:
                server.send(.aes67(aes67FullPayload()), to: connection)
            case .subscribeStream(let payload):
                aes67Manager.setSubscribed(id: payload.id, subscribed: payload.subscribed)
                // onChange broadcasts the refreshed network state.
            case .getVST:
                server.send(.vst(stripManager.vstPayload()), to: connection)
            case .getStrips:
                server.send(.strips(stripManager.stripsPayload()), to: connection)
            case .setStrip(let strip):
                stripManager.setStrip(strip)
                // onChange broadcasts the refreshed strips.
            case .openPluginEditor(let payload):
                stripManager.openEditor(stripID: payload.stripID, index: payload.index)
            case .setConfig(let payload):
                configStore.update(payload)
                store.feedbackProtectionEnabled = payload.feedbackProtection
                tapManager.setMakeup(dB: payload.appTapMakeupDB)
                oscServer.apply(enabled: payload.oscEnabled, port: payload.oscPort)
                server.broadcast(.config(payload))
                log("Config updated: feedbackProtection=\(payload.feedbackProtection)")
            case .getInterfaces:
                server.send(.interfaces(InterfacesPayload(interfaces: interfaceStore.all())), to: connection)
            case .createInterface(let payload):
                if interfaceStore.create(name: payload.name,
                                         inChannels: payload.inChannels,
                                         outChannels: payload.outChannels,
                                         ndiTX: payload.ndiTX,
                                         aes67TX: payload.aes67TX) != nil {
                    server.broadcast(.interfaces(InterfacesPayload(interfaces: interfaceStore.all())))
                    ndiManager.syncTx(interfaces: interfaceStore.all())
                    aes67TxManager.syncTx(interfaces: interfaceStore.all())
                }
            case .deleteInterface(let ref):
                if let removed = interfaceStore.delete(id: ref.id) {
                    // Drop patches touching the freed slices (per direction).
                    let inRange = removed.inBase ..< (removed.inBase + removed.inChannels)
                    let outRange = removed.outBase ..< (removed.outBase + removed.outChannels)
                    let kept = store.allConnections().filter { (conn: Connection) -> Bool in
                        let srcHit = conn.source.nodeID == Hydra.backplaneNodeID
                            && inRange.contains(conn.source.channelIndex)
                        let dstHit = conn.destination.nodeID == Hydra.backplaneNodeID
                            && outRange.contains(conn.destination.channelIndex)
                        return !srcHit && !dstHit
                    }
                    if kept.count != store.allConnections().count, store.replaceAll(kept) {
                        server.broadcast(.matrix(MatrixPayload(connections: store.allConnections())))
                    }
                    server.broadcast(.interfaces(InterfacesPayload(interfaces: interfaceStore.all())))
                    ndiManager.syncTx(interfaces: interfaceStore.all())
                    aes67TxManager.syncTx(interfaces: interfaceStore.all())
                    recordingManager.interfacesChanged(interfaceStore.all())
                }
            case .setInterfaceNDI(let payload):
                if interfaceStore.setNDI(id: payload.id, enabled: payload.enabled) {
                    server.broadcast(.interfaces(InterfacesPayload(interfaces: interfaceStore.all())))
                    ndiManager.syncTx(interfaces: interfaceStore.all())
                }
            case .setInterfaceAES67(let payload):
                if interfaceStore.setAES67(id: payload.id, enabled: payload.enabled) {
                    server.broadcast(.interfaces(InterfacesPayload(interfaces: interfaceStore.all())))
                    aes67TxManager.syncTx(interfaces: interfaceStore.all())
                }
            case .getNdi:
                server.send(.ndi(ndiManager.payload()), to: connection)
            case .getRecordings:
                server.send(.recordings(recordingManager.payload()), to: connection)
            case .startRecording(let ref):
                if let interface = interfaceStore.all().first(where: { $0.id == ref.id }) {
                    recordingManager.start(interface: interface)
                }
            case .stopRecording(let ref):
                recordingManager.stop(interfaceID: ref.id)
                // onChange broadcasts the refreshed recordings state.
            case .subscribeNdi(let payload):
                ndiManager.setSubscribed(id: payload.id, subscribed: payload.subscribed)
                // onChange broadcasts the refreshed NDI state.
            case .status, .matrix, .levels, .labels, .scenes, .devices, .apps, .aes67,
                 .vst, .strips, .events, .event, .config, .interfaces, .ndi, .recordings:
                break // daemon → app only; ignore if echoed
            }
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
            recordingManager.start(interface: interface)
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
        lastStatus = status
        log("State changed — broadcasting (backplane: \(status.backplaneInstalled ? "present" : "absent"), engine: \(status.engineRunning ? "running" : "stopped"))")
        server.broadcast(.status(status))
    }
}
probeTimer.resume()

// Meters: broadcast post-gain peaks while clients are connected.
let meterTimer = DispatchSource.makeTimerSource(queue: .global())
meterTimer.schedule(deadline: .now() + Hydra.meterInterval, repeating: Hydra.meterInterval)
var lastLevels: LevelsPayload?
meterTimer.setEventHandler {
    let active = engine.isRunning && server.hasClients
    store.channelMeteringEnabled = active
    guard active else { return }
    let (inputs, outputs) = store.channelPeaks()
    let payload = LevelsPayload(peaks: store.levels(),
                                sourcePeaks: inputs,
                                destinationPeaks: outputs)
    // Idle system → identical payloads → skip: no JSON encode, no wake-ups
    // in the app. Real audio changes every tick, so nothing is lost.
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
