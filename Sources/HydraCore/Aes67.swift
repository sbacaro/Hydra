// Hydra Audio — GPL-3.0
// AES67 discovery model + pure SAP/SDP parsing (Phase 4).
// Parsers are pure functions (no networking) so they are fully unit-testable
// without Dante hardware on the network.

import Foundation

// MARK: - Wire model

/// A device present on the network (mDNS `_netaudio-*` announcement).
public struct Aes67Device: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    /// True when the device is also announcing SAP streams (subscribable).
    /// False = "AES67 Offline": present, but AES67 mode is off on the device
    /// (enable it in Dante Controller — Hydra cannot do it remotely).
    public var aes67On: Bool

    public var id: String { name }

    public init(name: String, aes67On: Bool) {
        self.name = name
        self.aes67On = aes67On
    }
}

/// An AES67 stream announced via SAP/SDP.
public struct Aes67Stream: Codable, Sendable, Equatable, Identifiable {
    /// Stable ID: origin address + multicast address + port.
    public var id: String
    public var name: String
    /// Multicast group carrying the RTP audio.
    public var address: String
    public var port: UInt16
    public var channels: Int
    public var sampleRate: Double
    /// "L24" or "L16".
    public var encoding: String
    /// Announcer's address (from the SDP origin line).
    public var origin: String
    public var subscribed: Bool

    public var nodeID: String { Hydra.aes67NodeID(streamID: id) }

    public init(id: String, name: String, address: String, port: UInt16,
                channels: Int, sampleRate: Double, encoding: String,
                origin: String, subscribed: Bool = false) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.channels = channels
        self.sampleRate = sampleRate
        self.encoding = encoding
        self.origin = origin
        self.subscribed = subscribed
    }
}

/// One of Hydra's own AES67 transmitters (a virtual interface's Out side
/// announced via SAP and sent as multicast RTP).
public struct Aes67TxInfo: Codable, Sendable, Equatable, Identifiable {
    public var interfaceID: UUID
    public var name: String
    public var channels: Int
    public var address: String
    public var port: UInt16

    public var id: UUID { interfaceID }

    public init(interfaceID: UUID, name: String, channels: Int,
                address: String, port: UInt16) {
        self.interfaceID = interfaceID
        self.name = name
        self.channels = channels
        self.address = address
        self.port = port
    }
}

/// Daemon → app: network state (pushed on connect and on changes).
public struct Aes67Payload: Codable, Sendable, Equatable {
    public var devices: [Aes67Device]
    public var streams: [Aes67Stream]
    /// Hydra's own transmitters currently on the network.
    public var txFlows: [Aes67TxInfo]

    public init(devices: [Aes67Device], streams: [Aes67Stream],
                txFlows: [Aes67TxInfo] = []) {
        self.devices = devices
        self.streams = streams
        self.txFlows = txFlows
    }

    private enum CodingKeys: String, CodingKey { case devices, streams, txFlows }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        devices = try c.decode([Aes67Device].self, forKey: .devices)
        streams = try c.decode([Aes67Stream].self, forKey: .streams)
        txFlows = try c.decodeIfPresent([Aes67TxInfo].self, forKey: .txFlows) ?? []
    }
}

/// App → daemon: subscribe/unsubscribe an announced stream.
public struct SubscribeStreamPayload: Codable, Sendable, Equatable {
    public var id: String
    public var subscribed: Bool
    public init(id: String, subscribed: Bool) {
        self.id = id
        self.subscribed = subscribed
    }
}

// MARK: - SAP (RFC 2974)

public enum SAPParser {

    public struct Announcement: Equatable {
        /// True for session deletion announcements.
        public let isDeletion: Bool
        public let originAddress: String
        public let sdp: String
    }

