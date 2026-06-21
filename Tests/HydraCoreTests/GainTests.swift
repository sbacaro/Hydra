// Hydra Audio — GPL-3.0
// dB ↔ linear conversion: reference values, floor behaviour, sign handling
// and monotonicity. Audio-calibration accuracy matters, so this is exhaustive.

import Testing
import Foundation
@testable import HydraCore

struct GainTests {

    @Test func unityIsZeroDB() {
        #expect(abs(Gain.decibels(fromLinear: 1.0) - 0) <= 0.0001)
        #expect(abs(Gain.linear(fromDecibels: 0) - 1.0) <= 0.0001)
    }

    @Test func knownReferenceValues() {
        // -6 dB ≈ 0.5012, +6 dB ≈ 1.9953, -20 dB = 0.1, +20 dB = 10.
        #expect(abs(Gain.linear(fromDecibels: -6) - 0.5012) <= 0.001)
        #expect(abs(Gain.linear(fromDecibels: 6) - 1.9953) <= 0.001)
        #expect(abs(Gain.linear(fromDecibels: -20) - 0.1) <= 0.0001)
        #expect(abs(Gain.linear(fromDecibels: 20) - 10) <= 0.001)
    }

    @Test func silenceClampsAtFloor() {
        #expect(abs(Gain.decibels(fromLinear: 0) - (-120)) <= 0.001)
    }

    @Test func negativeLinearUsesMagnitude() {
        #expect(Gain.decibels(fromLinear: -1.0) == Gain.decibels(fromLinear: 1.0))
        #expect(Gain.decibels(fromLinear: -0.5) == Gain.decibels(fromLinear: 0.5))
    }

    @Test func roundTripAcrossRange() {
        for db: Float in stride(from: -60, through: 24, by: 3).map({ Float($0) }) {
            let back = Gain.decibels(fromLinear: Gain.linear(fromDecibels: db))
            #expect(abs(back - db) <= 0.001)
        }
    }

    @Test func decibelsAreMonotonic() {
        let a = Gain.decibels(fromLinear: 0.25)
        let b = Gain.decibels(fromLinear: 0.5)
        let c = Gain.decibels(fromLinear: 1.0)
        #expect(a < b)
        #expect(b < c)
    }
}
