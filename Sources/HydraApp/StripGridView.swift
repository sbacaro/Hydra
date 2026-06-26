import SwiftUI
import AppKit
import HydraCore

/// In/out peak levels for one channel strip (linear amplitude).
/// Populated from the daemon's strip-meter broadcasts; zero when no data yet.
struct StripMeters {
    var inPeak: Float = 0
    var outPeak: Float = 0
}

struct StripGridView: View {
    @Environment(DaemonClient.self) private var client
    
    let columns = [
        GridItem(.adaptive(minimum: 260, maximum: 320), spacing: 16, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            if client.strips.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(client.strips) { strip in
                        StripCardView(strip: strip)
                            .id(strip.id)
                    }
                }
                .padding(16)
                .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: client.strips.count)
    }
    
    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 72, weight: .thin))
                .foregroundStyle(.tertiary)
            
            VStack(spacing: 8) {
                Text("No Channel Strips")
                    .font(.system(size: 18, weight: .semibold))
                
                Text("Create one by adding inserts to the matrix")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StripCardView: View {
    @Environment(DaemonClient.self) private var client
    let strip: StripInfo
    @State private var showInsertPicker = false
    @State private var isHovering = false
    
    var meters: StripMeters {
        client.stripMeters[strip.id] ?? StripMeters()
    }

    var body: some View {
        VStack(spacing: 0) {
            stripHeader
            Divider().background(.separator)
            
            if strip.inserts.isEmpty {
                emptyInsertsState
            } else {
                insertsList
            }
            
            Divider().background(.separator)
            metersAndControlsSection
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 0.5))
        .onHover { isHovering = $0 }
    }
    
    private var stripHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: strip.stereo ? "speaker.2" : "speaker.1")
                        .font(.system(size: 11, weight: .semibold))
                    Text(strip.key)
                        .font(.system(size: 13, weight: .bold))
                        .monospacedDigit()
                }
                .foregroundStyle(.primary)
                
                Text(channelDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if isHovering {
                Button(action: {}) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(12)
    }
    
    private var channelDescription: String {
        let ch = strip.channelIndex + 1
        if strip.stereo {
            return "Stereo (Ch \(ch)–\(ch + 1))"
        }
        return "Mono (Ch \(ch))"
    }
    
    private var emptyInsertsState: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No inserts")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Button(action: { showInsertPicker = true }) {
                Label("Add Insert", systemImage: "plus.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .sheet(isPresented: $showInsertPicker) {
            PluginPickerSheet(strip: strip)
        }
    }
    
    private var insertsList: some View {
        VStack(spacing: 0) {
            ForEach(strip.inserts.indices, id: \.self) { index in
                InsertRowView(strip: strip, index: index)
                if index < strip.inserts.count - 1 {
                    Divider().background(.separator)
                }
            }
            
            Divider().background(.separator)
            
            Button(action: { showInsertPicker = true }) {
                Label("Add Another", systemImage: "plus.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(10)
            .sheet(isPresented: $showInsertPicker) {
                PluginPickerSheet(strip: strip)
            }
        }
    }
    
    private var metersAndControlsSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                MeterColumn(label: "IN", peak: meters.inPeak)
                MeterColumn(label: "OUT", peak: meters.outPeak)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("TRIM")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f dB", linearToDb(strip.trim)))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                
                Slider(value: Binding(
                    get: { Double(strip.trim) },
                    set: { value in
                        var updated = strip
                        updated.trim = Float(max(0.001, min(4, value)))
                        client.setStrip(updated)
                    }
                ), in: 0.001...4)
                    .tint(Theme.accent)
            }
            
            Spacer(minLength: 0)
        }
        .padding(12)
    }
}

struct InsertRowView: View {
    @Environment(DaemonClient.self) private var client
    let strip: StripInfo
    let index: Int
    @State private var isHovering = false
    
    var plugin: VSTPlugin {
        index < strip.inserts.count ? strip.inserts[index] : VSTPlugin(id: "", name: "?", vendor: "")
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                
                Text(plugin.vendor)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            HStack(spacing: 6) {
                Button(action: {
                    client.openPluginEditor(stripID: strip.id, index: index,
                                            pinned: NSEvent.modifierFlags.contains(.shift))
                }) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(isHovering ? Theme.accent : .secondary)
                
                Button(action: {
                    var updated = strip
                    // Guard: a daemon echo may have shrunk the array between
                    // render and tap (ForEach uses indices as identity).
                    guard updated.inserts.indices.contains(index) else { return }
                    updated.inserts.remove(at: index)
                    client.setStrip(updated)
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(isHovering ? Theme.clip : .secondary)
            }
        }
        .padding(10)
        .background(isHovering ? Color(.controlBackgroundColor) : .clear)
        .cornerRadius(6)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }
}

struct MeterColumn: View {
    let label: String
    let peak: Float
    
    var color: Color {
        if peak > 1 { return Theme.clip }
        if peak > 0.7 { return Theme.warning }
        return Theme.live
    }

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Color(.controlBackgroundColor)
                    
                    LinearGradient(
                        gradient: Gradient(colors: [color, color.opacity(0.6)]),
                        startPoint: .bottom,
                        endPoint: .top
                    )
                    .frame(height: geo.size.height * CGFloat(min(peak, 1)))
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 48)
            
            Text(String(format: "%.1f dB", linearToDb(peak)))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }
}

private func linearToDb(_ linear: Float) -> Float {
    20 * log10(max(linear, 1e-7))
}
