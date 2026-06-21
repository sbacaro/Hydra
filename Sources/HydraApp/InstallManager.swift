// Hydra Audio — GPL-3.0
// InstallManager — drives the one-click installs in the Welcome flow.
//
//   • Soundcard driver: the "Hydra Virtual Soundcard" backplane is a HAL plugin
//     and MUST live in /Library/Audio/Plug-Ins/HAL (root-owned). We copy the
//     driver bundled inside the app into place via a single
//     `do shell script … with administrator privileges` call (one macOS auth
//     dialog) and restart coreaudiod so the device appears immediately.
//
//   • NDI runtime: the proprietary NDI runtime is NEVER bundled or linked
//     (GPL constraint — see Hydra.ndiRedistURL and AboutView). The most we can
//     do automatically is fetch Vizrt's OFFICIAL redistributable and launch its
//     own installer; the user clicks through Vizrt's installer. If the download
//     fails we fall back to opening the official download page.

import Foundation
import AppKit
import Combine
import os
import HydraCore

@MainActor
final class InstallManager: ObservableObject {

    /// Per-task progress. `.skipped` means "already present, nothing to do".
    enum Phase: Equatable {
        case idle
        case running
        case success
        case skipped
        case failed(String)

        var isBusy: Bool { self == .running }
        var isDone: Bool { self == .success || self == .skipped }
    }

    @Published private(set) var driver = Phase.idle
    @Published private(set) var ndi    = Phase.idle

    /// True while either task is mid-flight — the Welcome step disables Next.
    var isBusy: Bool { driver.isBusy || ndi.isBusy }

    private let log = Logger(subsystem: "audio.hydra.app", category: "InstallManager")

    // Driver placement (mirrors Scripts/install_local.sh).
    private let driverBundleName = "HydraVirtualSoundcard"          // .driver
    private let halDir           = "/Library/Audio/Plug-Ins/HAL"

    // MARK: - Public entry points

    /// Run both installs in sequence. `driverAlreadyInstalled` /
    /// `ndiAlreadyInstalled` come from the live daemon status so we don't redo
    /// work (and don't prompt for a password unnecessarily).
    func installAll(driverAlreadyInstalled: Bool, ndiAlreadyInstalled: Bool) {
        installDriver(skipIfPresent: driverAlreadyInstalled)
        installNDI(skipIfPresent: ndiAlreadyInstalled)
    }

    // MARK: Soundcard driver

