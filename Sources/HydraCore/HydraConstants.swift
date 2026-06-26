// Hydra Audio — GPL-3.0
// Single source of truth for project-wide constants.
// Imported by the daemon, the app, and (as reference) the backplane build script.

import Foundation

public enum Hydra {
    // MARK: Version
    public static let version = "1.0.6"
    /// Pre-release qualifier (e.g. "beta"). Empty for a stable release.
    public static let stage = ""
    public static var versionString: String {
        stage.isEmpty ? version : "\(version) \(stage)"
    }

    // MARK: Engine hub (internal, hidden)
    /// The engine's internal clock+mixing device. HIDDEN from users — it only
    /// exists so the IOProc can drive the matrix that routes the bridges. Users
    /// see only the Hydra Audio Bridges. (Formerly the user-facing 256-ch
    /// "Hydra Virtual Soundcard"; now renamed + hidden, same UID/bundle.)
    public static let backplaneDeviceName = "Hydra Engine"
    /// CoreAudio UID of the hub (kDriver_Name + "_UID"). The engine resolves the
    /// hub by UID (TranslateUIDToDevice), which works even though it's hidden —
    /// a hidden device is excluded from the enumerated device list but can still
    /// be translated from its UID.
    public static let backplaneDeviceUID = "HydraVirtualSoundcard_UID"
    /// Bundle ID of the HAL plugin (customized BlackHole).
    public static let backplaneBundleID = "audio.hydra.virtualsoundcard"
    /// Loopback wires of the backplane device (output N → input N): 256 in / 256
    /// out. ONE shared pool — transmitters (app→Hydra) and receivers (Hydra→app)
    /// both allocate from [0, backplaneChannels), exclusively (a wire can't carry
    /// both directions through the loopback). So transmitters + receivers ≤ 256.
    public static let backplaneChannels = 256
    /// Max channels one direction (in or out) may use; the shared pool also caps
    /// the in+out total at backplaneChannels.
    public static let poolChannels = 256
    /// Initial target sample rate.
    public static let defaultSampleRate: Double = 48_000

    // MARK: Bridges (fixed multi-device set)
    /// A fixed "Hydra Audio Bridge": an independent loopback CoreAudio device with
    /// `channels` inputs and `channels` outputs. Replaces the old single 256-wire
    /// backplane + user-created virtual interfaces. The driver exposes one device
    /// (and one box, for the on/off toggle) per spec; the engine attaches the
    /// enabled ones and the grid shows each as its own node (`bridge:<id>`).
    public struct BridgeSpec: Sendable, Equatable, Identifiable {
        /// Stable short key (also the grid node suffix and persistence key).
        public let id: String
        /// Name shown in macOS (Audio MIDI Setup) and in the app.
        public let name: String
        /// CoreAudio device UID (must match what the driver publishes).
        public let uid: String
        /// Channel count, identical for input and output.
        public let channels: Int
        public init(id: String, name: String, uid: String, channels: Int) {
            self.id = id; self.name = name; self.uid = uid; self.channels = channels
        }
    }

    /// The fixed catalog of bridges, in display order. The driver, engine and UI
    /// all derive from this single list.
    /// UIDs MUST match what the driver publishes: kDevice_UID = kDriver_Name +
    /// "_UID" (the driver builds with kHas_Driver_Name_Format=false). See the
    /// per-bridge wrappers in Backplane/Driver/bridges/.
    public static let bridgeCatalog: [BridgeSpec] = [
        BridgeSpec(id: "2a",  name: "Hydra Audio Bridge 2-A", uid: "HydraAudioBridge2A_UID",  channels: 2),
        BridgeSpec(id: "2b",  name: "Hydra Audio Bridge 2-B", uid: "HydraAudioBridge2B_UID",  channels: 2),
        BridgeSpec(id: "4",   name: "Hydra Audio Bridge 4",   uid: "HydraAudioBridge4_UID",   channels: 4),
        BridgeSpec(id: "8",   name: "Hydra Audio Bridge 8",   uid: "HydraAudioBridge8_UID",   channels: 8),
        BridgeSpec(id: "16",  name: "Hydra Audio Bridge 16",  uid: "HydraAudioBridge16_UID",  channels: 16),
        BridgeSpec(id: "32",  name: "Hydra Audio Bridge 32",  uid: "HydraAudioBridge32_UID",  channels: 32),
        BridgeSpec(id: "64",  name: "Hydra Audio Bridge 64",  uid: "HydraAudioBridge64_UID",  channels: 64),
        BridgeSpec(id: "128", name: "Hydra Audio Bridge 128", uid: "HydraAudioBridge128_UID", channels: 128),
    ]

