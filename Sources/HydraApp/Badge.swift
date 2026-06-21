// Hydra Audio — GPL-3.0
// A small, consistent pill badge ("sign") — e.g. a plug-in's type ("Fx"),
// an "Offline" marker, or a "TX on" tag. Unifies the hand-rolled
// Text + padding + Capsule pills that were scattered across the views so they
// share one padding/shape/tinting recipe. Tinted text on a faint tint fill,
// per the app's badge style.

import SwiftUI

struct Badge: View {
    let text: String
    var tint: Color = .secondary
    /// Denser variant for tight contexts (e.g. inline in the sidebar list).
    var small: Bool = false

    init(_ text: String, tint: Color = .secondary, small: Bool = false) {
        self.text = text
        self.tint = tint
        self.small = small
    }

    var body: some View {
        Text(text)
            .font(small ? .system(size: 9, weight: .bold) : .caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, small ? 5 : 6)
            .padding(.vertical, small ? 1 : 2)
            .background(tint.opacity(0.15), in: Capsule())
    }
}
