// Hydra Audio — GPL-3.0
// Extra SAP/SDP coverage: rejected SAP variants (version, IPv6, encryption,
// compression, auth-word skipping, MIME filtering) and SDP edge cases
// (missing fields, channel cap, defaults, payload-type matching, case-folding).

import Testing
import Foundation
@testable import HydraCore

struct Aes67ParserExtraTests {

    // MARK: - SAP packet builder

    /// Builds a SAP datagram. `authWords` 32-bit auth blocks sit AFTER the
    /// IPv4 origin, matching SAPParser's `offset += 4 + authLength*4`.
    private func sap(flags: UInt8,
                     authWords: Int = 0,
                     origin: [UInt8] = [10, 0, 0, 5],
                     payload: [UInt8]) -> Data {
        var b: [UInt8] = [flags, UInt8(authWords), 0xAB, 0xCD]
        b += origin
        b += Array(repeating: 0, count: authWords * 4)
        b += payload
        return Data(b)
    }

    private let minimalSDP = """
    v=0
    o=- 1 1 IN IP4 10.0.0.5
    s=Name
    c=IN IP4 239.1.2.3/32
    t=0 0
    m=audio 5004 RTP/AVP 98
    a=rtpmap:98 L24/48000/2
    """

    private func directPayload(_ sdp: String) -> [UInt8] { Array(sdp.utf8) }
    private func mimePayload(_ mime: String, _ sdp: String) -> [UInt8] {
        Array(mime.utf8) + [0] + Array(sdp.utf8)
    }

    // MARK: - SAP rejection

    @Test func sapRejectsVersionOtherThanOne() {
        #expect(SAPParser.parse(sap(flags: 0x00, payload: directPayload(minimalSDP))) == nil) // v0
        #expect(SAPParser.parse(sap(flags: 0x40, payload: directPayload(minimalSDP))) == nil) // v2
    }

    @Test func sapRejectsIPv6() {
        #expect(SAPParser.parse(sap(flags: 0x30, payload: directPayload(minimalSDP))) == nil)
    }

    @Test func sapRejectsEncryptedAndCompressed() {
        #expect(SAPParser.parse(sap(flags: 0x22, payload: directPayload(minimalSDP))) == nil) // E
        #expect(SAPParser.parse(sap(flags: 0x21, payload: directPayload(minimalSDP))) == nil) // C
    }

    @Test func sapRejectsTooShort() {
        #expect(SAPParser.parse(Data([0x20, 0, 0, 0, 0, 0, 0, 0])) == nil) // exactly 8 bytes
    }

    @Test func sapSkipsAuthWords() {
        let pkt = sap(flags: 0x20, authWords: 2, origin: [192, 168, 0, 9],
                      payload: directPayload(minimalSDP))
        let ann = SAPParser.parse(pkt)
        #expect(ann?.originAddress == "192.168.0.9")
        #expect(ann?.sdp.hasPrefix("v=0") == true)
    }

    @Test func sapRejectsNonSDPMime() {
        let pkt = sap(flags: 0x20, payload: mimePayload("text/plain", minimalSDP))
        #expect(SAPParser.parse(pkt) == nil)
    }

    @Test func sapAcceptsEmptyMimePrefix() {
        // A leading null (empty MIME) is allowed; SDP follows it.
        let pkt = sap(flags: 0x20, payload: [0] + Array(minimalSDP.utf8))
        #expect(SAPParser.parse(pkt)?.sdp.hasPrefix("v=0") == true)
    }

    // MARK: - SDP rejection

    @Test func sdpRejectsMissingConnection() {
        let sdp = """
        v=0
        o=- 1 1 IN IP4 10.0.0.5
        s=Name
        m=audio 5004 RTP/AVP 98
        a=rtpmap:98 L24/48000/2
        """
        #expect(SDPParser.parseStream(sdp: sdp, origin: "10.0.0.5") == nil)
    }

    @Test func sdpRejectsMissingAudioMedia() {
        let sdp = """
        v=0
        o=- 1 1 IN IP4 10.0.0.5
        s=Name
        c=IN IP4 239.1.2.3/32
        """
        #expect(SDPParser.parseStream(sdp: sdp, origin: "10.0.0.5") == nil)
    }

    @Test func sdpRejectsTooManyChannels() {
        let sdp = minimalSDP.replacingOccurrences(of: "L24/48000/2", with: "L24/48000/96")
        #expect(SDPParser.parseStream(sdp: sdp, origin: "10.0.0.5") == nil)
    }

    // MARK: - SDP defaults & parsing

    @Test func sdpDefaultsChannelsWhenCountOmitted() throws {
        let sdp = minimalSDP.replacingOccurrences(of: "L24/48000/2", with: "L24/48000")
        let stream = try #require(SDPParser.parseStream(sdp: sdp, origin: "10.0.0.5"))
        #expect(stream.channels == 2) // default
        #expect(stream.sampleRate == 48_000)
    }

    @Test func sdpFallsBackToDefaultNameForDash() throws {
        let sdp = minimalSDP.replacingOccurrences(of: "s=Name", with: "s=-")
        let stream = try #require(SDPParser.parseStream(sdp: sdp, origin: "10.0.0.5"))
        #expect(stream.name == "AES67 stream")
    }

    @Test func sdpStripsTTLFromConnectionAddress() throws {
        let stream = try #require(SDPParser.parseStream(sdp: minimalSDP, origin: "10.0.0.5"))
        #expect(stream.address == "239.1.2.3") // "/32" removed
    }

    @Test func sdpUsesOriginFromOLine() throws {
        // o= advertises a different address than the SAP origin passed in.
        let stream = try #require(SDPParser.parseStream(sdp: minimalSDP, origin: "0.0.0.0"))
        #expect(stream.origin == "10.0.0.5")
        #expect(stream.id == "10.0.0.5/239.1.2.3:5004")
    }

    @Test func sdpAcceptsLowercaseEncoding() throws {
        let sdp = minimalSDP.replacingOccurrences(of: "L24/48000/2", with: "l16/44100/4")
        let stream = try #require(SDPParser.parseStream(sdp: sdp, origin: "10.0.0.5"))
        #expect(stream.encoding == "L16")
        #expect(stream.channels == 4)
        #expect(stream.sampleRate == 44_100)
    }

    @Test func sdpIgnoresRtpmapWithMismatchedPayloadType() throws {
        // m=audio advertises pt 98, but rtpmap is for 99 → ignored, defaults kept.
        let sdp = minimalSDP.replacingOccurrences(of: "a=rtpmap:98", with: "a=rtpmap:99")
        let stream = try #require(SDPParser.parseStream(sdp: sdp, origin: "10.0.0.5"))
        #expect(stream.encoding == "L24")   // default
        #expect(stream.channels == 2)       // default
    }

    // MARK: - Aes67 model

    @Test func aes67TxFlowIDComposesInterfaceAndFlowIndex() {
        let uuid = UUID()
        let tx = Aes67TxInfo(interfaceID: uuid, name: "Mix", channels: 8,
                             address: "239.0.0.1", port: 5004, flowIndex: 2)
        #expect(tx.id == "\(uuid.uuidString):2")
    }

    @Test func aes67DeviceDecodesLegacyWithoutChannels() throws {
        let json = Data(#"{"name":"AXI22","aes67On":true}"#.utf8)
        let device = try JSONDecoder().decode(Aes67Device.self, from: json)
        #expect(device.channels == 0) // defaulted
        #expect(device.aes67On)
    }
}
