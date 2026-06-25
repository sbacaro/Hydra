// Hydra Audio — GPL-3.0
// Design tokens — Apple-standard adaptive palette (macOS 26 Liquid Glass).
//
// Philosophy (Apple HIG — Color, Materials, Dark Mode, Accessibility):
//   • Status uses SYSTEM colors (.green/.orange/.red/.yellow). System colors
//     already ship light, dark and Increase-Contrast variants, so they adapt
//     for free — exactly what the Color and Dark Mode guidelines ask for.
//   • The action color is Color.accentColor, so Hydra follows the accent the
//     person chose in System Settings instead of a hard-coded blue (the Color
//     guideline explicitly warns against hard-coding system color values).
//   • Semantic colors (.primary/.secondary/.tertiary) are used directly at the
//     call sites for everything outside the Canvas-rendered patch grid.
//   • The patch grid is drawn in a Canvas, where hierarchical/semantic styles
//     can't be resolved at paint time, so Theme.Grid supplies EXPLICIT colors.
//     Those tokens are now appearance-adaptive (light + dark) via an NSColor
//     dynamic provider, giving the grid a true light and dark design.
//   • The brand mark is the only place indigo lives.

import SwiftUI
import AppKit

// MARK: - Adaptive token helpers
// An NSColor dynamic provider resolves per-appearance, so these concrete colors
// adapt to Light/Dark (and the Increase-Contrast variants the system derives)
// even inside a Canvas, where .primary/.secondary/.accentColor cannot resolve.

/// Neutral overlay: black at `light` alpha in Light Mode, white at `dark` alpha
/// in Dark Mode. Replaces the old white-opacity-on-dark-only tokens.
private func gridGray(light: CGFloat, dark: CGFloat) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: dark)
            : NSColor(white: 0, alpha: light)
    })
}

/// The user's system accent at a per-appearance alpha (selection fills/borders).
/// Uses `NSColor.controlAccentColor` so the grid follows the accent chosen in
/// System Settings. A concrete NSColor (unlike SwiftUI's `Color.accentColor`)
/// resolves correctly inside Canvas draw calls.
private func gridAccent(light: CGFloat, dark: CGFloat) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let a = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor.controlAccentColor.withAlphaComponent(a)
    })
}

enum Theme {

    // MARK: - Action
    // Follows the user's chosen system accent. Not used inside Canvas draw calls.
    static let accent = Color.accentColor

    // MARK: - Status (system colors — adapt to light/dark/Increase Contrast)
    static let live        = Color.green
    static let warning     = Color.orange
    static let clip        = Color.red
    static let meterYellow = Color.yellow

    // MARK: - Brand (logo mark only)
    static let brandGradient = LinearGradient(
        colors: [
            Color(red: 0x7D / 255, green: 0x7A / 255, blue: 0xFF / 255),
            Color(red: 0x58 / 255, green: 0x56 / 255, blue: 0xD6 / 255),
            Color(red: 0x3F / 255, green: 0x3D / 255, blue: 0xA8 / 255),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    // MARK: - Grid Canvas tokens (explicit, appearance-adaptive)
    // For use inside Canvas { } draw calls and the frozen-pane grid. Each token
    // carries a Light and a Dark value, so the patch grid renders correctly in
    // both appearances instead of assuming a near-black surface.
    enum Grid {
        // Apple-style: no box per cell. Rest is transparent; the grid reads as
        // content (dots) in space. Hover/crosshair tint with the ACCENT so the
        // hovered row+column orient you (Numbers-style), not a neutral gray.
        static let cellRest           = Color.clear
        static let cellHover          = gridAccent(light: 0.13, dark: 0.16)
        static let cellCrosshair      = gridAccent(light: 0.07, dark: 0.09)
        static let cellSelected       = gridAccent(light: 0.16, dark: 0.22)
        static let cellSelectedBorder = gridAccent(light: 0.55, dark: 0.55)
        static let patchDot           = Color(nsColor: .controlAccentColor)
        static let patchGhost         = gridGray(light: 0.32, dark: 0.25)
        static let separator          = gridGray(light: 0.10, dark: 0.09)
        static let groupHeader        = gridGray(light: 0.06, dark: 0.07)
        /// Faint band on alternating channel rows (Finder/Numbers scannability).
        static let rowBand            = gridGray(light: 0.022, dark: 0.032)
        /// Quiet fill behind group lanes (was groupHeader at 0.25 — too heavy).
        static let groupBand          = gridGray(light: 0.05, dark: 0.06)
        static let textPrimary        = gridGray(light: 0.85, dark: 0.88)
        static let textSecondary      = gridGray(light: 0.55, dark: 0.55)
        static let textTertiary       = gridGray(light: 0.40, dark: 0.30)
        static let signal             = Color(nsColor: .systemGreen)
        static let noSignal           = gridGray(light: 0.14, dark: 0.10)
        static let panel              = gridGray(light: 0.025, dark: 0.045)
        static let hairline           = gridGray(light: 0.12, dark: 0.08)
    }
}

// MARK: - Brand mark

/// The Hydra logo — the only place indigo survives in the UI.
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
            .shadow(
                color: Color(red: 0x58 / 255, green: 0x56 / 255, blue: 0xD6 / 255).opacity(0.45),
                radius: 5)
    }
}
