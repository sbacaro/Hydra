// Hydra Audio — GPL-3.0
// BridgeManager — owns the fixed set of Hydra Audio Bridges (see
// Hydra.bridgeCatalog). Each bridge is its own loopback CoreAudio device behind
// a CoreAudio "box"; an UNACQUIRED box hides the device from the whole system.
//
// Enabling a bridge = acquire its box (the device appears in Audio MIDI Setup and
// every app's device picker) AND attach an engine IOProc so Hydra routes it in
// the grid as a `bridge:<id>` node. Disabling = detach + release the box. The
// user's enabled set is persisted, so bridges come back across launches.
//
// Routing reuses the proven physical-device path: each enabled+present bridge
// gets a DeviceIO (rings + consumer-side ASRC) and is registered with MatrixStore
// via setBridgeTaps. The matrix itself is driven by the hidden engine hub
// (AudioEngine's IOProc), exactly as physical devices are.

import Foundation
import CoreAudio
import HydraCore

// @unchecked Sendable: all mutable state is confined to the serial `queue`
// (matches Aes67Manager / ModuleManager). Required to capture self in the
// @Sendable queue.async / CoreAudio listener closures.
final class BridgeManager: @unchecked Sendable {

    private let store: MatrixStore
    private let queue = DispatchQueue(label: "hydra.bridges")
    /// Bridge ids the user has turned on (persisted).
    private var enabledIDs: Set<String>
    /// Per-bridge grid role (in/out/both). Display-only — controls which
    /// directions surface in the grid; missing entries default to `.both`.
    private var roles: [String: BridgeRole] = [:]
    /// Bridges transmitting their OUTPUT over NDI / AES67.
    private var ndiTXSet: Set<String> = []
    private var aes67TXSet: Set<String> = []
    /// Bridge ids referenced by ≥1 patch (from MatrixStore). We open IOProcs/ASRC
    /// only for these — a bridge that's enabled but unpatched carries no Hydra
    /// audio, so attaching it would just waste CPU (this caused XRUN storms).
    private var usedBridgeIDs: Set<String> = []
    /// Attached engine IO, keyed by bridge id (only enabled+present+patched).
    private var active: [String: DeviceIO] = [:]
    /// Pending debounced reconcile (coalesces the box-acquire storm).
    private var reconcileWork: DispatchWorkItem?
    /// Called on the manager queue after any change, with the fresh list.
    var onChange: (([BridgeInfo]) -> Void)?

    /// Engine IOProc attach can be disabled at runtime for isolation:
    /// `HYDRA_BRIDGE_ATTACH=0` keeps bridges visible (boxes acquired) but opens
    /// NO IOProcs — useful to tell the hub apart from bridge attach if coreaudiod
    /// misbehaves.
    private static var attachEnabled: Bool {
        ProcessInfo.processInfo.environment["HYDRA_BRIDGE_ATTACH"] != "0"
    }

