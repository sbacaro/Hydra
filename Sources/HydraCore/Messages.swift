// Hydra Audio — GPL-3.0
// Typed WebSocket messages between app (client) and daemon (server).
// JSON envelope: {"type": "...", "payload": {...}}

import Foundation

// MARK: - Payloads

/// Daemon → app: current daemon/backplane status.
public struct StatusPayload: Codable, Sendable, Equatable {
    public var daemonVersion: String
    /// True when the backplane device was found via Core Audio.
    public var backplaneInstalled: Bool
    public var backplaneDeviceName: String?
    public var inputChannels: Int
    public var outputChannels: Int
    public var sampleRate: Double
    /// True when the audio engine (IOProc) is attached and running.
    public var engineRunning: Bool
    /// Render load: time spent inside the IOProc / cycle period (0…1),
    /// exponentially smoothed. 0 when the engine is idle.
    public var cpuLoad: Double
    /// CoreAudio processor-overload count since the engine started (XRUNs).
    public var xruns: Int

    public init(daemonVersion: String,
                backplaneInstalled: Bool,
                backplaneDeviceName: String? = nil,
                inputChannels: Int = 0,
                outputChannels: Int = 0,
                sampleRate: Double = 0,
                engineRunning: Bool = false,
                cpuLoad: Double = 0,
                xruns: Int = 0) {
        self.daemonVersion = daemonVersion
        self.backplaneInstalled = backplaneInstalled
        self.backplaneDeviceName = backplaneDeviceName
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.sampleRate = sampleRate
        self.engineRunning = engineRunning
        self.cpuLoad = cpuLoad
        self.xruns = xruns
    }

    private enum CodingKeys: String, CodingKey {
        case daemonVersion, backplaneInstalled, backplaneDeviceName
        case inputChannels, outputChannels, sampleRate, engineRunning
        case cpuLoad, xruns
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        daemonVersion = try c.decode(String.self, forKey: .daemonVersion)
        backplaneInstalled = try c.decode(Bool.self, forKey: .backplaneInstalled)
        backplaneDeviceName = try c.decodeIfPresent(String.self, forKey: .backplaneDeviceName)
        inputChannels = try c.decodeIfPresent(Int.self, forKey: .inputChannels) ?? 0
        outputChannels = try c.decodeIfPresent(Int.self, forKey: .outputChannels) ?? 0
        sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 0
        engineRunning = try c.decodeIfPresent(Bool.self, forKey: .engineRunning) ?? false
        cpuLoad = try c.decodeIfPresent(Double.self, forKey: .cpuLoad) ?? 0
        xruns = try c.decodeIfPresent(Int.self, forKey: .xruns) ?? 0
    }
}

/// Daemon → app: full matrix state (pushed on connect and after every change).
public struct MatrixPayload: Codable, Sendable, Equatable {
    public var connections: [Connection]
    public init(connections: [Connection]) {
        self.connections = connections
    }
}

/// Daemon → app (~10 Hz): meters.
public struct LevelsPayload: Codable, Sendable, Equatable {
    /// Post-gain peak per connection ID (linear).
    public var peaks: [String: Float]
    /// Per-channel input peaks (linear), index = channel. For signal LEDs.
    public var sourcePeaks: [Float]?
    /// Per-channel output peaks (linear), index = channel.
    public var destinationPeaks: [Float]?
    /// Source-node channels that currently carry signal, as "nodeID:channel"
    /// keys. Lets a transmitter's pin light from its OWN audio (app/device/NDI/…)
    /// even when it isn't patched anywhere — the backplane peaks above only cover
    /// the engine hub, not the per-node sources.
    public var activeSources: [String]?

    public init(peaks: [String: Float],
                sourcePeaks: [Float]? = nil,
                destinationPeaks: [Float]? = nil,
                activeSources: [String]? = nil) {
        self.peaks = peaks
        self.sourcePeaks = sourcePeaks
        self.destinationPeaks = destinationPeaks
        self.activeSources = activeSources
    }
}

// MARK: Physical devices

/// A physical audio device as seen by the daemon (Phase 2b).
public struct PhysicalDeviceInfo: Codable, Sendable, Equatable, Identifiable {
    /// Core Audio device UID — stable across reconnects.
    public var uid: String
    public var name: String
    public var inputChannels: Int
    public var outputChannels: Int
    public var sampleRate: Double
    /// User opted this device into the grid.
    public var used: Bool
    /// Currently connected (a used device can be temporarily absent;
    /// its patch re-binds automatically when it returns — Section 7.8).
    public var present: Bool

    public var id: String { uid }
    public var nodeID: String { Hydra.deviceNodeID(uid: uid) }

    public init(uid: String, name: String, inputChannels: Int, outputChannels: Int,
                sampleRate: Double, used: Bool, present: Bool) {
        self.uid = uid
        self.name = name
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.sampleRate = sampleRate
        self.used = used
        self.present = present
    }
}

/// Daemon → app: all known devices (pushed on connect and on hot-plug).
public struct DevicesPayload: Codable, Sendable, Equatable {
    public var devices: [PhysicalDeviceInfo]
    public init(devices: [PhysicalDeviceInfo]) {
        self.devices = devices
    }
}

/// App → daemon: opt a device in/out of the grid.
public struct SetDeviceUsePayload: Codable, Sendable, Equatable {
    public var uid: String
    public var used: Bool
    public init(uid: String, used: Bool) {
        self.uid = uid
        self.used = used
    }
}

// MARK: App capture (process taps)

/// A running app that registered with the audio system (Phase 3).
public struct AppInfo: Codable, Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var bundleID: String?
    public var name: String
    /// Currently producing audio output.
    public var isPlaying: Bool
    /// User opted this app's audio into the grid.
    public var captured: Bool

    public var id: Int32 { pid }
    public var nodeID: String { Hydra.appNodeID(bundleID: bundleID, pid: pid) }

    public init(pid: Int32, bundleID: String?, name: String, isPlaying: Bool, captured: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.isPlaying = isPlaying
        self.captured = captured
    }
}

/// Daemon → app: audio-capable apps (pushed on connect and on changes).
public struct AppsPayload: Codable, Sendable, Equatable {
    public var apps: [AppInfo]
    public init(apps: [AppInfo]) {
        self.apps = apps
    }
}

/// App → daemon: start/stop capturing an app.
public struct SetAppCapturePayload: Codable, Sendable, Equatable {
    public var pid: Int32
    public var captured: Bool
    public init(pid: Int32, captured: Bool) {
        self.pid = pid
        self.captured = captured
    }
}

// MARK: VST3 chains (Phase 6)

/// An installed VST3 plugin class (effect or instrument).
public struct VSTPlugin: Codable, Sendable, Equatable, Identifiable {
    /// "<bundle path>#<class index>" — stable while the bundle stays put.
    public var id: String
    public var name: String
    public var vendor: String
    /// VST3 subcategory string from the class info, e.g. "Fx", "Fx|Reverb",
    /// "Fx|Dynamics", "Instrument", "Instrument|Synth". "" when unknown (old data).
    public var category: String
    /// True when the bundle hung or crashed during the (isolated) scan and was
    /// skipped. Shown in the manager as "offline"; never offered as an insert.
    public var offline: Bool

