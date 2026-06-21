// Hydra Audio — GPL-3.0
// hydra-plugin-host — out-of-process VST chain host.
//
// One of these runs per hosted strip chain. The daemon (hydrad) launches it,
// hands it a shared-memory region name and the chain to load, and streams audio
// through that region. If a plugin crashes, only THIS process dies; hydrad
// detects the silence, passes audio through dry, and relaunches us.
//
// Increment 2: the host is now a faceless NSApplication, so it can host the
// plugin EDITOR windows (the plugin instance and its window live in the same
// crashable process). Threading:
//   • a dedicated high-QoS audio thread runs the busy-poll process loop;
//   • the main thread runs the AppKit run loop (editor windows) and drains the
//     daemon→host command ring (open editor / set parameter) on a timer.
// Both the GUI's own parameter edits and externally-set parameters happen on
// main, so the shim's GUI→audio parameter ring stays single-producer.
//
// Usage (the daemon builds this argv):
//   hydra-plugin-host --shm <name> --channels 2 --max-frames 4096 --rate 48000 \
//                     --plugin <path>#<classIndex> --title <name> [ ... ]

import Foundation
import AppKit
import Darwin
import HydraPluginHostABI
import HydraVST

// MARK: - Argument parsing

func argValue(_ flag: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: flag),
          i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

func argValues(_ flag: String) -> [String] {
    var out: [String] = []
    let args = CommandLine.arguments
    var i = 0
    while i < args.count {
        if args[i] == flag, i + 1 < args.count { out.append(args[i + 1]); i += 2 }
        else { i += 1 }
    }
    return out
}

// MARK: - PluginHost: owns all state (shared so the audio thread + main can use it)

final class PluginHost: @unchecked Sendable {
    let header: UnsafeMutablePointer<hydra_plugin_shm>
    let channels: Int
    let maxFrames: Int
    /// Aligned 1:1 with the chain (nil = a plugin that failed to load), so the
    /// daemon's per-plugin command indices stay valid.
    let instances: [UnsafeMutableRawPointer?]
    let titles: [String]
    /// Dense list of loaded instances (nils removed) — the audio chain order.
    private let active: [UnsafeMutableRawPointer]

    private let bufA: [UnsafeMutablePointer<Float>]
    private let bufB: [UnsafeMutablePointer<Float>]
    private let argA: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let argB: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>

    private var lastInput: UInt64
    private var idleSpins = 0
    private var lastCmd: UInt64 = 0

    init(header: UnsafeMutablePointer<hydra_plugin_shm>, channels: Int, maxFrames: Int,
         instances: [UnsafeMutableRawPointer?], titles: [String]) {
        self.header = header
        self.channels = channels
        self.maxFrames = maxFrames
        self.instances = instances
        self.active = instances.compactMap { $0 }
        self.titles = titles
        func make() -> [UnsafeMutablePointer<Float>] {
            (0..<channels).map { _ in
                let p = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
                p.initialize(repeating: 0, count: maxFrames)
                return p
            }
        }
        bufA = make(); bufB = make()
        argA = .allocate(capacity: channels)
        argB = .allocate(capacity: channels)
        for ch in 0..<channels { argA[ch] = bufA[ch]; argB[ch] = bufB[ch] }
        lastInput = hydra_shm_load_u64(&header.pointee.inputSeq)
    }

    // MARK: Lifecycle — start the audio thread + command drain. Created inside
    // the (nonisolated) instance so the @Sendable closures capture `self`
    // (Sendable) rather than a main-actor top-level binding.

    func startAudioThread() {
        let thread = Thread { [self] in runAudioLoop() }
        thread.name = "hydra.plugin-host.audio"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func startCommandDrain() {
        let timer = Timer(timeInterval: 0.03, repeats: true) { [self] _ in drainCommands() }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: Audio thread — busy-poll the input sequence

    private func configureRealTimeThread() {
        var info = thread_time_constraint_policy()
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        
        let msToNs: UInt32 = 1_000_000
        let periodNs = UInt32(3 * msToNs)
        let periodCycles = periodNs * tb.denom / tb.numer
        
        let constraintNs = UInt32(1.5 * Float(msToNs))
        let constraintCycles = constraintNs * tb.denom / tb.numer
        
        let computationNs = UInt32(1 * msToNs)
        let computationCycles = computationNs * tb.denom / tb.numer
        
        info.period = periodCycles
        info.computation = computationCycles
        info.constraint = constraintCycles
        info.preemptible = 1
        
        let threadPort = mach_thread_self()
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(threadPort,
                                  thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY),
                                  $0,
                                  count)
            }
        }
        mach_port_deallocate(mach_task_self_, threadPort)
        if result != KERN_SUCCESS {
            let msg = "hydra-plugin-host: Warning: Failed to set real-time thread priority: \(result)\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }
    }

