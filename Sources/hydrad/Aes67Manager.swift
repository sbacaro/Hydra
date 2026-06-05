// Hydra Audio — GPL-3.0
// AES67 reception — "the Controller" (Phase 4).
//
// Two independent discoveries (Section 5.5):
// - Presence: passive Bonjour browsing of Dante's `_netaudio-*._udp` services
//   → who is on the network.
// - Streams: SAP listener on 239.255.255.255:9875 carrying SDP descriptions
//   → what can be subscribed.
// Cross-reference: device announcing SAP → "AES67 On"; present without SAP →
// "AES67 Offline" (informative only: enabling AES67 happens in Dante
// Controller, not here).
//
// RX: subscribing a stream joins its multicast group, parses RTP (L24/L16 →
// Float32) and feeds a ChannelRing — the same consumer-side ASRC path as
// physical devices, so reception needs no PTP (Section 5.6: RX tolerates
// imperfection; TX is Phase 5).

import Foundation
import Network
import HydraCore

// MARK: - Aes67Rx: one subscribed stream feeding the engine

final class Aes67Rx: EngineTap {
    let nodeID: String
    let stream: Aes67Stream
    let inChannels: Int
    let outChannels: Int = 0
    let inRing: ChannelRing?
    let outRing: ChannelRing? = nil
    let inStaging: UnsafeMutablePointer<Float>?
    let outStaging: UnsafeMutablePointer<Float>? = nil

    private var group: NWConnectionGroup?
    private let queue = DispatchQueue(label: "hydra.aes67.rx")
    private let scratch: UnsafeMutablePointer<Float>
    private let bytesPerSample: Int

    init?(stream: Aes67Stream, engineRate: Double) {
        self.stream = stream
        self.nodeID = stream.nodeID
        self.inChannels = stream.channels
        self.bytesPerSample = stream.encoding == "L16" ? 2 : 3

        let staging = UnsafeMutablePointer<Float>.allocate(capacity: Hydra.maxIOFrames * stream.channels)
        staging.initialize(repeating: 0, count: Hydra.maxIOFrames * stream.channels)
        inStaging = staging
        scratch = .allocate(capacity: Hydra.maxIOFrames * stream.channels)
        scratch.initialize(repeating: 0, count: Hydra.maxIOFrames * stream.channels)
        inRing = ChannelRing(channels: stream.channels,
                             producerRate: stream.sampleRate,
                             consumerRate: engineRate)

        guard let port = NWEndpoint.Port(rawValue: stream.port),
              let multicast = try? NWMulticastGroup(for: [
                .hostPort(host: NWEndpoint.Host(stream.address), port: port)
              ]) else {
            log("AES67 RX \"\(stream.name)\": invalid multicast endpoint \(stream.address):\(stream.port)")
            staging.deallocate()
            scratch.deallocate()
            return nil
        }

        let group = NWConnectionGroup(with: multicast, using: .udp)
        group.setReceiveHandler(maximumMessageSize: 65536, rejectOversizedMessages: true) { [weak self] _, content, _ in
            if let content {
                self?.handleRTP(content)
            }
        }
        group.stateUpdateHandler = { state in
            switch state {
            case .ready:
                log("AES67 RX joined \(stream.address):\(stream.port) — \"\(stream.name)\" (\(stream.channels)ch \(stream.encoding) @ \(Int(stream.sampleRate)) Hz)")
            case .failed(let error):
                log("AES67 RX \"\(stream.name)\" failed: \(error)")
            default:
                break
            }
        }
        self.group = group
        group.start(queue: queue)
    }

    deinit {
        stop()
        inStaging?.deallocate()
        scratch.deallocate()
    }

    func stop() {
        group?.cancel()
        group = nil
    }

