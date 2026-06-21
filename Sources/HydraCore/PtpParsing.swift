// Hydra Audio — GPL-3.0
// Pure PTPv2 (IEEE 1588-2008) wire parsing + BMCA helpers extracted from
// hydrad's PtpClock so they are unit-testable without sockets or the network
// clock. The socket I/O, election state machine and threading stay in PtpClock.

import Foundation

public enum PtpParsing {

    /// Formats an 8-byte clock identity slice as EUI-64 "XX-XX-…-XX".
    public static func formatIdentity(_ id: ArraySlice<UInt8>) -> String {
        id.map { String(format: "%02X", $0) }.joined(separator: "-")
    }

    /// Decodes a 10-byte PTP timestamp at `offset`: 6-byte big-endian seconds
    /// + 4-byte big-endian nanoseconds → seconds. Nil if the buffer is short.
    public static func timestamp(_ b: [UInt8], at offset: Int) -> Double? {
        guard offset >= 0, b.count >= offset + 10 else { return nil }
        var seconds: UInt64 = 0
        for i in 0..<6 { seconds = (seconds << 8) | UInt64(b[offset + i]) }
        var nanos: UInt32 = 0
        for i in 6..<10 { nanos = (nanos << 8) | UInt32(b[offset + i]) }
        return Double(seconds) + Double(nanos) / 1_000_000_000
    }

    /// Builds the BMCA comparison tuple + grandmaster string from an Announce
    /// message body: priority1, gm clockQuality (4), priority2, gm identity (8).
    /// Nil if the body is too short.
    public static func announceDataset(_ b: [UInt8]) -> (dataset: [UInt8], grandmaster: String)? {
        guard b.count >= 64 else { return nil }
        let dataset: [UInt8] = [b[47]]          // priority1
            + Array(b[48..<52])                 // gm clockQuality
            + [b[52]]                           // priority2
            + Array(b[53..<61])                 // gm identity
        return (dataset, formatIdentity(b[53..<61]))
    }

    /// BMCA precedence: the lexicographically-smaller dataset is the better
    /// (preferred) grandmaster.
    public static func bmcaPrecedes(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        a.lexicographicallyPrecedes(b)
    }

    /// Robust offset estimate: the upper-middle element of the sorted window
    /// (matches PtpClock's index `count / 2`). 0 for an empty window.
    public static func median(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return samples.sorted()[samples.count / 2]
    }
}
