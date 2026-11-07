import LouVoiceCore
import SwiftUI

struct StatusDot: View {
    var ok: Bool
    var body: some View {
        Circle().fill(ok ? Color.green : Color.orange).frame(width: 8, height: 8)
    }
}

struct SimulatorBanner: View {
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

struct MetricTile: View {
    var title: String
    var value: String
    var detail: String? = nil
    var emphasis = false
    var dimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: emphasis ? 40 : 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(dimmed ? .secondary : .primary)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(emphasis ? 0.14 : 0.08)))
    }
}

struct SectionCard<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }
}

/// Rolling line plot of a few channels from the motion history.
struct LivePlot: View {
    var samples: [MotionSample]
    var channels: [(String, Color, (MotionSample) -> Double)]
    var range: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { ctx, size in
                guard let last = samples.last?.t else { return }
                let span = MotionHub.historySeconds
                ctx.stroke(Path { p in p.move(to: CGPoint(x: 0, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width, y: size.height / 2)) },
                           with: .color(.secondary.opacity(0.3)))
                for (_, color, value) in channels {
                    var path = Path()
                    for (i, s) in samples.enumerated() {
                        let x = size.width * (1 - (last - s.t) / span)
                        let v = max(-1, min(1, value(s) / range))
                        let pt = CGPoint(x: x, y: size.height / 2 * (1 - v))
                        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    ctx.stroke(path, with: .color(color), lineWidth: 1.4)
                }
            }
            .frame(height: 120)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))
            HStack(spacing: 12) {
                ForEach(channels.indices, id: \.self) { i in
                    HStack(spacing: 4) {
                        Circle().fill(channels[i].1).frame(width: 7, height: 7)
                        Text(channels[i].0).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

func percent(_ x: Double?) -> String {
    guard let x else { return "–" }
    return String(format: "%.0f%%", x * 100)
}

func displayLabel(_ label: String) -> String { label == noneLabel ? "(not a word)" : label }
