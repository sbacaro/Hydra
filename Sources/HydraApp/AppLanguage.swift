// Hydra Audio — GPL-3.0
// In-app language override. The app is localized via the Localizable String
// Catalog (English base + translations); this lets the person force a specific
// language regardless of the system setting. The list is built dynamically from
// the languages actually compiled into the app (Bundle.main.localizations), so
// any language added to the catalog shows up here automatically — nothing to
// hardcode. macOS resolves the app's language from `AppleLanguages` at launch,
// so a change takes full effect after a relaunch (offered inline).

import SwiftUI
import AppKit

enum AppLanguageStore {
    static let key = "appLanguage"
    static let systemTag = "system"

    /// Language codes bundled in the app, minus the "Base" pseudo-localization,
    /// sorted by their endonym.
    static var availableCodes: [String] {
        Bundle.main.localizations
            .filter { $0 != "Base" }
            .sorted { endonym($0).localizedCaseInsensitiveCompare(endonym($1)) == .orderedAscending }
    }

    /// A language's name in its own language (e.g. "Português (Brasil)").
    static func endonym(_ code: String) -> String {
        let name = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        guard let first = name.first else { return code }
        return first.uppercased() + String(name.dropFirst())
    }

    /// Persist the choice into `AppleLanguages` so it survives relaunch.
    static func apply(_ code: String) {
        let defaults = UserDefaults.standard
        if code == systemTag {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([code], forKey: "AppleLanguages")
        }
    }

    /// Relaunch the app so the new language applies everywhere.
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", url.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// Reusable language control: a menu picker (System default + every bundled
/// language) plus an inline "relaunch to apply" affordance shown after a change.
/// Used in the Welcome flow and in Settings.
struct LanguagePicker: View {
    @AppStorage(AppLanguageStore.key) private var selected = AppLanguageStore.systemTag
    @State private var changed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: Binding(
                get: { selected },
                set: { newValue in
                    guard newValue != selected else { return }
                    selected = newValue
                    AppLanguageStore.apply(newValue)
                    changed = true
                })) {
                Text("System default").tag(AppLanguageStore.systemTag)
                ForEach(AppLanguageStore.availableCodes, id: \.self) { code in
                    Text(AppLanguageStore.endonym(code)).tag(code)
                }
            } label: {
                Label("Language", systemImage: "globe")
            }
            .pickerStyle(.menu)

            if changed {
                HStack(spacing: 8) {
                    Text("Relaunch to apply the new language.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Relaunch") { AppLanguageStore.relaunch() }
                        .controlSize(.small)
                }
            }
        }
    }
}
