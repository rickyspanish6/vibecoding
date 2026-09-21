import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var engine: StreamEngine
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if engine.permissionDenied {
                permissionBanner
            }

            Toggle("Route system audio", isOn: routingBinding)
                .toggleStyle(.switch)

            localSection
            speakersSection

            VStack(alignment: .leading, spacing: 4) {
                Label("Master volume", systemImage: "speaker.wave.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $engine.masterVolume, in: 0...1)
            }

            advancedSection

            if let alert = engine.alertMessage {
                Label(alert, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .onTapGesture { engine.clearAlert() }
            }

            Divider()

            HStack {
                Button("Refresh") { engine.refreshLocalDevices() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { engine.refreshLocalDevices() }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("AudioRouter Pro")
                    .font(.headline)
                Spacer()
                if engine.isRouting {
                    levelMeter
                }
            }
            Text(engine.statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Live capture meter: visible proof that the tap is delivering samples.
    private var levelMeter: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(engine.captureLevel > 0.01 ? Color.green : Color.gray)
                    .frame(width: max(3, geometry.size.width * CGFloat(engine.captureLevel)))
            }
        }
        .frame(width: 60, height: 6)
        .animation(.linear(duration: 0.12), value: engine.captureLevel)
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("System audio access is required to capture and route audio.",
                  systemImage: "waveform.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.orange)
            Button("Open Privacy Settings") {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
                NSWorkspace.shared.open(url)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Local ("Play computer audio through")

    private var localSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Play computer audio through", systemImage: "speaker.wave.2")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Local device", selection: $engine.selectedLocalUID) {
                ForEach(engine.localDevices) { device in
                    HStack {
                        Image(systemName: device.transport.symbolName)
                        Text(device.name)
                    }
                    .tag(Optional(device.uid))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    // MARK: - Speakers (AirPlay receivers)

    private var speakersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Speakers", systemImage: "airplayaudio")
                .font(.caption)
                .foregroundStyle(.secondary)

            if engine.receivers.isEmpty {
                Text("Scanning the network for AirPlay receivers…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ForEach(engine.receivers) { receiver in
                receiverRow(receiver)
            }
        }
    }

    @ViewBuilder
    private func receiverRow(_ receiver: DiscoveredReceiver) -> some View {
        let state = engine.legState(receiver.name)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Toggle(isOn: transmitBinding(receiver)) {
                    Text(receiver.name).lineLimit(1)
                }
                .toggleStyle(.checkbox)
                .disabled(receiver.requiresAuth)

                Spacer()

                switch state {
                case .streaming:
                    Text("Streaming")
                        .font(.caption2)
                        .foregroundStyle(.green)
                case .connectedNotConsuming:
                    Text("Connected — not consuming")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("The receiver accepted the session but is not playing it — it may be busy with another AirPlay session (e.g. this Mac via Control Center). Disconnect that session and re-toggle.")
                case .connecting:
                    ProgressView()
                        .controlSize(.mini)
                case .authRequired:
                    Text("Requires AirPlay 2 auth — not yet supported")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .failed(let why):
                    Text("Failed")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .help(why)
                case .idle:
                    if receiver.requiresAuth {
                        Text("Requires AirPlay 2 auth — not yet supported")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if state == .streaming || state == .connecting || state == .connectedNotConsuming {
                Slider(value: receiverVolumeBinding(receiver.name), in: 0...1)
                    .controlSize(.mini)
                    .padding(.leading, 18)
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Sync trim")
                        .font(.caption)
                    Slider(value: $engine.syncTrimMS, in: -500...500)
                        .controlSize(.small)
                    Text("\(Int(engine.syncTrimMS)) ms")
                        .font(.caption.monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                }
                Text("Shifts local playback relative to AirPlay. Leave at 0 for automatic alignment.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 6)
        } label: {
            Text("Advanced")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bindings

    private var routingBinding: Binding<Bool> {
        Binding(
            get: { engine.isRouting },
            set: { $0 ? engine.startRouting() : engine.stopRouting() }
        )
    }

    private func transmitBinding(_ receiver: DiscoveredReceiver) -> Binding<Bool> {
        Binding(
            get: {
                switch engine.legState(receiver.name) {
                case .streaming, .connecting, .connectedNotConsuming: return true
                default: return false
                }
            },
            set: { _ in engine.toggleTransmit(receiver) }
        )
    }

    private func receiverVolumeBinding(_ name: String) -> Binding<Float> {
        Binding(
            get: { engine.receiverVolume(name) },
            set: { engine.setReceiverVolume(name, $0) }
        )
    }
}
