import SwiftUI
import HydraCore

struct PluginPickerSheet: View {
    @Environment(DaemonClient.self) private var client
    let strip: StripInfo
    @Environment(\.dismiss) var dismiss
    @State private var searchText = ""
    @State private var selectedCategory: String? = nil
    @State private var showOnlyFavorites = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                BrandMark(size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Insert")
                        .font(.system(size: 16, weight: .bold))
                    Text("to \(strip.key)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            Divider()
            
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    SearchField(text: $searchText, prompt: "Search")

                    Toggle(isOn: $showOnlyFavorites) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11))
                    }
                    .toggleStyle(.checkbox)
                }
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(allCategories, id: \.self) { cat in
                            Button(action: {
                                selectedCategory = (selectedCategory == cat) ? nil : cat
                            }) {
                                Text(cat)
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(selectedCategory == cat ? Theme.accent : Color(.controlBackgroundColor))
                                    .foregroundStyle(selectedCategory == cat ? .white : .primary)
                                    .cornerRadius(12)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(12)
            Divider()
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(filteredPlugins) { plugin in
                        pluginRow(plugin)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                var updated = strip
                                updated.inserts.append(plugin)
                                let newIndex = updated.inserts.count - 1
                                client.setStrip(updated)
                                // Open the plugin's editor right away — adding an
                                // insert should show its window, no extra click.
                                // setStrip + openEditor run in order on the daemon's
                                // serial queue, so the instance exists by then.
                                client.openPluginEditor(stripID: strip.id, index: newIndex)
                                dismiss()
                            }
                    }
                }
                .padding(12)
            }
            
            if client.vst.scanning {
                Divider()
                HStack(spacing: 8) {
                    ProgressView(value: client.vst.scanProgress)
                        .tint(Theme.accent)
                    Text(client.vst.scanLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }
        }
        .frame(minWidth: 420, minHeight: 550)
    }
    
    private var allCategories: [String] {
        let all = Set(client.vst.available.map(\.primaryType))
        return Array(all).sorted()
    }
    
    private var filteredPlugins: [VSTPlugin] {
        client.vst.pickerPlugins()
            .filter { plugin in
                if !searchText.isEmpty {
                    // Fuzzy (subsequence) match over name + vendor + category, so
                    // the search is forgiving: "fbpro" finds "FabFilter Pro-Q",
                    // "cheq" finds "Channel EQ".
                    let haystack = "\(plugin.name) \(plugin.vendor) \(plugin.category)"
                    if !haystack.fuzzyMatches(searchText) { return false }
                }
                
                if let cat = selectedCategory, plugin.primaryType != cat {
                    return false
                }
                
                if showOnlyFavorites {
                    return client.vst.favoriteIDs.contains(plugin.id)
                }
                
                return true
            }
    }
    
    private func pluginRow(_ plugin: VSTPlugin) -> some View {
        let isFavorite = client.vst.favoriteIDs.contains(plugin.id)
        
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(plugin.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    
                    if plugin.offline {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.warning)
                    }
                }
                
                HStack(spacing: 8) {
                    Text(plugin.vendor)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    
                    if !plugin.category.isEmpty {
                        Text(plugin.category)
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.controlBackgroundColor))
                            .cornerRadius(3)
                    }
                }
            }
            
            Spacer()
            
            Button(action: {
                client.setPluginFavorite(id: plugin.id, favorite: !isFavorite)
            }) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(isFavorite ? Theme.accent : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }
}
