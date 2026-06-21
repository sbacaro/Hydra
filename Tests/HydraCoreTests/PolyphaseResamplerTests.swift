// Hydra Audio — GPL-3.0
// Polyphase windowed-sinc resampler: unit DC gain, integer-position passthrough,
// constant/ramp reconstruction, decimation table, and numeric sanity. These give
// confidence in the kernel before it runs on the real-time audio thread.

import Testing
import Foundation
@testable import HydraCore

struct PolyphaseResamplerTests {

    // MARK: - Table shape

    @Test func tapsAreEvenAndAtLeastBase() {
        let r = PolyphaseResampler(ratio: 1.0, baseTaps: 24)
        #expect(r.taps % 2 == 0)
        #expect(r.taps >= 24)
        #expect(r.coefficients.count == r.taps * r.phases)
    }

    @Test func decimationWidensTheKernel() {
        let unity = PolyphaseResampler(ratio: 1.0, baseTaps: 24)
        let deci  = PolyphaseResampler(ratio: 2.0, baseTaps: 24)
        #expect(deci.taps > unity.taps) // more taps to realise the lower cutoff
    }

    @Test func tapsAreCapped() {
        let r = PolyphaseResampler(ratio: 100.0, baseTaps: 24, maxTaps: 96)
        #expect(r.taps <= 96)
    }

    // MARK: - DC gain

    @Test func everyPhaseHasUnityDCGain() {
        let r = PolyphaseResampler(ratio: 1.0)
        for p in stride(from: 0, to: r.phases, by: 37) {
            let sum = r.coefficients(phase: p).reduce(0, +)
            #expect(abs(sum - 1.0) <= 1e-3)
        }
    }

    @Test func decimationPhasesAlsoUnityGain() {
        let r = PolyphaseResampler(ratio: 2.18) // ~96k → 44.1k
        for p in [0, r.phases / 2, r.phases - 1] {
            let sum = r.coefficients(phase: p).reduce(0, +)
            #expect(abs(sum - 1.0) <= 1e-3)
        }
    }

    // MARK: - Reconstruction

    @Test func phaseZeroPeaksAtCenter() {
        // With a sub-Nyquist cutoff the phase-0 row is a windowed sinc (not a
        // perfect impulse), but the current sample must dominate and side taps
        // must decay. The "acts like identity for in-band signals" property is
        // covered by the DC / ramp / integer-passthrough tests.
        let r = PolyphaseResampler(ratio: 1.0)
        let row = Array(r.coefficients(phase: 0))
        let peak = row.indices.max(by: { abs(row[$0]) < abs(row[$1]) })!
        #expect(peak == r.center)             // largest tap is the current sample
        #expect(row[r.center] > 0.85)         // and it dominates the kernel
        #expect(abs(row[r.center + 4]) < abs(row[r.center + 1])) // side lobes decay
    }

    @Test func integerPositionPassesSampleThrough() {
        let r = PolyphaseResampler(ratio: 1.0)
        let ramp = (0..<80).map { Float($0) }
        #expect(abs(r.value(in: ramp, at: 40.0) - 40.0) <= 1e-3)
    }

    @Test func constantSignalIsPreserved() {
        let r = PolyphaseResampler(ratio: 1.0)
        let dc = [Float](repeating: 3.0, count: 64)
        for pos in [20.0, 30.4, 41.5, 50.9] {
            #expect(abs(r.value(in: dc, at: pos) - 3.0) <= 1e-3)
        }
    }

    @Test func linearRampIsReconstructed() {
        let r = PolyphaseResampler(ratio: 1.0)
        let ramp = (0..<80).map { Float($0) }
        // Well away from the edges so the kernel has full support.
        for pos in [40.3, 45.5, 50.75] {
            #expect(abs(Double(r.value(in: ramp, at: pos)) - pos) <= 0.05)
        }
    }

    // MARK: - Numeric sanity

    @Test func coefficientsAreFinite() {
        for ratio in [0.5, 1.0, 1.088, 2.0, 4.0] {
            let r = PolyphaseResampler(ratio: ratio)
            #expect(r.coefficients.allSatisfy { $0.isFinite })
        }
    }

    @Test func outputIsFiniteForArbitraryInput() {
        let r = PolyphaseResampler(ratio: 1.5)
        var rng = SystemRandomNumberGenerator()
        let signal = (0..<128).map { _ in Float.random(in: -1...1, using: &rng) }
        for i in 0..<200 {
            let pos = 30.0 + Double(i) * 0.37
            #expect(r.value(in: signal, at: pos).isFinite)
        }
    }

    // MARK: - Bessel I0 helper

    @Test func besselI0KnownValues() {
        #expect(abs(PolyphaseResampler.besselI0(0) - 1.0) <= 1e-9)
        #expect(abs(PolyphaseResampler.besselI0(1) - 1.2660658) <= 1e-4)
        #expect(abs(PolyphaseResampler.besselI0(2) - 2.2795853) <= 1e-4)
    }
}
