// Hydra Audio — GPL-3.0
// DaemonRuntime / DaemonContext — the Hydra audio engine, run IN-PROCESS inside
// Hydra.app.
//
// Historically this code lived in a separate `hydrad` executable (main.swift)
// launched as a LaunchAgent. Hydra now ships as a SINGLE process: the audio
// engine, all managers and the local WebSocket server are started here, on the
// app's main actor, by `DaemonRuntime.start()`. The SwiftUI UI is still a plain
// WebSocket client of `ws://127.0.0.1:59731` — only now the server lives in the
// same process, so the user sees one app in Activity Monitor instead of two.
//
// This module (HydraDaemon) is a framework, NOT the app target, so it keeps the
// `nonisolated`-by-default actor isolation the engine/managers were written for
// (the app target is MainActor-by-default). The control plane below is still
// explicitly `@MainActor`, exactly as it was in the old daemon.

import Foundation
import AppKit
import Network
import HydraCore

/// Public façade the app calls. Owns the single long-lived `DaemonContext`.
@MainActor
public enum DaemonRuntime {

    /// VST scan worker mode: when the host process is invoked as
    /// `<exe> --scan-bundle <bundle> --out <file>` it loads ONE plugin bundle in
    /// this throwaway process, writes its classes as JSON to <file>, and the
    /// caller exits — BEFORE any UI or engine setup. This isolates plugin scan
    /// hangs/crashes (and the objc class collisions some vendor plugins cause
    /// when loaded together) from the real app: the parent kills a hung worker on
    /// timeout and treats a crashed worker's non-zero exit as "offline".
    ///
    /// Returns true if it handled a scan request (the caller must then exit(0)).
    /// The scan worker is spawned via `Bundle.main.executableURL`, which — now
    /// that the daemon is folded into the app — is the Hydra.app executable; the
    /// app's `main.swift` calls this before SwiftUI starts.
    public nonisolated static func runScanWorkerIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let bi = args.firstIndex(of: "--scan-bundle"), bi + 1 < args.count,
              let oi = args.firstIndex(of: "--out"), oi + 1 < args.count else {
            return false
        }
        StripManager.scanBundleWorkerJSON(bundlePath: args[bi + 1], outPath: args[oi + 1])
        return true
    }

    /// The single live context, pinned for the life of the app.
    private static var context: DaemonContext?

    /// Bring the audio engine + local WebSocket server up, in-process. Idempotent.
    public static func start() {
        guard context == nil else { return }
        let ctx = DaemonContext()
        context = ctx
        ctx.start()
    }

    /// Tear down the in-process runtime on app quit. Critically, this terminates
    /// the out-of-process `hydra-plugin-host` children so they don't orphan to
    /// launchd. Call from `applicationWillTerminate`.
    public static func shutdown() {
        context?.shutdown()
        context = nil
    }
}

/// All daemon state + the control plane. One instance lives for the app's
/// lifetime (pinned by `DaemonRuntime.context`). Main-actor-isolated: the heavy
/// lifting happens on each manager's own internal queue and hops back here.
@MainActor
final class DaemonContext {

    let store = MatrixStore()
    let labels = LabelStore()
    let sceneStore = SceneStore()
    let engine: AudioEngine
    let deviceManager: DeviceManager
    let tapManager: ProcessTapManager
    let aes67Manager: Aes67Manager
    let stripManager: StripManager
    let ndiManager: NdiManager
    let moduleManager: ModuleManager
    let recordingManager: RecordingManager
    let aes67TxManager: Aes67TxManager
    let oscServer = OscServer()
    let configStore = ConfigStore()
    let interfaceStore = InterfaceStore()
    let bridgeManager: BridgeManager
    let surfaceManager: SurfaceManager
    let routeManager: RouteManager

    /// Set in `start()` once the socket is open.
    var server: WebSocketServer!

    private var probeTimer: DispatchSourceTimer?
    private var meterTimer: DispatchSourceTimer?

