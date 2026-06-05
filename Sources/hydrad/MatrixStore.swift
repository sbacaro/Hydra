// Hydra Audio — GPL-3.0
// Bridges the PatchMatrix (control plane) to the real-time audio thread.
//
// Phase 2b: endpoints are no longer backplane-only. The RT snapshot resolves
// every connection to (buffer index, channel): buffer 0 is the backplane's
// own ABL; buffer i (≥1) is the staging area of device tap i-1. Each used
// physical device contributes a tap (rings + stagings owned by DeviceIO).
// Connections to absent devices stay in the matrix but are excluded from the
// snapshot — they re-bind automatically when the device returns (Section 7.8).
//
// Threading model:
// - Control plane (WS handlers, timers, device manager): mutates `matrix` and
//   `taps`, rebuilds an immutable Snapshot, parks it in `pending` under an
//   unfair lock.
// - Audio thread (backplane IOProc): try-locks; on success adopts `pending`.
//   If the lock is contended it keeps mixing with the previous snapshot —
//   the audio thread never waits.
// - Snapshots are retained by the control plane so the audio thread never
//   triggers a deallocation (snapshots also retain their DeviceIO taps).
// - Meters: plain Float stores into preallocated buffers (atomic enough on
//   arm64/x86_64 for metering purposes).

import Foundation
import Accelerate
import CoreAudio
import HydraCore
import os

/// Anything that feeds audio into / drains audio from the engine across a
/// clock boundary: physical devices (Phase 2b) and app taps (Phase 3).
/// Sources expose inRing+inStaging; destinations expose outRing+outStaging.
/// A post-mix copy of a backplane-output slice — feeds network senders
/// (e.g. NDI TX for a virtual interface). Producer = RT thread, consumer =
/// the sender's own thread; same clock, so the ring's servo idles.
final class PoolTxTap {
    let base: Int
    let channels: Int
    let ring: ChannelRing
    let staging: UnsafeMutablePointer<Float>

    init(base: Int, channels: Int, rate: Double) {
        self.base = base
        self.channels = channels
        ring = ChannelRing(channels: channels, producerRate: rate, consumerRate: rate)
        staging = .allocate(capacity: Hydra.maxIOFrames * channels)
        staging.initialize(repeating: 0, count: Hydra.maxIOFrames * channels)
    }

    deinit {
        staging.deallocate()
    }
}

protocol EngineTap: AnyObject {
    var nodeID: String { get }
    var inChannels: Int { get }
    var outChannels: Int { get }
    var inRing: ChannelRing? { get }
    var outRing: ChannelRing? { get }
    var inStaging: UnsafeMutablePointer<Float>? { get }
    var outStaging: UnsafeMutablePointer<Float>? { get }
}

final class MatrixStore {

    // MARK: Control-plane state
    private let control = DispatchQueue(label: "hydra.matrix.control")
    private var matrix = PatchMatrix()
    private var deviceTaps: [EngineTap] = []
    private var appTaps: [EngineTap] = []
    private var netTaps: [EngineTap] = []
    private var ndiTaps: [EngineTap] = []
    private var poolTxTaps: [PoolTxTap] = []      // NDI senders
    private var recordTaps: [PoolTxTap] = []      // disk recorders
    private var aesTxTaps: [PoolTxTap] = []       // AES67 transmitters
    private var chainTaps: [ChainTap] = []
    private var stripRoutes: [StripRoute] = []
    /// Chains MUST come last: process() uses their buffer-index range to
    /// split mixing into pre-chain and post-chain passes.
    private var taps: [EngineTap] { deviceTaps + appTaps + netTaps + ndiTaps + chainTaps }
    private var slotByID: [String: Int32] = [:]
    private var freeSlots: [Int32] = (0..<Int32(Hydra.maxConnections)).reversed()
    private var retained: [Snapshot] = []
    private var saveWork: DispatchWorkItem?