    public init(id: String, name: String, vendor: String,
                category: String = "", offline: Bool = false) {
        self.id = id
        self.name = name
        self.vendor = vendor
        self.category = category
        self.offline = offline
    }

    /// Backward-compatible decode: `category`/`offline` are optional (absent in
    /// pre-1.x data persisted inside strips/scenes).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        vendor = try c.decode(String.self, forKey: .vendor)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        offline = try c.decodeIfPresent(Bool.self, forKey: .offline) ?? false
    }

    private enum CodingKeys: String, CodingKey { case id, name, vendor, category, offline }

    /// True when this is an instrument (VSTi) rather than an effect.
    public var isInstrument: Bool { category.localizedCaseInsensitiveContains("Instrument") }
    /// Top-level type segment for grouping/filtering, e.g. "Fx" or "Instrument".
    /// Falls back to "Fx" (the historical scan only collected effects).
    public var primaryType: String {
        category.split(separator: "|").first.map(String.init) ?? (category.isEmpty ? "Fx" : category)
    }
}

/// Internal effect-sequence description (used by the engine's chain taps).
public struct VSTChainInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var plugins: [VSTPlugin]
    /// Mirror of StripInfo.isolated — host this chain out-of-process.
    public var isolated: Bool

    public init(id: UUID = UUID(), name: String, plugins: [VSTPlugin] = [],
                isolated: Bool = true) {
        self.id = id
        self.name = name
        self.plugins = plugins
        self.isolated = isolated
    }
}

/// Daemon → app: installed plugins + the user's availability/favorite choices.
public struct VSTPayload: Codable, Sendable, Equatable {
    public var available: [VSTPlugin]
    /// Plugin IDs the user HID (opt-out): everything not listed here is offered
    /// to the strip's insert picker. Empty = all available (the default).
    public var disabledIDs: [String]
    /// Plugin IDs the user starred — surfaced first in the picker.
    public var favoriteIDs: [String]
    /// nil = never scanned (the app offers the first scan explicitly).
    public var scannedAt: Date?
    /// Live scan state (broadcast while a scan runs).
    public var scanning: Bool
    /// 0...1 while scanning.
    public var scanProgress: Double
    /// The bundle currently being probed (UI caption).
    public var scanLabel: String

    public init(available: [VSTPlugin],
                disabledIDs: [String] = [], favoriteIDs: [String] = [],
                scannedAt: Date? = nil, scanning: Bool = false, scanProgress: Double = 0,
                scanLabel: String = "") {
        self.available = available
        self.disabledIDs = disabledIDs
        self.favoriteIDs = favoriteIDs
        self.scannedAt = scannedAt
        self.scanning = scanning
        self.scanProgress = scanProgress
        self.scanLabel = scanLabel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = try c.decodeIfPresent([VSTPlugin].self, forKey: .available) ?? []
        disabledIDs = try c.decodeIfPresent([String].self, forKey: .disabledIDs) ?? []
        favoriteIDs = try c.decodeIfPresent([String].self, forKey: .favoriteIDs) ?? []
        scannedAt = try c.decodeIfPresent(Date.self, forKey: .scannedAt)
        scanning = try c.decodeIfPresent(Bool.self, forKey: .scanning) ?? false
        scanProgress = try c.decodeIfPresent(Double.self, forKey: .scanProgress) ?? 0
        scanLabel = try c.decodeIfPresent(String.self, forKey: .scanLabel) ?? ""
    }

    /// The plugins the strip picker should offer: not hidden, favorites first,
    /// then alphabetical. (UI convenience — pure, easily unit-tested.)
    public func pickerPlugins() -> [VSTPlugin] {
        let hidden = Set(disabledIDs)
        let favs = Set(favoriteIDs)
        return available
            .filter { !$0.offline && !hidden.contains($0.id) }   // offline = can't load
            .sorted { a, b in
                let fa = favs.contains(a.id), fb = favs.contains(b.id)
                if fa != fb { return fa }                    // favorites first
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }
}

/// App → daemon: show/hide a plugin in the strip picker (opt-out model).
public struct PluginAvailabilityPayload: Codable, Sendable, Equatable {
    public var id: String
    public var available: Bool
    public init(id: String, available: Bool) { self.id = id; self.available = available }
}

/// App → daemon: star/unstar a plugin.
public struct PluginFavoritePayload: Codable, Sendable, Equatable {
    public var id: String
    public var favorite: Bool
    public init(id: String, favorite: Bool) { self.id = id; self.favorite = favorite }
}

/// Which side of the patch a strip's inserts process.
/// `.source` — the transmitter side: audio leaving the source passes through
/// the inserts before reaching any destination (the historical behaviour).
/// `.destination` — the receiver side: everything patched INTO the destination
/// is summed, processed by the inserts, then delivered to the receiving channel.
public enum StripSide: String, Codable, Sendable, Equatable {
    case source
    case destination
}

/// A channel strip (Logic-style): a source OR destination channel (or stereo
/// pair) with insert slots and trim. Keyed by (nodeID, channelIndex, side);
/// stereo strips cover channelIndex and channelIndex+1.
public struct StripInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var nodeID: String
    public var channelIndex: Int
    public var stereo: Bool
    /// Which side of the patch these inserts sit on (source/destination).
    public var side: StripSide
    /// Channel trim, linear (applied before the inserts).
    public var trim: Float
    /// Ordered insert slots.
    public var inserts: [VSTPlugin]
    /// Run this strip's inserts in a SEPARATE process (crash isolation). On by
    /// default — a crashing plugin then takes down only that host, not the
    /// daemon. Turn off for plugins you trust to drop the ~1-block latency.
    public var isolated: Bool

    public init(id: UUID = UUID(), nodeID: String, channelIndex: Int,
                stereo: Bool, side: StripSide = .source,
                trim: Float = 1.0, inserts: [VSTPlugin] = [],
                isolated: Bool = true) {
        self.id = id
        self.nodeID = nodeID
        self.channelIndex = channelIndex
        self.stereo = stereo
        self.side = side
        self.trim = trim
        self.inserts = inserts
        self.isolated = isolated
    }

    private enum CodingKeys: String, CodingKey {
        case id, nodeID, channelIndex, stereo, side, trim, inserts, isolated
    }

    // Backward compatible: strips persisted before these fields existed default
    // to isolated (crash-protected) and the source (transmitter) side.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        nodeID = try c.decode(String.self, forKey: .nodeID)
        channelIndex = try c.decode(Int.self, forKey: .channelIndex)
        stereo = try c.decode(Bool.self, forKey: .stereo)
        side = try c.decodeIfPresent(StripSide.self, forKey: .side) ?? .source
        trim = try c.decode(Float.self, forKey: .trim)
        inserts = try c.decode([VSTPlugin].self, forKey: .inserts)
        isolated = try c.decodeIfPresent(Bool.self, forKey: .isolated) ?? true
    }

    /// Storage/lookup key. Source keeps the historical "node:ch" form (so old
    /// persisted strips and existing lookups still resolve); a destination strip
    /// gets a ":rx" suffix so it can coexist with a source strip on the same
    /// channel.
    public var key: String {
        side == .source ? "\(nodeID):\(channelIndex)" : "\(nodeID):\(channelIndex):rx"
    }
}

