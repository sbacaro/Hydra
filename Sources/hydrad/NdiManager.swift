// Hydra Audio — GPL-3.0
// NDI integration — RX (network sources → grid rows) and TX (virtual
// interfaces → NDI audio sources).
//
// Licensing model (DistroAV/OBS pattern): the proprietary NDI runtime is
// NEVER bundled or linked. HydraNDIShim dlopen()s the runtime the user
// installs from Vizrt's official redistributable (Hydra.ndiRedistURL);
// without it this manager reports runtimeAvailable=false and stays idle.
//
// RX: NDI doesn't advertise audio format up front, so a receiver starts a
// capture thread immediately but only joins the engine (ring + tap
// registration) after the first audio frame reveals channels + rate. The
// ring's consumer-side ASRC absorbs the clock difference, same as AES67.
//
// TX: a PoolTxTap in MatrixStore copies the interface's mixed backplane
// output slice each cycle; a sender thread drains it in ~10 ms chunks.

import Foundation
import HydraCore
import HydraNDIShim

// MARK: - NdiRx: one subscribed source

final class NdiRx: EngineTap {
    let nodeID: String
    let sourceID: String
    // EngineTap — populated once the format is known (before registration).
    private(set) var inChannels: Int = 0
    let outChannels: Int = 0
    private(set) var inRing: ChannelRing?
    let outRing: ChannelRing? = nil
    private(set) var inStaging: UnsafeMutablePointer<Float>?
    let outStaging: UnsafeMutablePointer<Float>? = nil

    /// Called on the capture thread when the first frame reveals the format.
    var onReady: ((NdiRx) -> Void)?

    private let engineRate: Double
    private var recv: UnsafeMutableRawPointer?
    private var thread: Thread?
    private let scratch: UnsafeMutablePointer<Float>
    private var running = true
    private(set) var sampleRate: Double = 0

    init?(sourceID: String, name: String, url: String, engineRate: Double) {
        guard let recv = hndi_recv_create(name, url) else {
            log("NDI RX \"\(name)\": receiver creation failed")
            return nil
        }
        self.recv = recv
        self.sourceID = sourceID
        self.nodeID = Hydra.ndiNodeID(sourceID: sourceID)
        self.engineRate = engineRate
        scratch = .allocate(capacity: Hydra.maxIOFrames * Hydra.ndiMaxChannels)
        scratch.initialize(repeating: 0, count: Hydra.maxIOFrames * Hydra.ndiMaxChannels)

        let thread = Thread { [weak self] in self?.captureLoop(name: name) }
        thread.name = "hydra.ndi.rx"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    deinit {
        stop()
        scratch.deallocate()
        inStaging?.deallocate()
    }

    func stop() {
        running = false
        thread = nil
        // recv is destroyed by the capture thread on exit (it may be blocked
        // inside capture with a timeout right now).
    }

    private func captureLoop(name: String) {
        while running {
            var channels: Int32 = 0
            var rate: Int32 = 0
            let frames = hndi_recv_audio(recv, scratch, Int32(Hydra.maxIOFrames),
                                         Int32(Hydra.ndiMaxChannels),
                                         &channels, &rate, 100)
            guard frames > 0, channels > 0, rate > 0 else { continue }

            if inRing == nil {
                // First frame: now we know the format — join the engine.
                inChannels = Int(channels)
                sampleRate = Double(rate)
                let staging = UnsafeMutablePointer<Float>.allocate(capacity: Hydra.maxIOFrames * inChannels)
                staging.initialize(repeating: 0, count: Hydra.maxIOFrames * inChannels)
                inStaging = staging
                inRing = ChannelRing(channels: inChannels,
                                     producerRate: sampleRate,
                                     consumerRate: engineRate)
                log("NDI RX \"\(name)\": \(inChannels)ch @ \(Int(sampleRate)) Hz")
                onReady?(self)
            }
            guard Int(channels) == inChannels else { continue } // format change: ignore frame
            inRing?.write(from: scratch, frames: Int(frames))
        }
        hndi_recv_destroy(recv)
        recv = nil
    }
}

// MARK: - NdiTx: one broadcasting virtual interface

final class NdiTx {
    let interfaceID: UUID
    let tap: PoolTxTap

