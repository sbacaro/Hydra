// Hydra Audio — GPL-3.0
// In-app auto-update — self-contained, no third-party framework.
//
// Flow (fully automatic):
//   1. On launch and every 24h, query the latest GitHub Release.
//   2. If its version is newer than the running build, download the .pkg and its
//      .pkg.sha256 sidecar.
//   3. Verify the download's SHA-256 against the sidecar (this replaces Sparkle's
//      EdDSA signature — integrity comes from the published checksum).
//   4. Install it with `installer -pkg … -target /` via an admin prompt (macOS
//      shows the native password dialog — unavoidable for a system install).
//   5. Relaunch the freshly installed app.
//
// The admin password prompt is the ONLY user interaction; everything else runs
// in the background. If the user cancels the prompt, `availableVersion` stays set
// so the menu bar / Settings still offer a manual retry, and we don't nag again
// this session.
//
// The release assets are produced by .github/workflows/release.yml:
//   Hydra-X.Y.Z.pkg          — the installer (app + HAL driver)
//   Hydra-X.Y.Z.pkg.sha256   — `shasum -a 256` output for the .pkg

import Foundation
import Combine
import CryptoKit
import AppKit
import HydraCore

@MainActor
final class Updater: ObservableObject {

    /// Set when a newer release is found; drives the in-app banner + menu items.
    @Published private(set) var availableVersion: String?

    /// Bound to the Settings toggle. When off, no automatic checks run (a manual
    /// "Check for Updates…" still works).
    @Published var automaticallyChecks: Bool {
        didSet { UserDefaults.standard.set(automaticallyChecks, forKey: Self.autoKey) }
    }

    private static let autoKey = "audio.hydra.autoUpdate"
    /// Last time an AUTOMATIC check ran, to throttle launch checks (the manual
    /// "Check for Updates" is never throttled).
    private static let lastAutoCheckKey = "audio.hydra.lastUpdateCheck"
    private static let autoCheckMinInterval: TimeInterval = 6 * 3600

    /// One automatic install attempt per launch, so a cancelled password prompt
    /// doesn't re-trigger on every scheduled check.
    private var attemptedThisSession = false
    private var checking = false
    private var timer: Timer?

    init() {
        automaticallyChecks = UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true
    }

    // MARK: - Public API (called by AppDelegate / menus / Settings)

