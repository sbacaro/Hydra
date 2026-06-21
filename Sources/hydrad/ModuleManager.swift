// Hydra Audio — GPL-3.0
// Generic module host. Loads external .dylib modules (never shipped with
// Hydra) from ~/Library/Application Support/Hydra/modules/ and exposes the
// network SOURCES they provide as grid nodes — the same role NDI/AES67 RX
// play, but for code that lives entirely outside the distributed binary.
//
// A module exports `hydra_module_entry()` returning a HydraModule vtable
// (see hydra_module.h). The host hands it callbacks; the module discovers
// sources and delivers received audio, which we resample into the pool.

import Foundation
import Synchronization
import HydraCore
import HydraRT
import HydraModuleABI

// MARK: - C trampolines (must be free functions for @convention(c))

private func moduleHostSourcesChanged(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    Unmanaged<ModuleManager>.fromOpaque(ctx).takeUnretainedValue().hostSourcesChanged()
}

private func moduleHostDeliver(_ ctx: UnsafeMutableRawPointer?,
                               _ sid: UnsafePointer<CChar>?,
                               _ data: UnsafePointer<Float>?,
                               _ channels: Int32, _ frames: Int32, _ rate: Double) {
    guard let ctx, let sid, let data, channels > 0, frames > 0 else { return }
    let mgr = Unmanaged<ModuleManager>.fromOpaque(ctx).takeUnretainedValue()
    mgr.hostDeliver(sourceID: String(cString: sid), data: data,
                    channels: Int(channels), frames: Int(frames), rate: rate)
}

private func moduleHostLog(_ ctx: UnsafeMutableRawPointer?, _ msg: UnsafePointer<CChar>?) {
    guard let msg else { return }
    log("Module: \(String(cString: msg))")
}

// MARK: - ModuleRx: one subscribed module source (an EngineTap)

final class ModuleRx: EngineTap {
    let nodeID: String
    let sourceID: String
    private(set) var inChannels: Int = 0
    let outChannels: Int = 0
    private(set) var inRing: ChannelRing?
    let outRing: ChannelRing? = nil
    private(set) var inStaging: UnsafeMutablePointer<Float>?
    let outStaging: UnsafeMutablePointer<Float>? = nil

    private let engineRate: Double
    /// Called on the delivery thread when the first buffer reveals the format.
    var onReady: ((ModuleRx) -> Void)?

    init(sourceID: String, engineRate: Double) {
        self.sourceID = sourceID
        self.nodeID = Hydra.moduleNodeID(sourceID: sourceID)
        self.engineRate = engineRate
    }

    deinit { inStaging?.deallocate() }

    /// Push interleaved float32 audio from the module into the ring.
    func deliver(_ interleaved: UnsafePointer<Float>, channels: Int, frames: Int, rate: Double) {
        if inRing == nil {
            let ch = min(channels, Hydra.moduleMaxChannels)
            inChannels = ch
            let staging = UnsafeMutablePointer<Float>.allocate(capacity: Hydra.maxIOFrames * ch)
            staging.initialize(repeating: 0, count: Hydra.maxIOFrames * ch)
            inStaging = staging
            inRing = ChannelRing(channels: ch, producerRate: rate, consumerRate: engineRate)
            onReady?(self)
        }
        guard channels == inChannels else { return }   // format change: skip
        inRing?.write(from: interleaved, frames: frames)
    }
}

// MARK: - ModuleTx: one module sink (a transmit destination = an output EngineTap)

final class ModuleTx: EngineTap {
    let nodeID: String
    let sinkID: String
    let inChannels: Int = 0
    let outChannels: Int
    let inRing: ChannelRing? = nil
    let outRing: ChannelRing?
    let inStaging: UnsafeMutablePointer<Float>? = nil
    let outStaging: UnsafeMutablePointer<Float>?

    private let scratch: UnsafeMutablePointer<Float>
    private let cap: Int
    /// Dante runs at 48 kHz; the module pulls at that rate.
    private let moduleRate: Double = 48000

