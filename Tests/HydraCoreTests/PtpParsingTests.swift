// Hydra Audio — GPL-3.0
// PTPv2 wire parsing + BMCA helpers: timestamp decode, identity formatting,
// Announce dataset extraction, grandmaster precedence, and the robust median.

import Testing
import Foundation
@testable import HydraCore

struct PtpParsingTests {

    // MARK: - Identity

    @Test func formatsEUI64Identity() {
        let id: [UInt8] = [0x00, 0x1D, 0xC1, 0xFF, 0xFE, 0x12, 0x34, 0x56]
        #expect(PtpParsing.formatIdentity(id[0..<8]) == "00-1D-C1-FF-FE-12-34-56")
    }

    // MARK: - Timestamp

    @Test func decodesSecondsAndNanos() {
        // 6-byte seconds = 1, 4-byte nanos = 500_000_000 → 1.5 s.
        var b = [UInt8](repeating: 0, count: 10)
        b[5] = 1                                   // seconds = 1
        let nanos: UInt32 = 500_000_000
        b[6] = UInt8((nanos >> 24) & 0xFF)
        b[7] = UInt8((nanos >> 16) & 0xFF)
        b[8] = UInt8((nanos >> 8) & 0xFF)
        b[9] = UInt8(nanos & 0xFF)
        let t = PtpParsing.timestamp(b, at: 0)
        #expect(t != nil)
        #expect(abs((t ?? 0) - 1.5) <= 1e-9)
    }

    @Test func timestampHonoursOffset() {
        var b = [UInt8](repeating: 0xFF, count: 14) // 4 byte prefix + 10
        for i in 4..<14 { b[i] = 0 }
        b[9] = 2 // seconds low byte at offset 4 → index 4+5 = 9
        let t = PtpParsing.timestamp(b, at: 4)
        #expect(abs((t ?? -1) - 2.0) <= 1e-9)
    }

    @Test func timestampRejectsShortBufferAndBadOffset() {
        #expect(PtpParsing.timestamp([0, 1, 2], at: 0) == nil)
        #expect(PtpParsing.timestamp([UInt8](repeating: 0, count: 10), at: 4) == nil)
        #expect(PtpParsing.timestamp([UInt8](repeating: 0, count: 10), at: -1) == nil)
    }

    // MARK: - Announce dataset

    @Test func announceDatasetRejectsShortBody() {
        #expect(PtpParsing.announceDataset([UInt8](repeating: 0, count: 40)) == nil)
    }

    @Test func announceDatasetExtractsTupleAndGrandmaster() {
        var b = [UInt8](repeating: 0, count: 64)
        b[47] = 128                               // priority1
        b[48] = 6; b[49] = 0x21; b[50] = 0x00; b[51] = 0x00 // clockQuality
        b[52] = 128                               // priority2
        let gmID: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11]
        for (i, byte) in gmID.enumerated() { b[53 + i] = byte }

        let parsed = PtpParsing.announceDataset(b)
        #expect(parsed?.grandmaster == "AA-BB-CC-DD-EE-FF-00-11")
        #expect(parsed?.dataset.first == 128)              // priority1 leads the tuple
        #expect(parsed?.dataset.count == 14)               // 1 + 4 + 1 + 8
        #expect(Array(parsed?.dataset.suffix(8) ?? []) == gmID)
    }

    // MARK: - BMCA precedence

    @Test func lowerDatasetWinsBMCA() {
        // Lower priority1 (first byte) wins regardless of later bytes.
        #expect(PtpParsing.bmcaPrecedes([10, 0xFF], [20, 0x00]))
        #expect(!PtpParsing.bmcaPrecedes([20, 0x00], [10, 0xFF]))
    }

    @Test func bmcaBreaksTiesOnLaterFields() {
        #expect(PtpParsing.bmcaPrecedes([128, 6, 0x20], [128, 6, 0x21]))
    }

    // MARK: - Median

    @Test func medianOfOddWindow() {
        #expect(PtpParsing.median([0.3, 0.1, 0.2]) == 0.2)
    }

    @Test func medianPicksUpperMiddleForEvenWindow() {
        // sorted = [0.1, 0.2, 0.3, 0.4]; index count/2 = 2 → 0.3.
        #expect(PtpParsing.median([0.4, 0.1, 0.3, 0.2]) == 0.3)
    }

    @Test func medianIsRobustToOutliers() {
        #expect(PtpParsing.median([0.10, 0.11, 0.12, 0.13, 99.0]) == 0.12)
    }

    @Test func medianOfEmptyIsZero() {
        #expect(PtpParsing.median([]) == 0)
    }
}
