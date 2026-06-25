// Hydra Audio — GPL-3.0
// Daemon side of out-of-process VST hosting (crash isolation).
//
// Owns a shared-memory region and a `hydra-plugin-host` child process, and
// exposes an RT-safe `process(input:output:frames:)` the engine calls in place
// of the in-process `hydra_vst_process`. If the child dies (a plugin crashed),
// audio passes through DRY and the child is relaunched — the daemon never
// crashes and never blocks the audio thread.
//
// Transport + ordering: see HydraPluginHostABI/include/hydra_plugin_shm.h.
// Latency cost: ~1 audio block on chains that are actually hosted remotely.
//
// Increment 1: audio path + crash isolation + relaunch with backoff. Parameter
// sync and editor GUI hosting come next (the GUI will move into this child so
// the plugin instance and its window live in the same crashable process).

import Foundation
import Darwin
import HydraCore
import HydraPluginHostABI

final class RemotePluginHost: @unchecked Sendable {

    let channels: Int
    let maxFrames: Int
    private let sampleRate: Double
    private let plugins: [String]            // "path#classIndex"
    private let titles: [String]             // editor window titles (per plugin)
    private let hostURL: URL
    private let shmName: String

    private var header: UnsafeMutablePointer<hydra_plugin_shm>?
    private var mapping: UnsafeMutableRawPointer?
    private var mappingBytes: Int = 0

