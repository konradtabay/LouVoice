import SwiftUI

/// Dev mode: the original LouVoice UI from before the simple redesign (sidebar, five screens,
/// system styling). Reached by clicking the LouVoice logo; "Simple UI" returns.
struct DevModeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(AppModel.DevScreen.allCases, selection: $model.devScreen) { screen in
                Label(screen.rawValue, systemImage: screen.symbol).tag(screen)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Button { model.devMode = false } label: {
                        Label("Simple UI", systemImage: "sparkles").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Back to the simple Signals / Train / Speak app")
                    DevSourceFooter()
                }
                .padding(12)
            }
        } detail: {
            VStack(spacing: 0) {
                if model.isSimulated { DevSimulatorBanner() }
                Group {
                    switch model.devScreen {
                    case .sensors: SensorsView()
                    case .enroll: EnrollView()
                    case .evaluate: EvaluateView()
                    case .tune: TuneView()
                    case .decode: DecodeView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct DevSourceFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Source", selection: Binding(get: { model.hub.source }, set: { model.setSource($0) })) {
                ForEach(MotionHub.Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 6) {
                StatusDot(ok: model.hub.status == .streaming)
                Text(model.hub.status == .streaming
                     ? String(format: "%.0f Hz", model.hub.sampleRate)
                     : model.hub.status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

private struct DevSimulatorBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
            Text("Simulator: synthetic motion for testing the flow. Its accuracy says nothing about real AirPods.")
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.purple.opacity(0.15))
    }
}