    private var send: UnsafeMutableRawPointer?
    private var thread: Thread?
    private var running = true
    private let chunk: Int
    private let sampleRate: Double
    private let buffer: UnsafeMutablePointer<Float>

    init?(interface info: VirtualInterfaceInfo, rate: Double) {
        guard info.outChannels > 0,
              let send = hndi_send_create(info.name, Int32(info.outChannels), Int32(rate)) else {
            log("NDI TX \"\(info.name)\": sender creation failed (needs ≥1 out channel)")
            return nil
        }
        self.send = send
        self.interfaceID = info.id
        self.tap = PoolTxTap(base: info.outBase, channels: info.outChannels, rate: rate)
        self.chunk = Int(rate / 100) // ~10 ms
        self.sampleRate = rate
        buffer = .allocate(capacity: chunk * info.outChannels)
        buffer.initialize(repeating: 0, count: chunk * info.outChannels)

        let thread = Thread { [weak self] in self?.sendLoop(name: info.name) }
        thread.name = "hydra.ndi.tx"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        log("NDI TX started: \"\(info.name)\" (\(info.outChannels)ch, pool \(info.outBase + 1)–\(info.outBase + info.outChannels))")
    }

    deinit {
        stop()
        buffer.deallocate()
    }

    func stop() {
        running = false
        thread = nil
    }

    private func sendLoop(name: String) {
        // Absolute-clock pacing at the engine rate: consuming faster than
        // real-time would drain the ring and interleave silence into the
        // stream; slower would overrun it.
        let interval = Double(chunk) / sampleRate
        var next = Date()
        while running {
            // The ring is fed by the RT thread on the engine clock; reading
            // resampled with equal rates just paces us to that clock.
            tap.ring.readResampled(into: buffer, frames: chunk)
            hndi_send_audio(send, buffer, Int32(chunk))
            next.addTimeInterval(interval)
            let delay = next.timeIntervalSinceNow
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            } else if delay < -0.25 {
                next = Date() // fell badly behind: resync
            }
        }
        hndi_send_destroy(send)
        send = nil
        log("NDI TX stopped: \"\(name)\"")
    }
}

// MARK: - NdiManager

final class NdiManager {

    private let store: MatrixStore
    private let queue = DispatchQueue(label: "hydra.ndi")
    private(set) var runtimeAvailable = false
    private var runtimeVersion: String?
    private var find: UnsafeMutableRawPointer?
    private var pollTimer: DispatchSourceTimer?

    /// Sources currently visible on the network: id → (name, url).
    private var discovered: [String: (name: String, url: String)] = [:]
    private var subscribedIDs: Set<String>
    /// All live receivers (registered with the engine only once ready).
    private var receivers: [String: NdiRx] = [:]
    private var senders: [UUID: NdiTx] = [:]
    var onChange: ((NdiPayload) -> Void)?

    private static let persistURL = hydraSupportURL("ndi.json")