    init(sinkID: String, channels: Int, engineRate: Double) {
        let ch = max(1, min(channels, Hydra.moduleMaxChannels))
        self.sinkID = sinkID
        self.outChannels = ch
        self.nodeID = Hydra.moduleSinkNodeID(sinkID: sinkID)
        self.cap = Hydra.maxIOFrames * ch
        let staging = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        staging.initialize(repeating: 0, count: cap)
        self.outStaging = staging
        // engine writes (producer = engine rate) → we drain (consumer = 48 kHz).
        self.outRing = ChannelRing(channels: ch, producerRate: engineRate, consumerRate: moduleRate)
        self.scratch = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        self.scratch.initialize(repeating: 0, count: cap)
    }
    deinit { outStaging?.deallocate(); scratch.deallocate() }

    /// Drain `frames` (≤ maxIOFrames) from outRing and push to the owning module.
    func drain(module mod: UnsafePointer<HydraModule>, frames: Int) {
        guard let outRing, let send = mod.pointee.send_audio else { return }
        let n = min(frames, Hydra.maxIOFrames)
        outRing.readResampled(into: scratch, frames: n)
        sinkID.withCString { send(mod.pointee.instance, $0, scratch,
                                  Int32(outChannels), Int32(n), moduleRate) }
    }
}

// MARK: - ModuleManager

final class ModuleManager: @unchecked Sendable {

    private let store: MatrixStore
    private let queue = DispatchQueue(label: "hydra.modules")

    private var handles: [UnsafeMutableRawPointer] = []
    private var loaded: [UnsafePointer<HydraModule>] = []
    private var host = HydraHost()

    /// Discovered sources by id (snapshot from the modules).
    private var sources: [String: ModuleSourceInfo] = [:]
    private var subscribedIDs: Set<String> = []
    private let receivers = Mutex<[String: ModuleRx]>([:])   // guarded by Mutex for reads on audio path

    /// Sinks (TX) the modules expose, and their output taps.
    private var sinks: [String: ModuleSinkInfo] = [:]
    private var txTaps: [String: ModuleTx] = [:]                  // sinkID → tap
    private var txOwner: [String: UnsafePointer<HydraModule>] = [:]  // sinkID → owning module

    var onChange: ((ModulesPayload) -> Void)?

    private static let persistURL = hydraSupportURL("modules-subscriptions.json")

