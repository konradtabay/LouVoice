import Foundation

/// Quality-gate thresholds (D14, D32). Tunable on the Tune screen.
public struct QualityConfig: Codable, Hashable, Sendable {
    public var checkStrength = true
    /// Minimum take strength: peak activity ÷ the take's own quiet level.
    public var minStrength = 3.0
    public var checkHeadMovement = true
    public var maxHeadDegrees = 15.0
    public var maxGapSeconds = 0.15
    public init() {}
}

/// Per-take checks at capture time. A failed take is re-queued with a reason.
public enum Quality {
    /// How far the take's activity rises above its own quiet frames (smoothed peak ÷ 20th
    /// percentile). Self-normalising, so it doesn't depend on a separate calibration (D32).
    /// The capture window is ~2 s and a word fills ~0.5 s, so the 20th percentile is rest.
    public static func strength(_ f: SegmentFeatures) -> Double {
        let smooth = Features.movingAverage(f.energies, radius: 1)
        let sorted = smooth.sorted()
        guard let peak = sorted.last, !sorted.isEmpty else { return 0 }
        return peak / max(sorted[sorted.count / 5], 1e-9)
    }

    public static func check(_ f: SegmentFeatures, config: QualityConfig = QualityConfig(), isNone: Bool) -> String? {
        if f.maxGap > config.maxGapSeconds {
            return String(format: "Motion dropped out for %.0f ms — keep the AirPods connected and close.", f.maxGap * 1000)
        }
        if f.sequence.count < 6 { return "Too short — try again." }
        guard !isNone else { return nil }
        if config.checkHeadMovement, f.headRotationDegrees > config.maxHeadDegrees {
            return String(format: "Head moved %.0f° (limit %.0f°) — keep your head still and move only your jaw.",
                          f.headRotationDegrees, config.maxHeadDegrees)
        }
        if config.checkStrength {
            let s = strength(f)
            if s < config.minStrength {
                return String(format: "Too subtle: strength %.1f×, needs %.1f× — exaggerate the jaw a little.", s, config.minStrength)
            }
        }
        return nil
    }
}
