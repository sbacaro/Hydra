// Hydra Audio — GPL-3.0
// Plugin-management model tests (Settings → Plugins feature): availability/favorite
// filtering, VST3 type classification, backward-compatible decode, and message
// round-trips. Pure logic — runs in CI without Core Audio or a host.

import Testing
import Foundation
@testable import HydraCore

struct PluginManagementTests {

    // MARK: pickerPlugins() — what the strip's insert picker offers.

    @Test func pickerHidesDisabledAndPutsFavoritesFirst() {
        let zebra = VSTPlugin(id: "a", name: "Zebra", vendor: "V")
        let apple = VSTPlugin(id: "b", name: "Apple", vendor: "V")
        let mango = VSTPlugin(id: "c", name: "Mango", vendor: "V")
        let payload = VSTPayload(available: [zebra, apple, mango],
                                 disabledIDs: ["c"],          // Mango hidden
                                 favoriteIDs: ["a"])          // Zebra starred
        // Mango filtered out; Zebra (favorite) first, then Apple alphabetically.
        #expect(payload.pickerPlugins().map(\.id) == ["a", "b"])
    }

    @Test func pickerDefaultShowsEverythingAlphabetical() {
        let p = VSTPayload(available: [
            VSTPlugin(id: "1", name: "Beta",  vendor: "V"),
            VSTPlugin(id: "2", name: "alpha", vendor: "V"),   // case-insensitive sort
        ])
        #expect(p.pickerPlugins().map(\.name) == ["alpha", "Beta"])
    }

    @Test func pickerExcludesOfflinePlugins() {
        let ok  = VSTPlugin(id: "ok",  name: "Good",   vendor: "V")
        let bad = VSTPlugin(id: "bad", name: "Crashy", vendor: "V", offline: true)
        let p = VSTPayload(available: [ok, bad])
        // An offline (hung/crashed) plugin is shown in the manager but never
        // offered as an insert.
        #expect(p.pickerPlugins().map(\.id) == ["ok"])
    }

    // MARK: Type classification from the VST3 subcategory string.

    @Test func instrumentDetection() {
        #expect(VSTPlugin(id: "i", name: "Synth", vendor: "V",
                          category: "Instrument|Synth").isInstrument)
        #expect(!VSTPlugin(id: "e", name: "EQ", vendor: "V",
                           category: "Fx|EQ").isInstrument)
    }

    @Test func primaryType() {
        #expect(VSTPlugin(id: "1", name: "R", vendor: "V", category: "Fx|Reverb").primaryType == "Fx")
        #expect(VSTPlugin(id: "2", name: "S", vendor: "V", category: "Instrument").primaryType == "Instrument")
        // Empty category (legacy data) falls back to the historical "Fx".
        #expect(VSTPlugin(id: "3", name: "L", vendor: "V").primaryType == "Fx")
    }

    // MARK: Backward compatibility — old persisted plugins have no `category`.

    @Test func decodeLegacyPluginWithoutCategory() throws {
        let json = Data(#"{"id":"a#0","name":"Comp","vendor":"Acme"}"#.utf8)
        let p = try JSONDecoder().decode(VSTPlugin.self, from: json)
        #expect(p.category == "")
        #expect(!p.isInstrument)
    }

    @Test func decodeLegacyPayloadWithoutNewFields() throws {
        // A pre-feature VSTPayload (no disabledIDs/favoriteIDs) must still decode.
        let json = Data(#"{"available":[],"scanning":false,"scanProgress":0,"scanLabel":""}"#.utf8)
        let payload = try JSONDecoder().decode(VSTPayload.self, from: json)
        #expect(payload.disabledIDs == [])
        #expect(payload.favoriteIDs == [])
    }

    // MARK: Message round-trips (app → daemon).

    @Test func setPluginAvailableRoundTrips() throws {
        let msg = WSMessage.setPluginAvailable(.init(id: "bundle#2", available: false))
        let decoded = try JSONDecoder().decode(WSMessage.self, from: JSONEncoder().encode(msg))
        guard case let .setPluginAvailable(p) = decoded else {
            Issue.record("decoded to wrong case: \(decoded)"); return
        }
        #expect(p == PluginAvailabilityPayload(id: "bundle#2", available: false))
    }

    @Test func setPluginFavoriteRoundTrips() throws {
        let msg = WSMessage.setPluginFavorite(.init(id: "bundle#2", favorite: true))
        let decoded = try JSONDecoder().decode(WSMessage.self, from: JSONEncoder().encode(msg))
        guard case let .setPluginFavorite(p) = decoded else {
            Issue.record("decoded to wrong case: \(decoded)"); return
        }
        #expect(p == PluginFavoritePayload(id: "bundle#2", favorite: true))
    }
}
