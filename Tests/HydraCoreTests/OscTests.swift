// Hydra Audio — GPL-3.0
import XCTest
@testable import HydraCore

final class OscTests: XCTestCase {

    private func pad(_ s: String) -> [UInt8] {
        var bytes = Array(s.utf8) + [0]
        while bytes.count % 4 != 0 { bytes.append(0) }
        return bytes
    }

    private func be(_ value: Int32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    func testMessageWithStringArg() {
        let data = Data(pad("/hydra/scene/apply") + pad(",s") + pad("Live"))
        let messages = OSCParser.parse(data)
        XCTAssertEqual(messages, [OSCMessage(address: "/hydra/scene/apply", args: [.string("Live")])])
        XCTAssertEqual(messages[0].firstString, "Live")
    }

    func testMessageWithIntAndFloat() {
        let data = Data(pad("/x") + pad(",if") + be(7) + be(Int32(bitPattern: Float(0.5).bitPattern)))
        let messages = OSCParser.parse(data)
        XCTAssertEqual(messages, [OSCMessage(address: "/x", args: [.int(7), .float(0.5)])])
        XCTAssertEqual(messages[0].firstInt, 7)
    }

    func testArgumentlessMessage() {
        let data = Data(pad("/ping"))
        XCTAssertEqual(OSCParser.parse(data), [OSCMessage(address: "/ping")])
    }

    func testBundle() {
        let inner = pad("/hydra/record/start") + pad(",s") + pad("OBS")
        var bundle = pad("#bundle") + [0, 0, 0, 0, 0, 0, 0, 1] // immediate timetag
        bundle += be(Int32(inner.count)) + inner
        let messages = OSCParser.parse(Data(bundle))
        XCTAssertEqual(messages, [OSCMessage(address: "/hydra/record/start", args: [.string("OBS")])])
    }

    func testGarbageRejected() {
        XCTAssertEqual(OSCParser.parse(Data([1, 2, 3])), [])
        XCTAssertEqual(OSCParser.parse(Data(pad("no-slash"))), [])
    }
}
