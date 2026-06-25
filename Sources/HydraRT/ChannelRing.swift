// Hydra Audio — GPL-3.0
// SPSC ring buffer with consumer-side asynchronous resampling (the "ASRC"
// of Section 5.4). Each physical device runs on its own clock; the ring
// absorbs buffer-size mismatch and the servo absorbs clock drift:
//
// - One producer thread writes interleaved frames at its own rate.
// - One consumer thread pulls frames resampled by a fractional read position.
// - The step is producerRate/consumerRate, trimmed by a proportional servo on
//   the ring fill level (target: half full, correction clamped to ±0.2%) so
//   drift never accumulates into overruns/underruns.
// - Interpolation: a polyphase Kaiser-windowed sinc kernel (HydraCore's
//   PolyphaseResampler), built once for the fixed clock ratio. It anti-aliases
//   on decimation (cutoff lowered for ratio > 1) — a real quality step up from
//   the former 2-tap linear interpolation.
//
// Real-time safety: no allocation, no locks; the write counter is the only
// shared state (acquire/release atomic).
//
// Lives in the HydraRT library (not the hydrad executable) so the SPSC ring +
// resampler can be unit-tested directly (see HydraRTTests). Its public surface
// is what the daemon's audio path needs.

import Foundation
import CoreAudio
import Synchronization
import HydraCore

public final class ChannelRing {

    public let channels: Int
    private let capacity: Int          // frames, power of two
    private let mask: Int64
    private let data: UnsafeMutablePointer<Float>
    private let written = Atomic<Int64>(0)
    private let nominalStep: Double    // producerRate / consumerRate
    /// Producer and consumer run at the SAME nominal rate (e.g. every virtual
    /// device + the hub at 48 kHz). The servo only nudges by sub-sample drift, so
    /// we skip the polyphase sinc and use cheap linear interpolation — ~10× less
    /// CPU per channel, transparent at unity. Falls back to sinc for real SRC.
    private let unity: Bool

    // Polyphase resampler kernel, built once for the fixed clock ratio. Stored as
    // a raw buffer so the RT loop indexes it without ARC/bounds overhead.
    private let coeff: UnsafeMutablePointer<Float>
    private let taps: Int
    private let center: Int
    private let phases: Int

    // Consumer-owned state (touched only by the consumer thread).
    private var readPos: Double = 0
    private var primed = false

    public init(channels: Int, producerRate: Double, consumerRate: Double,
                capacityFrames: Int = Hydra.deviceRingFrames) {
        precondition(channels > 0)
        precondition(capacityFrames > 0 && (capacityFrames & (capacityFrames - 1)) == 0,
                     "capacity must be a power of two")
        self.channels = channels
        self.capacity = capacityFrames
        self.mask = Int64(capacityFrames - 1)
        self.nominalStep = ResampleServo.nominalStep(producerRate: producerRate,
                                                     consumerRate: consumerRate)
        self.unity = abs(self.nominalStep - 1.0) < 1e-9
        self.data = .allocate(capacity: capacityFrames * channels)
        self.data.initialize(repeating: 0, count: capacityFrames * channels)

        // Build the polyphase kernel once for this fixed ratio (the servo's
        // ±0.2% trim is negligible for the kernel) and copy it into a raw buffer.
        let resampler = PolyphaseResampler(ratio: nominalStep)
        self.taps = resampler.taps
        self.center = resampler.center
        self.phases = resampler.phases
        self.coeff = .allocate(capacity: resampler.coefficients.count)
        resampler.coefficients.withUnsafeBufferPointer { src in
            coeff.initialize(from: src.baseAddress!, count: src.count)
        }
    }

    deinit {
        data.deallocate()
        coeff.deallocate()
    }

    // MARK: - Producer side

    /// Write `frames` interleaved frames. RT-safe. Writes larger than the
    /// ring are clamped to the most recent `capacity` frames.
    public func write(from source: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        var source = source
        var frames = frames
        if frames > capacity {
            source += (frames - capacity) * channels
            frames = capacity
        }
        let w = written.load(ordering: .relaxed) // producer owns the counter
        let start = Int(w & mask)
        let firstSpan = min(frames, capacity - start)
        memcpy(data + start * channels, source,
               firstSpan * channels * MemoryLayout<Float>.size)
        if frames > firstSpan {
            memcpy(data, source + firstSpan * channels,
                   (frames - firstSpan) * channels * MemoryLayout<Float>.size)
        }
        written.store(w &+ Int64(frames), ordering: .releasing)
    }

    // MARK: - Consumer side

