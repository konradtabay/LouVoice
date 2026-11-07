import Foundation

/// Feature-level augmentation (D9): rotation simulates re-seating, time-warp simulates speaking
/// rate, scaling simulates effort. Only ever applied to training data.
public struct AugmentConfig: Codable, Sendable, Hashable {
    public var maxRotationDegrees: Double = 12
    public var warp: ClosedRange<Double> = 0.85...1.15
    public var amplitude: ClosedRange<Double> = 0.9...1.1
    /// Jitter as a fraction of each channel's spread in this sequence.
    public var jitter: Double = 0.03
    public init() {}
}

public enum Augment {
    public static func augment(_ seq: FeatureSequence, config: AugmentConfig = AugmentConfig(),
                               rng: inout SeededRNG) -> FeatureSequence {
        guard seq.count >= 2, seq.dims % 3 == 0 else { return seq }
        let angle = rng.uniform(-config.maxRotationDegrees, config.maxRotationDegrees) * .pi / 180
        let rotation = Mat3(rotationVector: rng.unitVector() * angle)
        let gain = rng.uniform(config.amplitude.lowerBound, config.amplitude.upperBound)
        let warp = rng.uniform(config.warp.lowerBound, config.warp.upperBound)

        // Rotate each xyz triplet, scale.
        var rotated = seq
        for i in 0..<seq.count {
            for g in stride(from: 0, to: seq.dims, by: 3) {
                let v = rotation * Vec3(seq[frame: i, dim: g], seq[frame: i, dim: g + 1], seq[frame: i, dim: g + 2])
                rotated[frame: i, dim: g] = v.x * gain
                rotated[frame: i, dim: g + 1] = v.y * gain
                rotated[frame: i, dim: g + 2] = v.z * gain
            }
        }

        // Time-warp by linear resampling.
        let newCount = max(4, Int((Double(seq.count) * warp).rounded()))
        var values = [Double](repeating: 0, count: newCount * seq.dims)
        for k in 0..<newCount {
            let pos = Double(k) * Double(seq.count - 1) / Double(newCount - 1)
            let i = min(Int(pos), seq.count - 2), f = pos - Double(i)
            for d in 0..<seq.dims {
                values[k * seq.dims + d] = rotated[frame: i, dim: d] * (1 - f) + rotated[frame: i + 1, dim: d] * f
            }
        }
        var out = FeatureSequence(values: values, dims: seq.dims)

        // Jitter relative to each channel's spread.
        if config.jitter > 0 {
            for d in 0..<seq.dims {
                let ch = out.channel(d)
                let mean = ch.reduce(0, +) / Double(ch.count)
                let sd = (ch.map { pow($0 - mean, 2) }.reduce(0, +) / Double(ch.count)).squareRoot()
                for i in 0..<out.count { out[frame: i, dim: d] += rng.normal() * sd * config.jitter }
            }
        }
        return out
    }
}