/// Daemon → app: all configured strips.
public struct StripsPayload: Codable, Sendable, Equatable {
    public var strips: [StripInfo]
    public init(strips: [StripInfo]) {
        self.strips = strips
    }
}

/// App → daemon: open the editor window of a loaded insert.
public struct OpenEditorPayload: Codable, Sendable, Equatable {
    public var stripID: UUID
    public var index: Int
    /// Shift-open: keep this editor window standing on its own (don't close it
    /// when another editor opens, and don't let it be the auto-closed "transient"
    /// one). Defaults to false so an older client decodes as a normal open.
    public var pinned: Bool
    public init(stripID: UUID, index: Int, pinned: Bool = false) {
        self.stripID = stripID
        self.index = index
        self.pinned = pinned
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stripID = try c.decode(UUID.self, forKey: .stripID)
        index = try c.decode(Int.self, forKey: .index)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

// MARK: Labels

public enum ChannelScope: String, Codable, Sendable {
    case input, output
}

/// User labels per channel, persisted apart from system IDs (Section 7.7).
public struct ChannelLabelsPayload: Codable, Sendable, Equatable {
    /// channel index (0-based) → label
    public var inputs: [Int: String]
    public var outputs: [Int: String]

    public init(inputs: [Int: String] = [:], outputs: [Int: String] = [:]) {
        self.inputs = inputs
        self.outputs = outputs
    }

    public func label(_ scope: ChannelScope, _ index: Int) -> String? {
        scope == .input ? inputs[index] : outputs[index]
    }
}

/// App → daemon: set (or clear, with nil) one channel label.
public struct SetLabelPayload: Codable, Sendable, Equatable {
    public var scope: ChannelScope
    public var index: Int
    public var label: String?

    public init(scope: ChannelScope, index: Int, label: String?) {
        self.scope = scope
        self.index = index
        self.label = label
    }
}

// MARK: Scenes

/// Daemon → app: all saved scenes.
public struct ScenesPayload: Codable, Sendable {
    public var scenes: [PatchScene]
    public init(scenes: [PatchScene]) {
        self.scenes = scenes
    }
}

/// App → daemon: snapshot the current matrix under a name.
public struct SaveScenePayload: Codable, Sendable, Equatable {
    public var name: String
    public init(name: String) {
        self.name = name
    }
}

/// App → daemon: reference a scene by ID (apply / delete).
public struct SceneRefPayload: Codable, Sendable, Equatable {
    public var id: UUID
    public init(id: UUID) {
        self.id = id
    }
}

// MARK: Virtual interfaces (named blocks allocated from the 256-channel pool)

/// A user-created interface: a named, contiguous slice of the soundcard pool.
/// Only virtual interfaces (plus apps, streams and physical devices) appear
/// in the grid — the raw pool stays invisible. The app starts with zero
/// channels; the user builds their own set.
public struct VirtualInterfaceInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// Input lanes (rows — what external software PLAYS into Hydra) and
    /// output lanes (columns — what it RECORDS), sized independently
    /// (e.g. an AES67 return of 128×2). Each side gets its own exclusive
    /// slice of the 256-channel pool, allocated by the daemon.
    public var inChannels: Int
    public var outChannels: Int
    public var inBase: Int
    public var outBase: Int
    /// When true, whatever is routed to this interface's Out channels is
    /// broadcast on the network as an NDI audio source named after it.
    public var ndiTX: Bool
    /// When true, the Out side is announced via SAP and transmitted as an
    /// AES67 multicast flow (experimental until PTP sync lands).
    public var aes67TX: Bool
    /// When true, this interface's channels are grouped into stereo pairs
    /// (in/out counts must be even). Purely a layout hint: the grid shows one
    /// lane per pair (L/R) and patching connects L→L, R→R. Audio routing stays
    /// per-channel, so the daemon needs no special handling beyond persisting it.
    public var stereo: Bool

    public init(id: UUID = UUID(), name: String,
                inChannels: Int, outChannels: Int,
                inBase: Int, outBase: Int,
                ndiTX: Bool = false, aes67TX: Bool = false, stereo: Bool = false) {
        self.id = id
        self.name = name
        self.inChannels = inChannels
        self.outChannels = outChannels
        self.inBase = inBase
        self.outBase = outBase
        self.ndiTX = ndiTX
        self.aes67TX = aes67TX
        self.stereo = stereo
    }

    /// Pool channels this interface consumes in total.
    public var poolUse: Int { inChannels + outChannels }

    // Tolerate interfaces.json from before in/out split (single channels/base
    // meant the SAME slice both directions) and before ndiTX existed.
    private enum CodingKeys: String, CodingKey {
        case id, name, inChannels, outChannels, inBase, outBase, ndiTX, aes67TX, stereo
        case channels, base // legacy
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        let legacyChannels = try c.decodeIfPresent(Int.self, forKey: .channels) ?? 0
        let legacyBase = try c.decodeIfPresent(Int.self, forKey: .base) ?? 0
        inChannels = try c.decodeIfPresent(Int.self, forKey: .inChannels) ?? legacyChannels
        outChannels = try c.decodeIfPresent(Int.self, forKey: .outChannels) ?? legacyChannels
        inBase = try c.decodeIfPresent(Int.self, forKey: .inBase) ?? legacyBase
        outBase = try c.decodeIfPresent(Int.self, forKey: .outBase) ?? legacyBase
        ndiTX = try c.decodeIfPresent(Bool.self, forKey: .ndiTX) ?? false
        aes67TX = try c.decodeIfPresent(Bool.self, forKey: .aes67TX) ?? false
        stereo = try c.decodeIfPresent(Bool.self, forKey: .stereo) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(inChannels, forKey: .inChannels)
        try c.encode(outChannels, forKey: .outChannels)
        try c.encode(inBase, forKey: .inBase)
        try c.encode(outBase, forKey: .outBase)
        try c.encode(ndiTX, forKey: .ndiTX)
        try c.encode(aes67TX, forKey: .aes67TX)
        try c.encode(stereo, forKey: .stereo)
    }
}

public struct InterfacesPayload: Codable, Sendable, Equatable {
    public var interfaces: [VirtualInterfaceInfo]
    public init(interfaces: [VirtualInterfaceInfo]) {
        self.interfaces = interfaces
    }
}

/// App → daemon: create a named interface (daemon allocates the slices).
public struct CreateInterfacePayload: Codable, Sendable, Equatable {
    public var name: String
    public var inChannels: Int
    public var outChannels: Int
    public var ndiTX: Bool
    public var aes67TX: Bool
    public var stereo: Bool
    public init(name: String, inChannels: Int, outChannels: Int,
                ndiTX: Bool = false, aes67TX: Bool = false, stereo: Bool = false) {
        self.name = name
        self.inChannels = inChannels
        self.outChannels = outChannels
        self.ndiTX = ndiTX
        self.aes67TX = aes67TX
        self.stereo = stereo
    }

