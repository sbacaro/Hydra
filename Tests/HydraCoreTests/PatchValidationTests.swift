// Hydra Audio — GPL-3.0
// Routing validation: per-node-kind endpoint bounds and backplane feedback
// (cycle) detection. These guard the daemon's matrix; bugs here either drop
// valid patches or let a feedback loop howl, so coverage is exhaustive.

import Testing
import Foundation
@testable import HydraCore

struct EndpointPlausibleTests {

    private func point(_ node: String, _ ch: Int) -> PatchPoint {
        PatchPoint(nodeID: node, channelIndex: ch)
    }

    @Test func backplaneWithinRange() {
        #expect(PatchValidation.endpointPlausible(point(Hydra.backplaneNodeID, 0)))
        #expect(PatchValidation.endpointPlausible(point(Hydra.backplaneNodeID, Hydra.backplaneChannels - 1)))
        #expect(!PatchValidation.endpointPlausible(point(Hydra.backplaneNodeID, Hydra.backplaneChannels)))
        #expect(!PatchValidation.endpointPlausible(point(Hydra.backplaneNodeID, -1)))
    }

    @Test func deviceUsesDeviceCap() {
        let node = Hydra.deviceNodeID(uid: "ABC")
        #expect(PatchValidation.endpointPlausible(point(node, 0)))
        #expect(PatchValidation.endpointPlausible(point(node, Hydra.maxDeviceChannels - 1)))
        #expect(!PatchValidation.endpointPlausible(point(node, Hydra.maxDeviceChannels)))
    }

    @Test func appCappedToTapChannels() {
        let node = Hydra.appNodeID(bundleID: "com.x", pid: 1)
        #expect(PatchValidation.endpointPlausible(point(node, 0)))
        #expect(PatchValidation.endpointPlausible(point(node, Hydra.appTapChannels - 1)))
        #expect(!PatchValidation.endpointPlausible(point(node, Hydra.appTapChannels)))
    }

    @Test func aes67CappedAt64() {
        let node = Hydra.aes67NodeID(streamID: "s/a:5004")
        #expect(PatchValidation.endpointPlausible(point(node, 63)))
        #expect(!PatchValidation.endpointPlausible(point(node, 64)))
    }

    @Test func ndiUsesNdiCap() {
        let node = Hydra.ndiNodeID(sourceID: "src")
        #expect(PatchValidation.endpointPlausible(point(node, Hydra.ndiMaxChannels - 1)))
        #expect(!PatchValidation.endpointPlausible(point(node, Hydra.ndiMaxChannels)))
    }

    @Test func vstUsesChainChannels() {
        let node = Hydra.vstNodeID(chainID: UUID())
        #expect(PatchValidation.endpointPlausible(point(node, Hydra.vstChainChannels - 1)))
        #expect(!PatchValidation.endpointPlausible(point(node, Hydra.vstChainChannels)))
    }

    @Test func moduleSourceAndSinkUseModuleCap() {
        let src = Hydra.moduleNodeID(sourceID: "m")
        let sink = Hydra.moduleSinkNodeID(sinkID: "m")
        #expect(PatchValidation.endpointPlausible(point(src, Hydra.moduleMaxChannels - 1)))
        #expect(!PatchValidation.endpointPlausible(point(src, Hydra.moduleMaxChannels)))
        #expect(PatchValidation.endpointPlausible(point(sink, 0)))
        #expect(!PatchValidation.endpointPlausible(point(sink, Hydra.moduleMaxChannels)))
    }

    @Test func unknownNodePrefixRejected() {
        #expect(!PatchValidation.endpointPlausible(point("bogus:thing", 0)))
        #expect(!PatchValidation.endpointPlausible(point("", 0)))
    }
}

struct FeedbackDetectionTests {

    private func bp(_ s: Int, _ d: Int) -> Connection {
        Connection(source: .init(nodeID: Hydra.backplaneNodeID, channelIndex: s),
                   destination: .init(nodeID: Hydra.backplaneNodeID, channelIndex: d))
    }

    @Test func selfLoopIsFeedback() {
        #expect(PatchValidation.wouldFeedback(adding: bp(3, 3), existing: []))
    }

    @Test func directBackEdgeIsFeedback() {
        // Existing 0→1; adding 1→0 closes a 2-cycle.
        #expect(PatchValidation.wouldFeedback(adding: bp(1, 0), existing: [bp(0, 1)]))
    }

    @Test func transitiveCycleIsFeedback() {
        // 0→1, 1→2 exist; adding 2→0 closes a 3-cycle.
        #expect(PatchValidation.wouldFeedback(adding: bp(2, 0), existing: [bp(0, 1), bp(1, 2)]))
    }

    @Test func acyclicAdditionIsSafe() {
        // 0→1, 1→2 exist; adding 0→2 introduces no cycle.
        #expect(!PatchValidation.wouldFeedback(adding: bp(0, 2), existing: [bp(0, 1), bp(1, 2)]))
    }

    @Test func fanOutIsSafe() {
        #expect(!PatchValidation.wouldFeedback(adding: bp(0, 5), existing: [bp(0, 1), bp(0, 2)]))
    }

    @Test func nonBackplaneEndpointsNeverFeedback() {
        let dev = Hydra.deviceNodeID(uid: "X")
        let toDevice = Connection(source: .init(nodeID: Hydra.backplaneNodeID, channelIndex: 0),
                                  destination: .init(nodeID: dev, channelIndex: 0))
        #expect(!PatchValidation.wouldFeedback(adding: toDevice, existing: []))

        let fromDevice = Connection(source: .init(nodeID: dev, channelIndex: 0),
                                    destination: .init(nodeID: Hydra.backplaneNodeID, channelIndex: 0))
        #expect(!PatchValidation.wouldFeedback(adding: fromDevice, existing: []))
    }

    @Test func cycleThroughDeviceHopIsNotDetectedAsBackplaneLoop() {
        // Only backplane→backplane edges form the graph; device hops break it.
        let dev = Hydra.deviceNodeID(uid: "X")
        let viaDevice = Connection(source: .init(nodeID: Hydra.backplaneNodeID, channelIndex: 1),
                                   destination: .init(nodeID: dev, channelIndex: 0))
        #expect(!PatchValidation.wouldFeedback(adding: bp(1, 0), existing: [viaDevice]))
    }
}
