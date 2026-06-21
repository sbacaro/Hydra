// Hydra Audio — GPL-3.0
// One-click diagnostics export for support tickets.
//
// Collects the recent unified logs for BOTH the app and the daemon (they share
// the "audio.hydra" subsystem — see HydraCore/HydraLog.swift), plus environment
// and current status, into a single text file the user picks a location for.
//
// Uses the `/usr/bin/log` CLI rather than OSLogStore: `log show` reads the
// user-accessible system logs (so it captures the separate hydrad process)
// without needing the private logging entitlement an in-app OSLogStore(.system)
// would require.

import Foundation
import AppKit
import HydraCore

enum Diagnostics {

    /// Prompt for a destination, then gather the report off the main thread and
    /// reveal the resulting file in Finder.
    @MainActor
    static func export(statusSummary: String) {
        let panel = NSSavePanel()
        panel.title = "Export Hydra Diagnostics"
        panel.nameFieldStringValue = "Hydra-Diagnostics-\(fileTimestamp()).txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task.detached(priority: .userInitiated) {
            let report = buildReport(statusSummary: statusSummary)
            do {
                try report.data(using: .utf8)?.write(to: url, options: .atomic)
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't save diagnostics"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - Report

    nonisolated private static func buildReport(statusSummary: String) -> String {
        var out = ""
        out += "Hydra Diagnostics\n"
        out += "=================\n"
        out += "Generated:   \(ISO8601DateFormatter().string(from: Date()))\n"
        out += "App version: \(Hydra.versionString)\n"
        out += "macOS:       \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        out += "Hardware:    \(sysctlString("hw.model"))\n"
        out += "CPU:         \(sysctlString("machdep.cpu.brand_string"))\n\n"
        out += "Status\n------\n\(statusSummary)\n\n"
        out += "Unified logs — last 2h, subsystem audio.hydra (app + daemon)\n"
        out += "-----------------------------------------------------------\n"
        out += runLogShow()
        out += "\n"
        return out
    }

    /// `log show` for our subsystem only — bounded and privacy-scoped to Hydra.
    nonisolated private static func runLogShow() -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        proc.arguments = [
            "show",
            "--predicate", "subsystem == \"\(HydraLog.subsystem)\"",
            "--info",
            "--last", "2h",
            "--style", "syslog",
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            // Read BEFORE waiting so a large stream can't deadlock on a full pipe.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? "(could not decode log output)"
            return text.isEmpty ? "(no log entries in the window)" : text
        } catch {
            return "(failed to run `log show`: \(error.localizedDescription))"
        }
    }

    // MARK: - Helpers

    private static func fileTimestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }

    nonisolated private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