    private enum CodingKeys: String, CodingKey {
        case name, inChannels, outChannels, ndiTX, aes67TX, stereo
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        inChannels = try c.decode(Int.self, forKey: .inChannels)
        outChannels = try c.decode(Int.self, forKey: .outChannels)
        ndiTX = try c.decodeIfPresent(Bool.self, forKey: .ndiTX) ?? false
        aes67TX = try c.decodeIfPresent(Bool.self, forKey: .aes67TX) ?? false
        stereo = try c.decodeIfPresent(Bool.self, forKey: .stereo) ?? false
    }
}

/// App → daemon: toggle an interface's NDI TX.
public struct InterfaceNDIPayload: Codable, Sendable, Equatable {
    public var id: UUID
    public var enabled: Bool
    public init(id: UUID, enabled: Bool) {
        self.id = id
        self.enabled = enabled
    }
}

// MARK: NDI

/// One NDI source on the network (discovered by the runtime).
public struct NdiSourceInfo: Codable, Sendable, Equatable, Identifiable {
    /// Full NDI name ("MACHINE (Source)") — stable identifier.
    public var id: String
    public var name: String
    public var url: String
    /// 0 until the first audio frame arrives (NDI doesn't advertise format).
    public var channels: Int
    public var sampleRate: Double
    public var subscribed: Bool

    public init(id: String, name: String, url: String,
                channels: Int = 0, sampleRate: Double = 0, subscribed: Bool = false) {
        self.id = id
        self.name = name
        self.url = url
        self.channels = channels
        self.sampleRate = sampleRate
        self.subscribed = subscribed
    }
}

public struct NdiPayload: Codable, Sendable, Equatable {
    /// False when the NDI runtime isn't installed on this machine.
    public var runtimeAvailable: Bool
    public var runtimeVersion: String?
    public var sources: [NdiSourceInfo]

    public init(runtimeAvailable: Bool = false, runtimeVersion: String? = nil,
                sources: [NdiSourceInfo] = []) {
        self.runtimeAvailable = runtimeAvailable
        self.runtimeVersion = runtimeVersion
        self.sources = sources
    }
}

public struct SubscribeNdiPayload: Codable, Sendable, Equatable {
    public var id: String
    public var subscribed: Bool
    public init(id: String, subscribed: Bool) {
        self.id = id
        self.subscribed = subscribed
    }
}

// MARK: - Modules (generic plugin host; experimental/personal)

/// A source advertised by a loaded module (e.g. a network device's channels).
public struct ModuleSourceInfo: Codable, Sendable, Equatable, Identifiable {
    /// Stable id, namespaced by the module.
    public var id: String
    public var name: String
    public var moduleName: String
    /// 0 until the format is known.
    public var channels: Int
    public var subscribed: Bool

    public init(id: String, name: String, moduleName: String,
                channels: Int = 0, subscribed: Bool = false) {
        self.id = id
        self.name = name
        self.moduleName = moduleName
        self.channels = channels
        self.subscribed = subscribed
    }
}

/// A loaded module's identity/status.
public struct ModuleInfo: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var version: String
    public var id: String { name }
    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// A sink advertised by a loaded module (a transmit destination — Hydra → network).
public struct ModuleSinkInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var moduleName: String
    public var channels: Int
    public init(id: String, name: String, moduleName: String, channels: Int) {
        self.id = id; self.name = name; self.moduleName = moduleName; self.channels = channels
    }
}

/// Daemon → app: loaded modules + the sources (RX) and sinks (TX) they expose.
public struct ModulesPayload: Codable, Sendable, Equatable {
    public var modules: [ModuleInfo]
    public var sources: [ModuleSourceInfo]
    public var sinks: [ModuleSinkInfo]
    public init(modules: [ModuleInfo] = [], sources: [ModuleSourceInfo] = [],
                sinks: [ModuleSinkInfo] = []) {
        self.modules = modules
        self.sources = sources
        self.sinks = sinks
    }
}

/// App → daemon: subscribe/unsubscribe to a module source.
public struct SubscribeModuleSourcePayload: Codable, Sendable, Equatable {
    public var id: String
    public var subscribed: Bool
    public init(id: String, subscribed: Bool) {
        self.id = id
        self.subscribed = subscribed
    }
}

/// App → daemon: delete an interface (frees its pool slice).
public struct InterfaceRefPayload: Codable, Sendable, Equatable {
    public var id: UUID
    public init(id: UUID) {
        self.id = id
    }
}

// MARK: Config

/// Daemon-side settings (persisted by the daemon, edited in the app's
/// Settings window).
public struct ConfigPayload: Codable, Sendable, Equatable {
    /// Reject connections that would create loops on the backplane.
    public var feedbackProtection: Bool
    /// Makeup gain applied to app captures (dB) — calibration for the tap
    /// mixdown attenuation.
    public var appTapMakeupDB: Float
    /// OSC remote control (UDP, receive-only). Off by default.
    public var oscEnabled: Bool
    public var oscPort: Int
    /// Recording file format: "float32" (WAV 32-bit float) or "pcm24".
    public var recordingFormat: String
    /// Recording destination; empty = ~/Music/Hydra Recordings.
    public var recordingFolderPath: String
    /// Extra VST3 folder to scan; empty = only the standard locations
    /// (/Library/Audio/Plug-Ins/VST3 and ~/Library/Audio/Plug-Ins/VST3).
    public var vstFolderPath: String

    public init(feedbackProtection: Bool = true,
                appTapMakeupDB: Float = Hydra.appTapMakeupDB,
                oscEnabled: Bool = false,
                oscPort: Int = Hydra.defaultOSCPort,
                recordingFormat: String = "float32",
                recordingFolderPath: String = "",
                vstFolderPath: String = "") {
        self.feedbackProtection = feedbackProtection
        self.appTapMakeupDB = appTapMakeupDB
        self.oscEnabled = oscEnabled
        self.oscPort = oscPort
        self.recordingFormat = recordingFormat
        self.recordingFolderPath = recordingFolderPath
        self.vstFolderPath = vstFolderPath
    }

    // Tolerate configs saved by older versions (missing keys → defaults).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        feedbackProtection = try c.decodeIfPresent(Bool.self, forKey: .feedbackProtection) ?? true
        appTapMakeupDB = try c.decodeIfPresent(Float.self, forKey: .appTapMakeupDB) ?? Hydra.appTapMakeupDB
        oscEnabled = try c.decodeIfPresent(Bool.self, forKey: .oscEnabled) ?? false
        oscPort = try c.decodeIfPresent(Int.self, forKey: .oscPort) ?? Hydra.defaultOSCPort
        recordingFormat = try c.decodeIfPresent(String.self, forKey: .recordingFormat) ?? "float32"
        recordingFolderPath = try c.decodeIfPresent(String.self, forKey: .recordingFolderPath) ?? ""
        vstFolderPath = try c.decodeIfPresent(String.self, forKey: .vstFolderPath) ?? ""
    }
}

