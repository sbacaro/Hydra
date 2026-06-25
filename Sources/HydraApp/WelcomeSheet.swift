// Hydra Audio — GPL-3.0
// WelcomeSheet — first-run onboarding. Five steps; the penultimate one installs
// the Soundcard driver and the NDI runtime (see InstallManager). Reopenable from
// Help ▸ "Boas-vindas ao Hydra…".

import SwiftUI
import HydraCore

struct WelcomeSheet: View {
    @Environment(DaemonClient.self) private var client
    @EnvironmentObject private var daemon: DaemonService
    @StateObject private var install = InstallManager()
    @Environment(\.dismiss) private var dismiss

    /// Set true once the user finishes so we don't auto-present again.
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    @State private var step = 0
    private let lastStep = 4

    var body: some View {
        VStack(spacing: 0) {
            progressDots
                .padding(.top, 22)
                .padding(.bottom, 8)

            // Content
            Group {
                switch step {
                case 0: welcomeStep
                case 1: howItWorksStep
                case 2: permissionsStep
                case 3: installStep
                default: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 36)
            .transition(.opacity)

            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 560, height: 560)
    }

    // MARK: - Step indicator

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0...lastStep, id: \.self) { i in
                Capsule()
                    .fill(i == step ? Theme.accent : Color.secondary.opacity(0.25))
                    .frame(width: i == step ? 22 : 7, height: 7)
                    .animation(.easeInOut(duration: 0.2), value: step)
            }
        }
        .accessibilityLabel("Step \(step + 1) of \(lastStep + 1)")
    }

    // MARK: - Step 1 · Welcome

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 12)
            BrandMark(size: 72)
            VStack(spacing: 8) {
                Text("Welcome to Hydra")
                    .font(.largeTitle.weight(.bold))
                Text("Version \(Hydra.versionString)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("A complete audio patch bay for your Mac: route any source to any destination, capture the sound of individual apps, and connect over the network with AES67, NDI and VST3.")
            .font(.body)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            LanguagePicker()
                .padding(.top, 4)
            Spacer()
        }
    }

    // MARK: - Step 2 · How it works

    private var howItWorksStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            stepHeader("How it works", subtitle: "The building blocks you'll use day to day.")
            VStack(alignment: .leading, spacing: 16) {
                featureRow("rectangle.connected.to.line.below", "Patch bay",
                           "Connect inputs and outputs in a visual matrix. Click a cell to create a patch.")
                featureRow("waveform.badge.mic", "Per-app capture",
                           "Record the audio of a specific app without mixing it with the rest of the system.")
                featureRow("network", "Network audio",
                           "AES67 (including Dante in AES67 mode) and NDI carry sound to other machines on the network.")
                featureRow("pianokeys", "VST3 & OSC",
                           "Host VST3 plugins in the signal path and control everything remotely over OSC.")
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - Step 3 · Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            stepHeader("Permissions", subtitle: "Two macOS authorizations Hydra needs.")
            VStack(alignment: .leading, spacing: 16) {
                featureRow("wifi", "Local Network",
                           "The first time the audio engine runs, macOS asks for Local Network access — click Allow to discover AES67 and NDI devices.")
                permissionRow
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    private var permissionRow: some View {
        HStack(alignment: .top, spacing: 14) {
            icon("arrow.right.circle")
            VStack(alignment: .leading, spacing: 6) {
                Text("Start at login")
                    .font(.headline)
                Text("Let Hydra open at login so your routing is ready automatically. Enable it in Login Items.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Open Login Items…") { daemon.openLoginItemsSettings() }
                        .buttonStyle(.bordered)
                    if daemon.isEnabled {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Theme.live)
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Step 4 · Install (penultimate)

    private var installStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            stepHeader("Installation", subtitle: "Let's install the two remaining components.")

            VStack(spacing: 14) {
                installRow(
                    icon: "externaldrive.connected.to.line.below",
                    title: "Hydra Audio Bridges",
                    detail: "The audio engine driver (HAL plug-in). Asks for your administrator password.",
                    phase: install.driver,
                    doneText: driverDone ? "Installed" : "Done",
                    retry: { install.installDriver(skipIfPresent: false) }
                )
                installRow(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "NDI Runtime",
                    detail: "Opens Vizrt's official installer. By license (GPL), Hydra never bundles the runtime.",
                    phase: install.ndi,
                    doneText: "Installer opened",
                    retry: { install.installNDI(skipIfPresent: false) }
                )
            }

            if install.isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Installing… this may take a few seconds.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.top, 8)
        .onAppear {
            // Auto-start once when the step is shown.
            if install.driver == .idle && install.ndi == .idle {
                install.installAll(
                    driverAlreadyInstalled: driverDone,
                    ndiAlreadyInstalled: client.ndi.runtimeAvailable
                )
            }
        }
    }

    /// Live signal that the backplane is already present.
    private var driverDone: Bool { client.status?.backplaneInstalled == true }

    // MARK: - Step 5 · Done

    private var doneStep: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 12)
            ZStack {
                Circle().fill(Theme.live.opacity(0.15)).frame(width: 92, height: 92)
                Image(systemName: "checkmark")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(Theme.live)
            }
            Text("All set!")
                .font(.largeTitle.weight(.bold))
            Text("Hydra is configured. Open Audio MIDI Setup to see your Hydra Audio Bridges, or start creating patches right away.")
            .font(.body)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            Spacer()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { withAnimation { step -= 1 } }
                    .buttonStyle(.bordered)
            }
            Spacer()
            if step < lastStep {
                Button("Skip") { finish() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                Button(step == 3 ? "Continue" : "Next") { withAnimation { step += 1 } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(install.isBusy && step == 3)
            } else {
                Button("Get Started") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func finish() {
        hasSeenWelcome = true
        dismiss()
    }

    // MARK: - Building blocks

    private func stepHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title.weight(.bold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func featureRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            icon(symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(Theme.accent)
            .frame(width: 28, alignment: .center)
            .symbolRenderingMode(.hierarchical)
    }

    private func installRow(icon symbol: String,
                            title: String,
                            detail: String,
                            phase: InstallManager.Phase,
                            doneText: String,
                            retry: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            icon(symbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .failed(let message) = phase {
                    HStack(spacing: 8) {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try Again", action: retry)
                            .buttonStyle(.link)
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            phaseBadge(phase, doneText: doneText)
                .padding(.top, 2)
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 0.5))
    }

    @ViewBuilder
    private func phaseBadge(_ phase: InstallManager.Phase, doneText: String) -> some View {
        switch phase {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case .success:
            Label(doneText, systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.live)
        case .skipped:
            Label("Already installed", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.live)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
        }
    }
}
