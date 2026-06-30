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
import HydraRT
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
    /// When set, this chain runs in the SHARED out-of-process host (crash
    /// isolation) and `instances` stays empty; render/editor delegate to it.
    private let chainHandle: ChainHandle?
    /// The shared host that owns `chainHandle` (to remove the chain on teardown).
    private let sharedHost: SharedPluginHost?
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

    init(info: VSTChainInfo, sampleRate: Double, sharedHost: SharedPluginHost?) {
        self.info = info
        self.nodeID = Hydra.vstNodeID(chainID: info.id)
        self.sharedHost = sharedHost

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

        // Out-of-process hosting (info.isolated, on by default): the chain runs in
        // the SHARED host process (all plugins together → one editor window, one
        // Dock icon; a crash takes down the host but not the daemon). The local
        // `instances` array stays empty and render()/editor delegate to the chain
        // handle. HYDRA_REMOTE_PLUGINS=0 forces the legacy in-process path; we also
        // fall back to in-process if the shared host isn't available.
        if info.isolated,
           ProcessInfo.processInfo.environment["HYDRA_REMOTE_PLUGINS"] != "0",
           !info.plugins.isEmpty,
           let sharedHost,
           let handle = sharedHost.addChain(plugins: info.plugins.map(\.id),
                                            titles: info.plugins.map { "\($0.name) — \(info.name)" },
                                            channels: channels,
                                            maxFrames: Hydra.maxIOFrames,
                                            rate: sampleRate) {
            chainHandle = handle
            log("Strip \"\(info.name)\": hosting \(info.plugins.count) plugin(s) in the shared host")
            return
        }
        chainHandle = nil

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

    /// If this chain is hosted out-of-process, ask the host to open plugin
    /// `index`'s editor window. Returns true when handled remotely.
    func openEditorRemotely(index: Int) -> Bool {
        guard let chainHandle else { return false }
        chainHandle.openEditor(index: index)
        return true
    }

    /// Out-of-process counterpart of the close path. Returns true when handled
    /// remotely (so the caller skips the in-process close).
    func closeEditorRemotely(index: Int) -> Bool {
        guard let chainHandle else { return false }
        chainHandle.closeEditor(index: index)
        return true
    }

    deinit {
        // Out-of-process chain: remove it from the shared host (closes its editor,
        // stops its audio, frees its shm) — does NOT touch other chains.
        if let chainHandle { sharedHost?.removeChain(chainHandle) }
        // Waves (and some other) VST3 plugins call NSView/NSWindow APIs during
        // destruction (DisposeSystemWindow). Must run on the main thread.
        // We may arrive here from hydra.matrix.control or hydra.strips — both
        // have main free in its RunLoop, so sync dispatch is safe. At startup
        // we're already on main, so the isMainThread check avoids the deadlock
        // that DispatchQueue.main.sync-on-main would cause.
        let toDestroy = instances.compactMap { $0 }
        if Thread.isMainThread {
            for instance in toDestroy {
                hydra_vst_destroy_instance(instance)
            }
        } else {
            // Raw pointers aren't Sendable; pass them across to main as integer
            // bit patterns (which are) and rebuild on the other side.
            let addrs = toDestroy.map { UInt(bitPattern: $0) }
            DispatchQueue.main.async {
                for addr in addrs {
                    if let p = UnsafeMutableRawPointer(bitPattern: addr) {
                        hydra_vst_destroy_instance(p)
                    }
                }
            }
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

        // Out-of-process chain (opt-in): RT-safe, never blocks, passes dry on a
        // slow/crashed host. A plugin crash can't reach this thread.
        if let chainHandle {
            chainHandle.process(input: input, output: output, frames: n)
            vDSP_maxmgv(output, 1, &outPeakScratch, vDSP_Length(n * channels))
            outPeak = outPeakScratch
            return
        }

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

        // A misbehaving VST3 may substitute (or null) the channel buffer pointers
        // it was handed. Never force-unwrap on the audio thread: fall back to
        // silence for any channel the plugin left nil instead of trapping.
        for ch in 0..<channels {
            guard let channelData = source[ch] else {
                for frame in 0..<n { output[frame * channels + ch] = 0 }
                continue
            }
            for frame in 0..<n {
                output[frame * channels + ch] = channelData[frame]
            }
        }
        vDSP_maxmgv(output, 1, &outPeakScratch, vDSP_Length(n * channels))
        outPeak = outPeakScratch
    }
}

// MARK: - StripManager

/// Routing instruction for the engine: maps a backplane channel to a strip tap
/// channel. `side` says whether the strip processes the channel as a SOURCE
/// (transmitter: raw source → inserts → connections) or a DESTINATION
/// (receiver: connections → inserts → real receiver channel).
struct StripRoute {
    let nodeID: String
    let channelIndex: Int
    let chainID: UUID
    let stripChannel: Int32
    let trim: Float
    let side: StripSide
}

final class StripManager: @unchecked Sendable {

    private let store: MatrixStore
    private let queue = DispatchQueue(label: "hydra.strips")
    private var available: [VSTPlugin] = []
    private var scannedAt: Date?
    private var scanning = false
    private var scanProgress = 0.0
    private var scanLabel = ""
    /// User-chosen extra VST3 folder (Settings), set per scan request.
    private var customRoot = ""
    private var strips: [String: StripInfo] = [:]   // key → strip
    private var active: [UUID: ChainTap] = [:]      // strip id → tap
    /// Node IDs of currently-present physical devices. A device strip's plugins
    /// are NOT instantiated while its device is absent (saves CPU + avoids boot
    /// XRUNs); they load when the device returns. Fed from DeviceManager changes.
    private var presentDeviceNodes: Set<String> = []
    /// One shared out-of-process plugin host for ALL isolated chains (so every
    /// plugin editor lives in a single process — one window, one Dock icon).
    private let sharedHost: SharedPluginHost?
    /// A loaded plugin editor we believe is on screen (a strip insert).
    private struct EditorRef: Hashable { let stripID: UUID; let index: Int }
    /// Every editor we've opened → whether it's pinned. DAW single-window model:
    /// a plain (non-pinned) open closes ALL other NON-pinned editors first, so at
    /// most one shared window is up at a time; Shift-opened (pinned) windows stay
    /// open alongside. Closing a window only hides the editor — the plugin keeps
    /// processing audio. `queue`-only.
    private var openEditors: [EditorRef: Bool] = [:]
    /// User plugin-management choices (Settings → Plugins): hidden (opt-out) and
    /// starred plugin IDs. Persisted separately from the scan cache.
    private var disabledIDs: Set<String> = []
    private var favoriteIDs: Set<String> = []
    var onChange: ((VSTPayload, StripsPayload) -> Void)?

    /// Persisted scan results — the daemon must NOT rescan on every launch.
    private struct ScanCache: Codable {
        var plugins: [VSTPlugin]
        var scannedAt: Date
    }

    /// Persisted user plugin-management choices.
    private struct PluginPrefs: Codable {
        var disabledIDs: [String] = []
        var favoriteIDs: [String] = []
    }

    private static let persistURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hydra", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("strips.json")
    }()

    private static let scanCacheURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hydra", isDirectory: true)
        return base.appendingPathComponent("vst-plugins.json")
    }()

    private static let pluginPrefsURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hydra", isDirectory: true)
        return base.appendingPathComponent("vst-prefs.json")
    }()

    init(store: MatrixStore) {
        self.store = store
        // Spawn the single shared plugin host up front (nil if its binary isn't
        // found — chains then fall back to in-process hosting).
        self.sharedHost = SharedPluginHost.defaultHostURL().map { SharedPluginHost(hostURL: $0) }
        if let data = try? Data(contentsOf: Self.persistURL),
           let loaded = try? JSONDecoder().decode([StripInfo].self, from: data) {
            strips = Dictionary(uniqueKeysWithValues: loaded.map { ($0.key, $0) })
        }
        if let data = try? Data(contentsOf: Self.scanCacheURL),
           let cache = try? JSONDecoder().decode(ScanCache.self, from: data) {
            available = cache.plugins
            scannedAt = cache.scannedAt
        }
        if let data = try? Data(contentsOf: Self.pluginPrefsURL),
           let prefs = try? JSONDecoder().decode(PluginPrefs.self, from: data) {
            disabledIDs = Set(prefs.disabledIDs)
            favoriteIDs = Set(prefs.favoriteIDs)
        }
    }

    /// Terminate every out-of-process plugin-host child. Called on app quit so
    /// the `hydra-plugin-host` processes don't orphan to launchd.
    func shutdownAllHosts() {
        sharedHost?.shutdown()
    }

    func start() {
        // Called from the main thread during daemon startup — no concurrent
        // clients yet, so access state directly. Skipping queue.sync avoids
        // the deadlock that would occur if rebuildTapsLocked tried to dispatch
        // back to main (for ChainTap.init) while main is blocked on queue.sync.
        if scannedAt != nil {
            log("VST: \(available.count) plugin class(es) from cache (scanned \(scannedAt!))")
        } else {
            log("VST: never scanned — waiting for a user-requested scan")
        }
        rebuildTapsLocked()  // Already on main thread — no dispatch needed.
        // Diagnostics: while strips are active, log the chain's audio path
        // health every 3 s (in level → out level → failed blocks). This is
        // what pinpoints "GUI works but audio doesn't change" reports.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
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
        queue.sync { vstPayloadLocked() }
    }

    private func vstPayloadLocked() -> VSTPayload {
        VSTPayload(available: available,
                   disabledIDs: Array(disabledIDs), favoriteIDs: Array(favoriteIDs),
                   scannedAt: scannedAt,
                   scanning: scanning, scanProgress: scanProgress,
                   scanLabel: scanLabel)
    }

    /// Settings → Plugins: show/hide a plugin in the strip's insert picker
    /// (opt-out: hiding adds to disabledIDs; everything else stays available).
    func setPluginAvailable(id: String, available: Bool) {
        queue.sync {
            let changed = available ? (disabledIDs.remove(id) != nil)
                                    : disabledIDs.insert(id).inserted
            guard changed else { return }
            persistPrefsLocked()
            onChange?(vstPayloadLocked(), stripsPayload2Locked())
        }
    }

    /// Settings → Plugins: star/unstar a plugin (surfaced first in the picker).
    func setPluginFavorite(id: String, favorite: Bool) {
        queue.sync {
            let changed = favorite ? favoriteIDs.insert(id).inserted
                                   : (favoriteIDs.remove(id) != nil)
            guard changed else { return }
            persistPrefsLocked()
            onChange?(vstPayloadLocked(), stripsPayload2Locked())
        }
    }

    private func persistPrefsLocked() {
        let prefs = PluginPrefs(disabledIDs: Array(disabledIDs).sorted(),
                                favoriteIDs: Array(favoriteIDs).sorted())
        if let data = try? JSONEncoder().encode(prefs) {
            try? data.write(to: Self.pluginPrefsURL, options: .atomic)
        }
    }

    /// User-requested scan (Settings button / first Insert). Runs on the
    /// strip queue; progress is broadcast per bundle so the app can show a
    /// progress bar.
    func scanPlugins(extraRoot: String = "") {
        queue.async { [self] in
            guard !scanning else { return }
            customRoot = extraRoot
            scanning = true
            scanProgress = 0
            scanLabel = ""
            onChange?(vstPayloadLocked(), stripsPayload2Locked())
            scanLocked()
            scanning = false
            scanProgress = 1
            scanLabel = ""
            scannedAt = Date()
            if let data = try? JSONEncoder().encode(ScanCache(plugins: available, scannedAt: scannedAt!)) {
                try? data.write(to: Self.scanCacheURL, options: .atomic)
            }
            rebuildTapsLocked()
            onChange?(vstPayloadLocked(), stripsPayload2Locked())
        }
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
            onChange?(vstPayloadLocked(), stripsPayload2Locked())
        }
    }

    /// MatrixStore → a connection was added/removed. Re-evaluate which strips are
    /// patched and lazily load any newly-connected ones. Async (not sync) so it
    /// never re-enters the store's lock from inside its change notification.
    func recheckConnectivity() {
        queue.async { [weak self] in self?.rebuildTapsLocked() }
    }

    /// True if any connection is routed through this strip's channel(s) on its side.
    private func stripIsConnected(_ strip: StripInfo, in conns: [Connection]) -> Bool {
        let chans: Set<Int> = strip.stereo ? [strip.channelIndex, strip.channelIndex + 1]
                                           : [strip.channelIndex]
        return conns.contains { c in
            switch strip.side {
            case .source:      return c.source.nodeID == strip.nodeID && chans.contains(c.source.channelIndex)
            case .destination: return c.destination.nodeID == strip.nodeID && chans.contains(c.destination.channelIndex)
            }
        }
    }

    /// DeviceManager → the set of currently-present physical-device node IDs.
    /// Rebuilds the taps so an absent device's strip drops its plugins and a
    /// returning device's strip reloads them.
    func setPresentDevices(_ nodes: Set<String>) {
        queue.sync {
            guard presentDeviceNodes != nodes else { return }
            presentDeviceNodes = nodes
            rebuildTapsLocked()
        }
    }

    /// Drops every strip sitting on freed backplane slices (interface
    /// deletion): the channels return to the pool and a future interface
    /// must NOT inherit ghost inserts/trim.
    func removeStrips(nodeID: String, channelRanges: [Range<Int>]) {
        queue.sync {
            let doomed = strips.values.filter { strip in
                strip.nodeID == nodeID && channelRanges.contains { range in
                    range.contains(strip.channelIndex)
                        || (strip.stereo && range.contains(strip.channelIndex + 1))
                }
            }
            guard !doomed.isEmpty else { return }
            for strip in doomed {
                strips.removeValue(forKey: strip.key)
            }
            log("Strips: removed \(doomed.count) on freed channels of \(nodeID)")
            persistLocked()
            rebuildTapsLocked()
            onChange?(vstPayloadLocked(), stripsPayload2Locked())
        }
    }

    /// Opens the editor window of a loaded insert (in-process, or routed to the
    /// out-of-process host when the chain runs remotely).
    enum EditorTarget { case remote, local(UnsafeMutableRawPointer, String), none }
    /// Open an insert's editor. DAW single-window model: a plain open closes EVERY
    /// other non-pinned editor first (so one shared window is up at a time), and
    /// becomes the new shared window. With `pinned` (Shift-open) the window stands
    /// on its own — it doesn't close others and isn't closed by the next open.
    /// Closing an editor only hides the GUI; the plugin keeps processing.
    func openEditor(stripID: UUID, index: Int, pinned: Bool) {
        let target: EditorTarget = queue.sync {
            let this = EditorRef(stripID: stripID, index: index)
            // Single-window policy: a plain open dismisses every OTHER non-pinned
            // editor (robust against tracking drift — there should be ≤1).
            if !pinned {
                for (ref, isPinned) in openEditors where ref != this && !isPinned {
                    closeEditorLocked(stripID: ref.stripID, index: ref.index)
                    openEditors[ref] = nil
                }
            }

            guard let tap = active[stripID] else { return .none }
            let resolved: EditorTarget
            if tap.openEditorRemotely(index: index) {
                resolved = .remote                  // editor lives in the host process
            } else if let handle = tap.instanceHandle(at: index) {
                let title = tap.info.plugins.indices.contains(index)
                    ? "\(tap.info.plugins[index].name) — \(tap.info.name)"
                    : tap.info.name
                resolved = .local(handle, title)
            } else {
                resolved = .none
            }

            // Record the now-open editor with its pinned state (drives the
            // single-window close above on the next plain open).
            if case .none = resolved {} else {
                openEditors[this] = pinned
            }
            let resolvedDesc: String
            switch resolved { case .remote: resolvedDesc = "remote"; case .local: resolvedDesc = "local"; case .none: resolvedDesc = "none" }
            log("Editor open \(stripID)#\(index) pinned=\(pinned) → \(resolvedDesc) (open: \(openEditors.count))")
            return resolved
        }
        switch target {
        case .remote:
            break // opened by the host process
        case .none:
            log("VST editor: no loaded instance at \(stripID)#\(index)")
        case .local(let handle, let title):
            // Raw pointer isn't Sendable; cross to main as an integer bit pattern.
            let handleAddr = UInt(bitPattern: handle)
            DispatchQueue.main.async {
                guard let h = UnsafeMutableRawPointer(bitPattern: handleAddr) else { return }
                if !hydra_vst_open_editor(h, title) {
                    log("VST editor: plugin did not provide a view")
                }
            }
        }
    }

    /// Close one insert's editor window wherever it lives (remote host or
    /// in-process). `queue`-only; the in-process close hops to the main thread.
    private func closeEditorLocked(stripID: UUID, index: Int) {
        guard let tap = active[stripID] else {
            log("Editor close \(stripID)#\(index): no active tap (stale transient — window may linger)")
            return
        }
        if tap.closeEditorRemotely(index: index) {
            log("Editor close \(stripID)#\(index): remote")
            return
        }
        log("Editor close \(stripID)#\(index): in-process")
        guard let handle = tap.instanceHandle(at: index) else { return }
        let handleAddr = UInt(bitPattern: handle)
        DispatchQueue.main.async {
            guard let h = UnsafeMutableRawPointer(bitPattern: handleAddr) else { return }
            hydra_vst_close_editor(h)
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
        var roots = [
            "/Library/Audio/Plug-Ins/VST3",
            (NSHomeDirectory() as NSString).appendingPathComponent("Library/Audio/Plug-Ins/VST3")
        ]
        if !customRoot.isEmpty, !roots.contains(customRoot) {
            roots.append(customRoot)
        }
        // Pass 1: list the bundles, so progress has a denominator.
        var bundles: [(root: String, entry: String)] = []
        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries.sorted() where entry.hasSuffix(".vst3") {
                bundles.append((root, entry))
            }
        }
        var probed = 0
        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries.sorted() where entry.hasSuffix(".vst3") {
                probed += 1
                scanProgress = bundles.isEmpty ? 1 : Double(probed) / Double(bundles.count)
                scanLabel = (entry as NSString).deletingPathExtension
                onChange?(vstPayloadLocked(), stripsPayload2Locked())
                let path = (root as NSString).appendingPathComponent(entry)
                // Rosetta is on its way out (macOS 26+): an Intel-only
                // plugin can never load into this native process. Say so
                // explicitly instead of a generic open failure.
                if !Self.bundleHasNativeSlice(bundlePath: path) {
                    log("VST scan: \(entry) has no \(Self.nativeArchName) slice (Intel-only?) — skipped. It will stop working entirely once macOS drops Rosetta.")
                    continue
                }
                // Open the bundle in an ISOLATED worker process (one plugin per
                // process). A hang is killed after the timeout; a crash — including
                // the objc class collisions some vendor plugins cause when loaded
                // together — only takes down the worker, never the daemon. A bundle
                // that fails either way is recorded as "offline" and skipped.
                if let plugins = scanBundleOutOfProcess(path) {
                    found.append(contentsOf: plugins)
                } else {
                    found.append(VSTPlugin(id: "\(path)#offline",
                                           name: (entry as NSString).deletingPathExtension,
                                           vendor: "", category: "", offline: true))
                    log("VST scan: \(entry) hung or crashed — marked offline, skipped.")
                }
            }
        }
        available = found
        let offlineCount = found.filter(\.offline).count
        log("VST scan: \(found.count - offlineCount) plugin class(es) found" +
            (offlineCount > 0 ? ", \(offlineCount) bundle(s) offline (hung/crashed)" : ""))
    }

    /// Open one .vst3 bundle in a throwaway `hydrad --scan-bundle` child process.
    /// Returns its plugin classes, or nil if the worker hung (killed after the
    /// timeout) or crashed (non-zero exit). The worker writes JSON to a temp file,
    /// so nothing a plugin prints on stdout can corrupt the result.
    private func scanBundleOutOfProcess(_ path: String, timeout: TimeInterval = 12) -> [VSTPlugin]? {
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hydra-vstscan-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let proc = Process()
        proc.executableURL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        proc.arguments = ["--scan-bundle", path, "--out", outURL.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        do { try proc.run() } catch { return nil }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()                                  // SIGTERM
            if exited.wait(timeout: .now() + 2) == .timedOut, proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)          // forced
            }
            return nil                                        // hung
        }
        guard proc.terminationStatus == 0,
              let data = try? Data(contentsOf: outURL),
              let plugins = try? JSONDecoder().decode([VSTPlugin].self, from: data)
        else { return nil }                                   // crashed / no output
        return plugins
    }

    /// Worker-process body: load ONE bundle in this throwaway process and write its
    /// classes as JSON to `outPath`. Invoked by `hydrad --scan-bundle <path> --out <file>`.
    /// If the load crashes, the whole worker process dies — which is the point: the
    /// parent observes the non-zero exit and marks the bundle offline.
    static func scanBundleWorkerJSON(bundlePath: String, outPath: String) {
        var classCount: Int32 = 0
        var plugins: [VSTPlugin] = []
        if let module = hydra_vst_open_module(bundlePath, &classCount) {
            defer { hydra_vst_close_module(module) }
            for index in 0..<classCount {
                var info = hydra_vst_class_info()
                guard hydra_vst_class_info_at(module, index, &info) else { continue }
                let name = withUnsafeBytes(of: info.name) {
                    String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                let vendor = withUnsafeBytes(of: info.vendor) {
                    String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                let category = withUnsafeBytes(of: info.category) {
                    String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                plugins.append(VSTPlugin(id: "\(bundlePath)#\(index)", name: name,
                                         vendor: vendor, category: category))
            }
        }
        let data = (try? JSONEncoder().encode(plugins)) ?? Data("[]".utf8)
        try? data.write(to: URL(fileURLWithPath: outPath))
    }

    // MARK: Architecture probe (Mach-O header peek, no loading)

    #if arch(arm64)
    static let nativeArchName = "arm64"
    private static let nativeCPUType: UInt32 = 0x0100000C   // CPU_TYPE_ARM64
    #else
    static let nativeArchName = "x86_64"
    private static let nativeCPUType: UInt32 = 0x01000007   // CPU_TYPE_X86_64
    #endif

    /// True when the .vst3 bundle's executable contains a slice for THIS
    /// process's architecture (fat or thin Mach-O). In-process plugin
    /// loading cannot cross architectures — Rosetta never applied here,
    /// and is being removed from macOS anyway.
    static func bundleHasNativeSlice(bundlePath: String) -> Bool {
        let macOS = (bundlePath as NSString).appendingPathComponent("Contents/MacOS")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: macOS),
              let exe = names.first(where: { !$0.hasPrefix(".") }),
              let handle = FileHandle(forReadingAtPath: (macOS as NSString).appendingPathComponent(exe)),
              let header = try? handle.read(upToCount: 4096), header.count >= 8 else {
            // Unreadable/odd layout: let the loader try (it logs its own failure).
            return true
        }
        defer { try? handle.close() }
        func be32(_ offset: Int) -> UInt32 {
            (UInt32(header[offset]) << 24) | (UInt32(header[offset + 1]) << 16)
                | (UInt32(header[offset + 2]) << 8) | UInt32(header[offset + 3])
        }
        func le32(_ offset: Int) -> UInt32 {
            (UInt32(header[offset + 3]) << 24) | (UInt32(header[offset + 2]) << 16)
                | (UInt32(header[offset + 1]) << 8) | UInt32(header[offset])
        }
        let magic = be32(0)
        switch magic {
        case 0xCAFEBABE, 0xCAFEBABF:                  // fat (universal)
            let count = Int(be32(4))
            let entrySize = magic == 0xCAFEBABE ? 20 : 32
            for index in 0..<count {
                let offset = 8 + index * entrySize
                guard offset + 4 <= header.count else { break }
                if be32(offset) == nativeCPUType { return true }
            }
            return false
        case 0xFEEDFACF:                              // thin 64-bit, big-endian header? (rare)
            return be32(4) == nativeCPUType
        case 0xCFFAEDFE:                              // thin 64-bit, little-endian (usual)
            return le32(4) == nativeCPUType
        default:
            return true                               // unknown: let the loader decide
        }
    }

    private func rebuildTapsLocked() {
        let engineRate = BackplaneProbe.backplaneDeviceID()
            .map(BackplaneProbe.nominalSampleRate) ?? Hydra.defaultSampleRate

        let allConns = store.allConnections()
        var next: [UUID: ChainTap] = [:]
        var routes: [StripRoute] = []
        for strip in strips.values where !strip.inserts.isEmpty {
            // A physical-device strip whose device is absent: don't spin up its
            // plugins (saves CPU, avoids boot XRUNs). It reloads when the device
            // returns (DeviceManager change → setPresentDevices → rebuild). Bridge,
            // capture-tap and backplane strips aren't device-gated.
            if Hydra.deviceUID(fromNodeID: strip.nodeID) != nil,
               !presentDeviceNodes.contains(strip.nodeID) {
                continue
            }
            // Lazy load: don't instantiate a strip's plugins until something is
            // patched through it. Once loaded it stays (re-uses active[id]) — so a
            // disconnect doesn't churn the host; a fresh connection loads it.
            if active[strip.id] == nil, !stripIsConnected(strip, in: allConns) {
                continue
            }
            let sideTag = strip.side == .destination ? " RX" : ""
            let chainInfo = VSTChainInfo(id: strip.id,
                                         name: "\(strip.nodeID):\(strip.channelIndex + 1)\(sideTag)",
                                         plugins: strip.inserts,
                                         isolated: strip.isolated)
            let tap: ChainTap
            if let existing = active[strip.id], existing.info == chainInfo {
                tap = existing
            } else {
                // Some VST3 plugins create NSWindow/NSView during
                // IAudioProcessor::initialize(), which requires the main thread.
                // At startup rebuildTapsLocked is called directly on main, so
                // we check first to avoid the DispatchQueue.main.sync-on-main
                // deadlock. At runtime we're on hydra.strips queue with main
                // free in its RunLoop, so the sync dispatch is safe.
                if Thread.isMainThread {
                    tap = ChainTap(info: chainInfo, sampleRate: engineRate, sharedHost: sharedHost)
                } else {
                    tap = DispatchQueue.main.sync {
                        ChainTap(info: chainInfo, sampleRate: engineRate, sharedHost: sharedHost)
                    }
                }
            }
            next[strip.id] = tap

            let channels = strip.stereo ? 2 : 1
            for offset in 0..<channels {
                routes.append(StripRoute(nodeID: strip.nodeID,
                                         channelIndex: strip.channelIndex + offset,
                                         chainID: strip.id,
                                         stripChannel: Int32(offset),
                                         trim: strip.trim,
                                         side: strip.side))
            }
        }
        active = next
        store.setStripData(taps: Array(next.values), routes: routes)
    }
}