// MARK: Recording

/// One running recording (a virtual interface's outputs → WAV on disk).
public struct RecordingInfo: Codable, Sendable, Equatable, Identifiable {
    public var interfaceID: UUID
    public var interfaceName: String
    public var fileName: String
    public var path: String
    public var startedAt: Date

    public var id: UUID { interfaceID }

    public init(interfaceID: UUID, interfaceName: String, fileName: String,
                path: String, startedAt: Date) {
        self.interfaceID = interfaceID
        self.interfaceName = interfaceName
        self.fileName = fileName
        self.path = path
        self.startedAt = startedAt
    }
}

public struct RecordingsPayload: Codable, Sendable, Equatable {
    public var active: [RecordingInfo]
    public init(active: [RecordingInfo]) {
        self.active = active
    }
}

// MARK: Events

/// Daemon → app: recent events (sent on connect).
public struct EventsPayload: Codable, Sendable, Equatable {
    public var events: [HydraEvent]
    public init(events: [HydraEvent]) {
        self.events = events
    }
}

// MARK: - Bridges

/// How a bridge is used in the grid — controls which direction(s) of its
/// channels show (so an output-only bridge doesn't clutter the input axis).
public enum BridgeRole: String, Codable, Sendable, CaseIterable {
    case input    // capture INTO Hydra (its input channels appear as sources)
    case output   // send OUT of Hydra (its output channels appear as destinations)
    case both
    public var showsInput: Bool  { self == .input  || self == .both }
    public var showsOutput: Bool { self == .output || self == .both }
}

/// Runtime state of one fixed Hydra Audio Bridge (see `Hydra.bridgeCatalog`).
/// Derived from the catalog spec plus live state (enabled by the user, present
/// as a CoreAudio device).
public struct BridgeInfo: Codable, Sendable, Equatable, Identifiable {
    /// Matches `Hydra.BridgeSpec.id`.
    public var id: String
    public var name: String
    public var channels: Int
    /// User wants this bridge active (box acquired → device shown).
    public var enabled: Bool
    /// The CoreAudio device is currently visible in the system.
    public var present: Bool
    /// Which direction(s) to surface in the grid.
    public var role: BridgeRole
    /// Transmit this bridge's OUTPUT over NDI.
    public var ndiTX: Bool
    /// Transmit this bridge's OUTPUT over AES67.
    public var aes67TX: Bool

    public init(id: String, name: String, channels: Int,
                enabled: Bool, present: Bool, role: BridgeRole = .both,
                ndiTX: Bool = false, aes67TX: Bool = false) {
        self.id = id
        self.name = name
        self.channels = channels
        self.enabled = enabled
        self.present = present
        self.role = role
        self.ndiTX = ndiTX
        self.aes67TX = aes67TX
    }

    /// Grid node id for this bridge.
    public var nodeID: String { Hydra.bridgeNodeID(id: id) }

    // Tolerate older payloads (role/ndiTX/aes67TX default to off/.both).
    private enum CodingKeys: String, CodingKey {
        case id, name, channels, enabled, present, role, ndiTX, aes67TX
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        channels = try c.decode(Int.self, forKey: .channels)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        present = try c.decode(Bool.self, forKey: .present)
        role = try c.decodeIfPresent(BridgeRole.self, forKey: .role) ?? .both
        ndiTX = try c.decodeIfPresent(Bool.self, forKey: .ndiTX) ?? false
        aes67TX = try c.decodeIfPresent(Bool.self, forKey: .aes67TX) ?? false
    }
}

public struct SetBridgeRolePayload: Codable, Sendable, Equatable {
    public var id: String
    public var role: BridgeRole
    public init(id: String, role: BridgeRole) { self.id = id; self.role = role }
}

public struct SetBridgeNetworkTXPayload: Codable, Sendable, Equatable {
    public var id: String
    public var ndiTX: Bool
    public var aes67TX: Bool
    public init(id: String, ndiTX: Bool, aes67TX: Bool) {
        self.id = id; self.ndiTX = ndiTX; self.aes67TX = aes67TX
    }
}

// MARK: - Capture Flows (Audio-Hijack-style routing)

/// What a flow endpoint refers to. `deviceInput` captures a device's input
/// channels; `app` captures an application's output; `bridge`/`device` are
/// outputs (and `device` can also be a plain output target). `deviceOutput`
/// (capturing what apps send TO a device's output) is reserved for a later stage.
public enum FlowEndpointKind: String, Codable, Sendable, Equatable {
    case deviceInput
    case deviceOutput
    case app
    case bridge
    case device
}

/// One end of a flow: a node + the channels it touches. The flow maps the
/// source's `channels[i]` to the output's `channels[i]`, in order.
public struct FlowEndpoint: Codable, Sendable, Equatable {
    public var kind: FlowEndpointKind
    /// Device UID, app bundle id (or "pid:N"), or bridge id.
    public var id: String
    /// Display name (snapshot, for the row when the node is absent).
    public var name: String
    /// 0-based channel indices this endpoint touches (e.g. [0, 1] for ch 1–2).
    public var channels: [Int]
    public init(kind: FlowEndpointKind, id: String, name: String, channels: [Int] = [0, 1]) {
        self.kind = kind; self.id = id; self.name = name; self.channels = channels
    }
    /// Number of channels mapped.
    public var count: Int { channels.count }
}

/// A continuous route: capture `source`, send it to `output`. Audio-Hijack-style.
/// Volume lives on the matrix connection (edited in the channel-strip inspector,
/// like every other connection), not on the flow itself.
public struct FlowInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var source: FlowEndpoint
    public var output: FlowEndpoint
    /// User wants this flow live.
    public var enabled: Bool
    /// Engine confirms both ends are present and routed (daemon-set; ignored on upsert).
    public var running: Bool

    public init(id: UUID = UUID(), name: String, source: FlowEndpoint, output: FlowEndpoint,
                enabled: Bool = true, running: Bool = false) {
        self.id = id; self.name = name; self.source = source; self.output = output
        self.enabled = enabled; self.running = running
    }
}

public struct FlowsPayload: Codable, Sendable, Equatable {
    public var flows: [FlowInfo]
    public init(flows: [FlowInfo]) { self.flows = flows }
}

public struct RemoveFlowPayload: Codable, Sendable, Equatable {
    public var id: UUID
    public init(id: UUID) { self.id = id }
}

public struct BridgesPayload: Codable, Sendable, Equatable {
    public var bridges: [BridgeInfo]
    public init(bridges: [BridgeInfo]) { self.bridges = bridges }
}

public struct SetBridgeEnabledPayload: Codable, Sendable, Equatable {
    public var id: String
    public var enabled: Bool
    public init(id: String, enabled: Bool) { self.id = id; self.enabled = enabled }
}

// MARK: - Control surface (HiQnet ↔ HUI)

