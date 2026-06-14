// Hydra Audio — GPL-3.0
// Node-ID round-trip + cross-prefix rejection tests. These string helpers are the
// backbone of grid addressing: a regression here silently misroutes audio (a patch
// binds to the wrong node, or a subscription's node stops resolving). Pure logic,
// no Core Audio — safe to run anywhere (CI included).

import XCTest
@testable import HydraCore

final class NodeIDTests: XCTestCase {

    // MARK: Round-trips — id -> nodeID -> id must be identity for every kind.

    func testDeviceRoundTrip() {
        for uid in ["AppleHDAEngineOutput:1B,0,1,1:0", "BlackHole16ch_UID", "weird uid with spaces", ""] {
            XCTAssertEqual(Hydra.deviceUID(fromNodeID: Hydra.deviceNodeID(uid: uid)), uid)
        }
    }

    func testAppRoundTrip_bundleID() {
        let node = Hydra.appNodeID(bundleID: "com.apple.Safari", pid: 42)
        XCTAssertEqual(node, "app:com.apple.Safari")
        XCTAssertEqual(Hydra.appKey(fromNodeID: node), "com.apple.Safari")
    }

    func testAppRoundTrip_pidFallback() {
        // No bundle ID → pid form. The key round-trips to "pid:<n>".
        let node = Hydra.appNodeID(bundleID: nil, pid: 1337)
        XCTAssertEqual(node, "app:pid:1337")
        XCTAssertEqual(Hydra.appKey(fromNodeID: node), "pid:1337")
        // Empty bundle ID is treated like nil.
        XCTAssertEqual(Hydra.appNodeID(bundleID: "", pid: 7), "app:pid:7")
    }

    func testAes67RoundTrip() {
        let id = "stream-abc-123"
        XCTAssertEqual(Hydra.aes67StreamID(fromNodeID: Hydra.aes67NodeID(streamID: id)), id)
    }

    func testNdiRoundTrip() {
        let id = "MACHINE (Camera 1)"
        XCTAssertEqual(Hydra.ndiSourceID(fromNodeID: Hydra.ndiNodeID(sourceID: id)), id)
    }

    func testModuleSourceRoundTrip() {
        let id = "01@SomeDevice"
        XCTAssertEqual(Hydra.moduleSourceID(fromNodeID: Hydra.moduleNodeID(sourceID: id)), id)
    }

    func testModuleSinkRoundTrip() {
        let id = "tx-3"
        XCTAssertEqual(Hydra.moduleSinkID(fromNodeID: Hydra.moduleSinkNodeID(sinkID: id)), id)
    }

    func testVstRoundTrip() {
        let uuid = UUID()
        XCTAssertEqual(Hydra.vstChainID(fromNodeID: Hydra.vstNodeID(chainID: uuid)), uuid)
    }

    // MARK: The trap — "mod:" is a prefix-lookalike of "modtx:". A source decoder
    // must REJECT a sink node, and vice versa, or sources and sinks collide.

    func testModuleSourceRejectsSinkNode() {
        let sinkNode = Hydra.moduleSinkNodeID(sinkID: "x")     // "modtx:x"
        XCTAssertNil(Hydra.moduleSourceID(fromNodeID: sinkNode),
                     "moduleSourceID must not accept a sink node (modtx:)")
    }

    func testModuleSinkRejectsSourceNode() {
        let sourceNode = Hydra.moduleNodeID(sourceID: "x")     // "mod:x"
        XCTAssertNil(Hydra.moduleSinkID(fromNodeID: sourceNode),
                     "moduleSinkID must not accept a source node (mod:)")
    }

    // MARK: Cross-prefix rejection — each decoder returns nil for foreign nodes.

    func testDecodersRejectForeignAndBackplane() {
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
            if !node.hasPrefix("dev:")  { XCTAssertNil(Hydra.deviceUID(fromNodeID: node), node) }
            if !node.hasPrefix("app:")  { XCTAssertNil(Hydra.appKey(fromNodeID: node), node) }
            if !node.hasPrefix("aes67:"){ XCTAssertNil(Hydra.aes67StreamID(fromNodeID: node), node) }
            if !node.hasPrefix("ndi:")  { XCTAssertNil(Hydra.ndiSourceID(fromNodeID: node), node) }
        }
    }

    func testVstChainIDRejectsMalformedUUID() {
        // Right prefix, garbage payload → nil (not a crash).
        XCTAssertNil(Hydra.vstChainID(fromNodeID: "vst:not-a-uuid"))
    }

    // MARK: Version string is well-formed (catches an empty/blank release tag).

    func testVersionStringFormat() {
        XCTAssertFalse(Hydra.version.isEmpty)
        XCTAssertEqual(Hydra.versionString, "\(Hydra.version) \(Hydra.stage)")
    }
}
