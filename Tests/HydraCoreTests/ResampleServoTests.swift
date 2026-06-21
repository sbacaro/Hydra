// Hydra Audio — GPL-3.0
// The async-resampler servo: nominal-step from clock rates, fill-level drift
// correction (clamped), and underrun detection. Backs ChannelRing's clock-sync.

import Testing
import Foundation
@testable import HydraCore

struct ResampleServoTests {

    // MARK: - Nominal step

    @Test func nominalStepFromMatchingRatesIsUnity() {
        #expect(ResampleServo.nominalStep(producerRate: 48_000, consumerRate: 48_000) == 1.0)
    }

    @Test func nominalStepReflectsRateRatio() {
        #expect(ResampleServo.nominalStep(producerRate: 96_000, consumerRate: 48_000) == 2.0)
        #expect(abs(ResampleServo.nominalStep(producerRate: 44_100, consumerRate: 48_000) - 0.91875) <= 1e-9)
    }

    @Test func nominalStepFallsBackToUnityForBadRates() {
        #expect(ResampleServo.nominalStep(producerRate: 0, consumerRate: 48_000) == 1.0)
        #expect(ResampleServo.nominalStep(producerRate: 48_000, consumerRate: 0) == 1.0)
        #expect(ResampleServo.nominalStep(producerRate: -1, consumerRate: -1) == 1.0)
    }

    // MARK: - Servo step

    private let target = 4096.0

    @Test func stepIsNominalAtTargetFill() {
        #expect(ResampleServo.step(fill: target, target: target, nominalStep: 1.0) == 1.0)
    }

    @Test func overfilledReadsFasterUnderfilledReadsSlower() {
        let fast = ResampleServo.step(fill: target * 1.1, target: target, nominalStep: 1.0)
        let slow = ResampleServo.step(fill: target * 0.9, target: target, nominalStep: 1.0)
        #expect(fast > 1.0)
        #expect(slow < 1.0)
    }

    @Test func smallDeviationIsProportionalAndUnclamped() {
        // deviation 0.1 → correction 0.1 * servoGain (0.01) = 0.001 (< maxCorrection).
        let step = ResampleServo.step(fill: target * 1.1, target: target, nominalStep: 1.0)
        #expect(abs(step - 1.001) <= 1e-9)
    }

    @Test func largeDeviationClampsToMaxCorrection() {
        let high = ResampleServo.step(fill: target * 5, target: target, nominalStep: 1.0)
        let low  = ResampleServo.step(fill: 0, target: target, nominalStep: 1.0)
        #expect(abs(high - (1.0 + ResampleServo.maxCorrection)) <= 1e-9)
        #expect(abs(low - (1.0 - ResampleServo.maxCorrection)) <= 1e-9)
    }

    @Test func correctionScalesWithNominalStep() {
        // At 2× nominal, the same +maxCorrection scales the larger step.
        let step = ResampleServo.step(fill: target * 5, target: target, nominalStep: 2.0)
        #expect(abs(step - 2.0 * (1 + ResampleServo.maxCorrection)) <= 1e-9)
    }

    // MARK: - Underrun

    @Test func underrunWhenFillBelowDemand() {
        // step 1.0, 512 frames → needs fill ≥ 514.
        #expect(ResampleServo.isUnderrun(fill: 400, step: 1.0, frames: 512))
        #expect(ResampleServo.isUnderrun(fill: 513, step: 1.0, frames: 512))
    }

    @Test func noUnderrunWhenFillSufficient() {
        #expect(!ResampleServo.isUnderrun(fill: 514, step: 1.0, frames: 512))
        #expect(!ResampleServo.isUnderrun(fill: 9000, step: 1.0, frames: 512))
    }

    @Test func underrunAccountsForStepRate() {
        // At 2× step, 256 frames consume ~512 source frames (+2 guard).
        #expect(ResampleServo.isUnderrun(fill: 500, step: 2.0, frames: 256))
        #expect(!ResampleServo.isUnderrun(fill: 520, step: 2.0, frames: 256))
    }

    @Test func lookaheadReservesKernelHeadroom() {
        // step 1.0, 512 frames → base need 514; a 24-tap kernel needs 24 more.
        #expect(ResampleServo.isUnderrun(fill: 520, step: 1.0, frames: 512, lookahead: 24))
        #expect(!ResampleServo.isUnderrun(fill: 540, step: 1.0, frames: 512, lookahead: 24))
    }
}