    init() {
        store.loadFromDisk()
        engine = AudioEngine(store: store)
        deviceManager = DeviceManager(store: store)
        tapManager = ProcessTapManager(store: store)
        aes67Manager = Aes67Manager(store: store)
        stripManager = StripManager(store: store)
        ndiManager = NdiManager(store: store)
        moduleManager = ModuleManager(store: store)
        recordingManager = RecordingManager(store: store)
        aes67TxManager = Aes67TxManager(store: store)
        bridgeManager = BridgeManager(store: store)
        surfaceManager = SurfaceManager()
        routeManager = RouteManager(store: store, devices: deviceManager, bridges: bridgeManager)
    }

    // MARK: - Status helpers

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

    /// Push the full current state to a freshly connected client.
    func pushFullState(to connection: NWConnection) {
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
        server.send(.bridges(BridgesPayload(bridges: bridgeManager.infos())), to: connection)
        server.send(.surface(surfaceManager.payload()), to: connection)
    }

    /// Tear down on app quit. Most state dies with the process, but the
    /// out-of-process `hydra-plugin-host` children would otherwise orphan to
    /// launchd — terminate them explicitly. Also stops the surface bridge so its
    /// virtual MIDI ports and HiQnet session close cleanly.
    func shutdown() {
        log("Hydra engine shutting down — terminating plugin hosts")
        stripManager.shutdownAllHosts()
        surfaceManager.stop()
    }

    // MARK: - Startup