    /// Begin scheduled checks (launch + every 24h). Call once after launch.
    func start() {
        guard automaticallyChecks else { return }
        Task { await self.runCheck(userInitiated: false) }
        let timer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.runCheck(userInitiated: false) }
        }
        self.timer = timer
    }

    /// User-initiated check (menu / Settings / banner). Reports "up to date" and
    /// errors via an alert; otherwise downloads, verifies and installs.
    func checkForUpdates() {
        Task { await self.runCheck(userInitiated: true) }
    }

    // MARK: - Core flow

    private func runCheck(userInitiated: Bool) async {
        guard !checking else { return }
        // Throttle AUTOMATIC checks so frequent relaunches don't burn the
        // unauthenticated GitHub rate limit (60/h per IP). A user-initiated check
        // always runs.
        if !userInitiated {
            let last = UserDefaults.standard.object(forKey: Self.lastAutoCheckKey) as? Date
            if let last, Date().timeIntervalSince(last) < Self.autoCheckMinInterval { return }
            UserDefaults.standard.set(Date(), forKey: Self.lastAutoCheckKey)
        }
        checking = true
        defer { checking = false }

        do {
            guard let release = try await fetchLatestRelease() else {
                if userInitiated { presentInfo("Hydra is up to date.") }
                return
            }
            let current = Self.currentVersion
            guard Self.isVersion(release.version, newerThan: current) else {
                availableVersion = nil
                if userInitiated {
                    presentInfo("Hydra \(current) is the latest version.")
                }
                return
            }
            availableVersion = release.version

            // Fully automatic: download + verify + install. Once per session for
            // background checks; always for an explicit user request.
            if !userInitiated && attemptedThisSession { return }
            attemptedThisSession = true

            let pkgURL = try await downloadAndVerify(release)
            try install(pkgAt: pkgURL)   // shows the admin password prompt
            relaunch()
        } catch let error as UpdateError where error == .cancelled {
            // User dismissed the password prompt — leave availableVersion set.
            return
        } catch {
            if userInitiated { presentError(error) }
            HydraLog.app.error("updater: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - GitHub release lookup

    private struct Release { let version: String; let pkg: URL; let sha256: URL }

    private struct GHRelease: Decodable { let tag_name: String; let assets: [GHAsset] }
    private struct GHAsset: Decodable { let name: String; let browser_download_url: String }

    /// The GitHub REST endpoint for the latest release, derived from the GPL
    /// source URL so it follows the repository automatically.
    private static var latestReleaseAPI: URL {
        let api = Hydra.sourceURL.replacingOccurrences(
            of: "https://github.com/", with: "https://api.github.com/repos/")
        return URL(string: api + "/releases/latest")!
    }

    private func fetchLatestRelease() async throws -> Release? {
        var request = URLRequest(url: Self.latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Hydra-Updater", forHTTPHeaderField: "User-Agent")
        // Always fetch a FRESH result: a 404 cached while no release existed yet
        // must never hide a release published later — and a slow link must not
        // hang the check forever.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.network("Could not reach the update server.")
        }
        // Distinguish the cases instead of collapsing every non-200 into one
        // misleading "could not reach" — so the failure is self-diagnosing.
        switch http.statusCode {
        case 200:
            break
        case 404:
            // No published, non-draft, non-prerelease release yet — nothing to
            // update to. Treated as "up to date", not an error.
            return nil
        case 403, 429:
            // The unauthenticated GitHub API allows 60 requests/hour per IP.
            throw UpdateError.network("GitHub is rate-limiting update checks. Please try again in a little while.")
        default:
            throw UpdateError.network("The update server returned HTTP \(http.statusCode).")
        }
        let gh = try JSONDecoder().decode(GHRelease.self, from: data)

        guard let pkgAsset = gh.assets.first(where: { $0.name.hasSuffix(".pkg") }),
              let shaAsset = gh.assets.first(where: { $0.name.hasSuffix(".pkg.sha256") }),
              let pkgURL = URL(string: pkgAsset.browser_download_url),
              let shaURL = URL(string: shaAsset.browser_download_url) else {
            return nil // a release without our assets isn't installable
        }
        let version = gh.tag_name.hasPrefix("v") ? String(gh.tag_name.dropFirst()) : gh.tag_name
        return Release(version: version, pkg: pkgURL, sha256: shaURL)
    }

    // MARK: - Download + verify

    private func downloadAndVerify(_ release: Release) async throws -> URL {
        // Expected digest: first whitespace-delimited token of `shasum -a 256`.
        let (shaData, _) = try await get(release.sha256)
        guard let shaText = String(data: shaData, encoding: .utf8),
              let expected = shaText.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first
                  .map({ String($0).lowercased() }), expected.count == 64 else {
            throw UpdateError.verification("The update checksum is malformed.")
        }

        let (pkgData, _) = try await get(release.pkg)
        let actual = SHA256.hash(data: pkgData).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw UpdateError.verification("The downloaded update failed its checksum — not installing.")
        }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("Hydra-\(release.version).pkg")
        try? FileManager.default.removeItem(at: dest)
        try pkgData.write(to: dest, options: .atomic)
        return dest
    }

    private func get(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.setValue("Hydra-Updater", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UpdateError.network("Download failed (HTTP \(code)).")
        }
        return (data, response)
    }

    // MARK: - Install (privileged) + relaunch

    /// Runs `installer` as root via the system's authorization dialog. Throws
    /// `.cancelled` if the user dismisses the password prompt.
    private func install(pkgAt url: URL) throws {
        // The pkg path is wrapped in double quotes for the shell. That whole
        // command is then embedded inside an AppleScript string literal, so every
        // backslash and double quote in it — including the structural quotes we
        // just added around the path — must be escaped for AppleScript. Escaping
        // only the path (and not the surrounding quotes) was the bug that aborted
        // every install with AppleScript error -2740, "an identifier can't go
        // after this number": the unescaped quote closed the string early and the
        // temp-dir path (e.g. /var/folders/…/00000gn/…) was parsed as code.
        let shell = "/usr/sbin/installer -pkg \"\(url.path)\" -target /"
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"

        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw UpdateError.install("Could not start the installer.")
        }
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -128 { throw UpdateError.cancelled } // user cancelled auth
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "Installation failed."
            throw UpdateError.install(message)
        }
    }

    /// Relaunch the freshly installed app and quit this instance. The pkg is
    /// non-relocatable, so it always lands in /Applications.
    private func relaunch() {
        let installed = "/Applications/\(Self.appName).app"
        let path = FileManager.default.fileExists(atPath: installed)
            ? installed : Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Hydra"
    }

    private static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? Hydra.version
    }

    /// Numeric, component-wise version comparison ("0.20.1" > "0.20.0").
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Alerts (user-initiated only)

    private func presentInfo(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Software Update"
        alert.informativeText = text
        alert.runModal()
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Update failed"
        alert.informativeText = (error as? UpdateError)?.message ?? error.localizedDescription
        alert.runModal()
    }
}

/// Updater failure modes.
enum UpdateError: Error, Equatable {
    case network(String)
    case verification(String)
    case install(String)
    case cancelled

    var message: String {
        switch self {
        case .network(let m), .verification(let m), .install(let m): return m
        case .cancelled: return "Update cancelled."
        }
    }
}
