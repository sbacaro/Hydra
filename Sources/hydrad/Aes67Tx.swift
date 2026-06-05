// Hydra Audio — GPL-3.0
// AES67 transmit (Phase 5, first slice): a virtual interface's Out side is
// announced via SAP/SDP and sent as multicast RTP (L24, 1 ms packets).
//
// EXPERIMENTAL until PTP sync lands: RTP timestamps run on the engine's
// sample clock with no IEEE 1588 alignment, so strict receivers may show
// clock warnings or refuse to lock. Announcement/visibility (the "appears
// in Dante Controller as an AES67 flow" part) is fully functional.

import Foundation
import Network
import HydraCore

// MARK: - Local IPv4 (for SAP/SDP origin)

func localIPv4Address() -> String {
    var address = "0.0.0.0"
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return address }
    defer { freeifaddrs(list) }
    var pointer: UnsafeMutablePointer<ifaddrs>? = first
    while let current = pointer {
        let flags = Int32(current.pointee.ifa_flags)
        if let sa = current.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
           (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                address = String(cString: host)
                break
            }
        }
        pointer = current.pointee.ifa_next
    }
    return address
}

// MARK: - Aes67Tx: one transmitting interface

final class Aes67Tx {
    let info: Aes67TxInfo
    let tap: PoolTxTap

    private let sampleRate: Double
    private var rtp: NWConnection?
    private var sap: NWConnection?
    private var thread: Thread?
    private var sapTimer: DispatchSourceTimer?
    private var running = true
    private let queue = DispatchQueue(label: "hydra.aes67.tx")
    private let packetFrames = 48 // 1 ms @ 48 kHz (AES67 class A)
    private let pcm: UnsafeMutablePointer<Float>
    private var sequence: UInt16 = .random(in: 0...UInt16.max)
    private var timestamp: UInt32 = .random(in: 0...UInt32.max)
    private let ssrc: UInt32 = .random(in: 0...UInt32.max)
    private let originIP: String

    init?(interface iface: VirtualInterfaceInfo, rate: Double) {
        guard iface.outChannels > 0 else { return nil }
        // AES67 flows carry up to 8 channels; cap honestly and log.
        let channels = min(iface.outChannels, 8)
        if channels != iface.outChannels {
            log("AES67 TX \"\(iface.name)\": capped at 8 of \(iface.outChannels) channels (AES67 flow limit)")
        }
        // Deterministic multicast group from the interface identity
        // (239.69.x.y — the AES67 convention range).
        let bytes = [UInt8](iface.id.uuidString.utf8)
        let x = max(1, bytes[0] % 254)
        let y = max(1, bytes[1] % 254)
        let address = "239.69.\(x).\(y)"

        self.info = Aes67TxInfo(interfaceID: iface.id, name: iface.name,
                                channels: channels, address: address, port: 5004)
        self.tap = PoolTxTap(base: iface.outBase, channels: channels, rate: rate)
        self.sampleRate = rate
        self.originIP = localIPv4Address()
        pcm = .allocate(capacity: packetFrames * channels)
        pcm.initialize(repeating: 0, count: packetFrames * channels)

        rtp = NWConnection(host: NWEndpoint.Host(address), port: 5004, using: .udp)
        rtp?.start(queue: queue)
        sap = NWConnection(host: NWEndpoint.Host(Hydra.sapAddress),
                           port: NWEndpoint.Port(rawValue: Hydra.sapPort)!, using: .udp)
        sap?.start(queue: queue)

        let thread = Thread { [weak self] in self?.sendLoop() }
        thread.name = "hydra.aes67.tx"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()

        // SAP announce now + every 30 s (RFC 2974 re-announce).
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 30)
        timer.setEventHandler { [weak self] in self?.sendSAP(deletion: false) }
        timer.resume()
        sapTimer = timer

