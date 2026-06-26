// Hydra Audio — GPL-3.0
// Node-ID round-trip + cross-prefix rejection tests. These string helpers are the
// backbone of grid addressing: a regression here silently misroutes audio (a patch
// binds to the wrong node, or a subscription's node stops resolving). Pure logic,
// no Core Audio — safe to run anywhere (CI included).

import Testing
import Foundation
@testable import HydraCore

struct NodeIDTests {

    // MARK: Round-trips — id -> nodeID -> id must be identity for every kind.

    @Test func deviceRoundTrip() {
        for uid in ["AppleHDAEngineOutput:1B,0,1,1:0", "BlackHole16ch_UID", "weird uid with spaces", ""] {
            #expect(Hydra.deviceUID(fromNodeID: Hydra.deviceNodeID(uid: uid)) == uid)
        }
    }

    @Test func appRoundTrip_bundleID() {
        let node = Hydra.appNodeID(bundleID: "com.apple.Safari", pid: 42)
        #expect(node == "app:com.apple.Safari")
        #expect(Hydra.appKey(fromNodeID: node) == "com.apple.Safari")
    }

    @Test func appRoundTrip_pidFallback() {
        // No bundle ID → pid form. The key round-trips to "pid:<n>".
        let node = Hydra.appNodeID(bundleID: nil, pid: 1337)
        #expect(node == "app:pid:1337")
        #expect(Hydra.appKey(fromNodeID: node) == "pid:1337")
        // Empty bundle ID is treated like nil.
        #expect(Hydra.appNodeID(bundleID: "", pid: 7) == "app:pid:7")
    }

    @Test func aes67RoundTrip() {
        let id = "stream-abc-123"
        #expect(Hydra.aes67StreamID(fromNodeID: Hydra.aes67NodeID(streamID: id)) == id)
    }

    @Test func ndiRoundTrip() {
        let id = "MACHINE (Camera 1)"
        #expect(Hydra.ndiSourceID(fromNodeID: Hydra.ndiNodeID(sourceID: id)) == id)
    }

    @Test func moduleSourceRoundTrip() {
        let id = "01@SomeDevice"
        #expect(Hydra.moduleSourceID(fromNodeID: Hydra.moduleNodeID(sourceID: id)) == id)
    }

    @Test func moduleSinkRoundTrip() {
        let id = "tx-3"
        #expect(Hydra.moduleSinkID(fromNodeID: Hydra.moduleSinkNodeID(sinkID: id)) == id)
    }

    @Test func vstRoundTrip() {
        let uuid = UUID()
        #expect(Hydra.vstChainID(fromNodeID: Hydra.vstNodeID(chainID: uuid)) == uuid)
    }

    // MARK: The trap — "mod:" is a prefix-lookalike of "modtx:". A source decoder
    // must REJECT a sink node, and vice versa, or sources and sinks collide.

    @Test func moduleSourceRejectsSinkNode() {
        let sinkNode = Hydra.moduleSinkNodeID(sinkID: "x")     // "modtx:x"
        #expect(Hydra.moduleSourceID(fromNodeID: sinkNode) == nil,
                "moduleSourceID must not accept a sink node (modtx:)")
    }

    @Test func moduleSinkRejectsSourceNode() {
        let sourceNode = Hydra.moduleNodeID(sourceID: "x")     // "mod:x"
        #expect(Hydra.moduleSinkID(fromNodeID: sourceNode) == nil,
                "moduleSinkID must not accept a source node (mod:)")
    }

    // MARK: Cross-prefix rejection — each decoder returns nil for foreign nodes.

    @Test func decodersRejectForeignAndBackplane() {
        let foreign = [
            Hydra.backplaneNodeID,                       // "backplane"
            Hydra.deviceNodeID(uid: "u"),
            Hydra.appNodeID(bundleID: "b", pid: 1),
            Hydra.aes67NodeID(streamID: "s"),
            Hydra.ndiNodeID(sourceID: "n"),
            Hydra.vstNodeID(chainID: UUID()),
            "", "garbage", "dev", "app",
        ]
        for node in foreign {
            // A device decoder only accepts dev: nodes.
            if !node.hasPrefix("dev:")  { #expect(Hydra.deviceUID(fromNodeID: node) == nil, "\(node)") }
            if !node.hasPrefix("app:")  { #expect(Hydra.appKey(fromNodeID: node) == nil, "\(node)") }
            if !node.hasPrefix("aes67:"){ #expect(Hydra.aes67StreamID(fromNodeID: node) == nil, "\(node)") }
            if !node.hasPrefix("ndi:")  { #expect(Hydra.ndiSourceID(fromNodeID: node) == nil, "\(node)") }
        }
    }

    @Test func vstChainIDRejectsMalformedUUID() {
        // Right prefix, garbage payload → nil (not a crash).
        #expect(Hydra.vstChainID(fromNodeID: "vst:not-a-uuid") == nil)
    }

    // MARK: Version string is well-formed (catches an empty/blank release tag).

    @Test func versionStringFormat() {
        #expect(!Hydra.version.isEmpty)
        let expected = Hydra.stage.isEmpty ? Hydra.version : "\(Hydra.version) \(Hydra.stage)"
        #expect(Hydra.versionString == expected)
    }
}
