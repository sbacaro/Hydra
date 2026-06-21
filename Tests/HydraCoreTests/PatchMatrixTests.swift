// Hydra Audio — GPL-3.0
import Testing
import Foundation
@testable import HydraCore

struct PatchMatrixTests {

    private func conn(_ s: Int, _ d: Int, gain: Float = 1.0) -> Connection {
        Connection(source: .init(nodeID: Hydra.backplaneNodeID, channelIndex: s),
                   destination: .init(nodeID: Hydra.backplaneNodeID, channelIndex: d),
                   gain: gain)
    }

    @Test func upsertInsertsAndUpdates() {
        var m = PatchMatrix()
        let inserted = m.upsert(conn(0, 2))
        #expect(inserted)
        #expect(m.connections.count == 1)

        // Same endpoints, same gain → no change
        let reinserted = m.upsert(conn(0, 2))
        #expect(!reinserted)

        // Same endpoints, new gain → update in place
        let updated = m.upsert(conn(0, 2, gain: 0.5))
        #expect(updated)
        #expect(m.connections.count == 1)
        #expect(m.connections[0].gain == 0.5)
    }

    @Test func remove() {
        var m = PatchMatrix()
        _ = m.upsert(conn(1, 3))
        let removed = m.remove(source: conn(1, 3).source, destination: conn(1, 3).destination)
        #expect(removed)
        #expect(m.connections.isEmpty)
        let removedAgain = m.remove(source: conn(1, 3).source, destination: conn(1, 3).destination)
        #expect(!removedAgain)
    }

    @Test func connectionLookup() {
        var m = PatchMatrix()
        m.upsert(conn(4, 5, gain: 0.25))
        #expect(m.connection(source: conn(4, 5).source, destination: conn(4, 5).destination)?.gain == 0.25)
        #expect(m.connection(source: conn(5, 4).source, destination: conn(5, 4).destination) == nil)
    }

    @Test func maxConnectionsCap() {
        var m = PatchMatrix()
        // Fill beyond the cap using distinct endpoints.
        for i in 0..<(Hydra.maxConnections + 10) {
            m.upsert(conn(i / 256, i % 256))
        }
        #expect(m.connections.count <= Hydra.maxConnections)
    }

    @Test func gainConversionRoundTrip() {
        for db: Float in [-60, -12, -6, 0, 6, 12] {
            let linear = Gain.linear(fromDecibels: db)
            #expect(abs(Gain.decibels(fromLinear: linear) - db) <= 0.001)
        }
        #expect(abs(Gain.linear(fromDecibels: 0) - 1.0) <= 0.0001)
        // Silence clamps at the floor instead of -inf
        #expect(abs(Gain.decibels(fromLinear: 0) - (-120)) <= 0.1)
    }

    @Test func matrixCodableRoundTrip() throws {
        var m = PatchMatrix()
        m.upsert(conn(0, 1, gain: 0.7))
        m.upsert(conn(2, 3, gain: 1.2))
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(PatchMatrix.self, from: data)
        #expect(decoded == m)
    }
}

@Suite struct ConnectionIndexTests {
    private func conn(_ s: Int, _ d: Int, node: String = Hydra.backplaneNodeID) -> Connection {
        Connection(source: .init(nodeID: node, channelIndex: s),
                   destination: .init(nodeID: node, channelIndex: d),
                   gain: 1.0)
    }

    @Test func indexingBuildsIDIndexCorrectly() {
        let c1 = conn(0, 2)
        let c2 = conn(1, 3, node: "another-node")
        let index = ConnectionIndex(connections: [c1, c2])

        #expect(index.byID[c1.id] == c1)
        #expect(index.byID[c2.id] == c2)
        #expect(index.byID["non-existent"] == nil)
    }

    @Test func indexingGroupsBySourceAndDestination() {
        let c1 = conn(0, 2, node: "node-A")
        let c2 = conn(0, 4, node: "node-A") // Same source, different destination
        let c3 = conn(1, 2, node: "node-A") // Different source, same destination
        
        let index = ConnectionIndex(connections: [c1, c2, c3])

        // Verify lookup by source
        let srcKey = "node-A:0"
        let srcConns = index.bySource[srcKey] ?? []
        #expect(srcConns.count == 2)
        #expect(srcConns.contains(c1.id))
        #expect(srcConns.contains(c2.id))

        // Verify lookup by destination
        let dstKey = "node-A:2"
        let dstConns = index.byDestination[dstKey] ?? []
        #expect(dstConns.count == 2)
        #expect(dstConns.contains(c1.id))
        #expect(dstConns.contains(c3.id))
    }

    @Test func indexingHandlesEmptyConnections() {
        let index = ConnectionIndex(connections: [])
        #expect(index.byID.isEmpty)
        #expect(index.bySource.isEmpty)
        #expect(index.byDestination.isEmpty)
    }
}
