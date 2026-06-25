// swift-tools-version: 6.0
// Hydra Audio — GPL-3.0
//
// Language modes here mirror the shipping build only where it's safe to do so
// under SwiftPM. The Xcode project (Scripts/generate_xcodeproj.rb) builds EVERY
// target in full Swift 6 mode with `SWIFT_STRICT_CONCURRENCY = complete` and
// per-target actor isolation — that's the real gate (and what CI runs).
//
// Under SwiftPM we enable Swift 6 mode for HydraCore + its tests (so `swift test`
// matches CI's strict-concurrency checking of the pure code), and keep the app /
// daemon / plugin-host at v5 here: SwiftPM has no equivalent of the project's
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so flipping them to v6 under
// SwiftPM alone would diverge from the Xcode build. They stay strictly checked in
// Xcode/CI; `swift test` doesn't build them anyway.
import PackageDescription

let v6: [SwiftSetting] = [.swiftLanguageMode(.v6)]
let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Hydra",
    platforms: [
        // Tahoe: required for the Liquid Glass design APIs used by the app.
        .macOS("26.0")
    ],
    targets: [
        // Single source of truth: shared constants, model types, WS messages.
        .target(
            name: "HydraCore",
            path: "Sources/HydraCore",
            swiftSettings: v6
        ),
        // Real-time DSP: SPSC ring + polyphase resampler. Split out of the daemon
        // so it's unit-testable on its own. Pure Swift (no MainActor default), so
        // it runs in full Swift 6 mode under SwiftPM too.
        .target(
            name: "HydraRT",
            dependencies: ["HydraCore"],
            path: "Sources/HydraRT",
            swiftSettings: v6
        ),
        // VST3 hosting shim (C++ over the Steinberg VST3 SDK, GPLv3 option).
        // The SDK is fetched by Scripts/fetch_vst3sdk.sh into ThirdParty/.
        .target(
            name: "HydraVST",
            path: "Sources/HydraVST",
            cxxSettings: [
                .unsafeFlags(["-IThirdParty/vst3sdk"]),
                .define("RELEASE", to: "1")
            ],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Foundation")
            ]
        ),
        // NDI shim: flat C facade that dlopen()s the proprietary NDI runtime
        // at run time (never linked/bundled — GPL-safe, DistroAV pattern).
        .target(
            name: "HydraNDIShim",
            path: "Sources/HydraNDIShim"
        ),
        // Module ABI for VST3 plugin loading
        .target(
            name: "HydraModuleABI",
            path: "Sources/HydraModuleABI"
        ),
        // Shared-memory transport ABI between the daemon and the out-of-process
        // plugin host (crash isolation). Header-only C.
        .target(
            name: "HydraPluginHostABI",
            path: "Sources/HydraPluginHostABI"
        ),
        // Out-of-process VST chain host: a plugin crash kills this, not hydrad.
        .executableTarget(
            name: "hydra-plugin-host",
            dependencies: ["HydraVST", "HydraPluginHostABI"],
            path: "Sources/hydra-plugin-host",
            swiftSettings: v5
        ),
        // Audio engine: all audio/network work lives here. Built as a FRAMEWORK
        // (library) — it runs IN-PROCESS inside Hydra.app via DaemonRuntime.start()
        // rather than as a separate `hydrad` process. Path stays Sources/hydrad.
        .target(
            name: "HydraDaemon",
            dependencies: ["HydraCore", "HydraRT", "HydraVST", "HydraNDIShim", "HydraModuleABI", "HydraPluginHostABI"],
            path: "Sources/hydrad",
            exclude: ["Info.plist", "hydrad.entitlements"],
            swiftSettings: v5
        ),
        // SwiftUI app + the in-process audio engine (HydraDaemon).
        .executableTarget(
            name: "HydraApp",
            dependencies: ["HydraCore", "HydraDaemon"],
            path: "Sources/HydraApp",
            swiftSettings: v5
        ),
        .testTarget(
            name: "HydraCoreTests",
            dependencies: ["HydraCore"],
            path: "Tests/HydraCoreTests",
            swiftSettings: v6
        ),
        // Real-time ring/resampler tests (now a proper library, so `swift test`
        // runs them too — not just the Xcode HydraRTTests scheme).
        .testTarget(
            name: "HydraRTTests",
            dependencies: ["HydraRT"],
            path: "Tests/HydraRTTests",
            swiftSettings: v6
        )
    ],
    // C++23 ("2b"): libc++'s <atomic> must coexist with the <stdatomic.h>
    // that Foundation's clang modules pull into the VST shim.
    cxxLanguageStandard: .cxx2b
)