    /// Atomic liveness flag (1 = child believed alive), read on the audio thread.
    private let aliveFlag = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)

    // Audio-thread-only state (no sync needed — single RT caller).
    private var lastSubmittedInput: UInt64 = 0
    private var lastConsumedOutput: UInt64 = 0

    // Control-thread state.
    private let control = DispatchQueue(label: "hydra.pluginhost")
    private var process: Process?
    private var shuttingDown = false
    private var lastLaunch = Date.distantPast
    /// Consecutive short-lived crashes; after `maxRelaunchAttempts` we give up
    /// and leave the chain DRY (the plugin is effectively bypassed) instead of
    /// relaunching forever — a plugin that reliably crashes a few seconds in.
    private var consecutiveCrashes = 0
    private let maxRelaunchAttempts = 5
    private var watchdog: DispatchSourceTimer?
    private var lastHeartbeat: UInt64 = 0
    private var heartbeatStallTicks = 0

    init?(channels: Int, maxFrames: Int, sampleRate: Double,
          plugins: [String], titles: [String], hostURL: URL) {
        self.channels = channels
        self.maxFrames = maxFrames
        self.sampleRate = sampleRate
        self.plugins = plugins
        self.titles = titles
        self.hostURL = hostURL
        // POSIX shm names are short (≤31). Keep it compact + unique per host; a
        // random suffix avoids global mutable counter state (mapSharedRegion
        // unlinks any stale region first, and O_EXCL would catch a collision).
        self.shmName = "/hyd\(getpid() % 100000)-\(UInt16.random(in: 0...0xFFFF))"
        aliveFlag.initialize(to: 0)

        guard mapSharedRegion() else { return nil }
        launch()
        startWatchdog()
    }

    deinit {
        shutdown()
        aliveFlag.deallocate()
    }

    // MARK: - RT audio path (called on the engine IOProc thread)

    /// Run `frames` of interleaved audio through the remote chain. RT-safe:
    /// only memcpy + acquire/release atomics, never blocks. Falls back to a dry
    /// passthrough whenever the host has no fresh output (priming, slow, dead).
    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frames: Int) {
        let n = min(frames, maxFrames)
        let bytes = n * channels * MemoryLayout<Float>.size
        guard let header, hydra_shm_load_u32(aliveFlag) == 1 else {
            memcpy(output, input, bytes)
            return
        }

        // 1. Adopt the most recent output the host has finished, else pass dry.
        let outSeq = hydra_shm_load_u64(&header.pointee.outputSeq)
        if outSeq != 0, outSeq != lastConsumedOutput {
            let outBuf = hydra_plugin_shm_output(header, outSeq)
            memcpy(output, outBuf, bytes)
            lastConsumedOutput = outSeq
        } else {
            memcpy(output, input, bytes)   // dry while the pipeline primes/stalls
        }

        // 2. Submit this block for the host to process into slot (seq % SLOTS).
        let seq = lastSubmittedInput &+ 1
        let inBuf = hydra_plugin_shm_input(header, seq)
        memcpy(inBuf, input, bytes)
        header.pointee.frames = Int32(n)
        hydra_shm_store_u64(&header.pointee.inputSeq, seq)   // release: publishes inBuf
        lastSubmittedInput = seq
    }

    var isHostReady: Bool {
        guard let header else { return false }
        return hydra_shm_load_u32(&header.pointee.hostReady) == 1
    }

    // MARK: - Control commands (daemon → host)
    //
    // Single producer: these are driven by the main-actor control plane, so the
    // command ring stays SPSC against the host's main-thread drain.

    /// Ask the host to open plugin `index`'s editor window (in the host process).
    func openEditor(index: Int) {
        sendCommand(UInt32(HYDRA_CMD_OPEN_EDITOR), instance: index)
    }

    /// Set a normalised parameter (0..1) on plugin `index` of the remote chain.
    func setParameter(index: Int, paramId: UInt32, value: Float) {
        sendCommand(UInt32(HYDRA_CMD_SET_PARAM), instance: index, paramId: paramId, value: value)
    }

    private func sendCommand(_ type: UInt32, instance: Int, paramId: UInt32 = 0, value: Float = 0) {
        guard let header else { return }
        let seq = hydra_shm_load_u64(&header.pointee.cmdWriteSeq) &+ 1
        let slot = hydra_plugin_shm_cmd(header, seq)
        slot.pointee.type = type
        slot.pointee.instance = Int32(instance)
        slot.pointee.paramId = paramId
        slot.pointee.value = value
        hydra_shm_store_u64(&header.pointee.cmdWriteSeq, seq)   // release: publishes the slot
    }

    // MARK: - Shared memory

    private func mapSharedRegion() -> Bool {
        let total = Int(hydra_plugin_shm_bytes(Int32(channels), Int32(maxFrames)))
        let fd = hydra_shm_create(shmName, hydra_plugin_shm_bytes(Int32(channels), Int32(maxFrames)))
        guard fd >= 0 else {
            log("PluginHost: hydra_shm_create(\(shmName)) failed (errno \(errno))")
            return false
        }
        defer { close(fd) }
        guard let raw = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              raw != MAP_FAILED else {
            log("PluginHost: mmap failed (errno \(errno))")
            shm_unlink(shmName)
            return false
        }
        memset(raw, 0, total)
        let h = raw.bindMemory(to: hydra_plugin_shm.self, capacity: 1)
        h.pointee.magic = HYDRA_PLUGIN_SHM_MAGIC
        h.pointee.abiVersion = HYDRA_PLUGIN_SHM_ABI
        h.pointee.channels = Int32(channels)
        h.pointee.maxFrames = Int32(maxFrames)
        mapping = raw
        mappingBytes = total
        header = h
        return true
    }

    // MARK: - Child lifecycle

    private func launch() {
        control.async { [self] in
            guard !shuttingDown else { return }
            let proc = Process()
            proc.executableURL = hostURL
            var args = ["--shm", shmName,
                        "--channels", "\(channels)",
                        "--max-frames", "\(maxFrames)",
                        "--rate", "\(Int(sampleRate))"]
            for p in plugins { args += ["--plugin", p] }
            for t in titles { args += ["--title", t] }
            proc.arguments = args
            // Crash fast: don't let Swift's interactive backtrace handler hang
            // the child (and freeze the audio thread) on a crash.
            var env = ProcessInfo.processInfo.environment
            env["SWIFT_BACKTRACE"] = "enable=no"
            proc.environment = env
            proc.terminationHandler = { [weak self] p in
                self?.handleExit(status: p.terminationStatus)
            }
            do {
                try proc.run()
                process = proc
                lastLaunch = Date()
                hydra_shm_store_u32(aliveFlag, 1)
                log("PluginHost: launched \(hostURL.lastPathComponent) for \(plugins.count) plugin(s)")
            } catch {
                hydra_shm_store_u32(aliveFlag, 0)
                log("PluginHost: failed to launch host: \(error.localizedDescription)")
                scheduleRelaunch(after: 1)
            }
        }
    }

    private func handleExit(status: Int32) {
        control.async { [self] in
            hydra_shm_store_u32(aliveFlag, 0)
            process = nil
            guard !shuttingDown else { return }
            let uptime = Date().timeIntervalSince(lastLaunch)
            // A host that ran healthily for a while and only now died is a
            // one-off; reset. Otherwise it's a reliably-crashing plugin.
            if uptime > 30 {
                consecutiveCrashes = 0
            } else {
                consecutiveCrashes += 1
            }
            guard consecutiveCrashes < maxRelaunchAttempts else {
                log("PluginHost: child crashed \(consecutiveCrashes)× — giving up; chain stays DRY (plugin bypassed, daemon unaffected)")
                EventCenter.shared.emit(.error, "A plugin kept crashing and was bypassed. The rest of Hydra is unaffected (it ran in a separate process).")
                return  // stop relaunching; process() already passes audio through dry
            }
            let delay = min(30.0, 0.5 * pow(2.0, Double(consecutiveCrashes - 1)))
            log("PluginHost: child exited (status \(status), uptime \(String(format: "%.1f", uptime))s) — passthrough; relaunch \(consecutiveCrashes)/\(maxRelaunchAttempts) in \(String(format: "%.1f", delay))s")
            scheduleRelaunch(after: delay)
        }
    }

    private func scheduleRelaunch(after delay: TimeInterval) {
        control.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.shuttingDown else { return }
            // Reset the handshake so the fresh child starts clean.
            if let header = self.header {
                hydra_shm_store_u32(&header.pointee.hostReady, 0)
            }
            self.launch()
        }
    }

    /// Detects a hung (not crashed) host: heartbeat stops advancing while alive.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, let header = self.header,
                  hydra_shm_load_u32(self.aliveFlag) == 1 else { return }
            let hb = hydra_shm_load_u64(&header.pointee.heartbeat)
            if hb == self.lastHeartbeat {
                self.heartbeatStallTicks += 1
                if self.heartbeatStallTicks >= 3 {   // ~3s frozen
                    log("PluginHost: host frozen (no heartbeat) — killing to relaunch")
                    self.process?.terminate()        // → handleExit → relaunch
                    self.heartbeatStallTicks = 0
                }
            } else {
                self.heartbeatStallTicks = 0
                self.lastHeartbeat = hb
            }
        }
        timer.resume()
        watchdog = timer
    }

    func shutdown() {
        control.sync {
            shuttingDown = true
            watchdog?.cancel(); watchdog = nil
            process?.terminate(); process = nil
            hydra_shm_store_u32(aliveFlag, 0)
        }
        if let mapping { munmap(mapping, mappingBytes); self.mapping = nil; header = nil }
        shm_unlink(shmName)
    }

    // MARK: - Host binary location

    /// Locate the embedded `hydra-plugin-host`. Looks next to the daemon
    /// executable (CLI/dev builds) and inside the app bundle's Helpers, with an
    /// env override for development.
    static func defaultHostURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["HYDRA_PLUGIN_HOST_PATH"] {
            return URL(fileURLWithPath: override)
        }
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        // Layouts:
        //   • SwiftPM:  .build/<cfg>/Hydra            → sibling executable
        //   • Shipped:  the engine runs inside Hydra.app, with hydra-plugin-host
        //              embedded at Hydra.app/Contents/Library/Helpers/
        //              hydra-plugin-host.app/Contents/MacOS/hydra-plugin-host
        let appHelpers = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/Helpers")
        let candidates = [
            exeDir.appendingPathComponent("hydra-plugin-host"),
            appHelpers.appendingPathComponent("hydra-plugin-host.app/Contents/MacOS/hydra-plugin-host"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
