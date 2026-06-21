// Hydra Audio — GPL-3.0
// Pure routing validation extracted from hydrad's MatrixStore so it is unit-
// testable without Core Audio. MatrixStore delegates to these; the RT mixing
// and persistence stay in the daemon.

import Foundation

public enum PatchValidation {

    /// Whether an endpoint (node + channel) can plausibly exist, given the
    /// channel-count limits of each node kind. Unknown node prefixes are
    /// rejected. Mirrors the daemon's per-kind caps exactly.
    public static func endpointPlausible(_ point: PatchPoint) -> Bool {
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
        if Hydra.moduleSourceID(fromNodeID: point.nodeID) != nil {
            return (0..<Hydra.moduleMaxChannels).contains(point.channelIndex)
        }
        if Hydra.moduleSinkID(fromNodeID: point.nodeID) != nil {
            return (0..<Hydra.moduleMaxChannels).contains(point.channelIndex)
        }
        return false
    }

    /// Feedback detection on the loopback backplane: Out n re-enters as In n,
    /// so backplane→backplane connections form a directed graph (edge s→d). A
    /// new edge that closes a cycle — including s == d — would howl. Connections
    /// touching any other node kind cannot loop internally and are always safe.
    ///
    /// - Parameters:
    ///   - new: the edge about to be added.
    ///   - existing: the connections already in the matrix.
    /// - Returns: true if adding `new` would create a cycle.
    public static func wouldFeedback(adding new: Connection,
                                     existing: [Connection]) -> Bool {
        guard new.source.nodeID == Hydra.backplaneNodeID,
              new.destination.nodeID == Hydra.backplaneNodeID else { return false }
        let s = new.source.channelIndex
        let d = new.destination.channelIndex
        if s == d { return true }

        var adjacency: [Int: [Int]] = [:]
        for c in existing
        where c.source.nodeID == Hydra.backplaneNodeID
           && c.destination.nodeID == Hydra.backplaneNodeID {
            adjacency[c.source.channelIndex, default: []].append(c.destination.channelIndex)
        }
        // Is there already a path from d back to s? If so, s→d closes a loop.
        var stack = [d]
        var seen: Set<Int> = []
        while let node = stack.popLast() {
            if node == s { return true }
            guard seen.insert(node).inserted else { continue }
            stack.append(contentsOf: adjacency[node] ?? [])
        }
        return false
    }
}