    func runAudioLoop() {
        configureRealTimeThread()
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        
        var lastInputTime = mach_absolute_time()
        
        while true {
            let seq = hydra_shm_load_u64(&header.pointee.inputSeq)
            if seq == lastInput {
                let now = mach_absolute_time()
                let elapsedTicks = now - lastInputTime
                let elapsedNanos = elapsedTicks * UInt64(tb.numer) / UInt64(tb.denom)
                
                if elapsedNanos > 50_000_000 { // 50 ms
                    // Deep idle: sleep for 10ms
                    Thread.sleep(forTimeInterval: 0.010)
                } else if elapsedNanos > 5_000_000 { // 5 ms
                    // Light idle: sleep for 1ms
                    Thread.sleep(forTimeInterval: 0.001)
                } else {
                    // Active streaming: spin/yield
                    idleSpins += 1
                    if idleSpins > 1_000 {
                        usleep(100)
                    }
                }
                hydra_shm_store_u64(&header.pointee.heartbeat, header.pointee.heartbeat &+ 1)
                continue
            }
            lastInput = seq
            lastInputTime = mach_absolute_time()
            idleSpins = 0
            let frames = min(Int(header.pointee.frames), maxFrames)
            let inBuf  = hydra_plugin_shm_input(header, seq)
            let outBuf = hydra_plugin_shm_output(header, seq)
            guard frames > 0 else {
                hydra_shm_store_u64(&header.pointee.outputSeq, seq)
                continue
            }

            if active.isEmpty {
                memcpy(outBuf, inBuf, frames * channels * MemoryLayout<Float>.size)
            } else {
                for frame in 0..<frames {
                    for ch in 0..<channels { bufA[ch][frame] = inBuf[frame * channels + ch] }
                }
                var source = argA
                var sink = argB
                for instance in active {
                    if hydra_vst_process(instance, source, sink, Int32(frames)) {
                        swap(&source, &sink)
                    }
                }
                for ch in 0..<channels {
                    guard let data = source[ch] else {
                        for frame in 0..<frames { outBuf[frame * channels + ch] = 0 }
                        continue
                    }
                    for frame in 0..<frames { outBuf[frame * channels + ch] = data[frame] }
                }
            }
            hydra_shm_store_u64(&header.pointee.outputSeq, seq)
            hydra_shm_store_u64(&header.pointee.heartbeat, header.pointee.heartbeat &+ 1)
        }
    }

    // MARK: Main thread — drain daemon→host commands (open editor / set param)

    func drainCommands() {
        let write = hydra_shm_load_u64(&header.pointee.cmdWriteSeq)
        while lastCmd != write {
            lastCmd &+= 1
            let cmd = hydra_plugin_shm_cmd(header, lastCmd).pointee
            let idx = Int(cmd.instance)
            guard instances.indices.contains(idx), let inst = instances[idx] else { continue }
            switch cmd.type {
            case UInt32(HYDRA_CMD_OPEN_EDITOR):
                let title = titles.indices.contains(idx) ? titles[idx] : "Plugin \(idx + 1)"
                _ = title.withCString { hydra_vst_open_editor(inst, $0) }
            case UInt32(HYDRA_CMD_SET_PARAM):
                hydra_vst_set_parameter(inst, cmd.paramId, Double(cmd.value))
            default:
                break
            }
        }
        hydra_shm_store_u64(&header.pointee.cmdReadSeq, lastCmd)
    }
}

// MARK: - Startup

guard let shmName = argValue("--shm"),
      let channels = argValue("--channels").flatMap({ Int($0) }),
      let maxFrames = argValue("--max-frames").flatMap({ Int($0) }),
      let rate = argValue("--rate").flatMap({ Double($0) }) else {
    FileHandle.standardError.write(Data("hydra-plugin-host: missing required args\n".utf8))
    exit(2)
}
let pluginSpecs = argValues("--plugin")   // each "path#classIndex"
let pluginTitles = argValues("--title")   // aligned with --plugin (editor titles)

let fd = hydra_shm_open_rw(shmName)
guard fd >= 0 else {
    FileHandle.standardError.write(Data("hydra-plugin-host: shm open(\(shmName)) failed\n".utf8))
    exit(3)
}
let totalBytes = Int(hydra_plugin_shm_bytes(Int32(channels), Int32(maxFrames)))
guard let raw = mmap(nil, totalBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
      raw != MAP_FAILED else {
    FileHandle.standardError.write(Data("hydra-plugin-host: mmap failed\n".utf8))
    exit(4)
}
let header = raw.bindMemory(to: hydra_plugin_shm.self, capacity: 1)
guard header.pointee.magic == HYDRA_PLUGIN_SHM_MAGIC,
      header.pointee.abiVersion == HYDRA_PLUGIN_SHM_ABI,
      Int(header.pointee.channels) == channels,
      Int(header.pointee.maxFrames) == maxFrames else {
    FileHandle.standardError.write(Data("hydra-plugin-host: shm header mismatch\n".utf8))
    exit(5)
}

// Aligned 1:1 with pluginSpecs (nil = failed/malformed), so command indices match.
var loaded: [UnsafeMutableRawPointer?] = []
for spec in pluginSpecs {
    let parts = spec.split(separator: "#")
    guard parts.count == 2, let classIndex = Int32(parts[1]) else { loaded.append(nil); continue }
    loaded.append(hydra_vst_create_instance(String(parts[0]), classIndex, rate, Int32(maxFrames)))
}

let host = PluginHost(header: header, channels: channels, maxFrames: maxFrames,
                      instances: loaded, titles: pluginTitles)
hydra_shm_store_u32(&header.pointee.hostReady, 1)

// Audio on a dedicated high-QoS thread; AppKit owns main (editor windows);
// commands drained on the main run loop.
host.startAudioThread()
host.startCommandDrain()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // faceless: no Dock icon, just plugin windows
app.run()
