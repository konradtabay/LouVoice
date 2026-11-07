import Foundation

public enum HeadGesture: String, Sendable { case nod, shake }

/// Nod (pitch) / shake (yaw) detector over a sliding window of attitude (D15).
/// A gesture is a big excursion on one axis that returns close to where it started,
/// with little movement on the other axis.
public struct HeadGestureDetector: Sendable {
    public var window: Double = 1.4
    public var minAmplitude: Double = 0.18      // ~10°
    public var crossAxisRatio: Double = 0.55
    public var returnFraction: Double = 0.45
    public var cooldown: Double = 1.0

    private var buffer: [(t: Double, pitch: Double, yaw: Double)] = []
    private var lastFire: Double = -.infinity

    public init() {}

    public mutating func reset() { buffer.removeAll() }

    public mutating func push(_ s: MotionSample) -> HeadGesture? {
        // Unwrap yaw so ±π crossings don't look like a shake.
        var yaw = s.yaw
        if let prev = buffer.last { yaw = prev.yaw + remainder(s.yaw - prev.yaw, 2 * .pi) }
        buffer.append((s.t, s.pitch, yaw))
        buffer.removeAll { $0.t < s.t - window }
        guard s.t - lastFire > cooldown, let first = buffer.first, s.t - first.t > window * 0.6 else { return nil }

        let pitches = buffer.map(\.pitch), yaws = buffer.map(\.yaw)
        let pr = pitches.max()! - pitches.min()!, yr = yaws.max()! - yaws.min()!
        let last = buffer.last!

        func returned(_ start: Double, _ end: Double, _ range: Double) -> Bool { abs(end - start) < range * returnFraction }

        var gesture: HeadGesture?
        if pr >= minAmplitude, yr < pr * crossAxisRatio, returned(first.pitch, last.pitch, pr) { gesture = .nod }
        else if yr >= minAmplitude, pr < yr * crossAxisRatio, returned(first.yaw, last.yaw, yr) { gesture = .shake }

        if gesture != nil { lastFire = s.t; buffer.removeAll() }
        return gesture
    }
}