    init(store: MatrixStore) {
        self.store = store
        if let data = try? Data(contentsOf: Self.persistURL),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            subscribedIDs = Set(ids)
        }
    }

    func start() {
        queue.sync {
            host.ctx = Unmanaged.passUnretained(self).toOpaque()
            host.sources_changed = moduleHostSourcesChanged
            host.deliver_audio = moduleHostDeliver
            host.log = moduleHostLog

            let dir = Hydra.modulesDirectory()
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
                log("Modules: none (\(dir) absent) — Hydra runs without external modules")
                return
            }
            for entry in entries.sorted() where entry.hasSuffix(".dylib") {
                loadModule(at: (dir as NSString).appendingPathComponent(entry))
            }
            if loaded.isEmpty {
                log("Modules: no loadable .dylib in \(dir)")
            }
            refreshLocked()
        }
        // Periodic discovery poll (modules update their own source lists).
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 3)
        timer.setEventHandler { [weak self] in self?.refreshLocked() }
        timer.resume()
        pollTimer = timer

        // Steady TX drain: push routed audio to module sinks at the Dante rate.
        let drain = DispatchSource.makeTimerSource(queue: queue)
        drain.schedule(deadline: .now() + 2, repeating: .milliseconds(10), leeway: .milliseconds(1))
        drain.setEventHandler { [weak self] in self?.drainTxLocked() }
        drain.resume()
        drainTimer = drain
    }
    private var pollTimer: DispatchSourceTimer?
    private var drainTimer: DispatchSourceTimer?

    private func loadModule(at path: String) {
        guard let handle = dlopen(path, RTLD_NOW) else {
            log("Modules: dlopen failed for \(path): \(String(cString: dlerror()))")
            return
        }
        guard let sym = dlsym(handle, "hydra_module_entry") else {
            log("Modules: \(path) has no hydra_module_entry — skipped")
            dlclose(handle)
            return
        }
        let entry = unsafeBitCast(sym, to: hydra_module_entry_fn.self)
        guard let mod = entry() else {
            log("Modules: \(path) entry returned null")
            dlclose(handle)
            return
        }
        guard mod.pointee.abi_version == HYDRA_MODULE_ABI_VERSION else {
            log("Modules: \(path) ABI \(mod.pointee.abi_version) ≠ \(HYDRA_MODULE_ABI_VERSION) — skipped")
            dlclose(handle)
            return
        }
        let name = mod.pointee.name.map { String(cString: $0) } ?? "?"
        let ver = mod.pointee.version.map { String(cString: $0) } ?? "?"
        if let startFn = mod.pointee.start {
            let rc = withUnsafePointer(to: host) { startFn(mod.pointee.instance, $0) }
            if rc != 0 {
                log("Modules: \(name) start() failed (\(rc))")
                dlclose(handle)
                return
            }
        }
        handles.append(handle)
        loaded.append(mod)
        log("Modules: loaded \"\(name)\" \(ver)")
    }

    // MARK: Host callbacks

    func hostSourcesChanged() {
        queue.async { [weak self] in self?.refreshLocked() }
    }

    func hostDeliver(sourceID: String, data: UnsafePointer<Float>,
                     channels: Int, frames: Int, rate: Double) {
        let rx = receivers.withLock { $0[sourceID] }
        rx?.deliver(data, channels: channels, frames: frames, rate: rate)
    }

    // MARK: API

    func setSubscribed(id: String, subscribed: Bool) {
        queue.sync {
            if subscribed { subscribedIDs.insert(id) } else { subscribedIDs.remove(id) }
            if let data = try? JSONEncoder().encode(Array(subscribedIDs).sorted()) {
                try? data.write(to: Self.persistURL, options: .atomic)
            }
            // Tell the owning module to (un)subscribe its flow.
            for mod in loaded where mod.pointee.subscribe != nil {
                _ = id.withCString { mod.pointee.subscribe!(mod.pointee.instance, $0, subscribed ? 1 : 0) }
            }
            refreshLocked()
        }
    }

    func payload() -> ModulesPayload {
        queue.sync { payloadLocked() }
    }

    // MARK: Internals (queue only)

    private func refreshLocked() {
        // Re-poll each module's source list.
        var fresh: [String: ModuleSourceInfo] = [:]
        // Sources the MODULE reports as already subscribed (externally driven — e.g.
        // a Dante RX flow the Dante Controller routed to us). These must appear and
        // route in the app even though the user never subscribed them here.
        var extSubscribed = Set<String>()
        var buf = [HydraModuleSource](repeating: HydraModuleSource(), count: 256)
        for mod in loaded {
            guard let lister = mod.pointee.list_sources else { continue }
            let modName = mod.pointee.name.map { String(cString: $0) } ?? "?"
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                Int(lister(mod.pointee.instance, ptr.baseAddress, Int32(ptr.count)))
            }
            for i in 0..<max(0, min(n, buf.count)) {
                let cs = buf[i]
                guard let idC = cs.id else { continue }
                let id = String(cString: idC)
                let name = cs.name.map { String(cString: $0) } ?? id
                let sub = cs.subscribed != 0 || subscribedIDs.contains(id)
                if cs.subscribed != 0 { extSubscribed.insert(id) }
                fresh[id] = ModuleSourceInfo(id: id, name: name, moduleName: modName,
                                             channels: Int(cs.channels), subscribed: sub)
            }
        }
        sources = fresh

        let engineRate = BackplaneProbe.backplaneDeviceID()
            .map(BackplaneProbe.nominalSampleRate) ?? Hydra.defaultSampleRate
        let wanted = subscribedIDs.intersection(sources.keys).union(extSubscribed)

        receivers.withLock { dict in
            for (id, rx) in dict where !wanted.contains(id) {
                dict.removeValue(forKey: id)
                _ = rx   // dropped; deinit frees staging
            }
            for id in wanted where dict[id] == nil {
                let rx = ModuleRx(sourceID: id, engineRate: engineRate)
                rx.onReady = { [weak self] _ in
                    guard let self else { return }
                    self.queue.async {
                        self.registerReadyLocked()
                        self.broadcastLocked()
                    }
                }
                dict[id] = rx
            }
        }

        // Re-poll each module's SINK (TX) list and reconcile output taps.
        var freshSinks: [String: ModuleSinkInfo] = [:]
        var freshOwner: [String: UnsafePointer<HydraModule>] = [:]
        var sbuf = [HydraModuleSink](repeating: HydraModuleSink(), count: 64)
        for mod in loaded {
            guard let sinkLister = mod.pointee.list_sinks else { continue }
            let modName = mod.pointee.name.map { String(cString: $0) } ?? "?"
            let n = sbuf.withUnsafeMutableBufferPointer { ptr in
                Int(sinkLister(mod.pointee.instance, ptr.baseAddress, Int32(ptr.count)))
            }
            for i in 0..<max(0, min(n, sbuf.count)) {
                let cs = sbuf[i]
                guard let idC = cs.id else { continue }
                let id = String(cString: idC)
                let name = cs.name.map { String(cString: $0) } ?? id
                freshSinks[id] = ModuleSinkInfo(id: id, name: name, moduleName: modName,
                                                channels: Int(cs.channels))
                freshOwner[id] = mod
            }
        }
        sinks = freshSinks
        txOwner = freshOwner
        for id in txTaps.keys where freshSinks[id] == nil { txTaps.removeValue(forKey: id) }
        for (id, info) in freshSinks {
            let ch = max(1, min(info.channels, Hydra.moduleMaxChannels))
            if let existing = txTaps[id], existing.outChannels == ch { continue }
            txTaps[id] = ModuleTx(sinkID: id, channels: ch, engineRate: engineRate)
        }

        registerReadyLocked()
        broadcastLocked()
    }

    private func registerReadyLocked() {
        let ready = receivers.withLock { dict in
            dict.values.filter { $0.inRing != nil }
        }
        var taps: [EngineTap] = ready.map { $0 as EngineTap }
        taps.append(contentsOf: txTaps.values.map { $0 as EngineTap })
        taps.sort { $0.nodeID < $1.nodeID }
        store.setModuleTaps(taps)
    }

    private func payloadLocked() -> ModulesPayload {
        let mods = loaded.map { m -> ModuleInfo in
            ModuleInfo(name: m.pointee.name.map { String(cString: $0) } ?? "?",
                       version: m.pointee.version.map { String(cString: $0) } ?? "?")
        }
        let srcs = sources.keys.sorted().map { id -> ModuleSourceInfo in
            var s = sources[id]!
            let ch = receivers.withLock { $0[id]?.inChannels }
            if let ch, ch > 0 { s.channels = ch }
            // Keep externally-driven subscriptions (e.g. Dante RX from the Controller,
            // already set in `sources`) — only OR in the app's own subscriptions.
            s.subscribed = s.subscribed || subscribedIDs.contains(id)
            return s
        }
        let snks = sinks.keys.sorted().map { sinks[$0]! }
        return ModulesPayload(modules: mods, sources: srcs, sinks: snks)
    }

    /// Drain routed audio from each TX tap's outRing into its owning module.
    /// 480 frames every 10 ms = exactly 48 kHz, the rate Dante pulls at.
    private func drainTxLocked() {
        for (id, tap) in txTaps {
            guard let mod = txOwner[id] else { continue }
            tap.drain(module: mod, frames: 480)
        }
    }

    private func broadcastLocked() {
        onChange?(payloadLocked())
    }
}
