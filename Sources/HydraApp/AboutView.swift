// Hydra Audio — GPL-3.0
// About / Legal — GPL-3.0 §0/§5d Appropriate Legal Notices:
// license statement, source availability, warranty disclaimer, and credits
// for every third-party component (mirrored in THIRD_PARTY_NOTICES.md).
//
// Apple HIG changes vs previous version:
//   • REMOVED preferredColorScheme(.dark) — About adapts to system appearance.
//   • REMOVED hardcoded background color. Window material handled by the system.
//   • Text colors use semantic .primary / .secondary / .tertiary.
//   • Dividers are native Divider().

import SwiftUI
import HydraCore

struct AboutView: View {
    var body: some View {
        VStack(spacing: 20) {
            // Logo
            BrandMark(size: 56)

            // Identity
            VStack(spacing: 4) {
                Text("Hydra")
                    .font(.title.weight(.bold))
                Text("Version \(Hydra.versionString)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Patch bay · per-app capture · AES67 · NDI · VST3 · OSC")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Legal notices
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("License") {
                        Text("""
                        Hydra is free software: you can redistribute it and/or modify it under the terms of \
                        the GNU General Public License, version 3, as published by the Free Software Foundation. \
                        Hydra is distributed WITHOUT ANY WARRANTY; without even the implied warranty of \
                        MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. The complete license text ships \
                        with the app (LICENSE file in the project folder).
                        """)
                        HStack(spacing: 14) {
                            Link("GPL-3.0 full text",
                                 destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
                            Link("Source code",
                                 destination: URL(string: Hydra.sourceURL)!)
                        }
                        .font(.caption.weight(.semibold))
                    }

                    section("Third-party components") {
                        credit(
                            name: "BlackHole — Existential Audio Inc.",
                            detail: "The \"Hydra Virtual Soundcard\" backplane is a customized BlackHole driver. GPL-3.0, same as Hydra.",
                            url: "https://github.com/ExistentialAudio/BlackHole")
                        credit(
                            name: "VST 3 SDK — Steinberg Media Technologies GmbH",
                            detail: "Plugin hosting uses the VST 3 SDK under its GPLv3 licensing option. VST® is a registered trademark of Steinberg Media Technologies GmbH, registered in Europe and other countries.",
                            url: "https://github.com/steinbergmedia/vst3sdk")
                        credit(
                            name: "NDI® — Vizrt NDI AB",
                            detail: "NDI® is a registered trademark of Vizrt NDI AB. The proprietary NDI runtime is NOT distributed with Hydra: it is loaded dynamically at run time, after the user installs Vizrt's official redistributable. Without it, NDI features stay off and everything else works.",
                            url: "https://ndi.video")
                    }

                    section("Open standards") {
                        Text("""
                        AES67 (audio-over-IP interoperability, including Dante® devices with AES67 mode enabled) \
                        and OSC (Open Sound Control) are open specifications — no SDK or license involved; Hydra \
                        implements them from scratch. Dante® is a registered trademark of Audinate Pty Ltd; \
                        Hydra is not affiliated with, or certified by, Audinate.
                        """)
                    }

                    Text("Naming devices is product UX; hiding the origin of components is not. Full notices: THIRD_PARTY_NOTICES.md.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 340)
        }
        .padding(28)
        .frame(width: 460)
    }

    // MARK: - Helpers

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            content()
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func credit(name: String, detail: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let link = URL(string: url) {
                Link(name, destination: link)
                    .font(.caption.weight(.semibold))
            } else {
                Text(name).font(.caption.weight(.semibold))
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
