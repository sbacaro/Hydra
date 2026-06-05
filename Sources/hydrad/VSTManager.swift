// Hydra Audio — GPL-3.0
// Channel strips, Logic-style (UI-redesign milestone). A strip = a source
// channel (or stereo pair) with insert slots and trim. All audio leaving the
// source passes through the strip's inserts before reaching any destination.
//
// Engine integration: each strip with loaded inserts gets a ChainTap; the
// MatrixStore reroutes connections from the strip's channels through it
// (raw source → trim → inserts → connections). Same clock domain — no rings,
// no added latency. Hosting goes through the HydraVST shim (Steinberg VST3
// SDK, GPLv3 option).

import Foundation
import Accelerate
import HydraCore
import HydraVST

// MARK: - ChainTap: an insert sequence as an engine node

final class ChainTap: EngineTap {
    let nodeID: String
    let info: VSTChainInfo
    let inChannels: Int = Hydra.vstChainChannels    // source side (strip output)
    let outChannels: Int = Hydra.vstChainChannels   // destination side (strip input)
    let inRing: ChannelRing? = nil
    let outRing: ChannelRing? = nil
    /// Strip OUTPUT (engine reads this as a source).
    let inStaging: UnsafeMutablePointer<Float>?
    /// Strip INPUT (engine mixes into this as a destination).
    let outStaging: UnsafeMutablePointer<Float>?

    /// Plugin instances aligned with `info.plugins` (nil = failed to load).
    private var instances: [UnsafeMutableRawPointer?] = []
    private var inPeakScratch: Float = 0
    private var outPeakScratch: Float = 0
    /// Deinterleaved ping-pong buffers (2 × channel pointers).
    private let bufA: [UnsafeMutablePointer<Float>]
    private let bufB: [UnsafeMutablePointer<Float>]
    /// Channel-pointer argument arrays for the C call (optional-typed, as
    /// imported from `float *const *`). Preallocated — RT-safe.
    private let argA: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let argB: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>

    var loadedCount: Int { instances.compactMap { $0 }.count }

    /// Diagnostics: written by the RT thread each render, read by the
    /// StripManager monitor (plain stores — approximate is fine).
    private(set) var inPeak: Float = 0
    private(set) var outPeak: Float = 0
    /// Counts render calls whose plugin process() FAILED (bypassed block).
    private(set) var bypassedBlocks: Int = 0

