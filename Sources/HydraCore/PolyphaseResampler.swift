// Hydra Audio — GPL-3.0
// Polyphase windowed-sinc fractional resampler — the quality upgrade from the
// ring's old linear (2-tap) interpolation.
//
// The kernel is a Kaiser-windowed sinc, sampled into a polyphase table indexed
// by sub-sample phase. For a continuous read position `pos = whole + frac`, the
// output is a `taps`-point dot product of the input around `whole` with the
// coefficients of the phase nearest `frac`.
//
// Anti-aliasing on DOWNSAMPLING: when the producer runs faster than the consumer
// (ratio > 1, i.e. decimation), a fixed-cutoff sinc would alias. So the kernel's
// cutoff is lowered to `rolloff / ratio` and its support widened by `ratio`
// (more taps), placing the lowpass at the consumer's Nyquist. The ratio is fixed
// at init (producerRate / consumerRate); the servo's ±0.2% trim is negligible
// for the kernel, so the table is built once.
//
// This type is PURE and unit-tested. The real-time consumer (hydrad's
// ChannelRing) copies `coefficients` into its own buffer and runs the dot
// product inline; `value(in:at:)` is the reference implementation for tests.

import Foundation

public struct PolyphaseResampler: Sendable {

    /// Taps per phase (even). Number of input samples each output touches.
    public let taps: Int
    /// Number of sub-sample phases in the table.
    public let phases: Int
    /// Index of the "current" input sample within a tap row (taps/2 - 1).
    public let center: Int
    /// Flattened `phases × taps` coefficient table (row-major by phase),
    /// each phase normalised to unity DC gain.
    public let coefficients: [Float]

    /// - Parameters:
    ///   - ratio: producerRate / consumerRate. > 1 ⇒ decimation (anti-aliased).
    ///   - baseTaps: taps at unity ratio (even). Widened for decimation.
    ///   - phases: sub-sample table resolution.
    ///   - rolloff: passband edge as a fraction of Nyquist (leaves a transition band).
    ///   - kaiserBeta: Kaiser window β (stopband ⇄ transition trade-off).
    ///   - maxTaps: hard cap so an extreme ratio can't blow up the kernel.
    public init(ratio: Double,
                baseTaps: Int = 24,
                phases: Int = 512,
                rolloff: Double = 0.92,
                kaiserBeta: Double = 9.0,
                maxTaps: Int = 96) {
        let scale = max(1.0, ratio.isFinite && ratio > 0 ? ratio : 1.0)
        let cutoff = min(1.0, rolloff / scale)

        // Even tap count, widened for decimation, capped.
        var t = Int((Double(baseTaps) * scale).rounded(.up))
        if t % 2 != 0 { t += 1 }
        t = min(max(t, baseTaps), maxTaps)
        if t % 2 != 0 { t -= 1 }

        self.taps = t
        self.phases = max(1, phases)
        self.center = t / 2 - 1

        var table = [Float](repeating: 0, count: self.phases * t)
        let i0Beta = Self.besselI0(kaiserBeta)
        let denom = Double(t - 1)

        for p in 0..<self.phases {
            let frac = Double(p) / Double(self.phases)   // [0, 1)
            var sum = 0.0
            let rowBase = p * t
            for k in 0..<t {
                let off = Double(k - self.center)        // input offset from `whole`
                let x = off - frac                       // distance to the resample point
                let s = cutoff * Self.sinc(cutoff * x)
                // Kaiser window across the tap span.
                let r = denom > 0 ? (2.0 * Double(k) / denom - 1.0) : 0.0
                let w = Self.besselI0(kaiserBeta * (1.0 - r * r).squareRoot()) / i0Beta
                let c = s * w
                table[rowBase + k] = Float(c)
                sum += c
            }
            // Normalise this phase to unity DC gain.
            if sum != 0 {
                let inv = Float(1.0 / sum)
                for k in 0..<t { table[rowBase + k] *= inv }
            }
        }
        self.coefficients = table
    }

    /// The phase row nearest `frac` (in [0,1)), clamped into range.
    @inlinable
    public func phaseIndex(forFraction frac: Double) -> Int {
        var p = Int(frac * Double(phases))
        if p >= phases { p = phases - 1 }
        if p < 0 { p = 0 }
        return p
    }

    /// Coefficients for one phase as a slice.
    @inlinable
    public func coefficients(phase: Int) -> ArraySlice<Float> {
        let base = phase * taps
        return coefficients[base ..< base + taps]
    }

    /// Reference (non-circular) evaluation at a continuous position. Samples
    /// outside `input` are treated as silence. Used by the tests; the RT path
    /// runs the equivalent dot product over its circular buffer.
    public func value(in input: [Float], at pos: Double) -> Float {
        let whole = Int(floor(pos))
        let frac = pos - Double(whole)
        let p = phaseIndex(forFraction: frac)
        let rowBase = p * taps
        var acc: Float = 0
        for k in 0..<taps {
            let idx = whole + k - center
            if idx >= 0 && idx < input.count {
                acc += input[idx] * coefficients[rowBase + k]
            }
        }
        return acc
    }

    // MARK: - Math

    /// Normalised sinc: sin(πx)/(πx), with sinc(0) = 1.
    @usableFromInline
    static func sinc(_ x: Double) -> Double {
        if abs(x) < 1e-9 { return 1.0 }
        let px = Double.pi * x
        return sin(px) / px
    }

    /// Modified Bessel function of the first kind, order 0 (for the Kaiser window).
    @usableFromInline
    static func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        let halfX = x / 2.0
        var m = 1.0
        // Converges quickly; 30 terms is ample for β up to ~20.
        while m < 30 {
            term *= (halfX / m) * (halfX / m)
            sum += term
            if term < sum * 1e-12 { break }
            m += 1
        }
        return sum
    }
}
