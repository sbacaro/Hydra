// Hydra Audio — GPL-3.0
// A reusable, HIG-correct search field for any custom layout.
//
// Wraps AppKit's NSSearchField — the standard macOS search control — so we get
// the magnifying-glass affordance, the built-in clear ("×") button, the rounded
// search appearance, and reliable click-to-focus across the whole control, for
// free. Hand-rolled "magnifyingglass + TextField" boxes lacked the clear button
// and only focused on the tiny text region (HIG: a search field should look and
// behave like the system search field). Placeholder text is sentence case with
// no trailing punctuation, per the HIG.

import SwiftUI
import AppKit

struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String = "Search"

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.sendsWholeSearchString = false        // update as the user types
        field.sendsSearchStringImmediately = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        // Keep it from stretching vertically inside HStacks.
        field.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != prompt { field.placeholderString = prompt }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
