// Hydra Audio — GPL-3.0
// About / Legal — the app's Appropriate Legal Notices (GPL-3.0 §0/§5d):
// license statement, source availability, warranty disclaimer, and credits
// for every third-party component (mirrored in THIRD_PARTY_NOTICES.md).

import SwiftUI
import HydraCore

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            BrandMark(size: 56)

            VStack(spacing: 4) {
                Text("Hydra")
                    .font(.system(size: 26, weight: .bold))
                Text("Version \(Hydra.versionString)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Patch bay \u{00B7} per-app capture \u{00B7} AES67 \u{00B7} NDI \u{00B7} VST3 \u{00B7} OSC")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().overlay(Color.white.opacity(0.1))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("License") {
                        Text("Hydra is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License, version 3, as published by the Free Software Foundation. Hydra is distributed WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. The complete license text ships with the app (LICENSE file in the project folder).")
                        HStack(spacing: 14) {
                            Link("GPL-3.0 full text", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
                            Link("Source code", destination: URL(string: Hydra.sourceURL)!)
                        }
                        .font(.caption.weight(.semibold))
                    }

                    section("Third-party components") {
                        credit(name: "BlackHole \u{2014} Existential Audio Inc.",
                               detail: "The \u{201C}Hydra Virtual Soundcard\u{201D} backplane is a customized BlackHole driver. GPL-3.0, same as Hydra.",
                               url: "https://github.com/ExistentialAudio/BlackHole")
                        credit(name: "VST 3 SDK \u{2014} Steinberg Media Technologies GmbH",
                               detail: "Plugin hosting uses the VST 3 SDK under its GPLv3 licensing option. VST\u{00AE} is a registered trademark of Steinberg Media Technologies GmbH, registered in Europe and other countries.",
                               url: "https://github.com/steinbergmedia/vst3sdk")
                        credit(name: "NDI\u{00AE} \u{2014} Vizrt NDI AB",
                               detail: "NDI\u{00AE} is a registered trademark of Vizrt NDI AB. The proprietary NDI runtime is NOT distributed with Hydra: it is loaded dynamically at run time, after the user installs Vizrt's official redistributable. Without it, NDI features stay off and everything else works.",
                               url: "https://ndi.video")
                    }

                    section("Open standards") {
                        Text("AES67 (audio-over-IP interoperability, including Dante\u{00AE} devices with AES67 mode enabled) and OSC (Open Sound Control) are open specifications \u{2014} no SDK or license involved; Hydra implements them from scratch. Dante\u{00AE} is a registered trademark of Audinate Pty Ltd; Hydra is not affiliated with, or certified by, Audinate.")
                    }

                    Text("Naming devices is product UX; hiding the origin of components is not. Full notices: THIRD_PARTY_NOTICES.md.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
        }
        .padding(28)
        .frame(width: 460)
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
        .preferredColorScheme(.dark)
    }

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
        VStack(alignment: .leading, spacing: 2) {
            if let link = URL(string: url) {
                Link(name, destination: link)
                    .font(.caption.weight(.semibold))
            } else {
                Text(name).font(.caption.weight(.semibold))
            }
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
