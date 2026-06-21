// Hydra Audio — GPL-3.0
import Testing
import Foundation
@testable import HydraCore

struct MessagesTests {

    @Test func statusRoundTrip() throws {
        let payload = StatusPayload(daemonVersion: Hydra.versionString,
                                    backplaneInstalled: true,
                                    backplaneDeviceName: Hydra.backplaneDeviceName,
                                    inputChannels: 256,
                                    outputChannels: 256,
                                    sampleRate: 48_000)
        let wire = try WSMessage.status(payload).encodedString()
        guard case .status(let decoded) = try WSMessage.decode(from: wire) else {
            Issue.record("expected .status"); return
        }
        #expect(decoded == payload)
    }

    @Test func getStatusRoundTrip() throws {
        let wire = try WSMessage.getStatus.encodedString()
        guard case .getStatus = try WSMessage.decode(from: wire) else {
            Issue.record("expected .getStatus"); return
        }
    }

    @Test func connectionIDIsStable() {
        let c = Connection(source: .init(nodeID: "a", channelIndex: 1),
                           destination: .init(nodeID: "b", channelIndex: 2),
                           gain: 0.5)
        #expect(c.id == "a:1->b:2")
    }

    @Test func matrixMessagesRoundTrip() throws {
        let conn = Connection(source: .init(nodeID: Hydra.backplaneNodeID, channelIndex: 0),
                              destination: .init(nodeID: Hydra.backplaneNodeID, channelIndex: 2),
                              gain: 0.5)

        let set = try WSMessage.decode(from: try WSMessage.setConnection(conn).encodedString())
        guard case .setConnection(let decodedSet) = set else { Issue.record("expected .setConnection"); return }
        #expect(decodedSet == conn)

        let matrix = try WSMessage.decode(from: try WSMessage.matrix(MatrixPayload(connections: [conn])).encodedString())
        guard case .matrix(let decodedMatrix) = matrix else { Issue.record("expected .matrix"); return }
        #expect(decodedMatrix.connections == [conn])

        let levels = try WSMessage.decode(from: try WSMessage.levels(LevelsPayload(peaks: [conn.id: 0.8])).encodedString())
        guard case .levels(let decodedLevels) = levels else { Issue.record("expected .levels"); return }
        #expect(abs((decodedLevels.peaks[conn.id] ?? 0) - 0.8) <= 0.0001)

        guard case .getMatrix = try WSMessage.decode(from: try WSMessage.getMatrix.encodedString()) else {
            Issue.record("expected .getMatrix"); return
        }
    }

    @Test func labelMessagesRoundTrip() throws {
        let set = SetLabelPayload(scope: .input, index: 2, label: "Mic Host")
        guard case .setLabel(let decodedSet) = try WSMessage.decode(from: try WSMessage.setLabel(set).encodedString()) else {
            Issue.record("expected .setLabel"); return
        }
        #expect(decodedSet == set)

        let labels = ChannelLabelsPayload(inputs: [0: "Mic", 3: "Return"], outputs: [1: "PA"])
        guard case .labels(let decodedLabels) = try WSMessage.decode(from: try WSMessage.labels(labels).encodedString()) else {
            Issue.record("expected .labels"); return
        }
        #expect(decodedLabels == labels)
        #expect(decodedLabels.label(.input, 3) == "Return")
        #expect(decodedLabels.label(.output, 0) == nil)
    }

    @Test func sceneMessagesRoundTrip() throws {
        let conn = Connection(source: .init(nodeID: Hydra.backplaneNodeID, channelIndex: 0),
                              destination: .init(nodeID: Hydra.backplaneNodeID, channelIndex: 2),
                              gain: 1.0)
        let scene = PatchScene(name: "Live", connections: [conn])

        guard case .scenes(let decoded) = try WSMessage.decode(
            from: try WSMessage.scenes(ScenesPayload(scenes: [scene])).encodedString()) else {
            Issue.record("expected .scenes"); return
        }
        #expect(decoded.scenes.count == 1)
        #expect(decoded.scenes[0].id == scene.id)
        #expect(decoded.scenes[0].name == "Live")
        #expect(decoded.scenes[0].connections == [conn])

        guard case .applyScene(let ref) = try WSMessage.decode(
            from: try WSMessage.applyScene(SceneRefPayload(id: scene.id)).encodedString()) else {
            Issue.record("expected .applyScene"); return
        }
        #expect(ref.id == scene.id)

        guard case .saveScene(let save) = try WSMessage.decode(
            from: try WSMessage.saveScene(SaveScenePayload(name: "Rec")).encodedString()) else {
            Issue.record("expected .saveScene"); return
        }
        #expect(save.name == "Rec")
    }

