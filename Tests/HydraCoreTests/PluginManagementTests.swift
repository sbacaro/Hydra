// Hydra Audio — GPL-3.0
// Plugin-management model tests (Settings → Plugins feature): availability/favorite
// filtering, VST3 type classification, backward-compatible decode, and message
// round-trips. Pure logic — runs in CI without Core Audio or a host.

import XCTest
@testable import HydraCore

final class PluginManagementTests: XCTestCase {

    // MARK: pickerPlugins() — what the strip's insert picker offers.

    func testPickerHidesDisabledAndPutsFavoritesFirst() {
        let zebra = VSTPlugin(id: "a", name: "Zebra", vendor: "V")
        let apple = VSTPlugin(id: "b", name: "Apple", vendor: "V")
        let mango = VSTPlugin(id: "c", name: "Mango", vendor: "V")
        let payload = VSTPayload(available: [zebra, apple, mango],
                                 disabledIDs: ["c"],          // Mango hidden
                                 favoriteIDs: ["a"])          // Zebra starred
        // Mango filtered out; Zebra (favorite) first, then Apple alphabetically.
        XCTAssertEqual(payload.pickerPlugins().map(\.id), ["a", "b"])
    }

    func testPickerDefaultShowsEverythingAlphabetical() {
        let p = VSTPayload(available: [
            VSTPlugin(id: "1", name: "Beta",  vendor: "V"),
            VSTPlugin(id: "2", name: "alpha", vendor: "V"),   // case-insensitive sort
        ])
        XCTAssertEqual(p.pickerPlugins().map(\.name), ["alpha", "Beta"])
    }

    func testPickerExcludesOfflinePlugins() {
        let ok  = VSTPlugin(id: "ok",  name: "Good",   vendor: "V")
        let bad = VSTPlugin(id: "bad", name: "Crashy", vendor: "V", offline: true)
        let p = VSTPayload(available: [ok, bad])
        // An offline (hung/crashed) plugin is shown in the manager but never
        // offered as an insert.
        XCTAssertEqual(p.pickerPlugins().map(\.id), ["ok"])
    }

    // MARK: Type classification from the VST3 subcategory string.

    func testInstrumentDetection() {
        XCTAssertTrue(VSTPlugin(id: "i", name: "Synth", vendor: "V",
                                category: "Instrument|Synth").isInstrument)
        XCTAssertFalse(VSTPlugin(id: "e", name: "EQ", vendor: "V",
                                 category: "Fx|EQ").isInstrument)
    }

    func testPrimaryType() {
        XCTAssertEqual(VSTPlugin(id: "1", name: "R", vendor: "V", category: "Fx|Reverb").primaryType, "Fx")
        XCTAssertEqual(VSTPlugin(id: "2", name: "S", vendor: "V", category: "Instrument").primaryType, "Instrument")
        // Empty category (legacy data) falls back to the historical "Fx".
        XCTAssertEqual(VSTPlugin(id: "3", name: "L", vendor: "V").primaryType, "Fx")
    }

    // MARK: Backward compatibility — old persisted plugins have no `category`.

    func testDecodeLegacyPluginWithoutCategory() throws {
        let json = Data(#"{"id":"a#0","name":"Comp","vendor":"Acme"}"#.utf8)
        let p = try JSONDecoder().decode(VSTPlugin.self, from: json)
        XCTAssertEqual(p.category, "")
        XCTAssertFalse(p.isInstrument)
    }

    func testDecodeLegacyPayloadWithoutNewFields() throws {
        // A pre-feature VSTPayload (no disabledIDs/favoriteIDs) must still decode.
        let json = Data(#"{"available":[],"scanning":false,"scanProgress":0,"scanLabel":""}"#.utf8)
        let payload = try JSONDecoder().decode(VSTPayload.self, from: json)
        XCTAssertEqual(payload.disabledIDs, [])
        XCTAssertEqual(payload.favoriteIDs, [])
    }

    // MARK: Message round-trips (app → daemon).

    func testSetPluginAvailableRoundTrips() throws {
        let msg = Message.setPluginAvailable(.init(id: "bundle#2", available: false))
        let decoded = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(msg))
        guard case let .setPluginAvailable(p) = decoded else {
            return XCTFail("decoded to wrong case: \(decoded)")
        }
        XCTAssertEqual(p, PluginAvailabilityPayload(id: "bundle#2", available: false))
    }

    func testSetPluginFavoriteRoundTrips() throws {
        let msg = Message.setPluginFavorite(.init(id: "bundle#2", favorite: true))
        let decoded = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(msg))
        guard case let .setPluginFavorite(p) = decoded else {
            return XCTFail("decoded to wrong case: \(decoded)")
        }
        XCTAssertEqual(p, PluginFavoritePayload(id: "bundle#2", favorite: true))
    }
}