    public static func bridgeSpec(id: String) -> BridgeSpec? {
        bridgeCatalog.first { $0.id == id }
    }
    public static func bridgeSpec(uid: String) -> BridgeSpec? {
        bridgeCatalog.first { $0.uid == uid }
    }
    /// Grid node id for a bridge (stable across reconnects).
    public static func bridgeNodeID(id: String) -> String { "bridge:\(id)" }
    public static func bridgeID(fromNodeID nodeID: String) -> String? {
        nodeID.hasPrefix("bridge:") ? String(nodeID.dropFirst(7)) : nil
    }
    /// True when a CoreAudio device UID belongs to one of our bridges (so the
    /// engine can present it as a `bridge:` node instead of a generic `dev:` one).
    public static func isBridgeUID(_ uid: String) -> Bool { bridgeSpec(uid: uid) != nil }

    // MARK: Daemon ↔ App transport
    /// Local-only WebSocket. The daemon is the source of truth for audio state.
    public static let daemonHost = "127.0.0.1"
    public static let daemonPort: UInt16 = 59731
    public static var daemonURL: URL { URL(string: "ws://\(daemonHost):\(daemonPort)")! }

    // MARK: Legal
    /// Where the complete corresponding source lives (GPL §6). Update when
    /// the public repository is published.
    public static let sourceURL = "https://github.com/sbacaro/Hydra-Soundcard"

    // MARK: Engine
    /// Node ID of the backplane in the unified grid.
    public static let backplaneNodeID = "backplane"
    /// Hard cap of simultaneous connections (sizes the RT meter buffer).
    public static let maxConnections = 1024
    /// Signal-presence poll interval (seconds). The daemon no longer streams
    /// continuous levels — it polls peaks, derives a binary on/off, and only
    /// broadcasts when the on/off set CHANGES. So this is just LED responsiveness,
    /// not a per-tick cost: ~150 ms to light/clear is plenty.
    public static let meterInterval: Double = 0.15
    /// Peak above which a channel/connection counts as "has signal" (linear,
    /// ~ -50 dBFS). Matches the app's signalThreshold.
    public static let signalFloorLinear: Float = 0.0032
    /// Stay "on" this long after the last over-threshold sample, so a steady
    /// source doesn't flicker and gaps in speech/music don't drop the LED.
    public static let signalReleaseSeconds: Double = 0.4

    // MARK: Physical devices (Phase 2b)
    /// Ring buffer length per device/direction, in frames (power of two).
    public static let deviceRingFrames = 8192
    /// Maximum frames per IO callback the engine stages for devices.
    public static let maxIOFrames = 4096
    /// Sanity cap on a physical device's channel count.
    public static let maxDeviceChannels = 512

    /// Grid node ID for a physical device (stable across reconnects: uses the
    /// Core Audio device UID).
    public static func deviceNodeID(uid: String) -> String { "dev:\(uid)" }
    public static func deviceUID(fromNodeID nodeID: String) -> String? {
        nodeID.hasPrefix("dev:") ? String(nodeID.dropFirst(4)) : nil
    }