    // MARK: Shared with audio thread
    private let meters: UnsafeMutablePointer<Float>
    /// Per-channel backplane peaks for signal LEDs (written by RT thread).
    private let inputPeaks: UnsafeMutablePointer<Float>
    private let outputPeaks: UnsafeMutablePointer<Float>
    private let frameAbs: UnsafeMutablePointer<Float>
    /// Single-byte flag: control sets it, RT reads it.
    var channelMeteringEnabled = false
    /// User setting (Settings → Feedback protection). Control-plane only.
    var feedbackProtectionEnabled = true
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var pending: Snapshot?
    /// Audio-thread-only. Touched exclusively inside process().
    private var current: Snapshot?

    // MARK: Snapshot

    final class Snapshot {
        struct Conn {
            /// 0 = backplane ABL; i ≥ 1 = taps[i-1] staging.
            let srcBuf: Int32
            let srcCh: Int32
            let dstBuf: Int32
            let dstCh: Int32
            let gain: Float
            let slot: Int32
        }
        /// Connections whose destination is a VST chain (mixed BEFORE chains render).
        let connsPre: ContiguousArray<Conn>
        /// All other connections (mixed AFTER chains render).
        let conns: ContiguousArray<Conn>
        /// Retained taps (devices + apps + net + chains), indexed by (buf - 1).
        let taps: ContiguousArray<EngineTap>
        /// The chain taps (last entries of `taps`), rendered between passes.
        let chains: ContiguousArray<ChainTap>
        /// Pool TX taps: post-mix copies of backplane-output slices (NDI TX).
        let poolTx: ContiguousArray<PoolTxTap>

        init(connsPre: ContiguousArray<Conn>, conns: ContiguousArray<Conn>,
             taps: ContiguousArray<EngineTap>, chains: ContiguousArray<ChainTap>,
             poolTx: ContiguousArray<PoolTxTap>) {
            self.connsPre = connsPre
            self.conns = conns
            self.taps = taps
            self.chains = chains
            self.poolTx = poolTx
        }
    }