    init(info: VSTChainInfo, sampleRate: Double) {
        self.info = info
        self.nodeID = Hydra.vstNodeID(chainID: info.id)

        let channels = Hydra.vstChainChannels
        let capacity = Hydra.maxIOFrames * channels
        let staging = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        staging.initialize(repeating: 0, count: capacity)
        inStaging = staging
        let outBuffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        outBuffer.initialize(repeating: 0, count: capacity)
        outStaging = outBuffer

        bufA = (0..<channels).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Hydra.maxIOFrames)
            p.initialize(repeating: 0, count: Hydra.maxIOFrames)
            return p
        }
        bufB = (0..<channels).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Hydra.maxIOFrames)
            p.initialize(repeating: 0, count: Hydra.maxIOFrames)
            return p
        }
        argA = .allocate(capacity: channels)
        argB = .allocate(capacity: channels)
        for ch in 0..<channels {
            argA[ch] = bufA[ch]
            argB[ch] = bufB[ch]
        }

        for plugin in info.plugins {
            let parts = plugin.id.split(separator: "#")
            guard parts.count == 2, let classIndex = Int32(parts[1]) else {
                log("Strip \"\(info.name)\": malformed plugin id \(plugin.id)")
                instances.append(nil)
                continue
            }
            let path = String(parts[0])
            if let instance = hydra_vst_create_instance(path, classIndex,
                                                        sampleRate,
                                                        Int32(Hydra.maxIOFrames)) {
                instances.append(instance)
                log("VST loaded: \"\(plugin.name)\" → strip \"\(info.name)\"")
            } else {
                instances.append(nil)
                log("VST FAILED to load: \"\(plugin.name)\" (\(path)) — skipped")
                EventCenter.shared.emit(.error, "Plugin \"\(plugin.name)\" failed to load and was bypassed.")
            }
        }
    }

    func instanceHandle(at index: Int) -> UnsafeMutableRawPointer? {
        instances.indices.contains(index) ? instances[index] : nil
    }

    deinit {
        for case let instance? in instances {
            hydra_vst_destroy_instance(instance)
        }
        inStaging?.deallocate()
        outStaging?.deallocate()
        for p in bufA { p.deallocate() }
        for p in bufB { p.deallocate() }
        argA.deallocate()
        argB.deallocate()
    }

    /// AUDIO THREAD: outStaging (strip input, interleaved) → inserts →
    /// inStaging (strip output, interleaved). Bypass when nothing loaded.
    func render(frames: Int) {
        guard let input = outStaging, let output = inStaging else { return }
        let channels = Hydra.vstChainChannels
        let n = min(frames, Hydra.maxIOFrames)

        vDSP_maxmgv(input, 1, &inPeakScratch, vDSP_Length(n * channels))
        inPeak = inPeakScratch

        guard loadedCount > 0 else {
            memcpy(output, input, n * channels * MemoryLayout<Float>.size)
            outPeak = inPeak
            return
        }

        for frame in 0..<n {
            for ch in 0..<channels {
                bufA[ch][frame] = input[frame * channels + ch]
            }
        }

        var source = argA
        var sink = argB
        for case let instance? in instances {
            if hydra_vst_process(instance, source, sink, Int32(n)) {
                swap(&source, &sink)
            } else {
                bypassedBlocks += 1 // keep `source` (plugin bypassed this block)
            }
        }

        for frame in 0..<n {
            for ch in 0..<channels {
                let channelData = source[ch]!
                output[frame * channels + ch] = channelData[frame]
            }
        }
        vDSP_maxmgv(output, 1, &outPeakScratch, vDSP_Length(n * channels))
        outPeak = outPeakScratch
    }
}

// MARK: - StripManager

/// Routing instruction for the engine: source channel → strip tap channel.
struct StripRoute {
    let nodeID: String
    let channelIndex: Int
    let chainID: UUID
    let stripChannel: Int32
    let trim: Float
}

final class StripManager {

    private let store: MatrixStore
    private let queue = DispatchQueue(label: "hydra.strips")
    private var available: [VSTPlugin] = []
    private var strips: [String: StripInfo] = [:]   // key → strip
    private var active: [UUID: ChainTap] = [:]      // strip id → tap
    var onChange: ((VSTPayload, StripsPayload) -> Void)?

