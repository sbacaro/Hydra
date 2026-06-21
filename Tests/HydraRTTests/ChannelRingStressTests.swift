// Hydra Audio — GPL-3.0
// Real-time ring stress tests against the HydraRT library — the SPSC ring is
// exercised for real, most valuably under ThreadSanitizer (atomic ordering
// between the producer and consumer threads) and AddressSanitizer (the polyphase
// resampler's circular-buffer indexing). Run via the HydraRTTests scheme.

import Testing
import Foundation
import HydraRT

/// Thread-safe result flags shared by the producer/consumer closures. A class so
/// it's shared by reference across the `@Sendable` closures — unlike a
/// non-copyable `Atomic`, which Swift Testing's `#expect` can't capture.
private final class StressResult: @unchecked Sendable {
    private let lock = NSLock()
    private var finiteFlag = true
    private var signalFlag = false
    func noteNonFinite() { lock.withLock { finiteFlag = false } }
    func noteSignal()    { lock.withLock { signalFlag = true } }
    var finite: Bool { lock.withLock { finiteFlag } }
    var signal: Bool { lock.withLock { signalFlag } }
}

struct ChannelRingStressTests {

    /// Producer and consumer hammer the ring from two threads. Correct SPSC
    /// behaviour means TSan sees no race and ASan sees no bad access; output must
    /// stay finite and signal must flow once primed.
    @Test func concurrentProducerConsumerIsRaceFree() {
        let channels = 2
        // `nonisolated(unsafe)`: ChannelRing is deliberately SPSC — exactly one
        // producer and one consumer thread. The sanitizers verify that contract.
        nonisolated(unsafe) let ring = ChannelRing(channels: channels,
                                                   producerRate: 48_000,
                                                   consumerRate: 44_100) // decimation
        let result = StressResult()

        let blocks = 2_000
        let writeFrames = 256
        let readFrames = 235          // ≈ 256 × 44100/48000
        let group = DispatchGroup()

        // Producer: a 440 Hz sine, written in blocks.
        DispatchQueue.global().async(group: group) {
            var buf = [Float](repeating: 0, count: writeFrames * channels)
            var phase: Float = 0
            let inc: Float = 2 * .pi * 440 / 48_000
            for _ in 0..<blocks {
                for f in 0..<writeFrames {
                    let s = sin(phase)
                    phase += inc
                    if phase > 2 * .pi { phase -= 2 * .pi }
                    for c in 0..<channels { buf[f * channels + c] = s * 0.5 }
                }
                buf.withUnsafeBufferPointer {
                    ring.write(from: $0.baseAddress!, frames: writeFrames)
                }
            }
        }

        // Consumer: pulls resampled blocks concurrently.
        DispatchQueue.global().async(group: group) {
            var out = [Float](repeating: 0, count: readFrames * channels)
            for _ in 0..<(blocks + 64) {
                out.withUnsafeMutableBufferPointer {
                    ring.readResampled(into: $0.baseAddress!, frames: readFrames)
                }
                for v in out {
                    if !v.isFinite { result.noteNonFinite() }
                    if v != 0 { result.noteSignal() }
                }
            }
        }

        let outcome = group.wait(timeout: .now() + 120)
        #expect(outcome == .success)
        #expect(result.finite)
        #expect(result.signal)
    }

    /// Single-threaded sanity on the real RT path (not the pure reference): a
    /// sine resampled 48k → 44.1k should come out finite and at roughly the same
    /// level (the polyphase kernel has unity gain). Catches integration bugs in
    /// the circular indexing that the pure resampler tests can't see.
    @Test func resampledOutputPreservesLevel() {
        let channels = 1
        let ring = ChannelRing(channels: channels, producerRate: 48_000, consumerRate: 44_100)

        // Prime well past the half-full target before reading.
        let writeFrames = 512
        var inBuf = [Float](repeating: 0, count: writeFrames)
        var phase: Float = 0
        let inc: Float = 2 * .pi * 1_000 / 48_000   // 1 kHz, comfortably in-band
        func fillBlock() {
            for f in 0..<writeFrames {
                inBuf[f] = sin(phase) * 0.5
                phase += inc
                if phase > 2 * .pi { phase -= 2 * .pi }
            }
        }
        for _ in 0..<16 { // 8192 frames written → past the 4096 target
            fillBlock()
            inBuf.withUnsafeBufferPointer { ring.write(from: $0.baseAddress!, frames: writeFrames) }
        }

        // Read a few blocks; measure the last one (steady state).
        let readFrames = 470
        var out = [Float](repeating: 0, count: readFrames)
        for _ in 0..<4 {
            // keep the producer ahead so we don't underrun
            fillBlock()
            inBuf.withUnsafeBufferPointer { ring.write(from: $0.baseAddress!, frames: writeFrames) }
            out.withUnsafeMutableBufferPointer { ring.readResampled(into: $0.baseAddress!, frames: readFrames) }
        }

        #expect(out.allSatisfy { $0.isFinite })
        let rms = (out.reduce(0) { $0 + Double($1 * $1) } / Double(readFrames)).squareRoot()
        // Input sine amplitude 0.5 → RMS ≈ 0.354. Allow generous slack for
        // resampling + windowing.
        #expect(rms > 0.30)
        #expect(rms < 0.40)
    }
}