    /// Parses an RTP datagram and writes the PCM into the ring (queue thread —
    /// the ring is the SPSC boundary to the audio thread).
    private func handleRTP(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count > 12 else { return }
        let version = bytes[0] >> 6
        guard version == 2 else { return }
        let hasExtension = (bytes[0] & 0x10) != 0
        let csrcCount = Int(bytes[0] & 0x0F)
        var offset = 12 + csrcCount * 4
        if hasExtension {
            guard bytes.count >= offset + 4 else { return }
            let extWords = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4 + extWords * 4
        }
        guard bytes.count > offset else { return }

        let payloadBytes = bytes.count - offset
        let frameBytes = bytesPerSample * inChannels
        let frames = min(payloadBytes / frameBytes, Hydra.maxIOFrames)
        guard frames > 0, let ring = inRing else { return }

        // Big-endian linear PCM → Float32.
        if bytesPerSample == 3 {
            for i in 0..<(frames * inChannels) {
                let b = offset + i * 3
                var value = Int32(bytes[b]) << 16 | Int32(bytes[b + 1]) << 8 | Int32(bytes[b + 2])
                if value >= 0x800000 { value -= 0x1000000 } // sign-extend 24-bit
                scratch[i] = Float(value) / 8_388_608.0
            }
        } else {
            for i in 0..<(frames * inChannels) {
                let b = offset + i * 2
                let value = Int16(bitPattern: UInt16(bytes[b]) << 8 | UInt16(bytes[b + 1]))
                scratch[i] = Float(value) / 32_768.0
            }
        }
        ring.write(from: scratch, frames: frames)
    }
}

// MARK: - Aes67Manager

final class Aes67Manager {

    private let store: MatrixStore
    private let queue = DispatchQueue(label: "hydra.aes67")
    private var browsers: [NWBrowser] = []
    private var sapListener: NWConnectionGroup?
    /// Device names seen via mDNS.
    private var presentDevices: Set<String> = []
    /// Stream ID → (stream, last announcement time).
    private var streams: [String: (stream: Aes67Stream, lastSeen: Date)] = [:]
    private var subscribedIDs: Set<String>
    private var active: [String: Aes67Rx] = [:]   // stream ID → RX
    var onChange: ((Aes67Payload) -> Void)?