    // MARK: App capture (Phase 3)
    /// Process taps are mixed down to stereo.
    public static let appTapChannels = 2
    /// Makeup applied to app taps (dB). The tap's stereo mixdown delivers a
    /// noticeably attenuated signal; the exact amount is undocumented, so
    /// this is an empirical calibration constant — adjust here if captures
    /// still don't match interface levels.
    public static let appTapMakeupDB: Float = 12

    /// UID prefix of Hydra's own private aggregate devices (tap plumbing).
    /// DeviceManager filters these out of the interface list — they are
    /// internal machinery, not user-facing devices.
    public static let internalAggregateUIDPrefix = "hydra-internal-"

    /// Grid node ID for a captured app. Prefers the bundle ID (stable across
    /// relaunches → patch re-binds); falls back to the pid.
    public static func appNodeID(bundleID: String?, pid: Int32) -> String {
        if let bundleID, !bundleID.isEmpty { return "app:\(bundleID)" }
        return "app:pid:\(pid)"
    }
    public static func appKey(fromNodeID nodeID: String) -> String? {
        nodeID.hasPrefix("app:") ? String(nodeID.dropFirst(4)) : nil
    }

    // MARK: AES67 (Phase 4)
    /// SAP announcement multicast group/port (RFC 2974).
    public static let sapAddress = "239.255.255.255"
    public static let sapPort: UInt16 = 9875
    /// Streams unseen for this long are dropped (SAP re-announces periodically).
    public static let sapExpirySeconds: Double = 600

    public static func aes67NodeID(streamID: String) -> String { "aes67:\(streamID)" }
    public static func aes67StreamID(fromNodeID nodeID: String) -> String? {
        nodeID.hasPrefix("aes67:") ? String(nodeID.dropFirst(6)) : nil
    }

    // MARK: OSC remote control
    /// Default UDP port for the OSC server (TouchOSC/Companion convention).
    public static let defaultOSCPort = 9000

    // MARK: NDI
    /// Cap on channels accepted from one NDI source (rings are preallocated).
    public static let ndiMaxChannels = 16
    /// Official Vizrt redistributable — the ONLY permitted distribution
    /// channel for the (proprietary) NDI runtime; Hydra stays GPL by loading
    /// it dynamically at runtime, never bundling it.
    public static let ndiRedistURL = "https://ndi.link/NDIRedistV6Apple"

    public static func ndiNodeID(sourceID: String) -> String { "ndi:\(sourceID)" }
    public static func ndiSourceID(fromNodeID nodeID: String) -> String? {
        nodeID.hasPrefix("ndi:") ? String(nodeID.dropFirst(4)) : nil
    }

    // MARK: Modules (generic plugin host)
    /// Max channels a module source may expose (matches the RT scratch size).
    public static let moduleMaxChannels = 64
    public static func moduleNodeID(sourceID: String) -> String { "mod:\(sourceID)" }
    public static func moduleSourceID(fromNodeID nodeID: String) -> String? {
        nodeID.hasPrefix("mod:") ? String(nodeID.dropFirst(4)) : nil
    }
    /// Node id for a module SINK (transmit destination).
    public static func moduleSinkNodeID(sinkID: String) -> String { "modtx:\(sinkID)" }
    public static func moduleSinkID(fromNodeID nodeID: String) -> String? {
        nodeID.hasPrefix("modtx:") ? String(nodeID.dropFirst(6)) : nil
    }
    /// Where the daemon looks for module .dylibs (never shipped with Hydra).
    public static func modulesDirectory() -> String {
        let base = NSHomeDirectory()
        return base + "/Library/Application Support/Hydra/modules"
    }

    // MARK: VST3 (Phase 6)
    /// Chains are stereo in v1.
    public static let vstChainChannels = 2

    public static func vstNodeID(chainID: UUID) -> String { "vst:\(chainID.uuidString)" }
    public static func vstChainID(fromNodeID nodeID: String) -> UUID? {
        nodeID.hasPrefix("vst:") ? UUID(uuidString: String(nodeID.dropFirst(4))) : nil
    }
}