/// A console seen on the LAN — either dialed into the bridge (HiQnet is inbound)
/// or via a DiscoInfo UDP reply to the invite broadcast.
public struct SurfaceConsoleInfo: Codable, Sendable, Equatable, Identifiable {
    /// IPv4 address — stable identifier.
    public var id: String
    public var host: String
    /// Best-effort label (reverse-DNS or model), nil when only the IP is known.
    public var name: String?

    public init(id: String, host: String, name: String? = nil) {
        self.id = id
        self.host = host
        self.name = name
    }
}

/// Daemon → app: full control-surface state (pushed on connect and on change).
/// Fully automatic: Hydra publishes N virtual HUI ports, listens on TCP/3804 and
/// broadcasts a HiQnet invite — the console dials back in (HiQnet is inbound). The
/// `faders`/`mutes`/… arrays span ALL units (length = unitCount*8).
public struct SurfacePayload: Codable, Sendable, Equatable {
    /// The bridge is started (MIDI side live; emitting the HUI heartbeat).
    public var enabled: Bool
    /// HUI heartbeat is running → the DAW sees the surface as online.
    public var onlineToDAW: Bool
    /// A HiQnet session with the console is established.
    public var consoleConnected: Bool
    /// Console IP currently connected (peer of the inbound HiQnet session; empty =
    /// inviting/none).
    public var consoleIP: String
    /// Selected DAW preset id (see `Hydra.surfacePresets`) — affects heartbeat.
    public var presetID: String
    /// Number of HUI units published (each = 8 strips). Si Expression 3 → 4.
    public var unitCount: Int
    /// Names of the virtual HUI ports Hydra published — the DAW adds one HUI
    /// controller per name (the single setup step that lives inside the DAW).
    public var portNames: [String]
    /// Strip offset of the console's active bank/layer (slot = strip+1+offset).
    public var bankOffset: Int
    /// Diagnostic logging on (logs HiQnet frames + meter dumps to the daemon log).
    public var diagnostics: Bool
    /// Live state of ALL strips (a monitor for the UI), length = unitCount*8.
    public var faders: [Int]
    public var mutes: [Bool]
    public var solos: [Bool]
    public var selects: [Bool]
    /// Track names from the DAW (HUI scribble), per strip — shown on the console
    /// LCD and in the monitor. Length = unitCount*8 (empty string = no name yet).
    public var channelNames: [String]
    public var lastError: String?
    /// A HiQnet invite broadcast is in progress (waiting for the console to dial in).
    public var discovering: Bool
    /// Consoles seen via the last/ongoing invite (UDP DiscoInfo replies).
    public var discovered: [SurfaceConsoleInfo]

    /// Total strips across all units.
    public var stripCount: Int { unitCount * 8 }

    public init(enabled: Bool = false,
                onlineToDAW: Bool = false,
                consoleConnected: Bool = false,
                consoleIP: String = "",
                presetID: String = "protools",
                unitCount: Int = 4,
                portNames: [String] = [],
                bankOffset: Int = 0,
                diagnostics: Bool = false,
                faders: [Int] = [],
                mutes: [Bool] = [],
                solos: [Bool] = [],
                selects: [Bool] = [],
                channelNames: [String] = [],
                lastError: String? = nil,
                discovering: Bool = false,
                discovered: [SurfaceConsoleInfo] = []) {
        self.enabled = enabled
        self.onlineToDAW = onlineToDAW
        self.consoleConnected = consoleConnected
        self.consoleIP = consoleIP
        self.presetID = presetID
        self.unitCount = unitCount
        self.portNames = portNames
        self.bankOffset = bankOffset
        self.diagnostics = diagnostics
        self.faders = faders
        self.mutes = mutes
        self.solos = solos
        self.selects = selects
        self.channelNames = channelNames
        self.lastError = lastError
        self.discovering = discovering
        self.discovered = discovered
    }

    // Tolerate payloads from older daemons (missing keys → defaults).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        onlineToDAW = try c.decodeIfPresent(Bool.self, forKey: .onlineToDAW) ?? false
        consoleConnected = try c.decodeIfPresent(Bool.self, forKey: .consoleConnected) ?? false
        consoleIP = try c.decodeIfPresent(String.self, forKey: .consoleIP) ?? ""
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID) ?? "protools"
        unitCount = try c.decodeIfPresent(Int.self, forKey: .unitCount) ?? 4
        portNames = try c.decodeIfPresent([String].self, forKey: .portNames) ?? []
        bankOffset = try c.decodeIfPresent(Int.self, forKey: .bankOffset) ?? 0
        diagnostics = try c.decodeIfPresent(Bool.self, forKey: .diagnostics) ?? false
        faders = try c.decodeIfPresent([Int].self, forKey: .faders) ?? []
        mutes = try c.decodeIfPresent([Bool].self, forKey: .mutes) ?? []
        solos = try c.decodeIfPresent([Bool].self, forKey: .solos) ?? []
        selects = try c.decodeIfPresent([Bool].self, forKey: .selects) ?? []
        channelNames = try c.decodeIfPresent([String].self, forKey: .channelNames) ?? []
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        discovering = try c.decodeIfPresent(Bool.self, forKey: .discovering) ?? false
        discovered = try c.decodeIfPresent([SurfaceConsoleInfo].self, forKey: .discovered) ?? []
    }
}

/// App → daemon: enable/disable the (automatic) bridge and pick the DAW.
/// Everything else — MIDI ports, console connection, banking — is automatic.
public struct SurfaceConfigPayload: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var presetID: String
    public var diagnostics: Bool
    public init(enabled: Bool, presetID: String, diagnostics: Bool = false) {
        self.enabled = enabled
        self.presetID = presetID
        self.diagnostics = diagnostics
    }

    // Tolerate older clients without the diagnostics field.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        presetID = try c.decode(String.self, forKey: .presetID)
        diagnostics = try c.decodeIfPresent(Bool.self, forKey: .diagnostics) ?? false
    }
}

/// App → daemon: connect to a console at this IP manually (empty = disconnect).
/// Fallback for when auto-discovery can't reach the console (e.g. a direct
/// link-local Ethernet connection).
public struct SurfaceConsoleRefPayload: Codable, Sendable, Equatable {
    public var ip: String
    public init(ip: String) { self.ip = ip }
}

// MARK: - Envelope

