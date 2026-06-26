// Hydra Audio — GPL-3.0
// IconPack — the SINGLE source of the Hydra brand mark.
//
// Everything that shows the logo comes from here:
//   • the app icon and the plugin-host icon are rasterised PNGs in their asset
//     catalogs (Media.xcassets / hydra-plugin-host Assets.xcassets), generated
//     from this exact waveform + gradient;
//   • every in-app appearance uses the `BrandMark` view below (Welcome, About,
//     the menu-bar panel, the sidebar header, the plugin picker).
//
// To restyle the logo, change it here (and re-run the icon generator for the
// rasterised app/host icons) — there is no second definition anywhere.

import SwiftUI
import AppKit

enum IconPack {
    /// The icon's background — Apple "Space Black" effect: a deep near-black
    /// charcoal with a faint warm undertone (anodised aluminium), lighter top →
    /// darker bottom. Matches the rasterised app/host icons exactly.
    static let backgroundGradient = LinearGradient(
        colors: [Color(red: 54 / 255, green: 52 / 255, blue: 50 / 255),
                 Color(red: 20 / 255, green: 19 / 255, blue: 18 / 255)],
        startPoint: .top, endPoint: .bottom)

    /// The waveform colour.
    static let waveColor = Color.white

    /// Corner radius as a fraction of the mark's size (matches the rasterised icon).
    static let cornerFraction: CGFloat = 0.225
}

/// The Hydra waveform centreline — the exact wave used by the rasterised app and
/// host icons, so the in-app mark and the OS icons are visually identical.
struct WaveMark: Shape {
    var widthFraction: CGFloat = 0.70
    var ampFraction: CGFloat = 0.25

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width * widthFraction
        let x0 = rect.midX - w / 2, x1 = rect.midX + w / 2
        let amp = rect.height * ampFraction
        let cy = rect.midY
        let n = 180
        for i in 0...n {
            let u = Double(i) / Double(n)
            let env = 0.30 + 0.70 * pow(sin(.pi * u), 0.55)
            let x = x0 + (x1 - x0) * CGFloat(u)
            let y = cy - amp * CGFloat(env * sin(2 * .pi * 2.5 * u))
            let pt = CGPoint(x: x, y: y)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

/// The Hydra logo: the dark-gray gradient surface with the white waveform.
struct BrandMark: View {
    var size: CGFloat = 20

    var body: some View {
        let r = size * IconPack.cornerFraction
        RoundedRectangle(cornerRadius: r, style: .continuous)
            .fill(IconPack.backgroundGradient)
            .overlay(
                WaveMark()
                    .stroke(IconPack.waveColor,
                            style: StrokeStyle(lineWidth: size * 0.062,
                                               lineCap: .round, lineJoin: .round))
            )
            // Faint top hairline, echoing the icon's glass sheen.
            .overlay(
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: max(size * 0.012, 0.5))
            )
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.25), radius: size * 0.06, y: size * 0.02)
    }
}

extension IconPack {
    /// The waveform as a monochrome **menu-bar template image** — the same wave as
    /// the brand mark, but full-bleed (no rounded surface) and sized for the menu
    /// bar. Being a template, macOS tints it with the bar (and turns it white when
    /// the menu item is highlighted), exactly like an SF Symbol.
    static func menuBarWave(height: CGFloat = 16) -> NSImage {
        let w = (height * 1.7).rounded()
        let image = NSImage(size: NSSize(width: w, height: height))
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            // SwiftUI Path uses a top-left origin (y down); the NSImage context is
            // bottom-left (y up) — flip so the wave isn't drawn upside down.
            ctx.translateBy(x: 0, y: height)
            ctx.scaleBy(x: 1, y: -1)
            let rect = CGRect(x: 0, y: 0, width: w, height: height)
            let path = WaveMark(widthFraction: 0.96, ampFraction: 0.42).path(in: rect).cgPath
            ctx.setStrokeColor(NSColor.labelColor.cgColor)   // ignored for a template
            ctx.setLineWidth(max(height * 0.13, 1.3))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.strokePath()
        }
        image.unlockFocus()
        image.isTemplate = true   // tinted by the menu bar / highlight
        return image
    }
}
