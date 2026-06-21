// Hydra Audio — GPL-3.0
// Core model coverage: computed identities, OptionSet semantics, display-name
// fallback, and Codable round-trips for the value types that cross the wire.

import Testing
import Foundation
@testable import HydraCore

struct ModelsTests {

    // MARK: - Connection / PatchPoint

    @Test func connectionIDEncodesEndpoints() {
        let c = Connection(source: .init(nodeID: "dev:A", channelIndex: 3),
                           destination: .init(nodeID: "backplane", channelIndex: 7))
        #expect(c.id == "dev:A:3->backplane:7")
    }

    @Test func connectionIDIsDirectional() {
        let forward = Connection(source: .init(nodeID: "n", channelIndex: 0),
                                 destination: .init(nodeID: "n", channelIndex: 1))
        let reverse = Connection(source: .init(nodeID: "n", channelIndex: 1),
                                 destination: .init(nodeID: "n", channelIndex: 0))
        #expect(forward.id != reverse.id)
    }

    @Test func patchPointHashableInSet() {
        let a = PatchPoint(nodeID: "n", channelIndex: 1)
        let b = PatchPoint(nodeID: "n", channelIndex: 1)
        let c = PatchPoint(nodeID: "n", channelIndex: 2)
        #expect(Set([a, b, c]).count == 2)
    }

    @Test func connectionGainIgnoredByIdentity() {
        // id is endpoint-derived; gain does not change it.
        let a = Connection(source: .init(nodeID: "n", channelIndex: 0),
                           destination: .init(nodeID: "n", channelIndex: 1), gain: 0.1)
        let b = Connection(source: .init(nodeID: "n", channelIndex: 0),
                           destination: .init(nodeID: "n", channelIndex: 1), gain: 0.9)
        #expect(a.id == b.id)
    }

    // MARK: - Node / Channel

    @Test func nodeDisplayNamePrefersLabel() {
        var node = Node(stableID: "id", kind: .app, directions: .both, systemName: "System")
        #expect(node.displayName == "System")
        node.label = "Custom"
        #expect(node.displayName == "Custom")
    }

    @Test func channelIDMatchesIndex() {
        #expect(Channel(index: 5).id == 5)
    }

    @Test func nodeKindCoversAllCases() {
        #expect(Set(NodeKind.allCases) ==
                [.backplane, .physicalDevice, .app, .aes67, .vst])
    }

    // MARK: - NodeDirections (OptionSet)

    @Test func nodeDirectionsBothContainsTxAndRx() {
        #expect(NodeDirections.both.contains(.tx))
        #expect(NodeDirections.both.contains(.rx))
        #expect(!NodeDirections.tx.contains(.rx))
    }

    @Test func nodeDirectionsCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(NodeDirections.both)
        let decoded = try JSONDecoder().decode(NodeDirections.self, from: data)
        #expect(decoded == .both)
    }

    // MARK: - Codable round-trips

    @Test func nodeCodableRoundTrip() throws {
        let node = Node(stableID: "dev:UID", kind: .physicalDevice, directions: .tx,
                        systemName: "Scarlett", label: "Mic",
                        channels: [Channel(index: 0, label: "L", isInUse: true)])
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(Node.self, from: data)
        #expect(decoded.id == node.id)
        #expect(decoded.kind == .physicalDevice)
        #expect(decoded.directions == .tx)
        #expect(decoded.displayName == "Mic")
        #expect(decoded.channels.first?.isInUse == true)
    }

    @Test func patchSceneCodableRoundTrip() throws {
        let conn = Connection(source: .init(nodeID: "n", channelIndex: 0),
                              destination: .init(nodeID: "n", channelIndex: 1), gain: 0.5)
        let scene = PatchScene(id: UUID(), name: "Live", connections: [conn],
                               createdAt: Date(timeIntervalSinceReferenceDate: 1000),
                               modifiedAt: Date(timeIntervalSinceReferenceDate: 2000))
        let data = try JSONEncoder().encode(scene)
        let decoded = try JSONDecoder().decode(PatchScene.self, from: data)
        #expect(decoded.id == scene.id)
        #expect(decoded.name == "Live")
        #expect(decoded.connections == [conn])
        #expect(decoded.createdAt == scene.createdAt)
    }

    @Test func hydraEventCodableRoundTrip() throws {
        let event = HydraEvent(id: UUID(), kind: .warning, message: "XRUN",
                               timestamp: Date(timeIntervalSinceReferenceDate: 500))
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(HydraEvent.self, from: data)
        #expect(decoded == event)
    }
}