/// All messages on the wire. Adding a case is a deliberate protocol change.
public enum WSMessage: Codable, Sendable {
    // Status
    case getStatus
    case status(StatusPayload)
    // Matrix
    case getMatrix
    case matrix(MatrixPayload)
    case setConnection(Connection)
    case removeConnection(Connection)
    case levels(LevelsPayload)
    // Labels
    case getLabels
    case labels(ChannelLabelsPayload)
    case setLabel(SetLabelPayload)
    // Scenes
    case getScenes
    case scenes(ScenesPayload)
    case saveScene(SaveScenePayload)
    case applyScene(SceneRefPayload)
    case deleteScene(SceneRefPayload)
    // Physical devices
    case getDevices
    case devices(DevicesPayload)
    case setDeviceUse(SetDeviceUsePayload)
    // App capture
    case getApps
    case apps(AppsPayload)
    case setAppCapture(SetAppCapturePayload)
    // AES67
    case getAes67
    case aes67(Aes67Payload)
    case subscribeStream(SubscribeStreamPayload)
    // VST3 / channel strips
    case getVST
    case vst(VSTPayload)
    case scanVST
    case getStrips
    case strips(StripsPayload)
    case setStrip(StripInfo)
    case openPluginEditor(OpenEditorPayload)
    case setPluginAvailable(PluginAvailabilityPayload)
    case setPluginFavorite(PluginFavoritePayload)
    // Events (daemon → app)
    case events(EventsPayload)
    case event(HydraEvent)
    // Config
    case config(ConfigPayload)
    case setConfig(ConfigPayload)
    // Virtual interfaces
    case getInterfaces
    case interfaces(InterfacesPayload)
    case createInterface(CreateInterfacePayload)
    case deleteInterface(InterfaceRefPayload)
    case setInterfaceNDI(InterfaceNDIPayload)
    case setInterfaceAES67(InterfaceNDIPayload)

    case getBridges
    case bridges(BridgesPayload)
    case setBridgeEnabled(SetBridgeEnabledPayload)
    case setBridgeRole(SetBridgeRolePayload)
    case setBridgeNetworkTX(SetBridgeNetworkTXPayload)
    // Capture flows (Audio-Hijack-style routing)
    case getFlows
    case flows(FlowsPayload)
    case setFlow(FlowInfo)
    case removeFlow(RemoveFlowPayload)
    // NDI
    case getNdi
    case ndi(NdiPayload)
    case subscribeNdi(SubscribeNdiPayload)
    // Modules (generic plugin host)
    case getModules
    case modules(ModulesPayload)
    case subscribeModuleSource(SubscribeModuleSourcePayload)
    // Recording
    case getRecordings
    case recordings(RecordingsPayload)
    case startRecording(InterfaceRefPayload)
    case stopRecording(InterfaceRefPayload)
    // Control surface (HiQnet ↔ HUI) — automatic multi-unit
    case getSurface
    case surface(SurfacePayload)
    case setSurfaceConfig(SurfaceConfigPayload)
    case discoverSurfaces
    case connectSurfaceConsole(SurfaceConsoleRefPayload)

