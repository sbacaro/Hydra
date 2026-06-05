// Hydra Audio — GPL-3.0
import XCTest
@testable import HydraCore

final class PatchMatrixTests: XCTestCase {

    private func conn(_ s: Int, _ d: Int, gain: Float = 1.0) -> Connection {
        Connection(source: .init(nodeID: Hydra.backplaneNodeID, channelIndex: s),
                   destination: .init(nodeID: Hydra.backplaneNodeID, channelIndex: d),
                   gain: gain)
    }

    func testUpsertInsertsAndUpdates() {
        var m = PatchMatrix()
        XCTAssertTrue(m.upsert(conn(0, 2)))
        XCTAssertEqual(m.connections.count, 1)

        // Same endpoints, same gain → no change
        XCTAssertFalse(m.upsert(conn(0, 2)))

        // Same endpoints, new gain → update in place
        XCTAssertTrue(m.upsert(conn(0, 2, gain: 0.5)))
        XCTAssertEqual(m.connections.count, 1)
        XCTAssertEqual(m.connections[0].gain, 0.5)
    }

    func testRemove() {
        var m = PatchMatrix()
        m.upsert(conn(1, 3))
        XCTAssertTrue(m.remove(source: conn(1, 3).source, destination: conn(1, 3).destination))
        XCTAssertTrue(m.connections.isEmpty)
        XCTAssertFalse(m.remove(source: conn(1, 3).source, destination: conn(1, 3).destination))
    }

    func testConnectionLookup() {
        var m = PatchMatrix()
        m.upsert(conn(4, 5, gain: 0.25))
        XCTAssertEqual(m.connection(source: conn(4, 5).source, destination: conn(4, 5).destination)?.gain, 0.25)
        XCTAssertNil(m.connection(source: conn(5, 4).source, destination: conn(5, 4).destination))
    }

    func testMaxConnectionsCap() {
        var m = PatchMatrix()
        // Fill beyond the cap using distinct endpoints.
        for i in 0..<(Hydra.maxConnections + 10) {
            m.upsert(conn(i / 256, i % 256))
        }
        XCTAssertLessThanOrEqual(m.connections.count, Hydra.maxConnections)
    }

    func testGainConversionRoundTrip() {
        for db: Float in [-60, -12, -6, 0, 6, 12] {
            let linear = Gain.linear(fromDecibels: db)
            XCTAssertEqual(Gain.decibels(fromLinear: linear), db, accuracy: 0.001)
        }
        XCTAssertEqual(Gain.linear(fromDecibels: 0), 1.0, accuracy: 0.0001)
        // Silence clamps at the floor instead of -inf
        XCTAssertEqual(Gain.decibels(fromLinear: 0), -120, accuracy: 0.1)
    }

    func testMatrixCodableRoundTrip() throws {
        var m = PatchMatrix()
        m.upsert(conn(0, 1, gain: 0.7))
        m.upsert(conn(2, 3, gain: 1.2))
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(PatchMatrix.self, from: data)
        XCTAssertEqual(decoded, m)
    }
}
