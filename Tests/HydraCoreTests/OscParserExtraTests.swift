// Hydra Audio — GPL-3.0
// Extra OSC parser coverage: bundles (nesting, depth cap, multi-element),
// boolean tags, unknown-type termination, truncation, and the firstInt/
// firstString accessors. Complements OscTests with the edge cases.

import Testing
import Foundation
@testable import HydraCore

struct OscParserExtraTests {

    // MARK: - Byte helpers

    /// A null-terminated, 4-byte-aligned OSC string.
    private func pad(_ s: String) -> [UInt8] {
        var bytes = Array(s.utf8) + [0]
        while bytes.count % 4 != 0 { bytes.append(0) }
        return bytes
    }

    /// Big-endian Int32.
    private func be(_ value: Int32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    /// Float as its OSC big-endian bit pattern.
    private func beFloat(_ value: Float) -> [UInt8] {
        be(Int32(bitPattern: value.bitPattern))
    }

    /// Wrap several elements in a #bundle with an immediate timetag.
    private func bundle(_ elements: [[UInt8]]) -> [UInt8] {
        var b = pad("#bundle") + [0, 0, 0, 0, 0, 0, 0, 1] // immediate
        for e in elements { b += be(Int32(e.count)) + e }
        return b
    }

    // MARK: - Argument types

    @Test func booleanTagsBecomeIntsWithoutConsumingData() {
        // ,TF carries no payload bytes — T→1, F→0.
        let data = Data(pad("/b") + pad(",TF"))
        #expect(OSCParser.parse(data) == [OSCMessage(address: "/b", args: [.int(1), .int(0)])])
    }

    @Test func unknownTypeTagStopsParsingButKeepsPriorArgs() {
        // 's' is read, then 'x' (unsupported) ends the message gracefully.
        let data = Data(pad("/u") + pad(",sx") + pad("hi"))
        #expect(OSCParser.parse(data) == [OSCMessage(address: "/u", args: [.string("hi")])])
    }

    @Test func truncatedIntYieldsMessageWithoutThatArg() {
        let data = Data(pad("/t") + pad(",i") + [1, 2]) // only 2 of 4 bytes
        #expect(OSCParser.parse(data) == [OSCMessage(address: "/t")])
    }

    @Test func mixedArgsPreserveOrder() {
        let data = Data(pad("/m") + pad(",sif") + pad("name") + be(42) + beFloat(0.25))
        #expect(OSCParser.parse(data) ==
                [OSCMessage(address: "/m", args: [.string("name"), .int(42), .float(0.25)])])
    }

    // MARK: - Accessors

    @Test func firstIntFallsBackToFloat() {
        let msg = OSCMessage(address: "/x", args: [.float(3.9)])
        #expect(msg.firstInt == 3) // truncates toward zero
    }

    @Test func firstIntPrefersFirstNumeric() {
        let msg = OSCMessage(address: "/x", args: [.string("s"), .int(5), .float(9)])
        #expect(msg.firstInt == 5)
    }

    @Test func firstStringNilWhenAbsent() {
        #expect(OSCMessage(address: "/x", args: [.int(1)]).firstString == nil)
        #expect(OSCMessage(address: "/x").firstInt == nil)
    }

    // MARK: - Bundles

    @Test func bundleWithMultipleMessages() {
        let a = pad("/a") + pad(",s") + pad("one")
        let b = pad("/b") + pad(",i") + be(2)
        let messages = OSCParser.parse(Data(bundle([a, b])))
        #expect(messages == [OSCMessage(address: "/a", args: [.string("one")]),
                             OSCMessage(address: "/b", args: [.int(2)])])
    }

    @Test func nestedBundleIsFlattened() {
        let inner = pad("/deep") + pad(",s") + pad("v")
        let nested = bundle([bundle([inner])])
        #expect(OSCParser.parse(Data(nested)) ==
                [OSCMessage(address: "/deep", args: [.string("v")])])
    }

    @Test func excessiveBundleNestingIsRejected() {
        // Wrap a message in far more than maxBundleDepth (8) bundles.
        var payload = pad("/x") + pad(",s") + pad("v")
        for _ in 0..<12 { payload = bundle([payload]) }
        #expect(OSCParser.parse(Data(payload)) == [])
    }

    @Test func bundleWithZeroSizedElementStops() {
        // A declared element size of 0 terminates the scan (size > 0 guard).
        var b = pad("#bundle") + [0, 0, 0, 0, 0, 0, 0, 1]
        b += be(0) // zero-length element
        #expect(OSCParser.parse(Data(b)) == [])
    }

    @Test func bundleWithOversizedElementStops() {
        // Element claims more bytes than remain → break, no crash.
        var b = pad("#bundle") + [0, 0, 0, 0, 0, 0, 0, 1]
        b += be(9999) + pad("/x")
        #expect(OSCParser.parse(Data(b)) == [])
    }

    // MARK: - Rejection

    @Test func emptyDataYieldsNothing() {
        #expect(OSCParser.parse(Data()) == [])
    }

    @Test func addressWithoutNullTerminatorRejected() {
        #expect(OSCParser.parse(Data([0x2f, 0x61])) == []) // "/a", no null
    }

    @Test func typelessMessageIsArgumentless() {
        // Address present, but the tag string does not start with ',' → no args.
        let data = Data(pad("/only"))
        #expect(OSCParser.parse(data) == [OSCMessage(address: "/only")])
    }
}