        log("AES67 TX started: \"\(iface.name)\" → \(address):5004 (\(channels)ch L24 @ \(Int(rate)) Hz) — experimental, no PTP yet")
    }

    deinit {
        pcm.deallocate()
    }

    func stop() {
        sendSAP(deletion: true)
        running = false
        thread = nil
        sapTimer?.cancel()
        sapTimer = nil
        queue.asyncAfter(deadline: .now() + 0.2) { [rtp, sap] in
            rtp?.cancel()
            sap?.cancel()
        }
        log("AES67 TX stopped: \"\(info.name)\"")
    }

    // MARK: RTP (sender thread)

    private func sendLoop() {
        let channels = info.channels
        let interval = Double(packetFrames) / sampleRate
        var next = Date()
        while running {
            tap.ring.readResampled(into: pcm, frames: packetFrames)

            var packet = [UInt8]()
            packet.reserveCapacity(12 + packetFrames * channels * 3)
            packet.append(0x80)                       // V=2
            packet.append(96)                         // PT 96 (dynamic, L24)
            packet.append(UInt8(sequence >> 8))
            packet.append(UInt8(sequence & 0xFF))
            for shift in stride(from: 24, through: 0, by: -8) {
                packet.append(UInt8((timestamp >> UInt32(shift)) & 0xFF))
            }
            for shift in stride(from: 24, through: 0, by: -8) {
                packet.append(UInt8((ssrc >> UInt32(shift)) & 0xFF))
            }
            for i in 0..<(packetFrames * channels) {
                let clamped = max(-1.0, min(1.0, pcm[i]))
                let value = Int32(clamped * 8_388_607.0)
                packet.append(UInt8((value >> 16) & 0xFF))
                packet.append(UInt8((value >> 8) & 0xFF))
                packet.append(UInt8(value & 0xFF))
            }
            sequence &+= 1
            timestamp &+= UInt32(packetFrames)

            rtp?.send(content: Data(packet), completion: .idempotent)

            next.addTimeInterval(interval)
            let delay = next.timeIntervalSinceNow
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            } else if delay < -0.25 {
                next = Date() // fell badly behind (VM hiccup): resync
            }
        }
    }

    // MARK: SAP/SDP

    private var sdp: String {
        """
        v=0\r
        o=- \(abs(info.interfaceID.hashValue % 1_000_000_000)) 0 IN IP4 \(originIP)\r
        s=\(info.name) (Hydra)\r
        c=IN IP4 \(info.address)/32\r
        t=0 0\r
        m=audio \(info.port) RTP/AVP 96\r
        i=\(info.channels) channels\r
        a=rtpmap:96 L24/\(Int(sampleRate))/\(info.channels)\r
        a=recvonly\r
        a=ptime:1\r
        a=ts-refclk:ptp=IEEE1588-2008:00-00-00-00-00-00-00-00:0\r
        a=mediaclk:direct=0\r
        """
    }

    private func sendSAP(deletion: Bool) {
        var packet = [UInt8]()
        packet.append(deletion ? 0x24 : 0x20)  // V=1, IPv4, (T=deletion)
        packet.append(0)                       // no auth
        let hash = UInt16(truncatingIfNeeded: info.interfaceID.hashValue)
        packet.append(UInt8(hash >> 8))
        packet.append(UInt8(hash & 0xFF))
        let parts = originIP.split(separator: ".").compactMap { UInt8($0) }
        packet.append(contentsOf: parts.count == 4 ? parts : [0, 0, 0, 0])
        packet.append(contentsOf: Array("application/sdp".utf8))
        packet.append(0)
        packet.append(contentsOf: Array(sdp.utf8))
        sap?.send(content: Data(packet), completion: .idempotent)
    }
}

// MARK: - Aes67TxManager

final class Aes67TxManager {

    private let store: MatrixStore
    private let queue = DispatchQueue(label: "hydra.aes67.txmanager")
    private var senders: [UUID: Aes67Tx] = [:]
    /// Called when the set of transmitters changes.
    var onChange: (() -> Void)?

    init(store: MatrixStore) {
        self.store = store
    }

    func flows() -> [Aes67TxInfo] {
        queue.sync { senders.values.map(\.info).sorted { $0.name < $1.name } }
    }

    /// Rebinds transmitters to the current interface list.
    func syncTx(interfaces: [VirtualInterfaceInfo]) {
        var changed = false
        queue.sync {
            let rate = BackplaneProbe.backplaneDeviceID()
                .map(BackplaneProbe.nominalSampleRate) ?? Hydra.defaultSampleRate
            let wanted = Dictionary(uniqueKeysWithValues:
                interfaces.filter { $0.aes67TX && $0.outChannels > 0 }.map { ($0.id, $0) })

            for (id, tx) in senders {
                let current = wanted[id]
                if current == nil || current!.outBase != tx.tap.base
                    || min(current!.outChannels, 8) != tx.tap.channels {
                    tx.stop()
                    senders.removeValue(forKey: id)
                    changed = true
                }
            }
            for (id, iface) in wanted where senders[id] == nil {
                if let tx = Aes67Tx(interface: iface, rate: rate) {
                    senders[id] = tx
                    changed = true
                }
            }
            store.setAesTxTaps(senders.values.map(\.tap))
        }
        if changed {
            onChange?()
        }
    }
}
