import Charts
import SwiftUI

/// History: how movement strength and recognition accuracy change over months (D54).
/// With ALS movement weakens; regular practice keeps accuracy up. The data is SIMULATED for now
/// (no on-screen label, at the team's request).
/// TODO(team): replace `HistoryData.simulated()` with real per-session numbers (take strength and
/// held-out accuracy per training block) once enough sessions are recorded.
struct HistoryView: View {
    private let points = HistoryData.simulated()
    /// Week under the pointer, shared by both charts so hovering one highlights the same week in both.
    @State private var hovered: Date?

    var body: some View {
        let start = HistoryData.average(points.prefix(4)), now = HistoryData.average(points.suffix(4))
        LVScroll {
            VStack(alignment: .leading, spacing: 28) {
                Text("History").font(LV.display(54))
                HStack(alignment: .top, spacing: 48) {
                    HistoryChart(title: "Movement strength", now: now.strength, change: now.strength - start.strength,
                                 points: points, value: \.strength, color: LV.heartDark, hovered: $hovered,
                                 warning: (HistoryData.weakLevel, "Too weak to read reliably"))
                    HistoryChart(title: "Accuracy", now: now.accuracy, change: now.accuracy - start.accuracy,
                                 points: points, value: \.accuracy, color: LV.heart, hovered: $hovered, warning: nil)
                }
            }
            .padding(40)
            .frame(maxWidth: 1400)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Bare chart on the paper: title with the current value inline, one jagged line,
/// gridlines at 0/50/100%. Hovering snaps to the nearest week and shows its value.
private struct HistoryChart: View {
    var title: String
    var now: Double
    var change: Double
    var points: [HistoryData.Point]
    var value: KeyPath<HistoryData.Point, Double>
    var color: Color
    @Binding var hovered: Date?
    var warning: (level: Double, label: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(title).font(LV.display(40))
                Spacer(minLength: 8)
                Text("\(Int(now.rounded()))%").font(LV.display(40)).foregroundStyle(LV.heartDark)
                Text(String(format: "%+.0f pts", change))
                    .font(LV.sans(17, .semibold)).foregroundStyle(change < 0 ? LV.warn : LV.good)
            }
            .help("Average of the last 4 weeks, and the change since the first 4 weeks")
            chart.frame(height: 360).padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
    }

    private var chart: some View {
        Chart {
            if let warning {
                RuleMark(y: .value("Warning", warning.level))
                    .foregroundStyle(LV.warn)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text(warning.label).font(LV.sans(14, .semibold)).foregroundStyle(LV.warn)
                    }
            }
            ForEach(points) { p in
                LineMark(x: .value("Week", p.date), y: .value(title, p[keyPath: value]))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
            }
            if let hovered, let p = points.first(where: { $0.date == hovered }) {
                RuleMark(x: .value("Week", hovered))
                    .foregroundStyle(LV.ink.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Week", p.date), y: .value(title, p[keyPath: value]))
                    .foregroundStyle(color)
                    .symbolSize(90)
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(range: .plotDimension(startPadding: 4, endPadding: 28))
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(LV.schooner.opacity(0.7))
                AxisValueLabel { if let n = v.as(Int.self) { Text("\(n)%").font(LV.sans(18)).foregroundStyle(LV.muted) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated)).font(LV.sans(16)).foregroundStyle(LV.muted)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .overlay(alignment: .topLeading) {
                        // Tooltip beside the hover line, flipped to the left near the right edge.
                        if let hovered, let p = points.first(where: { $0.date == hovered }),
                           let frame = proxy.plotFrame, let x = proxy.position(forX: hovered) {
                            let plot = geo[frame]
                            let lineX = plot.origin.x + x
                            let w = Tooltip.width
                            let left = lineX + 14 + w > plot.maxX ? lineX - 14 - w : lineX + 14
                            Tooltip(date: hovered, value: p[keyPath: value], color: color)
                                .offset(x: left, y: plot.origin.y + 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let frame = proxy.plotFrame else { return }
                            let x = location.x - geo[frame].origin.x
                            guard let date: Date = proxy.value(atX: x) else { return }
                            hovered = points.map(\.date).min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
    }
}

private struct Tooltip: View {
    static let width: CGFloat = 150
    var date: Date
    var value: Double
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Week of \(date.formatted(.dateTime.month(.abbreviated).day()))")
                .font(LV.sans(15, .semibold)).foregroundStyle(LV.muted)
            Text("\(Int(value.rounded()))%").font(LV.display(34)).foregroundStyle(color)
        }
        .padding(12)
        .frame(width: Self.width, alignment: .leading)
        .background(LV.pearl)
        .overlay(Rectangle().strokeBorder(LV.ink, lineWidth: 1))
        .background(Rectangle().fill(LV.heart).offset(x: 4, y: 4))   // the site's offset shadow
    }
}

/// Simulated weekly history for one person with ALS over about nine months.
enum HistoryData {
    struct Point: Identifiable {
        var date: Date
        var strength: Double   // % of the first week's jaw-movement strength
        var accuracy: Double   // % of practice takes recognised correctly
        var id: Date { date }
    }

    /// Strength below which words become hard to read (caregiver warning). TODO(team): pick from real data.
    static let weakLevel = 20.0

    /// Deterministic (same picture every launch). Strength falls slowly then faster, with noisy weeks.
    /// Accuracy stays high (about 95% easing a few points) because regular practice keeps LouVoice
    /// adapted; it would only fall as strength nears the "too weak" line.
    static func simulated(weeks: Int = 39, endingAt end: Date = Calendar.current.startOfDay(for: Date())) -> [Point] {
        var rng = SeededRandom(seed: 7)
        let cal = Calendar.current
        return (0..<weeks).map { i in
            let t = Double(i) / Double(weeks - 1)
            let date = cal.date(byAdding: .weekOfYear, value: i - (weeks - 1), to: end) ?? end
            let strength = min(100, max(3, 100 - 52 * pow(t, 1.35) + rng.next(in: -4...4)))
            let nearWeak = max(0, weakLevel + 15 - strength) * 1.5
            let accuracy = min(100, max(20, 95 - 4 * t - nearWeak + rng.next(in: -3.5...3)))
            return Point(date: date, strength: strength, accuracy: accuracy)
        }
    }

    /// Mean strength and accuracy over a set of weeks.
    static func average<S: Sequence>(_ pts: S) -> (strength: Double, accuracy: Double) where S.Element == Point {
        let a = Array(pts)
        guard !a.isEmpty else { return (0, 0) }
        return (a.map(\.strength).reduce(0, +) / Double(a.count), a.map(\.accuracy).reduce(0, +) / Double(a.count))
    }
}

/// Tiny deterministic generator (SplitMix64) so the simulated chart doesn't change between launches.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextUInt() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + Double(nextUInt() >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }
}
