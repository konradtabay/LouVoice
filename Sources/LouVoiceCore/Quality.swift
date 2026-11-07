import Foundation

/// Per-take checks at capture time (D14). A failed take is re-queued with a reason.
public enum Quality {
    public static let maxGap = 0.15
    public static let maxHeadDegrees = 15.0
    public static let minPeakOverFloor = 2.5

    public static func check(_ f: SegmentFeatures, noiseFloor: Double?, isNone: Bool) -> String? {
        if f.maxGap > maxGap { return "Motion dropped out — keep the AirPods connected and close." }
        if f.sequence.count < 6 { return "Too short — try again." }
        guard !isNone else { return nil }
        if f.headRotationDegrees > maxHeadDegrees { return "Head moved — keep your head still and move only your jaw." }
        if let noiseFloor, f.energyPeak < noiseFloor * minPeakOverFloor {
            return "Too subtle — exaggerate the jaw movement."
        }
        return nil
    }
}
