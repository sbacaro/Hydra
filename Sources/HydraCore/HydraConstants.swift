// Hydra Audio — GPL-3.0
// Single source of truth for project-wide constants.
// Imported by the daemon, the app, and (as reference) the backplane build script.

import Foundation

public enum Hydra {
    // MARK: Version
    public static let version = "0.19.1"
    public static let stage = "beta"
    public static var versionString: String { "\(version) \(stage)" }

    // MARK: Backplane (virtual soundcard)
    /// Device name as it appears in Audio MIDI Setup.
    public static let backplaneDeviceName = "Hydra Virtual Soundcard"
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

    // MARK: Daemon ↔ App transport
    /// Local-only WebSocket. The daemon is the source of truth for audio state.
    public static let daemonHost = "127.0.0.1"
    public static let daemonPort: UInt16 = 59731
    public static var daemonURL: URL { URL(string: "ws://\(daemonHost):\(daemonPort)")! }

    // MARK: Legal
    /// Where the complete corresponding source lives (GPL §6). Update when
    /// the public repository is published.
    public static let sourceURL = "https://github.com/samuelbacaro/hydra-audio"

    // MARK: UI
    /// Accent color (Apple system indigo) as hex, used by the app.
    public static let accentHex = "#5856D6"

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
