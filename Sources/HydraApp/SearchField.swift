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

// MARK: - Fuzzy matching

extension StringProtocol {
    /// Case- and diacritic-insensitive fuzzy match. The query is split into
    /// whitespace tokens; each token must appear as an in-order subsequence of the
    /// receiver, but tokens may match in ANY order and anywhere. So word order and
    /// extra spaces stop mattering: "fbpro", "proq fab" and "fab proq" all find
    /// "FabFilter Pro-Q", and "cheq" finds "Channel EQ". Empty query matches all.
    func fuzzyMatches(_ query: String) -> Bool {
        func fold(_ s: String) -> [Character] {
            Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive],
                            locale: .current))
        }
        let tokens = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
        guard !tokens.isEmpty else { return true }
        let hay = fold(String(self)).filter { !$0.isWhitespace }
        for needle in tokens where !needle.isEmpty {
            var n = 0
            for ch in hay where ch == needle[n] {
                n += 1
                if n == needle.count { break }
            }
            if n != needle.count { return false }
        }
        return true
    }
}