    init() {
        meters = .allocate(capacity: Hydra.maxConnections)
        meters.initialize(repeating: 0, count: Hydra.maxConnections)
        inputPeaks = .allocate(capacity: Hydra.backplaneChannels)
        inputPeaks.initialize(repeating: 0, count: Hydra.backplaneChannels)
        outputPeaks = .allocate(capacity: Hydra.backplaneChannels)
        outputPeaks.initialize(repeating: 0, count: Hydra.backplaneChannels)
        frameAbs = .allocate(capacity: Hydra.backplaneChannels)
        frameAbs.initialize(repeating: 0, count: Hydra.backplaneChannels)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    // MARK: - Control-plane API

    func allConnections() -> [Connection] {
        control.sync { matrix.connections }
    }

    /// New device set (from DeviceManager). Triggers an atomic re-bind.
    func setDeviceTaps(_ newTaps: [EngineTap]) {
        control.sync {
            deviceTaps = newTaps
            rebuildLocked()
        }
    }

    /// New app-tap set (from ProcessTapManager). Triggers an atomic re-bind.
    func setAppTaps(_ newTaps: [EngineTap]) {
        control.sync {
            appTaps = newTaps
            rebuildLocked()
        }
    }

    /// New AES67 RX set (from Aes67Manager). Triggers an atomic re-bind.
    func setNetTaps(_ newTaps: [EngineTap]) {
        control.sync {
            netTaps = newTaps
            rebuildLocked()
        }
    }

    /// New NDI RX set (from NdiManager). Triggers an atomic re-bind.
    func setNdiTaps(_ newTaps: [EngineTap]) {
        control.sync {
            ndiTaps = newTaps
            rebuildLocked()
        }
    }

    /// New pool TX set (NDI senders bound to virtual interfaces).
    func setPoolTxTaps(_ newTaps: [PoolTxTap]) {
        control.sync {
            poolTxTaps = newTaps
            rebuildLocked()
        }
    }

    /// New recorder set (disk recordings bound to virtual interfaces).
    func setRecordTaps(_ newTaps: [PoolTxTap]) {
        control.sync {
            recordTaps = newTaps
            rebuildLocked()
        }
    }

    /// New AES67 TX set (transmitters bound to virtual interfaces).
    func setAesTxTaps(_ newTaps: [PoolTxTap]) {
        control.sync {
            aesTxTaps = newTaps
            rebuildLocked()
        }
    }

    /// New strip set (from StripManager). Triggers an atomic re-bind.
    func setStripData(taps: [ChainTap], routes: [StripRoute]) {
        control.sync {
            chainTaps = taps
            stripRoutes = routes
            rebuildLocked()
        }
    }

    private func endpointPlausible(_ point: PatchPoint) -> Bool {
        if point.nodeID == Hydra.backplaneNodeID {
            return (0..<Hydra.backplaneChannels).contains(point.channelIndex)
        }
        if Hydra.deviceUID(fromNodeID: point.nodeID) != nil {
            return (0..<Hydra.maxDeviceChannels).contains(point.channelIndex)
        }
        if Hydra.appKey(fromNodeID: point.nodeID) != nil {
            return (0..<Hydra.appTapChannels).contains(point.channelIndex)
        }
        if Hydra.aes67StreamID(fromNodeID: point.nodeID) != nil {
            return (0..<64).contains(point.channelIndex)
        }
        if Hydra.ndiSourceID(fromNodeID: point.nodeID) != nil {
            return (0..<Hydra.ndiMaxChannels).contains(point.channelIndex)
        }
        if Hydra.vstChainID(fromNodeID: point.nodeID) != nil {
            return (0..<Hydra.vstChainChannels).contains(point.channelIndex)
        }
        return false
    }

    /// Upsert with validation and feedback protection. Returns true if the
    /// matrix changed.
    func upsert(_ connection: Connection) -> Bool {
        guard endpointPlausible(connection.source),
              endpointPlausible(connection.destination),
              connection.gain.isFinite else { return false }
        return control.sync {
            // Gain updates on existing connections never create new loops.
            let isNew = matrix.connection(source: connection.source,
                                          destination: connection.destination) == nil
            if isNew && feedbackProtectionEnabled && wouldFeedbackLocked(adding: connection) {
                EventCenter.shared.emit(.warning,
                    "Blocked: \(connection.source.nodeID == Hydra.backplaneNodeID ? "In \(connection.source.channelIndex + 1)" : connection.source.nodeID) → Out \(connection.destination.channelIndex + 1) would create a feedback loop.")
                return false
            }
            guard matrix.upsert(connection) else { return false }
            assignSlotIfNeeded(connection.id)
            rebuildLocked()
            scheduleSaveLocked()
            return true
        }
    }

    /// Feedback detection: on the loopback backplane, Out n re-enters as
    /// In n, so backplane→backplane connections form a directed graph
    /// (edge s→d per connection). A new edge that closes a cycle — including
    /// s == d — would howl. Other node types cannot loop internally.
    private func wouldFeedbackLocked(adding new: Connection) -> Bool {
        guard new.source.nodeID == Hydra.backplaneNodeID,
              new.destination.nodeID == Hydra.backplaneNodeID else { return false }
        let s = new.source.channelIndex
        let d = new.destination.channelIndex
        if s == d { return true }

        var adjacency: [Int: [Int]] = [:]
        for c in matrix.connections
        where c.source.nodeID == Hydra.backplaneNodeID
           && c.destination.nodeID == Hydra.backplaneNodeID {
            adjacency[c.source.channelIndex, default: []].append(c.destination.channelIndex)
        }
        // Path from d back to s through existing edges?
        var stack = [d]
        var seen: Set<Int> = []
        while let node = stack.popLast() {
            if node == s { return true }
            guard seen.insert(node).inserted else { continue }
            stack.append(contentsOf: adjacency[node] ?? [])
        }
        return false
    }

    func remove(_ connection: Connection) -> Bool {
        control.sync {
            guard matrix.remove(source: connection.source, destination: connection.destination) else { return false }
            if let slot = slotByID.removeValue(forKey: connection.id) {
                freeSlots.append(slot)
                meters[Int(slot)] = 0
            }
            rebuildLocked()
            scheduleSaveLocked()
            return true
        }
    }

    /// Replace the entire matrix at once (scene apply). One snapshot swap ⇒
    /// no audible intermediate states.
    func replaceAll(_ connections: [Connection]) -> Bool {
        let valid = connections.filter {
            endpointPlausible($0.source) && endpointPlausible($0.destination) && $0.gain.isFinite
        }
        return control.sync {
            matrix = PatchMatrix()
            slotByID.removeAll()
            freeSlots = (0..<Int32(Hydra.maxConnections)).reversed()
            var blocked = 0
            for c in valid {
                if feedbackProtectionEnabled && wouldFeedbackLocked(adding: c) {
                    blocked += 1
                    continue
                }
                matrix.upsert(c)
                assignSlotIfNeeded(c.id)
            }
            if blocked > 0 {
                EventCenter.shared.emit(.warning,
                    "Scene applied with \(blocked) connection(s) skipped: they would create feedback loops.")
            }
            rebuildLocked()
            scheduleSaveLocked()
            return true
        }
    }

    /// Post-gain peaks per connection ID, for the levels broadcast.
    func levels() -> [String: Float] {
        control.sync {
            var out: [String: Float] = [:]
            out.reserveCapacity(slotByID.count)
            for (id, slot) in slotByID {
                out[id] = meters[Int(slot)]
            }
            return out
        }
    }

    /// Per-channel backplane peaks (for the grid's signal LEDs).
    func channelPeaks() -> (inputs: [Float], outputs: [Float]) {
        let n = Hydra.backplaneChannels
        return (Array(UnsafeBufferPointer(start: inputPeaks, count: n)),
                Array(UnsafeBufferPointer(start: outputPeaks, count: n)))
    }

    // MARK: - Snapshot plumbing (call on `control` only)

    private func assignSlotIfNeeded(_ id: String) {
        guard slotByID[id] == nil, let slot = freeSlots.popLast() else { return }
        slotByID[id] = slot
        meters[Int(slot)] = 0
    }

    private func rebuildLocked() {
        // nodeID → (buffer index, channel limit), per direction.
        var sourceMap: [String: (buf: Int32, channels: Int32)] = [
            Hydra.backplaneNodeID: (0, Int32(Hydra.backplaneChannels))
        ]
        var destinationMap = sourceMap
        let allTaps = taps
        // Chains are NOT grid endpoints — they are per-connection inserts.
        var chainIndexByID: [UUID: (buf: Int32, channels: Int32)] = [:]
        for (i, tap) in allTaps.enumerated() {
            if let chain = tap as? ChainTap {
                chainIndexByID[chain.info.id] = (Int32(i + 1), Int32(Hydra.vstChainChannels))
                continue
            }
            if tap.inChannels > 0 {
                sourceMap[tap.nodeID] = (Int32(i + 1), Int32(tap.inChannels))
            }
            if tap.outChannels > 0 {
                destinationMap[tap.nodeID] = (Int32(i + 1), Int32(tap.outChannels))
            }
        }

        // Strip routing: source channel → (strip tap buffer, strip channel).
        // Pre-legs (raw source → trim → strip input) are added once per strip
        // channel; connections from those channels then read the strip output.
        var stripBySource: [String: (buf: Int32, stripCh: Int32)] = [:]
        var connsPre = ContiguousArray<Snapshot.Conn>()
        for route in stripRoutes {
            guard let chain = chainIndexByID[route.chainID],
                  let src = sourceMap[route.nodeID],
                  route.channelIndex < src.channels else { continue }
            stripBySource["\(route.nodeID):\(route.channelIndex)"] = (chain.buf, route.stripChannel)
            connsPre.append(.init(srcBuf: src.buf, srcCh: Int32(route.channelIndex),
                                  dstBuf: chain.buf, dstCh: route.stripChannel,
                                  gain: route.trim, slot: -1)) // no meter on internal legs
        }

        var conns = ContiguousArray<Snapshot.Conn>()
        var reroutedCount = 0
        conns.reserveCapacity(matrix.connections.count)
        for c in matrix.connections {
            guard let src = sourceMap[c.source.nodeID],
                  let dst = destinationMap[c.destination.nodeID],
                  c.source.channelIndex < src.channels,
                  c.destination.channelIndex < dst.channels,
                  let slot = slotByID[c.id] else { continue } // absent device: waits to re-bind

            if let strip = stripBySource["\(c.source.nodeID):\(c.source.channelIndex)"] {
                // Read the strip's processed output instead of the raw source.
                reroutedCount += 1
                conns.append(.init(srcBuf: strip.buf, srcCh: strip.stripCh,
                                   dstBuf: dst.buf, dstCh: Int32(c.destination.channelIndex),
                                   gain: c.gain, slot: slot))
            } else {
                conns.append(.init(srcBuf: src.buf, srcCh: Int32(c.source.channelIndex),
                                   dstBuf: dst.buf, dstCh: Int32(c.destination.channelIndex),
                                   gain: c.gain, slot: slot))
            }
        }
        if !stripRoutes.isEmpty {
            log("Matrix rebuilt: \(conns.count) conns (\(reroutedCount) through strips), \(connsPre.count) strip legs, \(stripRoutes.count) routes")
        }
        let snapshot = Snapshot(connsPre: connsPre, conns: conns,
                                taps: ContiguousArray(allTaps),
                                chains: ContiguousArray(chainTaps),
                                poolTx: ContiguousArray(poolTxTaps + recordTaps + aesTxTaps))
        retained.append(snapshot)
        if retained.count > 8 { retained.removeFirst(retained.count - 8) }

        os_unfair_lock_lock(lock)
        pending = snapshot
        os_unfair_lock_unlock(lock)
    }

    // MARK: - Persistence (~/Library/Application Support/Hydra/matrix.json)

    private static var saveURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hydra", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("matrix.json")
    }

