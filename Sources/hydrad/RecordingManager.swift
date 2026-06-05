// Hydra Audio — GPL-3.0
// Disk recording — captures a virtual interface's mixed outputs to WAV
// (float32, engine rate), Audio Hijack style: whatever is routed to the
// interface's Out channels lands in the file.
//
// Engine side: a PoolTxTap (same post-mix slice copy as NDI TX) feeds a
// writer thread that drains the ring in ~50 ms chunks into an AVAudioFile.
// Files go to ~/Music/Hydra Recordings/.

import Foundation
import AVFoundation
import HydraCore

final class RecordingManager {

    private final class Recording {
        let info: RecordingInfo
        let tap: PoolTxTap
        private let file: AVAudioFile
        private let buffer: AVAudioPCMBuffer
        private let chunk: Int
        private var thread: Thread?
        private var running = true

        init?(interface: VirtualInterfaceInfo, rate: Double, directory: URL) {
            let stamp = Self.timestamp()
            let fileName = "\(interface.name) \(stamp).wav"
            let url = directory.appendingPathComponent(fileName)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: interface.outChannels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            // Chunk MUST stay below half the ring (the servo's fill target is
            // capacity/2 — a larger read would never find enough frames and
            // the file would record silence). ~50 ms is comfortably under it.
            let chunk = max(256, Int(rate / 20))
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                             channels: AVAudioChannelCount(interface.outChannels),
                                             interleaved: true),
                  let file = try? AVAudioFile(forWriting: url, settings: settings,
                                              commonFormat: .pcmFormatFloat32, interleaved: true),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(chunk)) else {
                log("Recording \"\(interface.name)\": could not create \(url.path)")
                return nil
            }
            self.file = file
            self.buffer = buffer
            self.chunk = chunk
            self.tap = PoolTxTap(base: interface.outBase, channels: interface.outChannels, rate: rate)
            self.info = RecordingInfo(interfaceID: interface.id,
                                      interfaceName: interface.name,
                                      fileName: fileName,
                                      path: url.path,
                                      startedAt: Date())

            let thread = Thread { [weak self] in self?.writeLoop() }
            thread.name = "hydra.recording"
            thread.qualityOfService = .userInitiated
            self.thread = thread
            thread.start()
        }

        func stop() {
            running = false
            thread = nil
        }

        private func writeLoop() {
            guard let data = buffer.floatChannelData?[0] else { return }
            // Absolute-clock pacing: consume exactly real-time on average so
            // the ring's fill level stays at the servo target (sleeping a
            // fraction of the interval would over-consume and interleave
            // silence into the file).
            let interval = Double(chunk) / file.fileFormat.sampleRate
            var next = Date()
            while running {
                tap.ring.readResampled(into: data, frames: chunk)
                buffer.frameLength = AVAudioFrameCount(chunk)
                do {
                    try file.write(from: buffer)
                } catch {
                    log("Recording \"\(info.interfaceName)\": write failed (\(error)) — stopping")
                    EventCenter.shared.emit(.error, "Recording of \(info.interfaceName) failed (disk?).")
                    running = false
                }
                next.addTimeInterval(interval)
                let delay = next.timeIntervalSinceNow
                if delay > 0 {
                    Thread.sleep(forTimeInterval: delay)
                } else if delay < -0.25 {
                    next = Date() // fell badly behind (slow disk): resync
                }
            }
        }

        private static func timestamp() -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            return formatter.string(from: Date())
        }
    }

    private let store: MatrixStore
    private let queue = DispatchQueue(label: "hydra.recordings")
    private var active: [UUID: Recording] = [:]
    var onChange: ((RecordingsPayload) -> Void)?

    private static let directory: URL = {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        let dir = music.appendingPathComponent("Hydra Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init(store: MatrixStore) {
        self.store = store
    }

    func start(interface: VirtualInterfaceInfo) {
        queue.sync {
            guard active[interface.id] == nil else { return }
            guard interface.outChannels > 0 else {
                EventCenter.shared.emit(.warning, "\(interface.name) has no Out channels — nothing to record.")
                return
            }
            let rate = BackplaneProbe.backplaneDeviceID()
                .map(BackplaneProbe.nominalSampleRate) ?? Hydra.defaultSampleRate
            guard let recording = Recording(interface: interface, rate: rate,
                                            directory: Self.directory) else {
                EventCenter.shared.emit(.error, "Could not start recording \(interface.name).")
                return
            }
            active[interface.id] = recording
            store.setRecordTaps(active.values.map(\.tap))
            EventCenter.shared.emit(.info, "Recording \(interface.name) → \(recording.info.fileName)")
            broadcastLocked()
        }
    }

    func stop(interfaceID: UUID) {
        queue.sync {
            guard let recording = active.removeValue(forKey: interfaceID) else { return }
            recording.stop()
            store.setRecordTaps(active.values.map(\.tap))
            EventCenter.shared.emit(.info, "Saved \(recording.info.fileName) (Music → Hydra Recordings)")
            broadcastLocked()
        }
    }

    /// Stops a recording when its interface is deleted.
    func interfacesChanged(_ interfaces: [VirtualInterfaceInfo]) {
        let ids = Set(interfaces.map(\.id))
        queue.sync {
            let orphans = active.keys.filter { !ids.contains($0) }
            guard !orphans.isEmpty else { return }
            for id in orphans {
                active[id]?.stop()
                active.removeValue(forKey: id)
            }
            store.setRecordTaps(active.values.map(\.tap))
            broadcastLocked()
        }
    }

    func payload() -> RecordingsPayload {
        queue.sync { RecordingsPayload(active: active.values.map(\.info)
            .sorted { $0.startedAt < $1.startedAt }) }
    }

    private func broadcastLocked() {
        onChange?(RecordingsPayload(active: active.values.map(\.info)
            .sorted { $0.startedAt < $1.startedAt }))
    }
}
