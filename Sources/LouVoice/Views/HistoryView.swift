import Charts
import SwiftUI

/// History: how movement strength and recognition accuracy change over months (D54).
/// With ALS both are expected to fall. The data is SIMULATED for now; the screen says so.
/// TODO(team): replace `HistoryData.simulated()` with real per-session numbers (take strength and
/// held-out accuracy per training block) once enough sessions are recorded.
struct HistoryView: View {
    private let points = HistoryData.simulated()

    var body: some View {
        let first = points.first!, last = points.last!
        LVScroll {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("History").font(LV.display(54))
                    Spacer()
                    StatusBadge(tone: .warn, text: "Simulated data")
                }
                Text("How your jaw movement and LouVoice's accuracy change over time. With ALS, both are expected to slowly go down. Practising again helps LouVoice keep up.")
                    .font(LV.body).foregroundStyle(LV.muted).frame(maxWidth: 820, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 24) {
                    Summary(title: "Movement strength now", value: last.strength, change: last.strength - first.strength, unit: "% of start")
                    Summary(title: "Accuracy now", value: last.accuracy, change: last.accuracy - first.accuracy, unit: "% of words right")
                }

                ChartCard(title: "Movement strength",
                          subtitle: "How strongly your jaw moves when you mouth a word, compared with your first week.",
                          points: points, value: \.strength, color: LV.heartDark,
                          warning: (HistoryData.weakLevel, "Too weak to read reliably"))
                ChartCard(title: "Accuracy",
                          subtitle: "How often LouVoice got the word right in that week's practice.",
                          points: points, value: \.accuracy, color: LV.heart, warning: nil)
            }
            .padding(40)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct Summary: View {
    var title: String
    var value: Double
    var change: Double
    var unit: String

    var body: some View {
        LVCard {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: title)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(Int(value.rounded()))%").font(LV.display(56)).foregroundStyle(LV.heartDark)
                    Text(unit).font(LV.small).foregroundStyle(LV.muted)
                }
                Text(String(format: "%+.0f points since the first week", change))
                    .font(LV.sans(17, .semibold)).foregroundStyle(change < 0 ? LV.warn : LV.good)
            }
        }
    }
}

private struct ChartCard: View {
    var title: String
    var subtitle: String
    var points: [HistoryData.Point]
    var value: KeyPath<HistoryData.Point, Double>
    var color: Color
    var warning: (level: Double, label: String)?

    var body: some View {
        LVCard(title: title, subtitle: subtitle) {
            Chart {
                if let warning {
                    RuleMark(y: .value("Warning", warning.level))
                        .foregroundStyle(LV.warn)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                        .annotation(position: .top, alignment: .leading) {
                            Text(warning.label).font(LV.sans(14, .semibold)).foregroundStyle(LV.warn)
                        }
                }
                ForEach(points) { p in
                    AreaMark(x: .value("Week", p.date), yStart: .value("Base", 0), yEnd: .value(title, p[keyPath: value]))
                        .foregroundStyle(color.opacity(0.08))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Week", p.date), y: .value(title, p[keyPath: value]))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Week", p.date), y: .value(title, p[keyPath: value]))
                        .foregroundStyle(color)
                        .symbolSize(22)
                }
            }
            .chartYScale(domain: 0...100)
            .chartXScale(range: .plotDimension(startPadding: 4, endPadding: 24))
            .chartYAxis {
                AxisMarks(values: [0, 25, 50, 75, 100]) { v in
                    AxisGridLine().foregroundStyle(LV.ink.opacity(0.12))
                    AxisValueLabel { if let n = v.as(Int.self) { Text("\(n)%").font(LV.sans(14)).foregroundStyle(LV.muted) } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisGridLine().foregroundStyle(LV.ink.opacity(0.06))
                    AxisValueLabel(format: .dateTime.month(.abbreviated)).font(LV.sans(14)).foregroundStyle(LV.muted)
                }
            }
            .frame(height: 280)
        }
    }
}

/// Simulated weekly history for one person with ALS over about nine months.
enum HistoryData {
    struct Point: Identifiable {
        var date: Date
        var strength: Double   // % of the first week's jaw-movement strength
        var accuracy: Double   // % of practice words recognised correctly
        var id: Date { date }
    }

    /// Strength below which words become hard to read (caregiver warning). TODO(team): pick from real data.
    static let weakLevel = 45.0

    /// Deterministic (same picture every launch): strength falls slowly then faster, accuracy holds
    /// near 95% while movement is strong and drops once it weakens. Small week-to-week noise, with
    /// occasional small recoveries after re-practice.
    static func simulated(weeks: Int = 39, endingAt end: Date = Date()) -> [Point] {
        var rng = SeededRandom(seed: 7)
        let cal = Calendar.current
        return (0..<weeks).map { i in
            let t = Double(i) / Double(weeks - 1)
            let date = cal.date(byAdding: .weekOfYear, value: i - (weeks - 1), to: end) ?? end
            let trend = 100 - 52 * pow(t, 1.35)
            let strength = min(100, max(5, trend + rng.next(in: -2.5...2.5)))
            // Accuracy tracks strength once it is below ~80% of the start.
            let loss = max(0, 80 - strength) * 1.05
            let accuracy = min(99, max(20, 95 - loss + rng.next(in: -2.0...2.0)))
            return Point(date: date, strength: strength, accuracy: accuracy)
        }
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
