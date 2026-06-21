// Hydra Audio — GPL-3.0
// Built-in, privacy-preserving diagnostics via Apple's MetricKit. No third-party
// telemetry: the OS delivers crash / hang / CPU-exception / disk-write reports
// (and daily performance metrics) directly to this subscriber, which logs a
// summary to the unified log and saves the raw JSON payloads under
// Application Support/Hydra/Diagnostics. The diagnostics export (see
// Diagnostics.swift) lists them so they can be attached to a bug report.
//
// MetricKit delivers payloads on its own schedule (typically once a day, and on
// the next launch after a crash) on a background queue — hence @unchecked
// Sendable and the lock-free, thread-safe work here (Logger + file writes).

import Foundation
import MetricKit
import HydraCore

// `nonisolated`: this type opts out of the app target's default MainActor
// isolation. MetricKit invokes the subscriber callbacks on a background queue,
// and everything here (Logger + FileManager) is thread-safe — so none of it
// belongs on the main actor.
nonisolated final class MetricsReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {

    static let shared = MetricsReporter()

    private let log = HydraLog.app

    /// Where raw payloads are kept (and where the diagnostics export looks).
    static var diagnosticsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("Hydra/Diagnostics", isDirectory: true)
    }

    /// Subscribe. Call once, after launch (from the AppDelegate).
    func start() {
        MXMetricManager.shared.add(self)
        log.info("MetricKit: subscribed (metrics + diagnostics)")
    }

    func stop() {
        MXMetricManager.shared.remove(self)
    }

    // MARK: - MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            save(payload.jsonRepresentation(), kind: "metrics")
        }
        log.info("MetricKit: stored \(payloads.count) metric payload(s)")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            save(payload.jsonRepresentation(), kind: "diagnostics")
            summarize(payload)
        }
    }

    // MARK: - Internals

    private func summarize(_ payload: MXDiagnosticPayload) {
        let crashes = payload.crashDiagnostics?.count ?? 0
        let hangs   = payload.hangDiagnostics?.count ?? 0
        let cpu     = payload.cpuExceptionDiagnostics?.count ?? 0
        let disk    = payload.diskWriteExceptionDiagnostics?.count ?? 0
        guard crashes + hangs + cpu + disk > 0 else { return }
        log.error("""
            MetricKit diagnostics — crashes: \(crashes), hangs: \(hangs), \
            cpuExceptions: \(cpu), diskWrites: \(disk) (saved to Application Support/Hydra/Diagnostics)
            """)
    }

    private func save(_ data: Data, kind: String) {
        let dir = Self.diagnosticsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Self.stampFormatter.string(from: Date())
        let url = dir.appendingPathComponent("\(kind)-\(stamp).json")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("MetricKit: failed to save \(kind) payload — \(error.localizedDescription)")
        }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
