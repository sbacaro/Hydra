// Hydra Audio — GPL-3.0
// Core data model (Section 6 of the foundation document).
// Phase 1 ships the types; the engine that uses them arrives in Phase 2.

import Foundation

// MARK: - Node

/// Category of a node in the unified grid.
public enum NodeKind: String, Codable, Sendable, CaseIterable {
    case backplane
    case physicalDevice
    case app
    case aes67
    case vst
}

/// Directions a node supports. A media player is a source (tx);
/// a recorder is a destination (rx); some nodes are both.
public struct NodeDirections: OptionSet, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let tx = NodeDirections(rawValue: 1 << 0)
    public static let rx = NodeDirections(rawValue: 1 << 1)
    public static let both: NodeDirections = [.tx, .rx]
}

/// A source and/or destination in the grid.
/// `stableID` is the persistent identity used to re-bind a resource
/// to its previous patch after a disconnect.
public struct Node: Codable, Identifiable, Sendable {
    public var id: String { stableID }
    public let stableID: String
    public var kind: NodeKind
    public var directions: NodeDirections
    /// System-provided name (not user-editable).
    public var systemName: String
    /// User-editable label, persisted separately from the system ID.
    public var label: String?
    /// Auto-detected (apps, devices, streams) vs. manually added.
    public var isAutoDetected: Bool
    public var channels: [Channel]

    public init(stableID: String,
                kind: NodeKind,
                directions: NodeDirections,
                systemName: String,
                label: String? = nil,
                isAutoDetected: Bool = true,
                channels: [Channel] = []) {
        self.stableID = stableID
        self.kind = kind
        self.directions = directions
        self.systemName = systemName
        self.label = label
        self.isAutoDetected = isAutoDetected
        self.channels = channels
    }

    public var displayName: String { label ?? systemName }
}

// MARK: - Channel

/// A channel belonging to a node.
public struct Channel: Codable, Identifiable, Sendable {
    public var id: Int { index }
    public let index: Int
    /// User-editable label (e.g. "Mic Host"), persisted apart from the system ID.
    public var label: String?
    /// Grid shows only channels "in use" by default.
    public var isInUse: Bool

    public init(index: Int, label: String? = nil, isInUse: Bool = false) {
        self.index = index
        self.label = label
        self.isInUse = isInUse
    }
}

// MARK: - Connection

/// One end of a connection: a node + channel index.
public struct PatchPoint: Codable, Hashable, Sendable {
    public let nodeID: String
    public let channelIndex: Int
    public init(nodeID: String, channelIndex: Int) {
        self.nodeID = nodeID
        self.channelIndex = channelIndex
    }
}

/// A source→destination crossing in the grid. Not boolean: carries gain.
/// (Effects live on channel strips — see StripInfo — not on connections.)
public struct Connection: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(source.nodeID):\(source.channelIndex)->\(destination.nodeID):\(destination.channelIndex)" }
    public let source: PatchPoint
    public let destination: PatchPoint
    /// Linear gain (1.0 = unity). The engine mixes multiple sources
    /// into a destination with their respective gains.
    public var gain: Float

    public init(source: PatchPoint, destination: PatchPoint, gain: Float = 1.0) {
        self.source = source
        self.destination = destination
        self.gain = gain
    }
}

// MARK: - Scene

/// Named snapshot of the entire matrix — connections, gains, labels.
/// Applied atomically (no audible intermediate states).
public struct PatchScene: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var connections: [Connection]
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), name: String, connections: [Connection] = [],
                createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.connections = connections
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

// MARK: - Event log

/// Lightweight event record (drops, reconnections, installs) for discreet notices.
public struct HydraEvent: Codable, Identifiable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case resourceLost, resourceRestored, installed, info, warning, error
    }
    public let id: UUID
    public let kind: Kind
    public let message: String
    public let timestamp: Date

    public init(id: UUID = UUID(), kind: Kind, message: String, timestamp: Date = Date()) {
        self.id = id
        self.kind = kind
        self.message = message
        self.timestamp = timestamp
    }
}