    @Test func deviceMessagesRoundTrip() throws {
        let info = PhysicalDeviceInfo(uid: "AppleUSBAudio:1234", name: "Scarlett 2i2",
                                      inputChannels: 2, outputChannels: 2,
                                      sampleRate: 48_000, used: true, present: true)
        guard case .devices(let decoded) = try WSMessage.decode(
            from: try WSMessage.devices(DevicesPayload(devices: [info])).encodedString()) else {
            Issue.record("expected .devices"); return
        }
        #expect(decoded.devices == [info])
        #expect(decoded.devices[0].nodeID == "dev:AppleUSBAudio:1234")

        guard case .setDeviceUse(let use) = try WSMessage.decode(
            from: try WSMessage.setDeviceUse(SetDeviceUsePayload(uid: info.uid, used: false)).encodedString()) else {
            Issue.record("expected .setDeviceUse"); return
        }
        #expect(use.uid == info.uid)
        #expect(!use.used)

        // Node ID helpers
        #expect(Hydra.deviceUID(fromNodeID: info.nodeID) == info.uid)
        #expect(Hydra.deviceUID(fromNodeID: Hydra.backplaneNodeID) == nil)
    }

    @Test func appMessagesRoundTrip() throws {
        let app = AppInfo(pid: 4321, bundleID: "com.spotify.client", name: "Spotify",
                          isPlaying: true, captured: true)
        guard case .apps(let decoded) = try WSMessage.decode(
            from: try WSMessage.apps(AppsPayload(apps: [app])).encodedString()) else {
            Issue.record("expected .apps"); return
        }
        #expect(decoded.apps == [app])
        #expect(decoded.apps[0].nodeID == "app:com.spotify.client")

        guard case .setAppCapture(let capture) = try WSMessage.decode(
            from: try WSMessage.setAppCapture(SetAppCapturePayload(pid: 4321, captured: false)).encodedString()) else {
            Issue.record("expected .setAppCapture"); return
        }
        #expect(capture.pid == 4321)
        #expect(!capture.captured)

        // Node ID helpers: bundleID preferred, pid fallback
        #expect(Hydra.appNodeID(bundleID: nil, pid: 99) == "app:pid:99")
        #expect(Hydra.appKey(fromNodeID: "app:com.spotify.client") == "com.spotify.client")
        #expect(Hydra.appKey(fromNodeID: "dev:xyz") == nil)
    }

    @Test func vstAndStripMessagesRoundTrip() throws {
        let plugin = VSTPlugin(id: "/Library/Audio/Plug-Ins/VST3/TAL-Reverb.vst3#0",
                               name: "TAL Reverb 4", vendor: "TAL")

        guard case .vst(let decoded) = try WSMessage.decode(
            from: try WSMessage.vst(VSTPayload(available: [plugin])).encodedString()) else {
            Issue.record("expected .vst"); return
        }
        #expect(decoded.available == [plugin])

        let strip = StripInfo(nodeID: Hydra.backplaneNodeID, channelIndex: 2,
                              stereo: true, trim: 0.5, inserts: [plugin])
        guard case .setStrip(let decodedStrip) = try WSMessage.decode(
            from: try WSMessage.setStrip(strip).encodedString()) else {
            Issue.record("expected .setStrip"); return
        }
        #expect(decodedStrip == strip)
        #expect(decodedStrip.key == "backplane:2")

        guard case .strips(let decodedStrips) = try WSMessage.decode(
            from: try WSMessage.strips(StripsPayload(strips: [strip])).encodedString()) else {
            Issue.record("expected .strips"); return
        }
        #expect(decodedStrips.strips == [strip])

        guard case .openPluginEditor(let editor) = try WSMessage.decode(
            from: try WSMessage.openPluginEditor(OpenEditorPayload(stripID: strip.id, index: 0)).encodedString()) else {
            Issue.record("expected .openPluginEditor"); return
        }
        #expect(editor.stripID == strip.id)
        #expect(editor.index == 0)
    }

    @Test func levelsWithChannelPeaksRoundTrip() throws {
        let payload = LevelsPayload(peaks: ["x": 0.5],
                                    sourcePeaks: [0, 0.1, 0.9],
                                    destinationPeaks: [0.2])
        guard case .levels(let decoded) = try WSMessage.decode(
            from: try WSMessage.levels(payload).encodedString()) else {
            Issue.record("expected .levels"); return
        }
        #expect(decoded == payload)
    }
}
