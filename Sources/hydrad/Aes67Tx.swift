// Hydra Audio — GPL-3.0
// AES67 transmit (Phase 5, first slice): a virtual interface's Out side is
// announced via SAP/SDP and sent as multicast RTP (L24, 1 ms packets).
//
// EXPERIMENTAL until PTP sync lands: RTP timestamps run on the engine's
// sample clock with no IEEE 1588 alignment, so strict receivers may show
// clock warnings or refuse to lock. Announcement/visibility (the "appears
// in Dante Controller as an AES67 flow" part) is fully functional.

import Foundation
import Synchronization
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
                address = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                break
            }
        }
        pointer = current.pointee.ifa_next
    }
    return address
}

// MARK: - Aes67Tx: one transmitting interface

final class Aes67Tx: @unchecked Sendable {
    let info: Aes67TxInfo
    let tap: PoolTxTap

    private let sampleRate: Double
    private var rtp: NWConnection?
    private var sap: NWConnection?
    private var thread: Thread?
    private var sapTimer: DispatchSourceTimer?
    private let running = Atomic<Bool>(true)
    private let queue = DispatchQueue(label: "hydra.aes67.tx")
    private let threadExitSemaphore = DispatchSemaphore(value: 0)
    private let packetFrames = 48 // 1 ms @ 48 kHz (AES67 class A)
    private let pcm: UnsafeMutablePointer<Float>
    private var sequence: UInt16 = .random(in: 0...UInt16.max)
    private var timestamp: UInt32 = .random(in: 0...UInt32.max)
    /// Set when PTP (re)locks: the next packet realigns its RTP timestamp
    /// to the network clock (ts ≡ PTP seconds × rate, AES67 media clock).
    private var needsPtpAlign = true
    private var ptpAligned = false
    private let ssrc: UInt32 = .random(in: 0...UInt32.max)
    private let originIP: String

    /// One 8-channel flow (slice `flowIndex`) of the interface's Out side.
    init?(interface iface: VirtualInterfaceInfo, flowIndex: Int, rate: Double) {
        let start = flowIndex * 8
        let channels = min(iface.outChannels - start, 8)
        guard channels > 0 else { return nil }
        // Flow name carries the channel range when the interface spans
        // several flows ("Stage 1\u{2013}8", "Stage 9\u{2013}16", …).
        let name = iface.outChannels <= 8
            ? iface.name
            : "\(iface.name) \(start + 1)\u{2013}\(start + channels)"
        // Deterministic multicast group from the interface identity + slice
        // (239.69.x.y — the AES67 convention range).
        let bytes = [UInt8](iface.id.uuidString.utf8)
        let x = max(1, bytes[0] % 254)
        let y = max(1, UInt8((Int(bytes[1]) + flowIndex) % 254))
        let address = "239.69.\(x).\(y)"

        self.info = Aes67TxInfo(interfaceID: iface.id, name: name,
                                channels: channels, address: address, port: 5004,
                                flowIndex: flowIndex)
        self.tap = PoolTxTap(base: iface.outBase + start, channels: channels, rate: rate)
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

        log("AES67 TX started: \"\(name)\" → \(address):5004 (\(channels)ch L24 @ \(Int(rate)) Hz) — experimental, no PTP yet")
    }

    deinit {
        pcm.deallocate()
    }

