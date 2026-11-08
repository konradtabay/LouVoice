import LouVoiceCore
import SwiftUI

/// Live motion from the AirPods: rotation, acceleration and attitude, three curves each.
/// When the AirPods aren't streaming, a large card says what to do instead.
/// The header's "AirPods on" dot shows the status everywhere else.
struct SignalsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hub = model.hub
        let streaming = hub.status == .streaming
        LVScroll {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 16) {
                    Text("Signals").font(LV.display(54))
                    Spacer()
                    if streaming {
                        StatusBadge(tone: .good, text: String(format: "Live · %.0f Hz", hub.sampleRate))
                    }
                    Button { model.cues.test() } label: { Label("Test sound", systemImage: "speaker.wave.2.fill") }
                        .lvButton(.outline)
                }

                if !streaming { NotConnectedCard(status: hub.status) }

                SignalPlot(title: "Rotation", unit: "rad/s", samples: hub.history, range: 1.6, channels: [
                    ("x", LV.heart, { $0.rotation.x }), ("y", LV.violet, { $0.rotation.y }), ("z", LV.ink, { $0.rotation.z }),
                ])
                SignalPlot(title: "Acceleration", unit: "g", samples: hub.history, range: 0.16, channels: [
                    ("x", LV.heart, { $0.accel.x }), ("y", LV.violet, { $0.accel.y }), ("z", LV.ink, { $0.accel.z }),
                ])
                SignalPlot(title: "Attitude", unit: "rad", samples: hub.history, range: 1.0, channels: [
                    ("pitch", LV.heart, { $0.pitch }), ("yaw", LV.violet, { $0.yaw }), ("roll", LV.ink, { $0.roll }),
                ])
            }
            .padding(40)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct NotConnectedCard: View {
    var status: MotionHub.Status

    var body: some View {
        LVCard {
            HStack(alignment: .center, spacing: 24) {
                Image(systemName: "airpodspro.chargingcase.wireless")
                    .font(.system(size: 56, weight: .light)).foregroundStyle(LV.schooner).frame(width: 80)
                VStack(alignment: .leading, spacing: 8) {
                    Text("AirPods not connected").font(LV.display(38))
                    Text(friendly).font(LV.body).foregroundStyle(LV.ink.opacity(0.8))
                }
                Spacer()
                StatusBadge(tone: .warn, text: "Not ready")
            }
        }
    }

    private var friendly: String {
        switch status {
        case .waiting, .idle, .streaming: "Put both AirPods in your ears. Make sure they're connected to this Mac."
        case .denied: "LouVoice needs permission. Open System Settings › Privacy & Security › Motion & Fitness and turn on LouVoice."
        case .unsupported: "This Mac can't read AirPods movement."
        case .error(let message): message
        }
    }
}

/// Rolling three-channel plot in the landing page style: ink frame, faint grid, brand colours.
struct SignalPlot: View {
    var title: String
    var unit: String
    var samples: [MotionSample]
    var range: Double
    var channels: [(String, Color, (MotionSample) -> Double)]
    /// Smaller title, no live values: for the preview on the Train tab.
    var compact = false
    var height: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(compact ? LV.sans(15, .semibold) : LV.display(28))
                Text(unit).font(LV.sans(15)).foregroundStyle(LV.muted)
                Spacer()
                ForEach(channels.indices, id: \.self) { i in
                    HStack(spacing: 6) {
                        Rectangle().fill(channels[i].1).frame(width: 14, height: 3)
                        Text(channels[i].0).font(LV.sans(15, .medium))
                        if !compact {
                            Text(current(i)).font(LV.sans(15).monospacedDigit()).foregroundStyle(LV.muted)
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }
            }
            Canvas { ctx, size in
                // Grid: quarter lines, centre line a bit stronger.
                for i in 1..<4 {
                    let y = size.height * CGFloat(i) / 4
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                               with: .color(LV.ink.opacity(i == 2 ? 0.3 : 0.08)), lineWidth: 1)
                }
                for i in 1..<8 {
                    let x = size.width * CGFloat(i) / 8
                    ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                               with: .color(LV.ink.opacity(0.06)), lineWidth: 1)
                }
                guard let last = samples.last?.t else { return }
                let span = MotionHub.historySeconds
                for (_, color, value) in channels {
                    var path = Path()
                    for (i, s) in samples.enumerated() {
                        let x = size.width * (1 - (last - s.t) / span)
                        let v = max(-1, min(1, value(s) / range))
                        let pt = CGPoint(x: x, y: size.height / 2 * (1 - 0.85 * v))  // 15% headroom so peaks stay inside
                        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
                }
            }
            .frame(height: height)
            .background(Color.white.opacity(0.45))
            .overlay(Rectangle().strokeBorder(LV.ink, lineWidth: 1))
        }
    }

    private func current(_ i: Int) -> String {
        guard let s = samples.last else { return "–" }
        return String(format: "%+.2f", channels[i].2(s))
    }
}
