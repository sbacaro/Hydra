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
// - Linear interpolation: honest v1 quality — fine at 48 kHz for routing;
//   a polyphase resampler can replace it later without changing this API.
//
// Real-time safety: no allocation, no locks; the write counter is the only
// shared state (acquire/release atomic).

import Foundation
import CoreAudio
import Synchronization
import HydraCore

final class ChannelRing {

    let channels: Int
    private let capacity: Int          // frames, power of two
    private let mask: Int64
    private let data: UnsafeMutablePointer<Float>
    private let written = Atomic<Int64>(0)
    private let nominalStep: Double    // producerRate / consumerRate

    // Consumer-owned state (touched only by the consumer thread).
    private var readPos: Double = 0
    private var primed = false

    /// Maximum servo correction (±0.2% ≈ ±2000 ppm — far above any real
    /// crystal drift, small enough to be inaudible).
    private static let maxCorrection = 0.002
    /// Proportional servo gain.
    private static let servoGain = 0.01

    init(channels: Int, producerRate: Double, consumerRate: Double,
         capacityFrames: Int = Hydra.deviceRingFrames) {
        precondition(channels > 0)
        precondition(capacityFrames > 0 && (capacityFrames & (capacityFrames - 1)) == 0,
                     "capacity must be a power of two")
        self.channels = channels
        self.capacity = capacityFrames
        self.mask = Int64(capacityFrames - 1)
        self.nominalStep = (producerRate > 0 && consumerRate > 0)
            ? producerRate / consumerRate : 1.0
        self.data = .allocate(capacity: capacityFrames * channels)
        self.data.initialize(repeating: 0, count: capacityFrames * channels)
    }

    deinit {
        data.deallocate()
    }

    // MARK: - Producer side

    /// Write `frames` interleaved frames. RT-safe. Writes larger than the
    /// ring are clamped to the most recent `capacity` frames.
    func write(from source: UnsafePointer<Float>, frames: Int) {
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
    func readResampled(into destination: UnsafeMutablePointer<Float>, frames: Int) {
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

        // Fill-level servo around the nominal ratio.
        let deviation = (fill - target) / target
        let correction = max(-Self.maxCorrection, min(Self.maxCorrection,
                                                      deviation * Self.servoGain))
        let step = nominalStep * (1 + correction)

        // Underrun: not enough ahead of us — emit silence, keep position.
        guard fill >= step * Double(frames) + 2 else {
            silence(destination, frames: frames)
            return
        }

        var pos = readPos
        let chans = channels
        // Hand-rolled while-loops (not `for … in 0..<n`): on the realtime audio
        // thread, Range/IndexingIterator goes through Collection protocol
        // witnesses + generic-metadata instantiation that an unoptimized (Debug)
        // build does NOT specialize away — profiling showed ~60% of the audio
        // thread here. Manual Int indices over the unchecked pointer are fast in
        // both Debug and Release.
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
                let b = data[i1 + ch]
                out[ch] = a + frac * (b - a)
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

enum ABLUtil {

    /// Frame count of the list (from its first buffer).
    static func frameCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        guard let first = list.first, first.mNumberChannels > 0 else { return 0 }
        return Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
    }

    /// Total channels across all buffers.
    static func channelCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Interleave all buffers into `scratch` (frame-major, `totalChannels` wide).
    /// Returns the frame count actually copied.
    static func flatten(_ list: UnsafeMutableAudioBufferListPointer,
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
    static func distribute(_ scratch: UnsafePointer<Float>,
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
