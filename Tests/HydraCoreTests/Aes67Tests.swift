// Hydra Audio — GPL-3.0
// SAP/SDP parser tests — runnable without any Dante hardware.

import XCTest
@testable import HydraCore

final class Aes67Tests: XCTestCase {

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

    func testSAPAnnouncementWithMIME() {
        let announcement = SAPParser.parse(sapPacket(sdp: danteSDP))
        XCTAssertNotNil(announcement)
        XCTAssertEqual(announcement?.isDeletion, false)
        XCTAssertEqual(announcement?.originAddress, "192.168.1.50")
        XCTAssertEqual(announcement?.sdp.hasPrefix("v=0"), true)
    }

    func testSAPAnnouncementWithoutMIME() {
        let announcement = SAPParser.parse(sapPacket(sdp: danteSDP, includeMIME: false))
        XCTAssertNotNil(announcement)
        XCTAssertEqual(announcement?.sdp.hasPrefix("v=0"), true)
    }

    func testSAPDeletion() {
        let announcement = SAPParser.parse(sapPacket(sdp: danteSDP, deletion: true))
        XCTAssertEqual(announcement?.isDeletion, true)
    }

    func testSAPRejectsGarbage() {
        XCTAssertNil(SAPParser.parse(Data([0x00, 0x01, 0x02])))
        XCTAssertNil(SAPParser.parse(Data(Array("not a sap packet at all".utf8))))
    }

    func testSDPParsesDanteStream() throws {
        let stream = try XCTUnwrap(SDPParser.parseStream(sdp: danteSDP, origin: "192.168.1.50"))
        XCTAssertEqual(stream.name, "DMP64PlusCAT : 32")
        XCTAssertEqual(stream.address, "239.69.83.133")
        XCTAssertEqual(stream.port, 5004)
        XCTAssertEqual(stream.channels, 2)
        XCTAssertEqual(stream.sampleRate, 48_000)
        XCTAssertEqual(stream.encoding, "L24")
        XCTAssertEqual(stream.origin, "192.168.1.50")
        XCTAssertEqual(stream.id, "192.168.1.50/239.69.83.133:5004")
        XCTAssertEqual(stream.nodeID, "aes67:192.168.1.50/239.69.83.133:5004")
    }

    func testSDPParsesL16EightChannels() throws {
        let sdp = """
        v=0
        o=- 99 99 IN IP4 10.0.0.7
        s=Stage Box
        c=IN IP4 239.1.2.3/16
        t=0 0
        m=audio 5004 RTP/AVP 96
        a=rtpmap:96 L16/44100/8
        """
        let stream = try XCTUnwrap(SDPParser.parseStream(sdp: sdp, origin: "10.0.0.7"))
        XCTAssertEqual(stream.channels, 8)
        XCTAssertEqual(stream.sampleRate, 44_100)
        XCTAssertEqual(stream.encoding, "L16")
    }

    func testSDPRejectsNonAudio() {
        let sdp = """
        v=0
        o=- 1 1 IN IP4 10.0.0.1
        s=Video thing
        c=IN IP4 239.0.0.9/16
        m=video 5004 RTP/AVP 96
        a=rtpmap:96 H264/90000
        """
        XCTAssertNil(SDPParser.parseStream(sdp: sdp, origin: "10.0.0.1"))
    }

    func testAes67MessagesRoundTrip() throws {
        let stream = Aes67Stream(id: "a/b:5004", name: "Test", address: "239.1.1.1",
                                 port: 5004, channels: 2, sampleRate: 48_000,
                                 encoding: "L24", origin: "10.0.0.1", subscribed: true)
        let payload = Aes67Payload(devices: [Aes67Device(name: "AXI22", aes67On: true)],
                                   streams: [stream])
        guard case .aes67(let decoded) = try WSMessage.decode(
            from: try WSMessage.aes67(payload).encodedString()) else {
            return XCTFail("expected .aes67")
        }
        XCTAssertEqual(decoded, payload)

        guard case .subscribeStream(let sub) = try WSMessage.decode(
            from: try WSMessage.subscribeStream(SubscribeStreamPayload(id: stream.id, subscribed: false)).encodedString()) else {
            return XCTFail("expected .subscribeStream")
        }
        XCTAssertEqual(sub.id, stream.id)
        XCTAssertFalse(sub.subscribed)
    }
}