    /// Parses one SAP datagram. Returns nil for malformed/unsupported packets.
    public static func parse(_ data: Data) -> Announcement? {
        guard data.count > 8 else { return nil }
        let bytes = [UInt8](data)
        let flags = bytes[0]
        let version = (flags >> 5) & 0x7
        guard version == 1 else { return nil }
        let isIPv6 = (flags & 0x10) != 0
        let isDeletion = (flags & 0x04) != 0
        let isEncrypted = (flags & 0x02) != 0
        let isCompressed = (flags & 0x01) != 0
        guard !isEncrypted, !isCompressed, !isIPv6 else { return nil } // out of scope

        let authLength = Int(bytes[1])
        var offset = 4 // flags + auth len + msg id hash
        // Origin (IPv4)
        guard data.count >= offset + 4 else { return nil }
        let origin = "\(bytes[offset]).\(bytes[offset + 1]).\(bytes[offset + 2]).\(bytes[offset + 3])"
        offset += 4 + authLength * 4
        guard data.count > offset else { return nil }

        // Optional payload type (null-terminated MIME). SDP may also start
        // directly with "v=0".
        let remainder = data.subdata(in: offset..<data.count)
        if let direct = String(data: remainder, encoding: .utf8), direct.hasPrefix("v=") {
            return Announcement(isDeletion: isDeletion, originAddress: origin, sdp: direct)
        }
        if let nullIndex = remainder.firstIndex(of: 0) {
            let mime = String(data: remainder[remainder.startIndex..<nullIndex], encoding: .utf8) ?? ""
            guard mime.isEmpty || mime.contains("sdp") else { return nil }
            let sdpData = remainder[remainder.index(after: nullIndex)...]
            guard let sdp = String(data: sdpData, encoding: .utf8), sdp.hasPrefix("v=") else { return nil }
            return Announcement(isDeletion: isDeletion, originAddress: origin, sdp: sdp)
        }
        return nil
    }
}

// MARK: - SDP (the AES67 subset)

public enum SDPParser {

    /// Parses an AES67 audio session. Returns nil if there is no usable
    /// L16/L24 audio media description.
    public static func parseStream(sdp: String, origin: String,
                                   subscribed: Bool = false) -> Aes67Stream? {
        var name = "AES67 stream"
        var connectionAddress: String?
        var port: UInt16?
        var mediaPayloadType: String?
        var channels = 2
        var sampleRate: Double = 48_000
        var encoding = "L24"
        var originAddress = origin
        var sawAudioMedia = false

        for rawLine in sdp.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.count >= 2 else { continue }

            if line.hasPrefix("s=") {
                let value = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty && value != "-" { name = value }
            } else if line.hasPrefix("o=") {
                // o=<user> <sess-id> <version> IN IP4 <address>
                let parts = line.dropFirst(2).split(separator: " ")
                if parts.count >= 6, parts[4] == "IP4" {
                    originAddress = String(parts[5])
                }
            } else if line.hasPrefix("c=") {
                // c=IN IP4 239.x.y.z/ttl
                let parts = line.dropFirst(2).split(separator: " ")
                if parts.count >= 3, parts[1] == "IP4" {
                    connectionAddress = String(parts[2].split(separator: "/")[0])
                }
            } else if line.hasPrefix("m=audio") {
                // m=audio <port> RTP/AVP <pt>
                let parts = line.dropFirst(2).split(separator: " ")
                if parts.count >= 4 {
                    sawAudioMedia = true
                    port = UInt16(parts[1])
                    mediaPayloadType = String(parts[3])
                }
            } else if line.hasPrefix("a=rtpmap:") {
                // a=rtpmap:<pt> L24/48000/8
                let body = line.dropFirst("a=rtpmap:".count)
                let parts = body.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let pt = String(parts[0])
                if let expected = mediaPayloadType, pt != expected { continue }
                let format = parts[1].split(separator: "/")
                guard format.count >= 2 else { continue }
                let enc = String(format[0]).uppercased()
                guard enc == "L24" || enc == "L16" else { continue }
                encoding = enc
                sampleRate = Double(format[1]) ?? 48_000
                channels = format.count >= 3 ? (Int(format[2]) ?? 2) : 2
            }
        }

        guard sawAudioMedia, let address = connectionAddress, let port,
              channels > 0, channels <= 64 else { return nil }

        return Aes67Stream(
            id: "\(originAddress)/\(address):\(port)",
            name: name,
            address: address,
            port: port,
            channels: channels,
            sampleRate: sampleRate,
            encoding: encoding,
            origin: originAddress,
            subscribed: subscribed)
    }
}