    func stop() {
        sendSAP(deletion: true)
        if running.load(ordering: .relaxed) {
            running.store(false, ordering: .relaxed)
            threadExitSemaphore.wait()
        }
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
        while running.load(ordering: .relaxed) {
            tap.ring.readResampled(into: pcm, frames: packetFrames)

            // AES67 media clock: when the PTP slave is locked, RTP
            // timestamps follow the network clock (aligned once per lock —
            // free-runs from there on our sample clock; receivers' buffers
            // absorb the residual drift).
            if needsPtpAlign, let ptpNow = PtpClock.shared.ptpTimeNow() {
                timestamp = UInt32(truncatingIfNeeded:
                    Int64((ptpNow * sampleRate).rounded()))
                needsPtpAlign = false
                ptpAligned = true
                log("AES67 TX \"\(info.name)\": RTP timestamps aligned to PTP")
            }

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
        threadExitSemaphore.signal()
    }

    // MARK: SAP/SDP

    /// Real grandmaster when locked; zeros (traceability unknown) otherwise.
    private var ptpRefclk: String {
        let status = PtpClock.shared.status()
        return status.locked
            ? "\(status.grandmaster):\(status.domain)"
            : "00-00-00-00-00-00-00-00:0"
    }

    /// Called by the manager when PTP lock changes.
    func ptpChanged(locked: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if locked && !self.ptpAligned {
                self.needsPtpAlign = true
            }
            self.sendSAP(deletion: false)   // refresh SDP refclk immediately
        }
    }

    private var sdp: String {
        """
        v=0\r
        o=- \(abs((info.interfaceID.hashValue &+ info.flowIndex) % 1_000_000_000)) 0 IN IP4 \(originIP)\r
        s=\(info.name) (Hydra)\r
        c=IN IP4 \(info.address)/32\r
        t=0 0\r
        m=audio \(info.port) RTP/AVP 96\r
        i=\(info.channels) channels\r
        a=rtpmap:96 L24/\(Int(sampleRate))/\(info.channels)\r
        a=recvonly\r
        a=ptime:1\r
        a=ts-refclk:ptp=IEEE1588-2008:\(ptpRefclk)\r
        a=mediaclk:direct=0\r
        """
    }

    private func sendSAP(deletion: Bool) {
        var packet = [UInt8]()
        packet.append(deletion ? 0x24 : 0x20)  // V=1, IPv4, (T=deletion)
        packet.append(0)                       // no auth
        let hash = UInt16(truncatingIfNeeded: info.interfaceID.hashValue &+ info.flowIndex)
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
    private var senders: [String: Aes67Tx] = [:]   // "interfaceID:flowIndex" 
    /// Called when the set of transmitters changes.
    var onChange: (() -> Void)?

    init(store: MatrixStore) {
        self.store = store
    }

    func flows() -> [Aes67TxInfo] {
        queue.sync { senders.values.map(\.info).sorted { $0.name < $1.name } }
    }

    /// PTP lock transitions: realign running flows + refresh their SDP.
    func ptpChanged(locked: Bool) {
        queue.sync {
            for tx in senders.values {
                tx.ptpChanged(locked: locked)
            }
        }
    }

    /// Rebinds transmitters to the current interface list. Interfaces wider
    /// than 8 channels are announced as several flows (the AES67 limit).
    func syncTx(interfaces: [VirtualInterfaceInfo]) {
        var changed = false
        queue.sync {
            let rate = BackplaneProbe.backplaneDeviceID()
                .map(BackplaneProbe.nominalSampleRate) ?? Hydra.defaultSampleRate
            // Desired flows: (key, interface, flowIndex).
            var wanted: [String: (iface: VirtualInterfaceInfo, flow: Int)] = [:]
            for iface in interfaces where iface.aes67TX && iface.outChannels > 0 {
                let flowCount = (iface.outChannels + 7) / 8
                for flow in 0..<flowCount {
                    wanted["\(iface.id.uuidString):\(flow)"] = (iface, flow)
                }
            }

            for (key, tx) in senders {
                if let (iface, flow) = wanted[key] {
                    let start = flow * 8
                    let channels = min(iface.outChannels - start, 8)
                    if iface.outBase + start == tx.tap.base && channels == tx.tap.channels {
                        continue   // unchanged
                    }
                }
                tx.stop()
                senders.removeValue(forKey: key)
                changed = true
            }
            for (key, want) in wanted where senders[key] == nil {
                if let tx = Aes67Tx(interface: want.iface, flowIndex: want.flow, rate: rate) {
                    senders[key] = tx
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
