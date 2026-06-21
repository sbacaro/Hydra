// Hydra Audio — GPL-3.0
// SAP/SDP parser tests — runnable without any Dante hardware.

import Testing
import Foundation
@testable import HydraCore

struct Aes67Tests {

    /// A representative Dante AES67 SDP (as announced via SAP).
    private let danteSDP = """
    v=0
    o=- 1311738121 1311738121 IN IP4 192.168.1.50
    s=DMP64PlusCAT : 32
    c=IN IP4 239.69.83.133/32
    t=0 0
    m=audio 5004 RTP/AVP 98
    i=2 channels: Left, Right
    a=recvonly
    a=rtpmap:98 L24/48000/2
    a=ptime:1
    a=ts-refclk:ptp=IEEE1588-2008:00-1D-C1-FF-FE-12-34-56:0
    a=mediaclk:direct=0
    """

    private func sapPacket(sdp: String, deletion: Bool = false,
                           origin: [UInt8] = [192, 168, 1, 50],
                           includeMIME: Bool = true) -> Data {
        var bytes: [UInt8] = []
        // V=1, IPv4, announcement/deletion
        bytes.append(deletion ? 0x24 : 0x20)
        bytes.append(0)            // auth length
        bytes.append(contentsOf: [0xAB, 0xCD]) // msg id hash
        bytes.append(contentsOf: origin)
        if includeMIME {
            bytes.append(contentsOf: Array("application/sdp".utf8))
            bytes.append(0)
        }
        bytes.append(contentsOf: Array(sdp.utf8))
        return Data(bytes)
    }

    @Test func sapAnnouncementWithMIME() {
        let announcement = SAPParser.parse(sapPacket(sdp: danteSDP))
        #expect(announcement != nil)
        #expect(announcement?.isDeletion == false)
        #expect(announcement?.originAddress == "192.168.1.50")
        #expect(announcement?.sdp.hasPrefix("v=0") == true)
    }

    @Test func sapAnnouncementWithoutMIME() {
        let announcement = SAPParser.parse(sapPacket(sdp: danteSDP, includeMIME: false))
        #expect(announcement != nil)
        #expect(announcement?.sdp.hasPrefix("v=0") == true)
    }

    @Test func sapDeletion() {
        let announcement = SAPParser.parse(sapPacket(sdp: danteSDP, deletion: true))
        #expect(announcement?.isDeletion == true)
    }

    @Test func sapRejectsGarbage() {
        #expect(SAPParser.parse(Data([0x00, 0x01, 0x02])) == nil)
        #expect(SAPParser.parse(Data(Array("not a sap packet at all".utf8))) == nil)
    }

    @Test func sdpParsesDanteStream() throws {
        let stream = try #require(SDPParser.parseStream(sdp: danteSDP, origin: "192.168.1.50"))
        #expect(stream.name == "DMP64PlusCAT : 32")
        #expect(stream.address == "239.69.83.133")
        #expect(stream.port == 5004)
        #expect(stream.channels == 2)
        #expect(stream.sampleRate == 48_000)
        #expect(stream.encoding == "L24")
        #expect(stream.origin == "192.168.1.50")
        #expect(stream.id == "192.168.1.50/239.69.83.133:5004")
        #expect(stream.nodeID == "aes67:192.168.1.50/239.69.83.133:5004")
    }

    @Test func sdpParsesL16EightChannels() throws {
        let sdp = """
        v=0
        o=- 99 99 IN IP4 10.0.0.7
        s=Stage Box
        c=IN IP4 239.1.2.3/16
        t=0 0
        m=audio 5004 RTP/AVP 96
        a=rtpmap:96 L16/44100/8
        """
        let stream = try #require(SDPParser.parseStream(sdp: sdp, origin: "10.0.0.7"))
        #expect(stream.channels == 8)
        #expect(stream.sampleRate == 44_100)
        #expect(stream.encoding == "L16")
    }

    @Test func sdpRejectsNonAudio() {
        let sdp = """
        v=0
        o=- 1 1 IN IP4 10.0.0.1
        s=Video thing
        c=IN IP4 239.0.0.9/16
        m=video 5004 RTP/AVP 96
        a=rtpmap:96 H264/90000
        """
        #expect(SDPParser.parseStream(sdp: sdp, origin: "10.0.0.1") == nil)
    }

    @Test func aes67MessagesRoundTrip() throws {
        let stream = Aes67Stream(id: "a/b:5004", name: "Test", address: "239.1.1.1",
                                 port: 5004, channels: 2, sampleRate: 48_000,
                                 encoding: "L24", origin: "10.0.0.1", subscribed: true)
        let payload = Aes67Payload(devices: [Aes67Device(name: "AXI22", aes67On: true)],
                                   streams: [stream])
        guard case .aes67(let decoded) = try WSMessage.decode(
            from: try WSMessage.aes67(payload).encodedString()) else {
            Issue.record("expected .aes67"); return
        }
        #expect(decoded == payload)

        guard case .subscribeStream(let sub) = try WSMessage.decode(
            from: try WSMessage.subscribeStream(SubscribeStreamPayload(id: stream.id, subscribed: false)).encodedString()) else {
            Issue.record("expected .subscribeStream"); return
        }
        #expect(sub.id == stream.id)
        #expect(!sub.subscribed)
    }
}
