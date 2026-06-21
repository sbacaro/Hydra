// Hydra Audio — GPL-3.0
// Pure (testable) matrix model + gain conversion helpers.
// The RT mixing that consumes this lives in hydrad's MatrixStore.

import Foundation

// MARK: - PatchMatrix

/// The set of connections of the grid. Value type, no threading concerns —
/// the daemon wraps it for real-time use.
public struct PatchMatrix: Codable, Sendable, Equatable {
    public private(set) var connections: [Connection]

    public init(connections: [Connection] = []) {
        self.connections = connections
    }

    public func connection(source: PatchPoint, destination: PatchPoint) -> Connection? {
        connections.first { $0.source == source && $0.destination == destination }
    }

    /// Insert or update (same endpoints ⇒ gain update). Returns true if anything changed.
    @discardableResult
    public mutating func upsert(_ new: Connection) -> Bool {
        if let idx = connections.firstIndex(where: { $0.source == new.source && $0.destination == new.destination }) {
            guard connections[idx].gain != new.gain else { return false }
            connections[idx].gain = new.gain
            return true
        }
        guard connections.count < Hydra.maxConnections else { return false }
        connections.append(new)
        return true
    }

    /// Returns true if a connection was removed.
    @discardableResult
    public mutating func remove(source: PatchPoint, destination: PatchPoint) -> Bool {
        let before = connections.count
        connections.removeAll { $0.source == source && $0.destination == destination }
        return connections.count != before
    }
}

// MARK: - Gain conversion

public enum Gain {
    /// Linear → dBFS. Floor: silence maps to -120 dB.
    public static func decibels(fromLinear linear: Float) -> Float {
        20 * log10(max(abs(linear), 1e-6))
    }

    /// dB → linear.
    public static func linear(fromDecibels db: Float) -> Float {
        pow(10, db / 20)
    }
}

// MARK: - ConnectionIndex

/// Fast lookup indices for a set of connections.
public struct ConnectionIndex: Sendable, Equatable {
    public private(set) var bySource: [String: [String]] = [:]
    public private(set) var byDestination: [String: [String]] = [:]
    public private(set) var byID: [String: Connection] = [:]

    public init(connections: [Connection]) {
        byID.reserveCapacity(connections.count)
        for c in connections {
            byID[c.id] = c
            let srcKey = "\(c.source.nodeID):\(c.source.channelIndex)"
            let dstKey = "\(c.destination.nodeID):\(c.destination.channelIndex)"
            bySource[srcKey, default: []].append(c.id)
            byDestination[dstKey, default: []].append(c.id)
        }
    }
}
