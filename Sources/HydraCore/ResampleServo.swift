// Hydra Audio — GPL-3.0
// The asynchronous-resampler servo math, extracted from hydrad's ChannelRing
// so the drift-correction logic is unit-testable without a real-time audio
// thread. Only the (cheap, per-callback) servo computation lives here; the
// per-sample interpolation stays inline in ChannelRing for RT performance.

import Foundation

public enum ResampleServo {

    /// Maximum servo correction (±0.2% ≈ ±2000 ppm — far above any real
    /// crystal drift, small enough to be inaudible).
    public static let maxCorrection = 0.002
    /// Proportional servo gain on the fill-level deviation.
    public static let servoGain = 0.01

    /// Nominal read step = producerRate / consumerRate. Falls back to 1.0 when
    /// either rate is non-positive (unknown clock).
    public static func nominalStep(producerRate: Double, consumerRate: Double) -> Double {
        (producerRate > 0 && consumerRate > 0) ? producerRate / consumerRate : 1.0
    }

    /// The fill-level servo: nudges the read step toward holding the ring at
    /// `target` frames, clamped to ±`maxCorrection`.
    public static func step(fill: Double, target: Double, nominalStep: Double) -> Double {
        let deviation = (fill - target) / target
        let correction = max(-maxCorrection, min(maxCorrection, deviation * servoGain))
        return nominalStep * (1 + correction)
    }

    /// True when there are not enough buffered frames to satisfy `frames`
    /// output frames at the current `step` (consumer must emit silence).
    ///
    /// `lookahead` reserves extra frames for an interpolation kernel that reads
    /// ahead of the read position (e.g. the polyphase resampler's half-width);
    /// pass 0 for plain linear interpolation.
    public static func isUnderrun(fill: Double, step: Double, frames: Int, lookahead: Int = 0) -> Bool {
        !(fill >= step * Double(frames) + Double(lookahead) + 2)
    }
}
