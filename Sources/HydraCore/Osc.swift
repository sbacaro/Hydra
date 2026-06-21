// Hydra Audio — GPL-3.0
// Minimal OSC 1.0 parsing — pure functions, unit-tested (like SAP/SDP).
//
// Scope: receive-only control surface. Supports messages and #bundle
// containers; argument types i (int32), f (float32), s (string). Everything
// else is skipped gracefully (unknown args end the parse of that message).
//
// Hydra's address space (handled by the daemon):
//   /hydra/scene/apply   s:name | i:index   — apply a saved scene
//   /hydra/scene/save    s:name             — snapshot the matrix as a scene
//   /hydra/record/start  s:interfaceName    — record a virtual interface
//   /hydra/record/stop   s:interfaceName

import Foundation

public enum OSCArg: Equatable, Sendable {
    case int(Int32)
    case float(Float)
    case string(String)
}

public struct OSCMessage: Equatable, Sendable {
    public var address: String
    public var args: [OSCArg]

    public init(address: String, args: [OSCArg] = []) {
        self.address = address
        self.args = args
    }

    public var firstString: String? {
        for arg in args { if case .string(let s) = arg { return s } }
        return nil
    }

    public var firstInt: Int? {
        for arg in args {
            if case .int(let i) = arg { return Int(i) }
            if case .float(let f) = arg { return Int(f) }
        }
        return nil
    }
}

public enum OSCParser {

    /// Parses a UDP datagram: either a single message or a #bundle
    /// (recursively flattened; timetags are ignored — execute immediately).
    public static func parse(_ data: Data) -> [OSCMessage] {
        let bytes = [UInt8](data)
        if bytes.starts(with: Array("#bundle\0".utf8)) {
            return parseBundle(bytes)
        }
        if let message = parseMessage(bytes) {
            return [message]
        }
        return []
    }

    // MARK: Internals

    /// Guards against a crafted datagram of deeply nested bundles overflowing
    /// the stack. OSC has no legitimate need for deep nesting.
    private static let maxBundleDepth = 8

    private static func parseBundle(_ bytes: [UInt8], depth: Int = 0) -> [OSCMessage] {
        guard depth < maxBundleDepth else { return [] }
        var messages: [OSCMessage] = []
        var offset = 16 // "#bundle\0" (8) + timetag (8)
        while offset + 4 <= bytes.count {
            let size = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                     | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard size > 0, offset + size <= bytes.count else { break }
            let element = Array(bytes[offset ..< offset + size])
            if element.starts(with: Array("#bundle\0".utf8)) {
                messages.append(contentsOf: parseBundle(element, depth: depth + 1))
            } else if let message = parseMessage(element) {
                messages.append(message)
            }
            offset += size
        }
        return messages
    }

    private static func parseMessage(_ bytes: [UInt8]) -> OSCMessage? {
        var offset = 0
        guard let address = readString(bytes, &offset), address.hasPrefix("/") else { return nil }
        guard let tags = readString(bytes, &offset), tags.hasPrefix(",") else {
            return OSCMessage(address: address) // no type tags: argument-less
        }
        var args: [OSCArg] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "i":
                guard let value = readInt32(bytes, &offset) else { return OSCMessage(address: address, args: args) }
                args.append(.int(value))
            case "f":
                guard let value = readInt32(bytes, &offset) else { return OSCMessage(address: address, args: args) }
                args.append(.float(Float(bitPattern: UInt32(bitPattern: value))))
            case "s":
                guard let value = readString(bytes, &offset) else { return OSCMessage(address: address, args: args) }
                args.append(.string(value))
            case "T": args.append(.int(1))
            case "F": args.append(.int(0))
            default:
                // Unknown type (blob, double, …): cannot skip safely — stop here.
                return OSCMessage(address: address, args: args)
            }
        }
        return OSCMessage(address: address, args: args)
    }

    /// Null-terminated string padded to a 4-byte boundary.
    private static func readString(_ bytes: [UInt8], _ offset: inout Int) -> String? {
        guard offset < bytes.count else { return nil }
        guard let end = bytes[offset...].firstIndex(of: 0) else { return nil }
        let string = String(decoding: bytes[offset ..< end], as: UTF8.self)
        offset = (end + 4) & ~3
        return string
    }

    private static func readInt32(_ bytes: [UInt8], _ offset: inout Int) -> Int32? {
        guard offset + 4 <= bytes.count else { return nil }
        let value = Int32(bitPattern:
            UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
          | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3]))
        offset += 4
        return value
    }
}
