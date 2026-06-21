// swift-tools-version: 5.9
// Hydra Audio — GPL-3.0
import PackageDescription

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
            path: "Sources/HydraCore"
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
            path: "Sources/hydra-plugin-host"
        ),
        // Background daemon: all audio/network work lives here.
        .executableTarget(
            name: "hydrad",
            dependencies: ["HydraCore", "HydraVST", "HydraNDIShim", "HydraModuleABI", "HydraPluginHostABI"],
            path: "Sources/hydrad",
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist (NSAudioCaptureUsageDescription) so the
                // CLI daemon can request the audio-capture TCC permission.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/hydrad/Info.plist"
                ])
            ]
        ),
        // SwiftUI app: UI only, client of the daemon.
        .executableTarget(
            name: "HydraApp",
            dependencies: ["HydraCore"],
            path: "Sources/HydraApp"
        ),
        .testTarget(
            name: "HydraCoreTests",
            dependencies: ["HydraCore"],
            path: "Tests/HydraCoreTests"
        )
    ],
    // C++23 ("2b"): libc++'s <atomic> must coexist with the <stdatomic.h>
    // that Foundation's clang modules pull into the VST shim.
    cxxLanguageStandard: .cxx2b
)
