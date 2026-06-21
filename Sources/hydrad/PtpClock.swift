// Hydra Audio — GPL-3.0
// PTP slave (IEEE 1588-2008, "PTPv2") — Phase 5.
//
// Listens to the PTP multicast domain that every AES67/Dante network runs
// (224.0.1.129, event port 319 / general port 320), elects the grandmaster
// from Announce messages (minimal BMCA: best (priority1, clockClass,
// accuracy, variance, priority2, GMID) tuple wins), and tracks the offset
// between the master's clock and the local monotonic clock from
// Sync/Follow_Up timestamps.
//
// HONEST LIMITS (documented, not hidden):
// - Software timestamps only: accuracy is in the tens-to-hundreds of µs,
//   not the ns of hardware PTP. Good enough to discipline RTP timestamps
//   so AES67 receivers accept the stream's clock; NOT a measurement-grade
//   PTP implementation.
// - No Delay_Req/Delay_Resp exchange (path delay treated as 0): on a LAN
//   the one-way delay is far below software-timestamp noise anyway.
//
// The offset estimator keeps a sliding window of (t1 - t2) samples — t1 =
// master origin timestamp, t2 = local receive time — and publishes the
// MEDIAN (robust against scheduling spikes).

import Foundation
import Synchronization
import HydraCore

struct PtpStatus: Equatable {
    var locked = false
    /// Grandmaster identity, "XX-XX-XX-XX-XX-XX-XX-XX" (EUI-64).
    var grandmaster = ""
    var domain: UInt8 = 0
    /// PTP-minus-host-monotonic offset (seconds) — diagnostics only.
    var offset: Double = 0
}

final class PtpClock: @unchecked Sendable {

    static let shared = PtpClock()

    private let queue = DispatchQueue(label: "hydra.ptp")
    private var eventRx: MulticastReceiver?
    private var generalRx: MulticastReceiver?
    private var expiryTimer: DispatchSourceTimer?

    /// Called when lock state / grandmaster changes (NOT on every Sync).
    var onChange: ((PtpStatus) -> Void)?

    // Master election (queue only)
    private struct Master {
        var dataset: [UInt8]   // comparable BMCA tuple
        var grandmaster: String
        var domain: UInt8
        var lastAnnounce: UInt64
    }
    private var master: Master?

    // Offset tracking (queue only)
    private var pendingSync: (seq: UInt16, t2: UInt64, source: [UInt8])?
    private var offsetWindow: [Double] = []
    private var lastSyncAt: UInt64 = 0
    private var published = PtpStatus()

    // Lock-free snapshot for the RT/sender threads.
    private struct Snapshot {
        var locked = false
        var offset: Double = 0   // PTP seconds = hostSeconds + offset
    }
    private let snapshot = Mutex<Snapshot>(Snapshot())

    // MARK: Public clock API

    /// Current PTP time in seconds (TAI epoch 1970), or nil when unlocked.
    /// Safe from any thread.
    func ptpTimeNow() -> Double? {
        let snap = snapshot.withLock { $0 }
        guard snap.locked else { return nil }
        return Self.hostSeconds() + snap.offset
    }

    func status() -> PtpStatus {
        queue.sync { published }
    }

    // MARK: Lifecycle