    func start() {
        log("Hydra engine \(Hydra.versionString) starting (in-process)")

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

        do {
            server = try WebSocketServer(
                port: Hydra.daemonPort,
                onConnect: { [weak self] connection in
                    // Hop to the main actor (the control plane) to push full state.
                    Task { @MainActor in self?.pushFullState(to: connection) }
                },
                onMessage: { [weak self] message, connection in
                    Task { @MainActor in self?.handleWSMessage(message, from: connection) }
                })
        } catch {
            log("Could not create server on port \(Hydra.daemonPort): \(error)")
            return
        }

        server.start()

        // These callbacks fire on the managers' own background queues, but touch the
        // main-actor control plane, so they hop to the main actor — otherwise Swift 6
        // traps the isolation assertion at runtime.

        EventCenter.shared.onEvent = { [weak self] event in
            Task { @MainActor in self?.server.broadcast(.event(event)) }
        }

        deviceManager.onChange = { [weak self] infos in
            Task { @MainActor in
                guard let self else { return }
                self.server.broadcast(.devices(DevicesPayload(devices: infos)))
                // Let strips drop/reload plugins as their devices come and go.
                self.stripManager.setPresentDevices(Set(infos.filter { $0.present }.map(\.nodeID)))
            }
        }
        deviceManager.startMonitoring()

        tapManager.onChange = { [weak self] infos in
            Task { @MainActor in self?.server.broadcast(.apps(AppsPayload(apps: infos))) }
        }
        tapManager.startMonitoring()

        aes67Manager.onChange = { [weak self] payload in
            Task { @MainActor in
                guard let self else { return }
                var full = payload
                full.txFlows = self.aes67TxManager.flows()
                self.server.broadcast(.aes67(full))
            }
        }
        aes67TxManager.onChange = { [weak self] in
            Task { @MainActor in guard let self else { return }
                self.server.broadcast(.aes67(self.aes67FullPayload())) }
        }
        aes67Manager.start()

        ndiManager.onChange = { [weak self] payload in
            Task { @MainActor in self?.server.broadcast(.ndi(payload)) }
        }
        ndiManager.start()
        ndiManager.syncTx(bridges: bridgeManager.infos())

        // Control surface (HiQnet ↔ HUI). The manager owns the bridge and only
        // broadcasts when its serialised state actually changes (see its tick).
        surfaceManager.onChange = { [weak self] payload in
            Task { @MainActor in self?.server.broadcast(.surface(payload)) }
        }
        surfaceManager.start()

        moduleManager.onChange = { [weak self] payload in
            Task { @MainActor in self?.server.broadcast(.modules(payload)) }
        }
        moduleManager.start()

        recordingManager.onChange = { [weak self] payload in
            Task { @MainActor in self?.server.broadcast(.recordings(payload)) }
        }

        // Bridges: fixed multi-device set. Reconcile system visibility to the
        // persisted enabled set, and broadcast state on change.
        bridgeManager.onChange = { [weak self] infos in
            Task { @MainActor in
                guard let self else { return }
                self.server.broadcast(.bridges(BridgesPayload(bridges: infos)))
                // Re-sync NDI/AES senders to the bridges' TX flags.
                self.ndiManager.syncTx(bridges: infos)
                self.aes67TxManager.syncTx(bridges: infos)
            }
        }
        // Lazy attach: when the patched-bridge set changes, attach/detach IOProcs.
        store.onBridgeUsage = { [weak self] ids in
            self?.bridgeManager.setUsedBridges(ids)
        }
        // Lazy plugin load: when the connection set changes, let strips instantiate
        // their plugins only once something is patched through them.
        store.onConnectionsChanged = { [weak self] in
            self?.stripManager.recheckConnectivity()
        }
        bridgeManager.start()
        // The persisted matrix loaded before the hook was wired — publish its
        // patched-bridge set now so those bridges attach.
        store.publishBridgeUsage()

        // Capture flows (Audio-Hijack-style): broadcast state, then apply the
        // persisted flows now that devices/bridges are up.
        routeManager.onChange = { [weak self] flows in
            Task { @MainActor in self?.server.broadcast(.flows(FlowsPayload(flows: flows))) }
        }
        routeManager.start()

        // OSC remote control: scenes + recordings, addressable by name.
        oscServer.onMessage = { [weak self] message in Task { @MainActor in
            guard let self else { return }
            switch message.address {
            case "/hydra/scene/apply":
                let scene: PatchScene?
                if let name = message.firstString {
                    scene = self.sceneStore.all().first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
                } else if let index = message.firstInt {
                    let all = self.sceneStore.all()
                    scene = all.indices.contains(index) ? all[index] : nil
                } else {
                    scene = nil
                }
                if let scene, self.store.replaceAll(scene.connections) {
                    self.server.broadcast(.matrix(MatrixPayload(connections: self.store.allConnections())))
                    log("OSC: scene applied — \"\(scene.name)\"")
                }
            case "/hydra/scene/save":
                if let name = message.firstString, !name.isEmpty {
                    self.sceneStore.save(name: name, connections: self.store.allConnections())
                    self.server.broadcast(.scenes(ScenesPayload(scenes: self.sceneStore.all())))
                    log("OSC: scene saved — \"\(name)\"")
                }
            case "/hydra/record/start":
                if let name = message.firstString,
                   let interface = self.interfaceStore.all().first(where: {
                       $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                    self.recordingManager.start(interface: interface, config: self.configStore.current())
                }
            case "/hydra/record/stop":
                if let name = message.firstString,
                   let interface = self.interfaceStore.all().first(where: {
                       $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                    self.recordingManager.stop(interfaceID: interface.id)
                }
            default:
                log("OSC: unhandled address \(message.address)")
            }
        } }

        stripManager.onChange = { [weak self] vstPayload, stripsPayload in
            Task { @MainActor in
                self?.server.broadcast(.vst(vstPayload))
                self?.server.broadcast(.strips(stripsPayload))
            }
        }
        stripManager.start()
        // Seed the present-device set so currently-connected devices' strips load
        // now; absent-device strips stay dormant until their device returns.
        stripManager.setPresentDevices(Set(deviceManager.infos().filter { $0.present }.map(\.nodeID)))

        PtpClock.shared.onChange = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.aes67TxManager.ptpChanged(locked: status.locked)
                self.server.broadcast(.aes67(self.aes67FullPayload()))
            }
        }
        PtpClock.shared.start()

        startProbeTimer(initial: initial)
        startMeterTimer()

        // NOTE: the old daemon ran its own `NSApplication(.accessory).run()` here —
        // it needed an AppKit event loop for VST plugin editor windows. The engine
        // now lives inside Hydra.app, which already runs that loop, so we MUST NOT
        // start a second one.
    }