    /// Pull `frames` frames resampled to the consumer clock. Writes silence
    /// on underrun (and while priming). RT-safe.
    public func readResampled(into destination: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let w = Double(written.load(ordering: .acquiring))
        let target = Double(capacity) / 2

        if !primed {
            guard w >= target else {
                silence(destination, frames: frames)
                return
            }
            readPos = w - target
            primed = true
        }

        var fill = w - readPos
        // Writer lapped us (long stall): jump back to target. One click, then clean.
        if fill > Double(capacity) - 64 {
            readPos = w - target
            fill = target
        }

        // Fill-level servo around the nominal ratio (pure math in HydraCore).
        let step = ResampleServo.step(fill: fill, target: target, nominalStep: nominalStep)

        // Underrun: not enough ahead of us — emit silence, keep position. The
        // kernel reads up to `taps` frames around the read point, so reserve them.
        guard !ResampleServo.isUnderrun(fill: fill, step: step, frames: frames, lookahead: taps) else {
            silence(destination, frames: frames)
            return
        }

        var pos = readPos
        let chans = channels

        // Unity fast-path: same in/out rate → linear interpolation (2 taps). At a
        // true integer position this is an exact copy; with sub-sample servo drift
        // it's a transparent lerp. ~10× cheaper than the polyphase sinc per channel.
        if unity {
            var frame = 0
            while frame < frames {
                let whole = Int64(pos)
                let frac = Float(pos - Double(whole))
                let i0 = Int(whole & mask) * chans
                let i1 = Int((whole &+ 1) & mask) * chans
                let out = destination + frame * chans
                var ch = 0
                while ch < chans {
                    let a = data[i0 + ch]
                    out[ch] = a + (data[i1 + ch] - a) * frac
                    ch += 1
                }
                pos += step
                frame += 1
            }
            readPos = pos
            return
        }

        let nTaps = taps
        let ctr = Int64(center)
        let nPhases = Double(phases)
        // Hand-rolled while-loops (not `for … in 0..<n`): on the realtime audio
        // thread, Range/IndexingIterator goes through Collection protocol witnesses
        // + generic-metadata instantiation that an unoptimized (Debug) build does
        // NOT specialize away. Manual Int indices over the unchecked pointers are
        // fast in both Debug and Release.
        var frame = 0
        while frame < frames {
            let whole = Int64(pos)
            var p = Int((pos - Double(whole)) * nPhases)
            if p >= phases { p = phases - 1 }
            let krow = coeff + p * nTaps
            let baseFrame = whole &- ctr          // first input frame for the kernel
            let out = destination + frame * chans
            var ch = 0
            while ch < chans {
                var acc: Float = 0
                var k = 0
                while k < nTaps {
                    let idx = Int((baseFrame &+ Int64(k)) & mask) * chans + ch
                    acc += data[idx] * krow[k]
                    k += 1
                }
                out[ch] = acc
                ch += 1
            }
            pos += step
            frame += 1
        }
        readPos = pos
    }

    private func silence(_ destination: UnsafeMutablePointer<Float>, frames: Int) {
        memset(destination, 0, frames * channels * MemoryLayout<Float>.size)
    }
}

// MARK: - AudioBufferList helpers (devices may expose several streams)

public enum ABLUtil {

    /// Frame count of the list (from its first buffer).
    public static func frameCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        guard let first = list.first, first.mNumberChannels > 0 else { return 0 }
        return Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
    }

    /// Total channels across all buffers.
    public static func channelCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Interleave all buffers into `scratch` (frame-major, `totalChannels` wide).
    /// Returns the frame count actually copied.
    public static func flatten(_ list: UnsafeMutableAudioBufferListPointer,
                               into scratch: UnsafeMutablePointer<Float>,
                               totalChannels: Int,
                               maxFrames: Int) -> Int {
        let frames = min(frameCount(list), maxFrames)
        guard frames > 0, totalChannels > 0 else { return 0 }
        var channelOffset = 0
        for buffer in list {
            let bufChans = Int(buffer.mNumberChannels)
            guard bufChans > 0, let raw = buffer.mData else { continue }
            let src = raw.assumingMemoryBound(to: Float.self)
            var frame = 0
            while frame < frames {           // while-loops: see readResampled note
                let dstBase = frame * totalChannels + channelOffset
                let srcBase = frame * bufChans
                var ch = 0
                while ch < bufChans {
                    scratch[dstBase + ch] = src[srcBase + ch]
                    ch += 1
                }
                frame += 1
            }
            channelOffset += bufChans
        }
        return frames
    }

    /// Spread interleaved `scratch` (frame-major, `totalChannels` wide) back
    /// into the list's buffers.
    public static func distribute(_ scratch: UnsafePointer<Float>,
                                  frames: Int,
                                  totalChannels: Int,
                                  into list: UnsafeMutableAudioBufferListPointer) {
        guard frames > 0, totalChannels > 0 else { return }
        var channelOffset = 0
        for buffer in list {
            let bufChans = Int(buffer.mNumberChannels)
            guard bufChans > 0, let raw = buffer.mData else { continue }
            let dst = raw.assumingMemoryBound(to: Float.self)
            let bufFrames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * bufChans))
            var frame = 0
            while frame < bufFrames {        // while-loops: see readResampled note
                let srcBase = frame * totalChannels + channelOffset
                let dstBase = frame * bufChans
                var ch = 0
                while ch < bufChans {
                    dst[dstBase + ch] = scratch[srcBase + ch]
                    ch += 1
                }
                frame += 1
            }
            channelOffset += bufChans
        }
    }
}