    private enum CodingKeys: String, CodingKey { case type, payload }
    private enum Kind: String, Codable {
        case getStatus, status
        case getMatrix, matrix, setConnection, removeConnection, levels
        case getLabels, labels, setLabel
        case getScenes, scenes, saveScene, applyScene, deleteScene
        case getDevices, devices, setDeviceUse
        case getApps, apps, setAppCapture
        case getAes67, aes67, subscribeStream
        case getVST, vst, scanVST, getStrips, strips, setStrip, openPluginEditor
        case setPluginAvailable, setPluginFavorite
        case events, event
        case config, setConfig
        case getInterfaces, interfaces, createInterface, deleteInterface, setInterfaceNDI, setInterfaceAES67
        case getBridges, bridges, setBridgeEnabled, setBridgeRole, setBridgeNetworkTX
        case getFlows, flows, setFlow, removeFlow
        case getNdi, ndi, subscribeNdi
        case getModules, modules, subscribeModuleSource
        case getRecordings, recordings, startRecording, stopRecording
        case getSurface, surface, setSurfaceConfig, discoverSurfaces, connectSurfaceConsole
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .getStatus:        self = .getStatus
        case .status:           self = .status(try c.decode(StatusPayload.self, forKey: .payload))
        case .getMatrix:        self = .getMatrix
        case .matrix:           self = .matrix(try c.decode(MatrixPayload.self, forKey: .payload))
        case .setConnection:    self = .setConnection(try c.decode(Connection.self, forKey: .payload))
        case .removeConnection: self = .removeConnection(try c.decode(Connection.self, forKey: .payload))
        case .levels:           self = .levels(try c.decode(LevelsPayload.self, forKey: .payload))
        case .getLabels:        self = .getLabels
        case .labels:           self = .labels(try c.decode(ChannelLabelsPayload.self, forKey: .payload))
        case .setLabel:         self = .setLabel(try c.decode(SetLabelPayload.self, forKey: .payload))
        case .getScenes:        self = .getScenes
        case .scenes:           self = .scenes(try c.decode(ScenesPayload.self, forKey: .payload))
        case .saveScene:        self = .saveScene(try c.decode(SaveScenePayload.self, forKey: .payload))
        case .applyScene:       self = .applyScene(try c.decode(SceneRefPayload.self, forKey: .payload))
        case .deleteScene:      self = .deleteScene(try c.decode(SceneRefPayload.self, forKey: .payload))
        case .getDevices:       self = .getDevices
        case .devices:          self = .devices(try c.decode(DevicesPayload.self, forKey: .payload))
        case .setDeviceUse:     self = .setDeviceUse(try c.decode(SetDeviceUsePayload.self, forKey: .payload))
        case .getApps:          self = .getApps
        case .apps:             self = .apps(try c.decode(AppsPayload.self, forKey: .payload))
        case .setAppCapture:    self = .setAppCapture(try c.decode(SetAppCapturePayload.self, forKey: .payload))
        case .getAes67:         self = .getAes67
        case .aes67:            self = .aes67(try c.decode(Aes67Payload.self, forKey: .payload))
        case .subscribeStream:  self = .subscribeStream(try c.decode(SubscribeStreamPayload.self, forKey: .payload))
        case .getVST:           self = .getVST
        case .vst:              self = .vst(try c.decode(VSTPayload.self, forKey: .payload))
        case .scanVST:          self = .scanVST
        case .getStrips:        self = .getStrips
        case .strips:           self = .strips(try c.decode(StripsPayload.self, forKey: .payload))
        case .setStrip:         self = .setStrip(try c.decode(StripInfo.self, forKey: .payload))
        case .openPluginEditor: self = .openPluginEditor(try c.decode(OpenEditorPayload.self, forKey: .payload))
        case .setPluginAvailable: self = .setPluginAvailable(try c.decode(PluginAvailabilityPayload.self, forKey: .payload))
        case .setPluginFavorite: self = .setPluginFavorite(try c.decode(PluginFavoritePayload.self, forKey: .payload))
        case .events:           self = .events(try c.decode(EventsPayload.self, forKey: .payload))
        case .event:            self = .event(try c.decode(HydraEvent.self, forKey: .payload))
        case .config:           self = .config(try c.decode(ConfigPayload.self, forKey: .payload))
        case .setConfig:        self = .setConfig(try c.decode(ConfigPayload.self, forKey: .payload))
        case .getInterfaces:    self = .getInterfaces
        case .interfaces:       self = .interfaces(try c.decode(InterfacesPayload.self, forKey: .payload))
        case .createInterface:  self = .createInterface(try c.decode(CreateInterfacePayload.self, forKey: .payload))
        case .deleteInterface:  self = .deleteInterface(try c.decode(InterfaceRefPayload.self, forKey: .payload))
        case .setInterfaceNDI:  self = .setInterfaceNDI(try c.decode(InterfaceNDIPayload.self, forKey: .payload))
        case .setInterfaceAES67: self = .setInterfaceAES67(try c.decode(InterfaceNDIPayload.self, forKey: .payload))
        case .getBridges:       self = .getBridges
        case .bridges:          self = .bridges(try c.decode(BridgesPayload.self, forKey: .payload))
        case .setBridgeEnabled: self = .setBridgeEnabled(try c.decode(SetBridgeEnabledPayload.self, forKey: .payload))
        case .setBridgeRole:    self = .setBridgeRole(try c.decode(SetBridgeRolePayload.self, forKey: .payload))
        case .setBridgeNetworkTX: self = .setBridgeNetworkTX(try c.decode(SetBridgeNetworkTXPayload.self, forKey: .payload))
        case .getFlows:         self = .getFlows
        case .flows:            self = .flows(try c.decode(FlowsPayload.self, forKey: .payload))
        case .setFlow:          self = .setFlow(try c.decode(FlowInfo.self, forKey: .payload))
        case .removeFlow:       self = .removeFlow(try c.decode(RemoveFlowPayload.self, forKey: .payload))
        case .getNdi:           self = .getNdi
        case .ndi:              self = .ndi(try c.decode(NdiPayload.self, forKey: .payload))
        case .subscribeNdi:     self = .subscribeNdi(try c.decode(SubscribeNdiPayload.self, forKey: .payload))
        case .getModules:       self = .getModules
        case .modules:          self = .modules(try c.decode(ModulesPayload.self, forKey: .payload))
        case .subscribeModuleSource: self = .subscribeModuleSource(try c.decode(SubscribeModuleSourcePayload.self, forKey: .payload))
        case .getRecordings:    self = .getRecordings
        case .recordings:       self = .recordings(try c.decode(RecordingsPayload.self, forKey: .payload))
        case .startRecording:   self = .startRecording(try c.decode(InterfaceRefPayload.self, forKey: .payload))
        case .stopRecording:    self = .stopRecording(try c.decode(InterfaceRefPayload.self, forKey: .payload))
        case .getSurface:       self = .getSurface
        case .surface:          self = .surface(try c.decode(SurfacePayload.self, forKey: .payload))
        case .setSurfaceConfig: self = .setSurfaceConfig(try c.decode(SurfaceConfigPayload.self, forKey: .payload))
        case .discoverSurfaces: self = .discoverSurfaces
        case .connectSurfaceConsole: self = .connectSurfaceConsole(try c.decode(SurfaceConsoleRefPayload.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func put(_ kind: Kind) throws { try c.encode(kind, forKey: .type) }
        func put<P: Encodable>(_ kind: Kind, _ payload: P) throws {
            try c.encode(kind, forKey: .type)
            try c.encode(payload, forKey: .payload)
        }
        switch self {
        case .getStatus:                try put(.getStatus)
        case .status(let p):            try put(.status, p)
        case .getMatrix:                try put(.getMatrix)
        case .matrix(let p):            try put(.matrix, p)
        case .setConnection(let p):     try put(.setConnection, p)
        case .removeConnection(let p):  try put(.removeConnection, p)
        case .levels(let p):            try put(.levels, p)
        case .getLabels:                try put(.getLabels)
        case .labels(let p):            try put(.labels, p)
        case .setLabel(let p):          try put(.setLabel, p)
        case .getScenes:                try put(.getScenes)
        case .scenes(let p):            try put(.scenes, p)
        case .saveScene(let p):         try put(.saveScene, p)
        case .applyScene(let p):        try put(.applyScene, p)
        case .deleteScene(let p):       try put(.deleteScene, p)
        case .getDevices:               try put(.getDevices)
        case .devices(let p):           try put(.devices, p)
        case .setDeviceUse(let p):      try put(.setDeviceUse, p)
        case .getApps:                  try put(.getApps)
        case .apps(let p):              try put(.apps, p)
        case .setAppCapture(let p):     try put(.setAppCapture, p)
        case .getAes67:                 try put(.getAes67)
        case .aes67(let p):             try put(.aes67, p)
        case .subscribeStream(let p):   try put(.subscribeStream, p)
        case .getVST:                   try put(.getVST)
        case .vst(let p):               try put(.vst, p)
        case .scanVST:                  try put(.scanVST)
        case .getStrips:                try put(.getStrips)
        case .strips(let p):            try put(.strips, p)
        case .setStrip(let p):          try put(.setStrip, p)
        case .openPluginEditor(let p):  try put(.openPluginEditor, p)
        case .setPluginAvailable(let p): try put(.setPluginAvailable, p)
        case .setPluginFavorite(let p): try put(.setPluginFavorite, p)
        case .events(let p):            try put(.events, p)
        case .event(let p):             try put(.event, p)
        case .config(let p):            try put(.config, p)
        case .setConfig(let p):         try put(.setConfig, p)
        case .getInterfaces:            try put(.getInterfaces)
        case .interfaces(let p):        try put(.interfaces, p)
        case .createInterface(let p):   try put(.createInterface, p)
        case .deleteInterface(let p):   try put(.deleteInterface, p)
        case .setInterfaceNDI(let p):   try put(.setInterfaceNDI, p)
        case .setInterfaceAES67(let p): try put(.setInterfaceAES67, p)
        case .getBridges:               try put(.getBridges)
        case .bridges(let p):           try put(.bridges, p)
        case .setBridgeEnabled(let p):  try put(.setBridgeEnabled, p)
        case .setBridgeRole(let p):     try put(.setBridgeRole, p)
        case .setBridgeNetworkTX(let p): try put(.setBridgeNetworkTX, p)
        case .getFlows:                 try put(.getFlows)
        case .flows(let p):             try put(.flows, p)
        case .setFlow(let p):           try put(.setFlow, p)
        case .removeFlow(let p):        try put(.removeFlow, p)
        case .getNdi:                   try put(.getNdi)
        case .ndi(let p):               try put(.ndi, p)
        case .subscribeNdi(let p):      try put(.subscribeNdi, p)
        case .getModules:               try put(.getModules)
        case .modules(let p):           try put(.modules, p)
        case .subscribeModuleSource(let p): try put(.subscribeModuleSource, p)
        case .getRecordings:            try put(.getRecordings)
        case .recordings(let p):        try put(.recordings, p)
        case .startRecording(let p):    try put(.startRecording, p)
        case .stopRecording(let p):     try put(.stopRecording, p)
        case .getSurface:               try put(.getSurface)
        case .surface(let p):           try put(.surface, p)
        case .setSurfaceConfig(let p):  try put(.setSurfaceConfig, p)
        case .discoverSurfaces:         try put(.discoverSurfaces)
        case .connectSurfaceConsole(let p): try put(.connectSurfaceConsole, p)
        }
    }

    // MARK: Wire helpers
    public func encodedString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let s = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "non-UTF8"))
        }
        return s
    }

    public static func decode(from string: String) throws -> WSMessage {
        try JSONDecoder().decode(WSMessage.self, from: Data(string.utf8))
    }
}