    private static let persistURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hydra", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("aes67.json")
    }()

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
        startBrowsing()
        startSAPListener()
        // Expire stale streams (SAP re-announces periodically).
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            self?.expireStaleLocked()
        }
        timer.resume()
        expiryTimer = timer
    }
    private var expiryTimer: DispatchSourceTimer?

    func setSubscribed(id: String, subscribed: Bool) {
        queue.sync {
            if subscribed { subscribedIDs.insert(id) } else { subscribedIDs.remove(id) }
            if let data = try? JSONEncoder().encode(Array(subscribedIDs).sorted()) {
                try? data.write(to: Self.persistURL, options: .atomic)
            }
            refreshLocked()
        }
    }

    func payload() -> Aes67Payload {
        queue.sync { payloadLocked() }
    }

    // MARK: Presence (mDNS / Bonjour)

    private func startBrowsing() {
        // Dante devices advertise several _netaudio-* services; ARC is the
        // most universal for presence.
        for type in ["_netaudio-arc._udp", "_netaudio-chan._udp"] {
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: parameters)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.queue.async {
                    self?.updatePresence(results)
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    log("AES67 browser (\(type)) failed: \(error)")
                }
            }
            browser.start(queue: queue)
            browsers.append(browser)
        }
    }

    private func updatePresence(_ results: Set<NWBrowser.Result>) {
        var names: Set<String> = []
        for result in results {
            if case .service(let name, _, _, _) = result.endpoint {
                names.insert(name)
            }
        }
        // Union across browsers: collect from all current browser results.
        // (Names disappear when devices go offline — browsers push fresh sets.)
        presentDevices = names.union(
            browsers.flatMap { browser in
                browser.browseResults.compactMap { result -> String? in
                    if case .service(let name, _, _, _) = result.endpoint { return name }
                    return nil
                }
            })
        broadcastLocked()
    }

    // MARK: Streams (SAP/SDP)

    private func startSAPListener() {
        guard let port = NWEndpoint.Port(rawValue: Hydra.sapPort),
              let multicast = try? NWMulticastGroup(for: [
                .hostPort(host: NWEndpoint.Host(Hydra.sapAddress), port: port)
              ]) else {
            log("AES67: could not form SAP multicast group")
            return
        }
        let listener = NWConnectionGroup(with: multicast, using: .udp)
        listener.setReceiveHandler(maximumMessageSize: 65536, rejectOversizedMessages: true) { [weak self] _, content, _ in
            guard let self, let content else { return }
            self.handleSAP(content)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                log("AES67: SAP listener on \(Hydra.sapAddress):\(Hydra.sapPort)")
            case .failed(let error):
                log("AES67: SAP listener failed: \(error)")
            default:
                break
            }
        }
        listener.start(queue: queue)
        sapListener = listener
    }

    /// Runs on `queue` (receive handler queue).
    private func handleSAP(_ data: Data) {
        guard let announcement = SAPParser.parse(data) else { return }
        guard let stream = SDPParser.parseStream(sdp: announcement.sdp,
                                                 origin: announcement.originAddress) else { return }
        if announcement.isDeletion {
            if streams.removeValue(forKey: stream.id) != nil {
                refreshLocked()
            }
            return
        }
        let isNew = streams[stream.id] == nil || streams[stream.id]?.stream != stream
        streams[stream.id] = (stream, Date())
        if isNew {
            log("AES67 stream announced: \"\(stream.name)\" \(stream.channels)ch \(stream.encoding) @ \(Int(stream.sampleRate)) Hz (\(stream.address):\(stream.port))")
            refreshLocked()
        }
    }

    private func expireStaleLocked() {
        let cutoff = Date().addingTimeInterval(-Hydra.sapExpirySeconds)
        let stale = streams.filter { $0.value.lastSeen < cutoff }.map(\.key)
        guard !stale.isEmpty else { return }
        for id in stale {
            streams.removeValue(forKey: id)
        }
        refreshLocked()
    }

    // MARK: State assembly (queue only)

    private func payloadLocked() -> Aes67Payload {
        // Cross-reference: a device is "AES67 On" when any announced stream's
        // session name mentions it (Dante embeds the device name) — honest
        // approximation documented in the foundation doc, Section 5.5.
        let streamList = streams.values
            .map { entry -> Aes67Stream in
                var s = entry.stream
                s.subscribed = subscribedIDs.contains(s.id)
                return s
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let devices = presentDevices.sorted().map { name in
            Aes67Device(name: name,
                        aes67On: streamList.contains { $0.name.localizedCaseInsensitiveContains(name) })
        }
        return Aes67Payload(devices: devices, streams: streamList)
    }

    private func refreshLocked() {
        let engineRate = BackplaneProbe.backplaneDeviceID()
            .map(BackplaneProbe.nominalSampleRate) ?? Hydra.defaultSampleRate

        let wanted = streams.values
            .map(\.stream)
            .filter { subscribedIDs.contains($0.id) }
        let wantedByID = Dictionary(uniqueKeysWithValues: wanted.map { ($0.id, $0) })

        // Drop RX for unsubscribed/vanished/changed streams.
        for (id, rx) in active {
            let current = wantedByID[id]
            if current == nil || current.map({ $0 != rx.stream }) == true {
                rx.stop()
                active.removeValue(forKey: id)
            }
        }
        // Join newly subscribed streams.
        for (id, stream) in wantedByID where active[id] == nil {
            if let rx = Aes67Rx(stream: stream, engineRate: engineRate) {
                active[id] = rx
            }
        }

        store.setNetTaps(active.values.sorted { $0.nodeID < $1.nodeID })
        broadcastLocked()
    }

    private func broadcastLocked() {
        onChange?(payloadLocked())
    }
}