    private static let persistURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hydra", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("strips.json")
    }()

    init(store: MatrixStore) {
        self.store = store
        if let data = try? Data(contentsOf: Self.persistURL),
           let loaded = try? JSONDecoder().decode([StripInfo].self, from: data) {
            strips = Dictionary(uniqueKeysWithValues: loaded.map { ($0.key, $0) })
        }
    }

    func start() {
        queue.sync {
            scanLocked()
            rebuildTapsLocked()
        }
        // Diagnostics: while strips are active, log the chain's audio path
        // health every 3 s (in level → out level → failed blocks). This is
        // what pinpoints "GUI works but audio doesn't change" reports.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for tap in self.active.values {
                let inDB = 20 * log10(max(tap.inPeak, 1e-7))
                let outDB = 20 * log10(max(tap.outPeak, 1e-7))
                log(String(format: "Strip \"%@\": in %.1f dBFS → out %.1f dBFS · %d plugin(s) · %d bypassed blocks",
                           tap.info.name, inDB, outDB, tap.loadedCount, tap.bypassedBlocks))
            }
        }
        timer.resume()
        monitorTimer = timer
    }
    private var monitorTimer: DispatchSourceTimer?

    func vstPayload() -> VSTPayload {
        queue.sync { VSTPayload(available: available) }
    }

    func stripsPayload() -> StripsPayload {
        queue.sync { StripsPayload(strips: Array(strips.values).sorted { $0.key < $1.key }) }
    }

    /// Upsert a strip (the app sends the whole strip on every edit).
    func setStrip(_ incoming: StripInfo) {
        queue.sync {
            var strip = incoming
            // Stereo strips snap to an even base channel (Logic-style 1-2, 3-4).
            if strip.stereo {
                strip.channelIndex = strip.channelIndex & ~1
            }
            // Keep the existing identity for the same key (editor windows
            // and routes stay stable across edits).
            if let existing = strips[strip.key] {
                strip.id = existing.id
            }
            strips[strip.key] = strip
            persistLocked()
            rebuildTapsLocked()
            onChange?(VSTPayload(available: available), stripsPayload2Locked())
        }
    }

    /// Opens the editor window of a loaded insert.
    func openEditor(stripID: UUID, index: Int) {
        let handleAndTitle: (UnsafeMutableRawPointer, String)? = queue.sync {
            guard let tap = active[stripID],
                  let handle = tap.instanceHandle(at: index) else { return nil }
            let title = tap.info.plugins.indices.contains(index)
                ? "\(tap.info.plugins[index].name) — \(tap.info.name)"
                : tap.info.name
            return (handle, title)
        }
        guard let (handle, title) = handleAndTitle else {
            log("VST editor: no loaded instance at \(stripID)#\(index)")
            return
        }
        DispatchQueue.main.async {
            if !hydra_vst_open_editor(handle, title) {
                log("VST editor: plugin did not provide a view")
            }
        }
    }

    // MARK: Internals (queue only)

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(Array(strips.values)) {
            try? data.write(to: Self.persistURL, options: .atomic)
        }
    }

    private func stripsPayload2Locked() -> StripsPayload {
        StripsPayload(strips: Array(strips.values).sorted { $0.key < $1.key })
    }

    private func scanLocked() {
        var found: [VSTPlugin] = []
        let roots = [
            "/Library/Audio/Plug-Ins/VST3",
            (NSHomeDirectory() as NSString).appendingPathComponent("Library/Audio/Plug-Ins/VST3")
        ]
        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries.sorted() where entry.hasSuffix(".vst3") {
                let path = (root as NSString).appendingPathComponent(entry)
                var classCount: Int32 = 0
                guard let module = hydra_vst_open_module(path, &classCount) else {
                    log("VST scan: could not open \(entry)")
                    continue
                }
                defer { hydra_vst_close_module(module) }
                for index in 0..<classCount {
                    var info = hydra_vst_class_info()
                    if hydra_vst_class_info_at(module, index, &info) {
                        let name = withUnsafeBytes(of: info.name) { raw in
                            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                        }
                        let vendor = withUnsafeBytes(of: info.vendor) { raw in
                            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                        }
                        found.append(VSTPlugin(id: "\(path)#\(index)", name: name, vendor: vendor))
                    }
                }
            }
        }
        available = found
        log("VST scan: \(found.count) audio-effect class(es) found")
    }

    private func rebuildTapsLocked() {
        let engineRate = BackplaneProbe.backplaneDeviceID()
            .map(BackplaneProbe.nominalSampleRate) ?? Hydra.defaultSampleRate

        var next: [UUID: ChainTap] = [:]
        var routes: [StripRoute] = []
        for strip in strips.values where !strip.inserts.isEmpty {
            let chainInfo = VSTChainInfo(id: strip.id,
                                         name: "\(strip.nodeID):\(strip.channelIndex + 1)",
                                         plugins: strip.inserts)
            let tap: ChainTap
            if let existing = active[strip.id], existing.info == chainInfo {
                tap = existing
            } else {
                tap = ChainTap(info: chainInfo, sampleRate: engineRate)
            }
            next[strip.id] = tap

            let channels = strip.stereo ? 2 : 1
            for offset in 0..<channels {
                routes.append(StripRoute(nodeID: strip.nodeID,
                                         channelIndex: strip.channelIndex + offset,
                                         chainID: strip.id,
                                         stripChannel: Int32(offset),
                                         trim: strip.trim))
            }
        }
        active = next
        store.setStripData(taps: Array(next.values), routes: routes)
    }
}
