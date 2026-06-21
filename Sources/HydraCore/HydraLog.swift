// Hydra Audio — GPL-3.0
// Unified logging + signposts for the whole project (daemon, app, plugin host).
//
// Everything goes through Apple's unified logging (`os.Logger`), so logs are:
//   • persistent and queryable (`log show --predicate 'subsystem == "audio.hydra"'`
//     or Console.app), surviving a daemon relaunch — unlike the old `print()`s;
//   • categorised, so you can isolate the audio thread from networking, etc.;
//   • exportable from the app (see Diagnostics export) for support tickets.
//
// The audio render cycle is also instrumented with `os_signpost` intervals so
// XRUN/dropout investigations can be done in Instruments (Points of Interest /
// the "Hydra Audio" subsystem) instead of guessing.

import Foundation
import os

public enum HydraLog {
    /// One subsystem for the whole product; categories split the streams.
    public static let subsystem = "audio.hydra"

    public enum Category: String {
        case daemon          // daemon lifecycle / general
        case audio           // real-time engine + routing
        case network         // WebSocket / OSC / AES67 / NDI
        case plugin          // VST hosting / plugin host process
        case device          // CoreAudio devices + taps
        case install         // driver install / updates
        case app             // SwiftUI app
    }

    /// Cheap to construct and internally cached by the OS, so we just make one
    /// per call site category. Prefer the typed accessors below.
    public static func logger(_ category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    public static let daemon  = Logger(subsystem: subsystem, category: Category.daemon.rawValue)
    public static let audio   = Logger(subsystem: subsystem, category: Category.audio.rawValue)
    public static let network = Logger(subsystem: subsystem, category: Category.network.rawValue)
    public static let plugin  = Logger(subsystem: subsystem, category: Category.plugin.rawValue)
    public static let device  = Logger(subsystem: subsystem, category: Category.device.rawValue)
    public static let install = Logger(subsystem: subsystem, category: Category.install.rawValue)
    public static let app     = Logger(subsystem: subsystem, category: Category.app.rawValue)
}

// MARK: - Signposts (audio thread profiling)

public enum HydraSignpost {
    /// Real-time audio cycle. `OSSignposter` is no-op overhead when nothing is
    /// recording, and is safe to call from the audio IOProc (lock-free, no
    /// allocation for the static names used here).
    public static let audio = OSSignposter(subsystem: HydraLog.subsystem, category: "PointsOfInterest")
}
