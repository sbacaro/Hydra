// Hydra Audio — GPL-3.0
// Design tokens for the final UI (user-approved prototype, 2026-06).
// Apple dark-mode palette, Logic Pro aesthetic. The Hydra BRAND mark keeps
// its indigo gradient; everywhere else the action color is system blue.

import SwiftUI

enum Theme {
    // Action / selection (Logic-style)
    static let accent = Color(red: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255) // systemBlue
    static let accentBright = Color(red: 0x3B / 255, green: 0x9E / 255, blue: 0xFF / 255)

    // Status
    static let live = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)   // systemGreen
    static let warning = Color(red: 1.0, green: 0x9F / 255, blue: 0x0A / 255)       // systemOrange
    static let clip = Color(red: 1.0, green: 0x45 / 255, blue: 0x3A / 255)          // systemRed
    static let meterYellow = Color(red: 1.0, green: 0xD6 / 255, blue: 0x0A / 255)   // systemYellow

    // Brand (logo mark only)
    static let brandGradient = LinearGradient(
        colors: [Color(red: 0x7D / 255, green: 0x7A / 255, blue: 0xFF / 255),
                 Color(red: 0x58 / 255, green: 0x56 / 255, blue: 0xD6 / 255),
                 Color(red: 0x3F / 255, green: 0x3D / 255, blue: 0xA8 / 255)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    // Surfaces
    static let backgroundGradient = RadialGradient(
        colors: [Color(red: 0x0D / 255, green: 0x12 / 255, blue: 0x20 / 255),
                 Color(red: 0x08 / 255, green: 0x08 / 255, blue: 0x10 / 255),
                 Color(red: 0x04 / 255, green: 0x04 / 255, blue: 0x0A / 255)],
        center: .top, startRadius: 0, endRadius: 900)
    static let panel = Color.white.opacity(0.045)
    static let hairline = Color.white.opacity(0.08)

    // Text
    static let textPrimary = Color.white.opacity(0.88)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.30)
}

/// The Hydra brand mark — the only place indigo survives in the UI.
struct BrandMark: View {
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26)
            .fill(Theme.brandGradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "waveform.path")
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: Color(red: 0x58 / 255, green: 0x56 / 255, blue: 0xD6 / 255).opacity(0.45),
                    radius: 5)
    }
}
