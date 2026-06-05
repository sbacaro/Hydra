// Hydra Audio — GPL-3.0
import XCTest
@testable import HydraCore

final class MessagesTests: XCTestCase {

    func testStatusRoundTrip() throws {
        let payload = StatusPayload(daemonVersion: Hydra.versionString,
                                    backplaneInstalled: true,
                                    backplaneDeviceName: Hydra.backplaneDeviceName,
                                    inputChannels: 256,
                                    outputChannels: 256,
                                    sampleRate: 48_000)
        let wire = try WSMessage.status(payload).encodedString()
        guard case .status(let decoded) = try WSMessage.decode(from: wire) else {
            return XCTFail("expected .status")
        }
        XCTAssertEqual(decoded, payload)
    }

    func testGetStatusRoundTrip() throws {
        let wire = try WSMessage.getStatus.encodedString()
        guard case .getStatus = try WSMessage.decode(from: wire) else {
            return XCTFail("expected .getStatus")
        }
    }

    func testConnectionIDIsStable() {
        let c = Connection(source: .init(nodeID: "a", channelIndex: 1),
                           destination: .init(nodeID: "b", channelIndex: 2),
                           gain: 0.5)
        XCTAssertEqual(c.id, "a:1->b:2")
    }

    func testMatrixMessagesRoundTrip() throws {
        let conn = Connection(source: .init(nodeID: Hydra.backplaneNodeID, channelIndex: 0),
                              destination: .init(nodeID: Hydra.backplaneNodeID, channelIndex: 2),
                              gain: 0.5)

        let set = try WSMessage.decode(from: try WSMessage.setConnection(conn).encodedString())
        guard case .setConnection(let decodedSet) = set else { return XCTFail("expected .setConnection") }
        XCTAssertEqual(decodedSet, conn)

        let matrix = try WSMessage.decode(from: try WSMessage.matrix(MatrixPayload(connections: [conn])).encodedString())
        guard case .matrix(let decodedMatrix) = matrix else { return XCTFail("expected .matrix") }
        XCTAssertEqual(decodedMatrix.connections, [conn])

        let levels = try WSMessage.decode(from: try WSMessage.levels(LevelsPayload(peaks: [conn.id: 0.8])).encodedString())
        guard case .levels(let decodedLevels) = levels else { return XCTFail("expected .levels") }
        XCTAssertEqual(decodedLevels.peaks[conn.id] ?? 0, 0.8, accuracy: 0.0001)

        guard case .getMatrix = try WSMessage.decode(from: try WSMessage.getMatrix.encodedString()) else {
            return XCTFail("expected .getMatrix")
        }
    }

    func testLabelMessagesRoundTrip() throws {
        let set = SetLabelPayload(scope: .input, index: 2, label: "Mic Host")
        guard case .setLabel(let decodedSet) = try WSMessage.decode(from: try WSMessage.setLabel(set).encodedString()) else {
            return XCTFail("expected .setLabel")
        }
        XCTAssertEqual(decodedSet, set)

        let labels = ChannelLabelsPayload(inputs: [0: "Mic", 3: "Return"], outputs: [1: "PA"])
        guard case .labels(let decodedLabels) = try WSMessage.decode(from: try WSMessage.labels(labels).encodedString()) else {
            return XCTFail("expected .labels")
        }
        XCTAssertEqual(decodedLabels, labels)
        XCTAssertEqual(decodedLabels.label(.input, 3), "Return")
        XCTAssertNil(decodedLabels.label(.output, 0))
    }

    func testSceneMessagesRoundTrip() throws {
        let conn = Connection(source: .init(nodeID: Hydra.backplaneNodeID, channelIndex: 0),
                              destination: .init(nodeID: Hydra.backplaneNodeID, channelIndex: 2),
                              gain: 1.0)
        let scene = PatchScene(name: "Live", connections: [conn])

        guard case .scenes(let decoded) = try WSMessage.decode(
            from: try WSMessage.scenes(ScenesPayload(scenes: [scene])).encodedString()) else {
            return XCTFail("expected .scenes")
        }
        XCTAssertEqual(decoded.scenes.count, 1)
        XCTAssertEqual(decoded.scenes[0].id, scene.id)
        XCTAssertEqual(decoded.scenes[0].name, "Live")
        XCTAssertEqual(decoded.scenes[0].connections, [conn])

        guard case .applyScene(let ref) = try WSMessage.decode(
            from: try WSMessage.applyScene(SceneRefPayload(id: scene.id)).encodedString()) else {
            return XCTFail("expected .applyScene")
        }
        XCTAssertEqual(ref.id, scene.id)

        guard case .saveScene(let save) = try WSMessage.decode(
            from: try WSMessage.saveScene(SaveScenePayload(name: "Rec")).encodedString()) else {
            return XCTFail("expected .saveScene")
        }
        XCTAssertEqual(save.name, "Rec")
    }

