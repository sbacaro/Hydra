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

// MARK: - MulticastReceiver: BSD-socket multicast RX

/// Classic socket + IGMP join. NWConnectionGroup reported `.ready` but its
/// join was never effective on a bridged VM network (packets reached the
/// host kernel — verified with a raw socket — yet the handler never fired;
/// diagnosed 2026-06-05 with the Tests/Emulation rig). SAP and RTP RX use
/// this instead.
final class MulticastReceiver {
    private let fd: Int32
    private let source: DispatchSourceRead

    init?(address: String, port: UInt16, queue: DispatchQueue,
          handler: @escaping (Data) -> Void) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        // Join on EVERY IPv4 interface (INADDR_ANY joins only the default
        // multicast route, which may not be where the packets arrive).
        var joins = 0
        for ifaceIP in Self.localIPv4Interfaces() + ["0.0.0.0"] {
            var mreq = ip_mreq()
            mreq.imr_multiaddr.s_addr = inet_addr(address)
            mreq.imr_interface.s_addr = inet_addr(ifaceIP)
            if ifaceIP == "0.0.0.0" { mreq.imr_interface.s_addr = INADDR_ANY }
            if setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq,
                          socklen_t(MemoryLayout<ip_mreq>.size)) == 0 {
                joins += 1
                log("Multicast \(address):\(port): joined via \(ifaceIP)")
            } else if errno != EADDRINUSE {   // already joined on that iface
                log("Multicast \(address):\(port): join via \(ifaceIP) failed (errno \(errno))")
            }
        }
        guard bound == 0, joins > 0,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK) != -1 else {
            close(fd)
            return nil
        }

        self.fd = fd
        var loggedFirst = false
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = recv(fd, &buffer, buffer.count, 0)
                guard n > 0 else { break }   // EWOULDBLOCK drains the loop
                if !loggedFirst {
                    loggedFirst = true
                    log("Multicast \(address):\(port): receiving (first datagram \(n) bytes)")
                }
                handler(Data(buffer[0..<n]))
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    /// IPv4 addresses of all up, non-loopback interfaces.
    private static func localIPv4Interfaces() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  (flags & IFF_MULTICAST) != 0,
                  let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                result.append(host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
            }
        }
        return result
    }

    func stop() {
        source.cancel()
    }

    deinit {
        if !source.isCancelled { source.cancel() }
    }
}

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

    private var receiver: MulticastReceiver?
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

        receiver = MulticastReceiver(address: stream.address, port: stream.port,
                                     queue: queue) { [weak self] data in
            self?.handleRTP(data)
        }
        guard receiver != nil else {
            log("AES67 RX \"\(stream.name)\": could not join \(stream.address):\(stream.port)")
            staging.deallocate()
            scratch.deallocate()
            return nil
        }
        log("AES67 RX joined \(stream.address):\(stream.port) — \"\(stream.name)\" (\(stream.channels)ch \(stream.encoding) @ \(Int(stream.sampleRate)) Hz)")
    }

    deinit {
        stop()
        inStaging?.deallocate()
        scratch.deallocate()
    }

    func stop() {
        receiver?.stop()
        receiver = nil
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
        // Guard against a malformed/0-channel stream causing divide-by-zero.
        guard frameBytes > 0 else { return }
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

final class Aes67Manager: @unchecked Sendable {

    private let store: MatrixStore
    private let queue = DispatchQueue(label: "hydra.aes67")
    private var browsers: [NWBrowser] = []
    private var sapListener: MulticastReceiver?
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
                self?.queue.async { [weak self] in
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
        sapListener = MulticastReceiver(address: Hydra.sapAddress, port: Hydra.sapPort,
                                        queue: queue) { [weak self] data in
            self?.handleSAP(data)
        }
        if sapListener != nil {
            log("AES67: SAP listener on \(Hydra.sapAddress):\(Hydra.sapPort)")
        } else {
            log("AES67: SAP listener failed (socket/join error)")
        }
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

        // `_netaudio-chan` advertises ONE instance PER CHANNEL ("01@device"):
        // collapse those into a single device entry with a channel count.
        var channelCounts: [String: Int] = [:]
        var deviceNames: Set<String> = []
        for raw in presentDevices {
            if let at = raw.firstIndex(of: "@"),
               raw[..<at].allSatisfy(\.isNumber), at != raw.startIndex {
                let device = String(raw[raw.index(after: at)...])
                guard !device.isEmpty else { continue }
                deviceNames.insert(device)
                channelCounts[device, default: 0] += 1
            } else {
                deviceNames.insert(raw)
            }
        }
        let devices = deviceNames.sorted().map { name in
            Aes67Device(name: name,
                        aes67On: streamList.contains { $0.name.localizedCaseInsensitiveContains(name) },
                        channels: channelCounts[name] ?? 0)
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