    func loadFromDisk() {
        control.sync {
            guard let data = try? Data(contentsOf: Self.saveURL),
                  let loaded = try? JSONDecoder().decode(PatchMatrix.self, from: data) else { return }
            matrix = loaded
            for c in matrix.connections { assignSlotIfNeeded(c.id) }
            rebuildLocked()
            log("Matrix restored: \(matrix.connections.count) connection(s)")
        }
    }

    private func scheduleSaveLocked() {
        saveWork?.cancel()
        let snapshot = matrix
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: Self.saveURL, options: .atomic)
            }
        }
        saveWork = work
        control.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: - AUDIO THREAD (backplane IOProc) — no allocation, no waiting.

    func process(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        // 1. Always zero the backplane output.
        let outList = UnsafeMutableAudioBufferListPointer(output)
        for buf in outList {
            if let data = buf.mData {
                memset(data, 0, Int(buf.mDataByteSize))
            }
        }

        // 2. Adopt a newer snapshot if available (never block).
        if os_unfair_lock_trylock(lock) {
            if let p = pending {
                current = p
                pending = nil
            }
            os_unfair_lock_unlock(lock)
        }

        // 3. Resolve backplane buffers.
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let inBuf = inList.first, let outBuf = outList.first,
              let inRaw = inBuf.mData, let outRaw = outBuf.mData else { return }
        let inChans = Int(inBuf.mNumberChannels)
        let outChans = Int(outBuf.mNumberChannels)
        guard inChans > 0, outChans > 0 else { return }
        let frames = min(Int(inBuf.mDataByteSize) / (MemoryLayout<Float>.size * inChans),
                         Hydra.maxIOFrames)
        guard frames > 0 else { return }

        let inData = inRaw.assumingMemoryBound(to: Float.self)
        let outData = outRaw.assumingMemoryBound(to: Float.self)

        guard let snapshot = current else { return }

        // 4. Stage device inputs (resampled to the engine clock) and clear
        //    device output stagings.
        for tap in snapshot.taps {
            if let ring = tap.inRing, let staging = tap.inStaging {
                ring.readResampled(into: staging, frames: frames)
            }
            if let staging = tap.outStaging {
                vDSP_vclr(staging, 1, vDSP_Length(frames * tap.outChannels))
            }
        }

        // 5. Mix in two passes around the VST chains:
        //    sources → chain inputs, chains render, everything else.
        for conn in snapshot.connsPre {
            mixConnection(conn, snapshot: snapshot, inData: inData, outData: outData,
                          inChans: inChans, outChans: outChans, frames: frames)
        }
        for chain in snapshot.chains {
            chain.render(frames: frames)
        }
        for conn in snapshot.conns {
            mixConnection(conn, snapshot: snapshot, inData: inData, outData: outData,
                          inChans: inChans, outChans: outChans, frames: frames)
        }

        // 6. Push device output stagings into their rings (device IOProcs
        //    drain them on their own clock).
        for tap in snapshot.taps {
            if let ring = tap.outRing, let staging = tap.outStaging {
                ring.write(from: staging, frames: frames)
            }
        }

        // 6.5. Pool TX: copy the mixed backplane-output slices to their
        //      rings (NDI sender threads drain them).
        var zero: Float = 0
        for tx in snapshot.poolTx where tx.base + tx.channels <= outChans {
            for ch in 0..<tx.channels {
                // Strided copy (x + 0): outData[ch-th lane] → staging.
                vDSP_vsadd(outData + tx.base + ch, vDSP_Stride(outChans), &zero,
                           tx.staging + ch, vDSP_Stride(tx.channels), vDSP_Length(frames))
            }
            tx.ring.write(from: tx.staging, frames: frames)
        }

        // 7. Per-channel backplane peaks for signal LEDs.
        runChannelMetering(inData: inData, outData: outData,
                           inChans: inChans, outChans: outChans, frames: frames)
    }

    /// AUDIO THREAD: one connection — out[dst] += in[src] * gain, plus meter.
    @inline(__always)
    private func mixConnection(_ conn: Snapshot.Conn, snapshot: Snapshot,
                               inData: UnsafeMutablePointer<Float>,
                               outData: UnsafeMutablePointer<Float>,
                               inChans: Int, outChans: Int, frames: Int) {
        let srcPtr: UnsafePointer<Float>
        let srcStride: Int
        if conn.srcBuf == 0 {
            srcPtr = UnsafePointer(inData) + Int(conn.srcCh)
            srcStride = inChans
        } else {
            let tap = snapshot.taps[Int(conn.srcBuf) - 1]
            guard let staging = tap.inStaging else { return }
            srcPtr = UnsafePointer(staging) + Int(conn.srcCh)
            srcStride = tap.inChannels
        }
        let dstPtr: UnsafeMutablePointer<Float>
        let dstStride: Int
        if conn.dstBuf == 0 {
            dstPtr = outData + Int(conn.dstCh)
            dstStride = outChans
        } else {
            let tap = snapshot.taps[Int(conn.dstBuf) - 1]
            guard let staging = tap.outStaging else { return }
            dstPtr = staging + Int(conn.dstCh)
            dstStride = tap.outChannels
        }
        guard Int(conn.srcCh) < srcStride, Int(conn.dstCh) < dstStride else { return }

        var gain = conn.gain
        vDSP_vsma(srcPtr, srcStride, &gain,
                  dstPtr, dstStride,
                  dstPtr, dstStride,
                  vDSP_Length(frames))

        // slot < 0: internal leg (strip pre-leg) — no meter.
        if conn.slot >= 0 {
            var peak: Float = 0
            vDSP_maxmgv(srcPtr, srcStride, &peak, vDSP_Length(frames))
            meters[Int(conn.slot)] = peak * abs(gain)
        }
    }

    /// AUDIO THREAD: per-channel backplane peaks for signal LEDs.
    @inline(__always)
    private func runChannelMetering(inData: UnsafeMutablePointer<Float>,
                                    outData: UnsafeMutablePointer<Float>,
                                    inChans: Int, outChans: Int, frames: Int) {
        if channelMeteringEnabled {
            let nIn = min(inChans, Hydra.backplaneChannels)
            let nOut = min(outChans, Hydra.backplaneChannels)
            vDSP_vclr(inputPeaks, 1, vDSP_Length(Hydra.backplaneChannels))
            vDSP_vclr(outputPeaks, 1, vDSP_Length(Hydra.backplaneChannels))
            for frame in 0..<frames {
                vDSP_vabs(inData + frame * inChans, 1, frameAbs, 1, vDSP_Length(nIn))
                vDSP_vmax(frameAbs, 1, inputPeaks, 1, inputPeaks, 1, vDSP_Length(nIn))
                vDSP_vabs(outData + frame * outChans, 1, frameAbs, 1, vDSP_Length(nOut))
                vDSP_vmax(frameAbs, 1, outputPeaks, 1, outputPeaks, 1, vDSP_Length(nOut))
            }
        }
    }
}