    private static let persistURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hydra", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("bridges.json")
    }()

    /// Persisted shape: enabled ids + per-bridge role. Tolerates the legacy
    /// `[String]` (enabled only) format.
    private struct Persisted: Codable {
        var enabled: [String]
        var roles: [String: String]
        var ndiTX: [String]?
        var aes67TX: [String]?
    }

    init(store: MatrixStore) {
        self.store = store
        let valid = Set(Hydra.bridgeCatalog.map(\.id))
        if let data = try? Data(contentsOf: Self.persistURL),
           let p = try? JSONDecoder().decode(Persisted.self, from: data) {
            enabledIDs = Set(p.enabled).intersection(valid)
            roles = p.roles.reduce(into: [:]) { acc, kv in
                if valid.contains(kv.key), let r = BridgeRole(rawValue: kv.value) { acc[kv.key] = r }
            }
            ndiTXSet = Set(p.ndiTX ?? []).intersection(valid)
            aes67TXSet = Set(p.aes67TX ?? []).intersection(valid)
        } else if let data = try? Data(contentsOf: Self.persistURL),
                  let ids = try? JSONDecoder().decode([String].self, from: data) {
            enabledIDs = Set(ids).intersection(valid)   // legacy format
        } else {
            // First run: all bridges enabled (visible). The user turns off the
            // ones they don't want in the sidebar.
            enabledIDs = valid
        }
    }

    /// Reconcile the system to the persisted enabled set and start tracking
    /// device-list changes (a box we acquire makes its device appear a moment
    /// later — the listener catches it and attaches the engine IO).
    func start() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue) { [weak self] _, _ in
            self?.scheduleReconcile()
        }
        queue.async { [weak self] in
            guard let self else { return }
            for spec in Hydra.bridgeCatalog {
                Self.setBoxAcquired(uid: spec.uid, acquired: self.enabledIDs.contains(spec.id))
            }
            self.scheduleReconcile()
        }
    }

    /// Coalesce rapid device-list changes (acquiring 8 boxes fires the listener
    /// many times in a burst) into a single reconcile, so we don't churn IOProcs.
    private func scheduleReconcile() {
        reconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcileLocked() }
        reconcileWork = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func infos() -> [BridgeInfo] {
        queue.sync { infosLocked() }
    }

    /// Set a bridge's grid role (in/out/both). Display-only; just persist + report.
    func setRole(id: String, role: BridgeRole) {
        queue.async { [weak self] in
            guard let self, Hydra.bridgeSpec(id: id) != nil else { return }
            self.roles[id] = role
            self.persist()
            self.report()
        }
    }

    /// Enable/disable NDI / AES67 transmit of a bridge's output. Re-attaches if
    /// needed (a TX bridge must run even when not patched) and re-syncs senders.
    func setNetworkTX(id: String, ndiTX: Bool, aes67TX: Bool) {
        queue.async { [weak self] in
            guard let self, Hydra.bridgeSpec(id: id) != nil else { return }
            if ndiTX { self.ndiTXSet.insert(id) } else { self.ndiTXSet.remove(id) }
            if aes67TX { self.aes67TXSet.insert(id) } else { self.aes67TXSet.remove(id) }
            self.persist()
            self.reconcileLocked()   // attach/detach for TX; reports via onChange
        }
    }

    /// The set of bridges referenced by the patch matrix changed — re-evaluate
    /// which ones need an engine IOProc (called from MatrixStore.onBridgeUsage).
    func setUsedBridges(_ ids: Set<String>) {
        queue.async { [weak self] in
            guard let self, ids != self.usedBridgeIDs else { return }
            self.usedBridgeIDs = ids
            self.scheduleReconcile()
        }
    }

    /// Turn a bridge on/off: acquire/release its box, then re-attach engine IO.
    func setEnabled(id: String, enabled: Bool) {
        queue.async { [weak self] in
            guard let self, let spec = Hydra.bridgeSpec(id: id) else { return }
            if enabled { self.enabledIDs.insert(id) } else { self.enabledIDs.remove(id) }
            self.persist()
            Self.setBoxAcquired(uid: spec.uid, acquired: enabled)
            self.scheduleReconcile()
        }
    }

    // MARK: - Internals (manager queue)

    private struct PresentBridge {
        let spec: Hydra.BridgeSpec
        let deviceID: AudioObjectID
        let inChannels: Int
        let outChannels: Int
        let sampleRate: Double
    }

    /// Catalog bridges whose CoreAudio device is currently visible.
    private func presentBridges() -> [PresentBridge] {
        var byUID: [String: AudioObjectID] = [:]
        for id in BackplaneProbe.allDeviceIDs() {
            if let uid = BackplaneProbe.deviceUID(id) { byUID[uid] = id }
        }
        return Hydra.bridgeCatalog.compactMap { spec in
            guard let devID = byUID[spec.uid] else { return nil }
            return PresentBridge(
                spec: spec, deviceID: devID,
                inChannels: BackplaneProbe.channelCount(devID, scope: kAudioDevicePropertyScopeInput),
                outChannels: BackplaneProbe.channelCount(devID, scope: kAudioDevicePropertyScopeOutput),
                sampleRate: BackplaneProbe.nominalSampleRate(devID))
        }
    }

    private func infosLocked() -> [BridgeInfo] {
        let present = Set(presentBridges().map(\.spec.id))
        return Hydra.bridgeCatalog.map { spec in
            BridgeInfo(id: spec.id, name: spec.name, channels: spec.channels,
                       enabled: enabledIDs.contains(spec.id),
                       present: present.contains(spec.id),
                       role: roles[spec.id] ?? .both,
                       ndiTX: ndiTXSet.contains(spec.id),
                       aes67TX: aes67TXSet.contains(spec.id))
        }
    }

    /// Broadcast the current bridge list (manager queue only).
    private func report() { onChange?(infosLocked()) }

    /// Attach enabled+present bridges as engine taps; detach the rest.
    private func reconcileLocked() {
        reconcileWork = nil
        let present = presentBridges()
        let engineRate = BackplaneProbe.backplaneDeviceID()
            .map(BackplaneProbe.nominalSampleRate) ?? Hydra.defaultSampleRate
        // Lazy attach: only bridges that are enabled AND patched get an IOProc.
        // (HYDRA_BRIDGE_ATTACH=0 forces none — bridges stay visible but unrouted.)
        // Attach a bridge if it's enabled and either patched OR transmitting over
        // the network (a TX bridge must run even with no grid patch).
        let wanted = Self.attachEnabled
            ? present.filter {
                enabledIDs.contains($0.spec.id) &&
                (usedBridgeIDs.contains($0.spec.id) ||
                 ndiTXSet.contains($0.spec.id) || aes67TXSet.contains($0.spec.id))
              }
            : []
        let wantedIDs = Set(wanted.map(\.spec.id))

        // Detach: disabled or no longer present.
        for (id, io) in active where !wantedIDs.contains(id) {
            io.stop()
            active.removeValue(forKey: id)
        }
        // Attach new ones.
        for b in wanted where active[b.spec.id] == nil {
            let io = DeviceIO(uid: b.spec.uid, name: b.spec.name, deviceID: b.deviceID,
                              inChannels: b.inChannels, outChannels: b.outChannels,
                              sampleRate: b.sampleRate, engineRate: engineRate,
                              nodeID: Hydra.bridgeNodeID(id: b.spec.id))
            if io.start() { active[b.spec.id] = io }
        }

        store.setBridgeTaps(active.values.sorted { $0.uid < $1.uid })
        onChange?(infosLocked())
    }

    private func persist() {
        let p = Persisted(enabled: Array(enabledIDs).sorted(),
                          roles: roles.mapValues(\.rawValue),
                          ndiTX: Array(ndiTXSet).sorted(),
                          aes67TX: Array(aes67TXSet).sorted())
        if let data = try? JSONEncoder().encode(p) {
            try? data.write(to: Self.persistURL, options: .atomic)
        }
    }

    // MARK: - CoreAudio box plumbing

    /// Acquire (show) or release (hide) the box whose UID matches `uid`.
    private static func setBoxAcquired(uid: String, acquired: Bool) {
        guard let box = boxID(forUID: uid) else {
            log("BridgeManager: box not found for \(uid) — driver installed?")
            return
        }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioBoxPropertyAcquired,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = acquired ? 1 : 0
        let status = AudioObjectSetPropertyData(
            box, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        if status != noErr {
            log("BridgeManager: set acquired=\(acquired) on \(uid) failed (\(status))")
        }
    }

    private static func allBoxIDs() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyBoxList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func boxUID(_ box: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioBoxPropertyBoxUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var uid: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(box, &addr, 0, nil, &size, &uid) == noErr,
              let cf = uid?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private static func boxID(forUID uid: String) -> AudioObjectID? {
        allBoxIDs().first { boxUID($0) == uid }
    }
}