    /// Re-probe every 3 s: track backplane presence, manage engine lifecycle,
    /// broadcast status changes (e.g. backplane installed while app is open).
    private func startProbeTimer(initial: StatusPayload) {
        var lastStatus = initial
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let present = BackplaneProbe.backplaneDeviceID() != nil
                if present && !self.engine.isRunning {
                    self.engine.startIfPossible()
                } else if !present && self.engine.isRunning {
                    self.engine.stop()
                }
                let status = self.currentStatus()
                if status != lastStatus {
                    if status.backplaneInstalled != lastStatus.backplaneInstalled
                        || status.engineRunning != lastStatus.engineRunning {
                        log("State changed — broadcasting (backplane: \(status.backplaneInstalled ? "present" : "absent"), engine: \(status.engineRunning ? "running" : "stopped"))")
                    }
                    lastStatus = status
                    self.server.broadcast(.status(status))
                }
            }
        }
        timer.resume()
        probeTimer = timer
    }

    /// Signal presence: poll post-gain peaks while clients are connected and turn
    /// them into a BINARY on/off (1 = has signal, 0 = silent), with a short release
    /// hold so a steady source doesn't flicker.
    private func startMeterTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Hydra.meterInterval, repeating: Hydra.meterInterval)
        var lastLevels: LevelsPayload?
        let signalFloor = Hydra.signalFloorLinear
        let release     = Hydra.signalReleaseSeconds
        var lastOn:     [String: Date] = [:]
        var lastSrcOn:  [Int: Date]    = [:]
        var lastDstOn:  [Int: Date]    = [:]
        var lastNodeOn: [String: Date] = [:]   // "nodeID:channel" → last over-floor
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated {
            guard let self else { return }
            let active = self.engine.isRunning && self.server.hasClients
            self.store.channelMeteringEnabled = active
            guard active else { return }
            let now = Date()
            let rawPeaks = self.store.levels()
            let (inputs, outputs) = self.store.channelPeaks()

            var onPeaks: [String: Float] = [:]
            onPeaks.reserveCapacity(rawPeaks.count)
            for (id, v) in rawPeaks {
                if v > signalFloor { lastOn[id] = now }
                let on = lastOn[id].map { now.timeIntervalSince($0) < release } ?? false
                onPeaks[id] = on ? 1 : 0
            }
            lastOn = lastOn.filter { rawPeaks[$0.key] != nil }

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

            // Per-source-node presence: a transmitter's pin lights from its OWN
            // audio (app/device/NDI/…), independent of any patch. Same floor +
            // release-hold treatment as the connection/backplane peaks above.
            let nodePeaks = self.store.nodeChannelPeaks()
            var activeSources: [String] = []
            for (key, v) in nodePeaks {
                if v > signalFloor { lastNodeOn[key] = now }
                if lastNodeOn[key].map({ now.timeIntervalSince($0) < release }) ?? false {
                    activeSources.append(key)
                }
            }
            lastNodeOn = lastNodeOn.filter { nodePeaks[$0.key] != nil }
            activeSources.sort()

            let payload = LevelsPayload(peaks: onPeaks, sourcePeaks: srcOn,
                                        destinationPeaks: dstOn, activeSources: activeSources)
            guard payload != lastLevels else { return }
            lastLevels = payload
            self.server.broadcast(.levels(payload))
        } }
        timer.resume()
        meterTimer = timer
    }
}
