import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(AppModel.Screen.allCases, selection: $model.screen) { screen in
                Label(screen.rawValue, systemImage: screen.symbol).tag(screen)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) { SourceFooter().padding(12) }
        } detail: {
            VStack(spacing: 0) {
                if model.isSimulated { SimulatorBanner() }
                Group {
                    switch model.screen {
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

private struct SourceFooter: View {
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
