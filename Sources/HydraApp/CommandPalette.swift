// Hydra Audio — GPL-3.0
// ⌘K command palette (Phase 7): fuzzy-searchable actions over everything
// the app can do without a pointer — tabs, view modes, scenes, recordings,
// TX toggles, plugin scan, folders, settings.

import SwiftUI
import AppKit
import HydraCore

struct PaletteAction: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let run: () -> Void
}

struct CommandPalette: View {
    @EnvironmentObject private var client: DaemonClient
    @Binding var isPresented: Bool
    @Binding var sidebarTab: SidebarTab
    @Binding var sidebarVisible: Bool

    @AppStorage("patchViewMode") private var viewMode = "grid"
    @AppStorage("groupChannels") private var groupChannels = false
    @Environment(\.openSettings) private var openSettings

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    // MARK: Actions

    private var actions: [PaletteAction] {
        var list: [PaletteAction] = []
        for tab in SidebarTab.allCases {
            list.append(PaletteAction(
                id: "tab-\(tab.rawValue)", title: "Go to \(tab.rawValue)",
                subtitle: "Sidebar", icon: "sidebar.left") {
                    sidebarTab = tab
                    sidebarVisible = true
                })
        }
        list.append(PaletteAction(
            id: "view-toggle",
            title: viewMode == "grid" ? "Switch to List view" : "Switch to Grid view",
            subtitle: "Patch view", icon: "rectangle.grid.2x2") {
                viewMode = viewMode == "grid" ? "list" : "grid"
            })
        list.append(PaletteAction(
            id: "groups-toggle",
            title: groupChannels ? "Ungroup channels" : "Group channels in banks of 8",
            subtitle: "Patch view", icon: "square.stack.3d.up") {
                groupChannels.toggle()
            })
        for scene in client.scenes {
            list.append(PaletteAction(
                id: "scene-\(scene.id)", title: "Apply scene “\(scene.name)”",
                subtitle: "Scenes", icon: "square.on.square") {
                    client.applyScene(scene.id)
                })
        }
        for iface in client.interfaces {
            let recording = client.recordings.contains { $0.interfaceID == iface.id }
            if iface.outChannels > 0 {
                list.append(PaletteAction(
                    id: "rec-\(iface.id)",
                    title: recording ? "Stop recording “\(iface.name)”"
                                     : "Record “\(iface.name)”",
                    subtitle: "Recording", icon: recording ? "stop.circle" : "record.circle") {
                        recording ? client.stopRecording(iface.id) : client.startRecording(iface.id)
                    })
                list.append(PaletteAction(
                    id: "aes-\(iface.id)",
                    title: "\(iface.aes67TX ? "Disable" : "Enable") AES67 TX on “\(iface.name)”",
                    subtitle: "Network", icon: "dot.radiowaves.left.and.right") {
                        client.setInterfaceAES67(iface.id, enabled: !iface.aes67TX)
                    })
                list.append(PaletteAction(
                    id: "ndi-\(iface.id)",
                    title: "\(iface.ndiTX ? "Disable" : "Enable") NDI TX on “\(iface.name)”",
                    subtitle: "Network", icon: "antenna.radiowaves.left.and.right") {
                        client.setInterfaceNDI(iface.id, enabled: !iface.ndiTX)
                    })
            }
        }
        list.append(PaletteAction(
            id: "vst-scan", title: "Scan VST3 plugins",
            subtitle: "Plug-ins", icon: "magnifyingglass") {
                client.scanVST()
            })
        list.append(PaletteAction(
            id: "settings", title: "Open Settings…",
            subtitle: "App", icon: "gearshape") {
                openSettings()
            })
        list.append(PaletteAction(
            id: "recordings-folder", title: "Open recordings folder",
            subtitle: "App", icon: "folder") {
                let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
                NSWorkspace.shared.open(music.appendingPathComponent("Hydra Recordings"))
            })
        return list
    }

    private var filtered: [PaletteAction] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return actions }
        // Fuzzy: every query token must appear in title or subtitle.
        let tokens = trimmed.split(separator: " ")
        return actions.filter { action in
            let haystack = "\(action.title) \(action.subtitle)".lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                TextField("Type a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($fieldFocused)
                    .onSubmit { runHighlighted() }
            }
            .padding(12)

            Divider().overlay(Theme.Grid.separator)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, action in
                            Button {
                                run(action)
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: action.icon)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18)
                                    Text(action.title)
                                        .font(.system(size: 13))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(action.subtitle)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 7)
                                    .fill(index == highlighted ? Theme.accent.opacity(0.22) : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(action.id)
                        }
                        if filtered.isEmpty {
                            Text("Nothing matches “\(query)”.")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                                .padding(14)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 320)
                .onChange(of: highlighted) { _, index in
                    if let action = filtered[safe: index] {
                        proxy.scrollTo(action.id)
                    }
                }
            }
        }
        .frame(width: 480)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Grid.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        .onAppear {
            query = ""
            highlighted = 0
            fieldFocused = true
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(filtered.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
        .onExitCommand { isPresented = false }
    }

    private func runHighlighted() {
        if let action = filtered[safe: highlighted] {
            run(action)
        }
    }

    private func run(_ action: PaletteAction) {
        action.run()
        isPresented = false
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
