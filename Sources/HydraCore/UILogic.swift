// Hydra Audio — GPL-3.0
// Pure presentation logic shared by the app's views (menu bar, grid). Kept in
// HydraCore — which imports only Foundation — so it is unit-testable without
// SwiftUI or Core Audio. The views map these values to colors/SF Symbols.

import Foundation

// MARK: - Engine presence (menu bar status)

/// The four glanceable states the menu bar reports, derived from the daemon
/// connection + status. The view chooses the dot color and icon from this.
public enum EnginePresence: Equatable, Sendable {
    /// The daemon WebSocket is not connected.
    case offline
    /// Connected, but the virtual soundcard (backplane) is not installed.
    case noBackplane
    /// Backplane present, but the audio engine (IOProc) is not running.
    case stopped
    /// Backplane present and the engine is running.
    case running

    public init(connected: Bool, backplaneInstalled: Bool, engineRunning: Bool) {
        guard connected else { self = .offline; return }
        guard backplaneInstalled else { self = .noBackplane; return }
        self = engineRunning ? .running : .stopped
    }

    /// Short label for the header pill.
    public var shortLabel: String {
        switch self {
        case .offline:     return "Offline"
        case .noBackplane: return "No backplane"
        case .stopped:     return "Stopped"
        case .running:     return "Running"
        }
    }

    /// True only when audio can actually flow.
    public var isHealthy: Bool { self == .running }
}

// MARK: - Render-load severity (CPU tile)

/// Buckets the engine's render load (0…1) so the CPU tile can tint itself.
public enum LoadSeverity: Equatable, Sendable {
    case normal    // < 60%
    case elevated  // 60–85%
    case critical  // ≥ 85%

    public init(load: Double) {
        switch load {
        case ..<0.60: self = .normal
        case ..<0.85: self = .elevated
        default:      self = .critical
        }
    }
}

// MARK: - Elapsed time formatting (recording timer)

/// Formats a non-negative duration as `m:ss`, or `h:mm:ss` past an hour.
/// Negative inputs clamp to zero.
public func formatElapsed(seconds: Int) -> String {
    let total = max(0, seconds)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%d:%02d", m, s)
}

// MARK: - Console channel pairing

/// The console patch rules between two grid lanes, expressed purely in terms
/// of channel-index lists. Mirrors the daemon's routing:
///   stereo→stereo: L→L, R→R · stereo→mono: both summed into the mono dest ·
///   mono→stereo: the mono source duplicated to both dest lanes · else 1:1.
public enum ChannelPairing {
    public static func pairs(source: [Int], destination: [Int]) -> [(Int, Int)] {
        switch (source.count, destination.count) {
        case (2, 2):
            return [(source[0], destination[0]), (source[1], destination[1])]
        case (2, 1):
            return [(source[0], destination[0]), (source[1], destination[0])]
        case (1, 2):
            return [(source[0], destination[0]), (source[0], destination[1])]
        default:
            guard let s = source.first, let d = destination.first else { return [] }
            return [(s, d)]
        }
    }
}