    func installDriver(skipIfPresent: Bool) {
        guard !driver.isBusy else { return }
        if skipIfPresent {
            driver = .skipped
            return
        }
        guard let src = locateBundledDriver() else {
            driver = .failed("Driver not embedded in the app. Regenerate the project (ruby Scripts/generate_xcodeproj.rb) and rebuild with Clean Build Folder.")
            log.error("Bundled driver not found in app Resources or build products")
            return
        }

        driver = .running
        // Capture isolated state into locals BEFORE hopping off the main actor.
        let halDirLocal = halDir
        let dst = "\(halDir)/\(driverBundleName).driver"
        let srcPath = src.path

        Task.detached {
            let result = Self.runPrivilegedDriverInstall(srcPath: srcPath, dstPath: dst, halDir: halDirLocal)
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .success:               self.driver = .success
                case .failure(let message):  self.driver = .failed(message)
                }
            }
        }
    }

    // MARK: NDI runtime (official redistributable)

    func installNDI(skipIfPresent: Bool) {
        guard !ndi.isBusy else { return }
        if skipIfPresent {
            ndi = .skipped
            return
        }
        guard let url = URL(string: Hydra.ndiRedistURL) else {
            ndi = .failed("Invalid NDI URL.")
            return
        }

        ndi = .running
        Task { [weak self] in
            guard let self else { return }
            do {
                let installerURL = try await Self.downloadNDIInstaller(from: url)
                // Launch Vizrt's official installer (.pkg/.dmg). The user clicks
                // through it — we never bundle or silently install the runtime.
                NSWorkspace.shared.open(installerURL)
                self.ndi = .success
            } catch {
                // Network/redirect failure → hand the user the official page.
                self.log.error("NDI download failed: \(error.localizedDescription, privacy: .public)")
                NSWorkspace.shared.open(url)
                self.ndi = .failed("Couldn't download — opened the official NDI download page instead.")
            }
        }
    }

    private static var didCheckDriverRefresh = false

    // MARK: - Driver version refresh (after an app update)

    /// Reinstalls the HAL driver when the copy bundled in the (possibly just-
    /// updated) app is newer than the one in /Library/Audio/Plug-Ins/HAL. No-op
    /// when the driver isn't installed yet (the first-run Welcome handles that) or
    /// when versions match — so it only prompts for admin on a real driver update.
    func refreshDriverIfOutdated() {
        guard !Self.didCheckDriverRefresh else { return }
        Self.didCheckDriverRefresh = true

        guard !driver.isBusy,
              let bundled = locateBundledDriver(),
              let bundledVersion = Self.bundleVersion(at: bundled) else { return }
        let installed = URL(fileURLWithPath: "\(halDir)/\(driverBundleName).driver")
        guard FileManager.default.fileExists(atPath: installed.path),
              let installedVersion = Self.bundleVersion(at: installed) else { return }
        // Only act when the bundled driver is strictly newer (numeric compare).
        guard bundledVersion.compare(installedVersion, options: .numeric) == .orderedDescending else { return }
        log.info("Driver outdated (installed \(installedVersion, privacy: .public) < bundled \(bundledVersion, privacy: .public)) — reinstalling")
        installDriver(skipIfPresent: false)
    }

    /// Reads CFBundleShortVersionString (falling back to CFBundleVersion) from a
    /// bundle's Info.plist.
    nonisolated private static func bundleVersion(at bundleURL: URL) -> String? {
        let plist = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plist) else { return nil }
        return (dict["CFBundleShortVersionString"] as? String)
            ?? (dict["CFBundleVersion"] as? String)
    }

    // MARK: - Driver lookup

    /// Finds `HydraVirtualSoundcard.driver` in priority order:
    ///   1. Embedded in the running app's Resources (shipping / regenerated dev).
    ///   2. Next to HydraApp.app in the same Build/Products dir — where the driver
    ///      target lands when it's a build dependency (Xcode dev, no embed needed).
    ///   3. A prebuilt copy under <repo>/dist/ (legacy fallback).
    private func locateBundledDriver() -> URL? {
        let fm   = FileManager.default
        let name = "\(driverBundleName).driver"

        // 1) Embedded resource.
        if let inBundle = Bundle.main.url(forResource: driverBundleName, withExtension: "driver") {
            return inBundle
        }

        // 2) Sibling in the build-products directory (same configuration as the
        //    running app, e.g. Build/Products/Debug/).
        let productsDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let sibling = productsDir.appendingPathComponent(name)
        if fm.fileExists(atPath: sibling.path) { return sibling }

        // 3) Legacy: walk up from the app to find <repo>/dist/<driver>.
        var dir = productsDir
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("dist/\(name)")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Privileged copy (runs off the main actor)

    private enum InstallResult { case success; case failure(String) }

    /// Copies the driver into the HAL folder and restarts coreaudiod, all under
    /// a single administrator-privileges prompt. Returns once the auth dialog is
    /// resolved and the shell script has run.
    nonisolated private static func runPrivilegedDriverInstall(srcPath: String, dstPath: String, halDir: String) -> InstallResult {
        // Write the install steps to a temp script so we don't have to escape a
        // multi-line command inside AppleScript.
        // Single-quote every path so an app installed under a path containing
        // spaces, quotes, $ or backticks can't break (or inject into) the
        // script that runs as root.
        let qHal = shellQuote(halDir)
        let qDst = shellQuote(dstPath)
        let qSrc = shellQuote(srcPath)
        let script = """
        #!/bin/sh
        set -e
        mkdir -p \(qHal)
        rm -rf \(qDst)
        cp -R \(qSrc) \(qDst)
        chown -R root:wheel \(qDst)
        xattr -dr com.apple.quarantine \(qDst) 2>/dev/null || true
        # coreaudiod must reload to pick up the new HAL plugin.
        killall coreaudiod 2>/dev/null || true
        exit 0
        """

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hydra-install-\(UUID().uuidString).sh")
        do {
            try script.write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            return .failure("Couldn't prepare the installer: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        // AppleScript escaping: backslashes and double quotes.
        let shellInvocation = "/bin/sh \(shellQuote(tmp.path))"
        let escaped = shellInvocation
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", appleScript]
        let errPipe = Pipe()
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return .failure("Failed to run the installer: \(error.localizedDescription)")
        }

        if proc.terminationStatus == 0 {
            return .success
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8) ?? ""
        if errText.localizedCaseInsensitiveContains("User canceled") {
            return .failure("Installation cancelled — the administrator password is required.")
        }
        return .failure(errText.isEmpty ? "Installer returned error \(proc.terminationStatus)." : errText)
    }

    /// Minimal single-quote shell quoting for a file path.
    nonisolated private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - NDI download

    /// Downloads the official redistributable, following redirects, and returns
    /// a local file URL with a sensible extension so Installer.app/Finder open it.
    nonisolated private static func downloadNDIInstaller(from url: URL) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)

        // Preserve the server's filename/extension (.pkg or .dmg) so macOS knows
        // how to open it.
        let suggested = response.suggestedFilename ?? "NDI_Redistributable.pkg"
        var name = suggested
        if (name as NSString).pathExtension.isEmpty { name += ".pkg" }

        let dest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }
}