    init(store: MatrixStore) {
        self.store = store
        if let data = try? Data(contentsOf: Self.persistURL),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            subscribedIDs = Set(ids)
        } else {
            subscribedIDs = []
        }
    }

    func start() {
        queue.sync {
            runtimeAvailable = hndi_load() == 1
            guard runtimeAvailable else {
                log("NDI runtime not found — install it from \(Hydra.ndiRedistURL) (NDI features stay off)")
                return
            }
            runtimeVersion = String(cString: hndi_version())
            log("NDI runtime loaded: \(runtimeVersion ?? "?")")
            find = hndi_find_create()

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 3)
            timer.setEventHandler { [weak self] in self?.pollLocked() }
            timer.resume()
            pollTimer = timer
        }
    }

    func setSubscribed(id: String, subscribed: Bool) {
        queue.sync {
            if subscribed { subscribedIDs.insert(id) } else { subscribedIDs.remove(id) }
            if let data = try? JSONEncoder().encode(Array(subscribedIDs).sorted()) {
                try? data.write(to: Self.persistURL, options: .atomic)
            }
            refreshRxLocked()
        }
    }

    /// Rebinds TX senders to the current interface list (create/delete/toggle).
    func syncTx(interfaces: [VirtualInterfaceInfo]) {
        queue.sync {
            guard runtimeAvailable else { return }
            let rate = BackplaneProbe.backplaneDeviceID()
                .map(BackplaneProbe.nominalSampleRate) ?? Hydra.defaultSampleRate
            let wanted = Dictionary(uniqueKeysWithValues:
                interfaces.filter(\.ndiTX).map { ($0.id, $0) })

            for (id, tx) in senders {
                let current = wanted[id]
                if current == nil || current!.outBase != tx.tap.base || current!.outChannels != tx.tap.channels {
                    tx.stop()
                    senders.removeValue(forKey: id)
                }
            }
            for (id, info) in wanted where senders[id] == nil {
                if let tx = NdiTx(interface: info, rate: rate) {
                    senders[id] = tx
                }
            }
            store.setPoolTxTaps(senders.values.map(\.tap))
        }
    }

    func payload() -> NdiPayload {
        queue.sync { payloadLocked() }
    }

    // MARK: Discovery (queue only)

    private func pollLocked() {
        guard let find else { return }
        var buffer = [hndi_source_t](repeating: hndi_source_t(), count: 64)
        let count = Int(hndi_find_sources(find, &buffer, 64))
        var fresh: [String: (name: String, url: String)] = [:]
        for i in 0..<count {
            let name = withUnsafeBytes(of: buffer[i].name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            let url = withUnsafeBytes(of: buffer[i].url) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            guard !name.isEmpty else { continue }
            fresh[name] = (name, url)
        }
        guard Set(fresh.keys) != Set(discovered.keys) else { return }
        let appeared = Set(fresh.keys).subtracting(discovered.keys)
        for id in appeared.sorted() {
            log("NDI source found: \"\(id)\"")
        }
        discovered = fresh
        refreshRxLocked()
    }

    private func refreshRxLocked() {
        let engineRate = BackplaneProbe.backplaneDeviceID()
            .map(BackplaneProbe.nominalSampleRate) ?? Hydra.defaultSampleRate
        let wanted = subscribedIDs.intersection(discovered.keys)

        for (id, rx) in receivers where !wanted.contains(id) {
            rx.stop()
            receivers.removeValue(forKey: id)
        }
        for id in wanted where receivers[id] == nil {
            guard let source = discovered[id],
                  let rx = NdiRx(sourceID: id, name: source.name, url: source.url,
                                 engineRate: engineRate) else { continue }
            rx.onReady = { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    self.registerReadyLocked()
                    self.broadcastLocked()  // format now known → update UI
                }
            }
            receivers[id] = rx
        }
        registerReadyLocked()
        broadcastLocked()
    }

    /// Only format-known receivers join the engine (ring exists, channel
    /// count fixed — snapshot buffer sizing stays consistent).
    private func registerReadyLocked() {
        let ready = receivers.values
            .filter { $0.inRing != nil }
            .sorted { $0.nodeID < $1.nodeID }
        store.setNdiTaps(ready)
    }

    private func payloadLocked() -> NdiPayload {
        let sources = discovered.keys.sorted().map { id -> NdiSourceInfo in
            let rx = receivers[id]
            return NdiSourceInfo(id: id,
                                 name: discovered[id]?.name ?? id,
                                 url: discovered[id]?.url ?? "",
                                 channels: rx?.inChannels ?? 0,
                                 sampleRate: rx?.sampleRate ?? 0,
                                 subscribed: subscribedIDs.contains(id))
        }
        return NdiPayload(runtimeAvailable: runtimeAvailable,
                          runtimeVersion: runtimeVersion,
                          sources: sources)
    }

    private func broadcastLocked() {
        onChange?(payloadLocked())
    }
}
