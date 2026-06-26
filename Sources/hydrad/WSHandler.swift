// Hydra Audio — GPL-3.0
// WebSocket message dispatch. State (store, server, *Manager …) lives on the
// DaemonContext this extension belongs to (see DaemonRuntime.swift).

import Foundation
import Network
import HydraCore

extension DaemonContext {

/// Handles one inbound WebSocket message from `connection`.
/// Called from DaemonContext's `onMessage` closure (hopped to the main actor).
/// The control plane is main-actor-isolated: the state it touches (store,
/// server, *Manager) lives on the context, and the heavy lifting happens on
/// each manager's own internal queue.
func handleWSMessage(_ message: WSMessage, from connection: NWConnection) {
    switch message {
    case .getStatus:
        server.send(.status(currentStatus()), to: connection)
    case .getMatrix:
        server.send(.matrix(MatrixPayload(connections: store.allConnections())), to: connection)
    case .setConnection(let conn):
        // Scale guard: a gain tweak on an EXISTING patch must not
        // rebroadcast the whole matrix (65k connections worst case)
        // — only topology changes do. Gain-only updates go out as a
        // single light .setConnection echo.
        let gainOnly = store.allConnections().contains { $0.id == conn.id }
        if store.upsert(conn) {
            if gainOnly {
                server.broadcast(.setConnection(conn))
            } else {
                server.broadcast(.matrix(MatrixPayload(connections: store.allConnections())))
            }
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
    case .scanVST:
        stripManager.scanPlugins(extraRoot: configStore.current().vstFolderPath)
    case .getVST:
        server.send(.vst(stripManager.vstPayload()), to: connection)
    case .getStrips:
        server.send(.strips(stripManager.stripsPayload()), to: connection)
    case .setStrip(let strip):
        stripManager.setStrip(strip)
        // onChange broadcasts the refreshed strips.
    case .openPluginEditor(let payload):
        stripManager.openEditor(stripID: payload.stripID, index: payload.index, pinned: payload.pinned)
    case .setPluginAvailable(let payload):
        stripManager.setPluginAvailable(id: payload.id, available: payload.available)
        // onChange broadcasts the refreshed plugin list.
    case .setPluginFavorite(let payload):
        stripManager.setPluginFavorite(id: payload.id, favorite: payload.favorite)
        // onChange broadcasts the refreshed plugin list.
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
                                 aes67TX: payload.aes67TX,
                                 stereo: payload.stereo) != nil {
            server.broadcast(.interfaces(InterfacesPayload(interfaces: interfaceStore.all())))
            ndiManager.syncTx(bridges: bridgeManager.infos())
            aes67TxManager.syncTx(bridges: bridgeManager.infos())
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
            ndiManager.syncTx(bridges: bridgeManager.infos())
            aes67TxManager.syncTx(bridges: bridgeManager.infos())
            recordingManager.interfacesChanged(interfaceStore.all())
            // Ghost-state purge: inserts/trim configured on the freed
            // slices die with the interface.
            stripManager.removeStrips(nodeID: Hydra.backplaneNodeID,
                                    channelRanges: [inRange, outRange])
        }
    case .setInterfaceNDI(let payload):
        if interfaceStore.setNDI(id: payload.id, enabled: payload.enabled) {
            server.broadcast(.interfaces(InterfacesPayload(interfaces: interfaceStore.all())))
            ndiManager.syncTx(bridges: bridgeManager.infos())
        }
    case .setInterfaceAES67(let payload):
        if interfaceStore.setAES67(id: payload.id, enabled: payload.enabled) {
            server.broadcast(.interfaces(InterfacesPayload(interfaces: interfaceStore.all())))
            aes67TxManager.syncTx(bridges: bridgeManager.infos())
        }
    case .getBridges:
        server.send(.bridges(BridgesPayload(bridges: bridgeManager.infos())), to: connection)
    case .setBridgeEnabled(let payload):
        // Acquire/release the bridge's CoreAudio box; BridgeManager broadcasts the
        // refreshed state via its onChange hook.
        bridgeManager.setEnabled(id: payload.id, enabled: payload.enabled)
    case .setBridgeRole(let payload):
        bridgeManager.setRole(id: payload.id, role: payload.role)
    case .setBridgeNetworkTX(let payload):
        bridgeManager.setNetworkTX(id: payload.id, ndiTX: payload.ndiTX, aes67TX: payload.aes67TX)
    case .getNdi:
        server.send(.ndi(ndiManager.payload()), to: connection)
    case .getRecordings:
        server.send(.recordings(recordingManager.payload()), to: connection)
    case .startRecording(let ref):
        if let interface = interfaceStore.all().first(where: { $0.id == ref.id }) {
            recordingManager.start(interface: interface, config: configStore.current())
        }
    case .stopRecording(let ref):
        recordingManager.stop(interfaceID: ref.id)
        // onChange broadcasts the refreshed recordings state.
    case .subscribeNdi(let payload):
        ndiManager.setSubscribed(id: payload.id, subscribed: payload.subscribed)
        // onChange broadcasts the refreshed NDI state.
    case .getModules:
        server.send(.modules(moduleManager.payload()), to: connection)
    case .subscribeModuleSource(let payload):
        moduleManager.setSubscribed(id: payload.id, subscribed: payload.subscribed)
        // onChange broadcasts the refreshed module state.
    case .status, .matrix, .levels, .labels, .scenes, .devices, .apps, .aes67,
         .vst, .strips, .events, .event, .config, .interfaces, .ndi, .recordings,
         .modules, .bridges:
        break // daemon → app only; ignore if echoed
    }
}

} // extension DaemonContext