    func testDeviceMessagesRoundTrip() throws {
        let info = PhysicalDeviceInfo(uid: "AppleUSBAudio:1234", name: "Scarlett 2i2",
                                      inputChannels: 2, outputChannels: 2,
                                      sampleRate: 48_000, used: true, present: true)
        guard case .devices(let decoded) = try WSMessage.decode(
            from: try WSMessage.devices(DevicesPayload(devices: [info])).encodedString()) else {
            return XCTFail("expected .devices")
        }
        XCTAssertEqual(decoded.devices, [info])
        XCTAssertEqual(decoded.devices[0].nodeID, "dev:AppleUSBAudio:1234")

        guard case .setDeviceUse(let use) = try WSMessage.decode(
            from: try WSMessage.setDeviceUse(SetDeviceUsePayload(uid: info.uid, used: false)).encodedString()) else {
            return XCTFail("expected .setDeviceUse")
        }
        XCTAssertEqual(use.uid, info.uid)
        XCTAssertFalse(use.used)

        // Node ID helpers
        XCTAssertEqual(Hydra.deviceUID(fromNodeID: info.nodeID), info.uid)
        XCTAssertNil(Hydra.deviceUID(fromNodeID: Hydra.backplaneNodeID))
    }

    func testAppMessagesRoundTrip() throws {
        let app = AppInfo(pid: 4321, bundleID: "com.spotify.client", name: "Spotify",
                          isPlaying: true, captured: true)
        guard case .apps(let decoded) = try WSMessage.decode(
            from: try WSMessage.apps(AppsPayload(apps: [app])).encodedString()) else {
            return XCTFail("expected .apps")
        }
        XCTAssertEqual(decoded.apps, [app])
        XCTAssertEqual(decoded.apps[0].nodeID, "app:com.spotify.client")

        guard case .setAppCapture(let capture) = try WSMessage.decode(
            from: try WSMessage.setAppCapture(SetAppCapturePayload(pid: 4321, captured: false)).encodedString()) else {
            return XCTFail("expected .setAppCapture")
        }
        XCTAssertEqual(capture.pid, 4321)
        XCTAssertFalse(capture.captured)

        // Node ID helpers: bundleID preferred, pid fallback
        XCTAssertEqual(Hydra.appNodeID(bundleID: nil, pid: 99), "app:pid:99")
        XCTAssertEqual(Hydra.appKey(fromNodeID: "app:com.spotify.client"), "com.spotify.client")
        XCTAssertNil(Hydra.appKey(fromNodeID: "dev:xyz"))
    }

    func testVSTAndStripMessagesRoundTrip() throws {
        let plugin = VSTPlugin(id: "/Library/Audio/Plug-Ins/VST3/TAL-Reverb.vst3#0",
                               name: "TAL Reverb 4", vendor: "TAL")

        guard case .vst(let decoded) = try WSMessage.decode(
            from: try WSMessage.vst(VSTPayload(available: [plugin])).encodedString()) else {
            return XCTFail("expected .vst")
        }
        XCTAssertEqual(decoded.available, [plugin])

        let strip = StripInfo(nodeID: Hydra.backplaneNodeID, channelIndex: 2,
                              stereo: true, trim: 0.5, inserts: [plugin])
        guard case .setStrip(let decodedStrip) = try WSMessage.decode(
            from: try WSMessage.setStrip(strip).encodedString()) else {
            return XCTFail("expected .setStrip")
        }
        XCTAssertEqual(decodedStrip, strip)
        XCTAssertEqual(decodedStrip.key, "backplane:2")

        guard case .strips(let decodedStrips) = try WSMessage.decode(
            from: try WSMessage.strips(StripsPayload(strips: [strip])).encodedString()) else {
            return XCTFail("expected .strips")
        }
        XCTAssertEqual(decodedStrips.strips, [strip])

        guard case .openPluginEditor(let editor) = try WSMessage.decode(
            from: try WSMessage.openPluginEditor(OpenEditorPayload(stripID: strip.id, index: 0)).encodedString()) else {
            return XCTFail("expected .openPluginEditor")
        }
        XCTAssertEqual(editor.stripID, strip.id)
        XCTAssertEqual(editor.index, 0)
    }

    func testLevelsWithChannelPeaksRoundTrip() throws {
        let payload = LevelsPayload(peaks: ["x": 0.5],
                                    sourcePeaks: [0, 0.1, 0.9],
                                    destinationPeaks: [0.2])
        guard case .levels(let decoded) = try WSMessage.decode(
            from: try WSMessage.levels(payload).encodedString()) else {
            return XCTFail("expected .levels")
        }
        XCTAssertEqual(decoded, payload)
    }
}