    func start() {
        eventRx = MulticastReceiver(address: "224.0.1.129", port: 319,
                                    queue: queue) { [weak self] data in
            self?.handle(data)
        }
        generalRx = MulticastReceiver(address: "224.0.1.129", port: 320,
                                      queue: queue) { [weak self] data in
            self?.handle(data)
        }
        if eventRx == nil && generalRx == nil {
            log("PTP: could not open sockets (319/320) — TX stays on the free-running clock")
            return
        }
        log("PTP: listening on 224.0.1.129:319/320 (software-timestamp slave)")

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.expireLocked() }
        timer.resume()
        expiryTimer = timer
    }

    // MARK: Wire parsing (queue only)

    private static func hostNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    }
    private static func hostSeconds() -> Double {
        Double(hostNanos()) / 1_000_000_000
    }

    private func handle(_ data: Data) {
        let t2 = Self.hostNanos()
        let bytes = [UInt8](data)
        guard bytes.count >= 34, bytes[1] & 0x0F == 2 else { return } // PTPv2 only
        let type = bytes[0] & 0x0F
        let domain = bytes[4]
        if let master, domain != master.domain, type != 0xB { return }

        switch type {
        case 0xB: handleAnnounce(bytes, domain: domain)
        case 0x0: handleSync(bytes, t2: t2)
        case 0x8: handleFollowUp(bytes)
        default: break
        }
    }

    private func sourceIdentity(_ b: [UInt8]) -> [UInt8] { Array(b[20..<28]) }

    private static func formatIdentity(_ id: ArraySlice<UInt8>) -> String {
        id.map { String(format: "%02X", $0) }.joined(separator: "-")
    }

    /// 10-byte PTP timestamp at `offset`: 6-byte seconds + 4-byte nanos.
    private func timestamp(_ b: [UInt8], at offset: Int) -> Double? {
        guard b.count >= offset + 10 else { return nil }
        var seconds: UInt64 = 0
        for i in 0..<6 { seconds = (seconds << 8) | UInt64(b[offset + i]) }
        var nanos: UInt32 = 0
        for i in 6..<10 { nanos = (nanos << 8) | UInt32(b[offset + i]) }
        return Double(seconds) + Double(nanos) / 1_000_000_000
    }

    private func handleAnnounce(_ b: [UInt8], domain: UInt8) {
        guard b.count >= 64 else { return }
        // BMCA comparison tuple, in standard precedence order.
        let dataset: [UInt8] = [b[47]]              // priority1
            + Array(b[48..<52])                     // gm clockQuality
            + [b[52]]                               // priority2
            + Array(b[53..<61])                     // gm identity
        let gm = Self.formatIdentity(b[53..<61])
        let now = Self.hostNanos()

        if var current = master {
            if gm == current.grandmaster {
                current.lastAnnounce = now
                master = current
                return
            }
            // Lexicographic compare = BMCA precedence (lower wins).
            if dataset.lexicographicallyPrecedes(current.dataset) {
                master = Master(dataset: dataset, grandmaster: gm,
                                domain: domain, lastAnnounce: now)
                offsetWindow.removeAll()
                log("PTP: better grandmaster \(gm) (domain \(domain))")
                publishLocked()
            }
        } else {
            master = Master(dataset: dataset, grandmaster: gm,
                            domain: domain, lastAnnounce: now)
            log("PTP: grandmaster \(gm) (domain \(domain))")
            publishLocked()
        }
    }

    private func handleSync(_ b: [UInt8], t2: UInt64) {
        guard master != nil else { return }
        let seq = (UInt16(b[30]) << 8) | UInt16(b[31])
        let twoStep = (b[6] & 0x02) != 0
        if twoStep {
            pendingSync = (seq, t2, sourceIdentity(b))
        } else if let t1 = timestamp(b, at: 34) {
            ingest(t1: t1, t2: t2)
        }
    }

    private func handleFollowUp(_ b: [UInt8]) {
        guard let pending = pendingSync,
              (UInt16(b[30]) << 8) | UInt16(b[31]) == pending.seq,
              sourceIdentity(b) == pending.source,
              let t1 = timestamp(b, at: 34) else { return }
        pendingSync = nil
        ingest(t1: t1, t2: pending.t2)
    }

    private func ingest(t1: Double, t2: UInt64) {
        let sample = t1 - Double(t2) / 1_000_000_000
        offsetWindow.append(sample)
        if offsetWindow.count > 16 { offsetWindow.removeFirst() }
        lastSyncAt = Self.hostNanos()
        let wasLocked = published.locked
        publishLocked()
        if !wasLocked && published.locked {
            log(String(format: "PTP: locked to %@ (offset %.3f s, %d samples)",
                       published.grandmaster, published.offset, offsetWindow.count))
        }
    }

    private func expireLocked() {
        let now = Self.hostNanos()
        if let current = master, now &- current.lastAnnounce > 15_000_000_000 {
            log("PTP: grandmaster \(current.grandmaster) silent — unlocked")
            master = nil
            offsetWindow.removeAll()
            pendingSync = nil
        }
        publishLocked()
    }

    private func publishLocked() {
        let fresh = Self.hostNanos() &- lastSyncAt < 5_000_000_000
        let locked = master != nil && offsetWindow.count >= 4 && fresh
        let median = offsetWindow.sorted()[safePtp: offsetWindow.count / 2] ?? 0

        var status = PtpStatus()
        status.locked = locked
        status.grandmaster = master?.grandmaster ?? ""
        status.domain = master?.domain ?? 0
        status.offset = median

        snapshot.withLock { snap in
            snap = Snapshot(locked: locked, offset: median)
        }

        if status != published {
            published = status
            onChange?(status)
        }
    }
}

private extension Array {
    subscript(safePtp index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
