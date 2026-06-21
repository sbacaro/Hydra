// Hydra Audio — GPL-3.0
// Type-first creation form: picking a template pre-fills name, channels and
// NDI TX (all still editable). In and Out are sized independently —
// e.g. an AES67 return of 128 in × 2 out.

import SwiftUI
import HydraCore

struct AddInterfaceForm: View {
    @Environment(DaemonClient.self) private var client
    @Environment(\.dismiss) private var dismiss

    private struct Template: Identifiable {
        let id: String
        let icon: String
        let name: String
        let inCh: Int
        let outCh: Int
        let ndiTX: Bool
        let aesTX: Bool
        let hint: String
    }

    private static let templates: [Template] = [
        Template(id: "custom", icon: "slider.horizontal.3", name: "",
                 inCh: 2, outCh: 2, ndiTX: false, aesTX: false,
                 hint: "Blank — name it and size each side yourself."),
        Template(id: "daw", icon: "pianokeys", name: "DAW",
                 inCh: 32, outCh: 32, ndiTX: false, aesTX: false,
                 hint: "A DAW playing into Hydra and recording stems back."),
        Template(id: "obs", icon: "record.circle", name: "OBS",
                 inCh: 2, outCh: 2, ndiTX: false, aesTX: false,
                 hint: "Stream/recording app: monitor in, mixed program out."),
        Template(id: "aes67", icon: "network", name: "AES67 Stage",
                 inCh: 64, outCh: 2, ndiTX: false, aesTX: true,
                 hint: "Network audio: receive many channels, send a return — announced on the network from the start."),
        Template(id: "ndi", icon: "antenna.radiowaves.left.and.right", name: "NDI Feed",
                 inCh: 0, outCh: 2, ndiTX: true, aesTX: false,
                 hint: "Broadcasts what you route into it as an NDI source.")
    ]

    @State private var templateID = "custom"
    @State private var name = ""
    @State private var inChannels = 2
    @State private var outChannels = 2
    @State private var ndiTX = false
    @State private var aes67TX = false

    private let options = [0, 1, 2, 4, 6, 8, 16, 32, 64, 128]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Virtual Interface")
                    .font(.title3.weight(.semibold))
                Text("A named slice of the soundcard's channel pool.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Type — a template pre-fills the fields below.
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Type")
                HStack(spacing: 8) {
                    ForEach(Self.templates) { templateChip($0) }
                }
            }

            // Name
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Name")
                TextField("e.g. DAW, Stage, Stream", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .onSubmit(create)
            }

            // Channels — In = what software plays into Hydra; Out = what it records.
            HStack(spacing: 24) {
                channelPicker("Inputs", selection: $inChannels,
                              help: "Lanes other software plays INTO (grid rows)")
                channelPicker("Outputs", selection: $outChannels,
                              help: "Lanes other software records FROM (grid columns)")
                Spacer()
            }

            // Options
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Options")
                Toggle("Announce on the network (AES67 TX)", isOn: $aes67TX)
                    .disabled(outChannels == 0)
                    .help("The Out side is announced via SAP and sent as multicast RTP — appears in Dante Controller. Experimental until PTP sync lands.")
                Toggle("Broadcast as NDI source (TX)", isOn: $ndiTX)
                    .disabled(!client.ndi.runtimeAvailable || outChannels == 0)
                    .help(client.ndi.runtimeAvailable
                          ? "What you route to this interface's Out channels goes out on the network as NDI"
                          : "Requires the NDI runtime — see the Network tab")
            }
            .toggleStyle(.checkbox)
            .font(.callout)

            Divider()

            HStack(spacing: 8) {
                Text("\(client.allocatedInChannels + inChannels)/\(Hydra.poolChannels) TX · \(client.allocatedOutChannels + outChannels)/\(Hydra.poolChannels) RX")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("Independent pools: \(Hydra.poolChannels) transmitter and \(Hydra.poolChannels) receiver channels.")
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty ||
                              inChannels + outChannels == 0 ||
                              client.allocatedInChannels + inChannels > Hydra.poolChannels ||
                              client.allocatedOutChannels + outChannels > Hydra.poolChannels)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func templateChip(_ template: Template) -> some View {
        let selected = templateID == template.id
        return Button {
            templateID = template.id
            name = template.name
            inChannels = template.inCh
            outChannels = template.outCh
            ndiTX = template.ndiTX && client.ndi.runtimeAvailable
            aes67TX = template.aesTX
        } label: {
            VStack(spacing: 4) {
                Image(systemName: template.icon)
                    .font(.system(size: 15))
                Text(template.id == "custom" ? "Custom" : template.name.components(separatedBy: " ")[0])
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(selected ? Color.accentColor : .secondary)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.2),
                        lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(template.hint)
    }

    private func channelPicker(_ label: String, selection: Binding<Int>, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel(label)
            Picker(label, selection: selection) {
                ForEach(options, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 84)
        }
        .help(help)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, inChannels + outChannels > 0 else { return }
        // Channels are created mono; stereo pairs are linked later in the
        // channel strip (console-style odd+even).
        client.createInterface(name: trimmed, inChannels: inChannels,
                               outChannels: outChannels, ndiTX: ndiTX, aes67TX: aes67TX)
        dismiss()
    }
}
