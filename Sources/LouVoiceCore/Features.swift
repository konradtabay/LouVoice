import Foundation

/// A multichannel feature sequence stored flat (frame-major) for fast DTW.
public struct FeatureSequence: Sendable, Hashable {
    public var values: [Double]
    public let dims: Int
    /// Leading dims that are xyz vectors (rotated by augmentation); the rest are scalars.
    public var vectorDims: Int
    public var count: Int { dims == 0 ? 0 : values.count / dims }

    public init(values: [Double], dims: Int, vectorDims: Int? = nil) {
        self.values = values; self.dims = dims; self.vectorDims = vectorDims ?? dims
    }
    public init(frames: [[Double]], vectorDims: Int? = nil) {
        dims = frames.first?.count ?? 0
        values = frames.flatMap { $0 }
        self.vectorDims = vectorDims ?? dims
    }
    public subscript(frame i: Int, dim d: Int) -> Double {
        get { values[i * dims + d] }
        set { values[i * dims + d] = newValue }
    }
    public func channel(_ d: Int) -> [Double] { (0..<count).map { values[$0 * dims + d] } }
}

/// Which sensor channel groups feed the recognizer (each group is xyz).
public struct FeatureChannels: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let acceleration = FeatureChannels(rawValue: 1 << 0)
    public static let rotation = FeatureChannels(rawValue: 1 << 1)
    public static let attitude = FeatureChannels(rawValue: 1 << 2)
    public static let all: FeatureChannels = [.acceleration, .rotation, .attitude]

    public var label: String {
        var parts: [String] = []
        if contains(.acceleration) { parts.append("accel") }
        if contains(.rotation) { parts.append("rotation") }
        if contains(.attitude) { parts.append("attitude") }
        return parts.isEmpty ? "none" : parts.joined(separator: "+")
    }
}

/// Every tunable of the feature pipeline (Tune screen / auto-tune, D29).
public struct FeatureConfig: Codable, Hashable, Sendable {
    /// Resampling rate. AirPods on macOS deliver 50 Hz, but 25 Hz scored the same on real data
    /// and is 4× cheaper for DTW (D30).
    public var rate: Double = 25
    /// High-pass cutoff in Hz; 0 disables the filter. 0.8 Hz on 280 real takes (D37).
    public var highPassHz: Double = 0.8
    /// Low-pass cutoff in Hz; 0 disables (D35).
    public var lowPassHz: Double = 0
    /// Rotate each capture so its rest gravity points down (D7).
    public var canonicalize: Bool = true
    /// Rest pre-roll used to measure gravity for canonicalisation.
    public var restSeconds: Double = 0.3
    /// Rotation + attitude: the accelerometer mostly added noise on real data (D33).
    public var channels: FeatureChannels = [.rotation, .attitude]
    public var trim: Bool = true
    /// Trim threshold as a fraction of the floor-to-peak energy range (D22).
    public var trimThreshold: Double = 0.35
    /// Energy smoothing window before trimming, seconds.
    public var smoothSeconds: Double = 0.2
    /// Frames kept either side of the active region, seconds.
    public var trimPaddingSeconds: Double = 0.08
    /// Per-take amplitude normalisation, removing how hard a take was mouthed (D33).
    public var normalization: Normalization = .none
    /// Append rate-of-change (first difference) of each vector channel.
    public var derivatives: Bool = false
    /// Append rotation-free magnitudes |a|, |ω|, |θ| of the selected groups.
    public var magnitudes: Bool = true
    public init() {}

    public enum Normalization: String, Codable, CaseIterable, Sendable {
        case none, global, perChannel
        public var label: String {
            switch self { case .none: "off"; case .global: "per take"; case .perChannel: "per take & channel" }
        }
    }

    enum CodingKeys: String, CodingKey {
        case rate, highPassHz, lowPassHz, canonicalize, restSeconds, channels, trim, trimThreshold, smoothSeconds,
             trimPaddingSeconds, normalization, derivatives, magnitudes
    }
    // Tolerant decoding: saved settings keep working when new options are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FeatureConfig()
        rate = try c.decodeIfPresent(Double.self, forKey: .rate) ?? d.rate
        highPassHz = try c.decodeIfPresent(Double.self, forKey: .highPassHz) ?? d.highPassHz
        lowPassHz = try c.decodeIfPresent(Double.self, forKey: .lowPassHz) ?? d.lowPassHz
        canonicalize = try c.decodeIfPresent(Bool.self, forKey: .canonicalize) ?? d.canonicalize
        restSeconds = try c.decodeIfPresent(Double.self, forKey: .restSeconds) ?? d.restSeconds
        channels = try c.decodeIfPresent(FeatureChannels.self, forKey: .channels) ?? d.channels
        trim = try c.decodeIfPresent(Bool.self, forKey: .trim) ?? d.trim
        trimThreshold = try c.decodeIfPresent(Double.self, forKey: .trimThreshold) ?? d.trimThreshold
        smoothSeconds = try c.decodeIfPresent(Double.self, forKey: .smoothSeconds) ?? d.smoothSeconds
        trimPaddingSeconds = try c.decodeIfPresent(Double.self, forKey: .trimPaddingSeconds) ?? d.trimPaddingSeconds
        normalization = try c.decodeIfPresent(Normalization.self, forKey: .normalization) ?? d.normalization
        derivatives = try c.decodeIfPresent(Bool.self, forKey: .derivatives) ?? d.derivatives
        magnitudes = try c.decodeIfPresent(Bool.self, forKey: .magnitudes) ?? d.magnitudes
    }

    var smoothRadius: Int { max(0, Int((smoothSeconds * rate / 2).rounded())) }
    var trimPadding: Int { max(0, Int((trimPaddingSeconds * rate).rounded())) }
    var minFrames: Int { max(6, Int(0.24 * rate)) }
}

/// What the pipeline produces for one captured segment.
public struct SegmentFeatures: Sendable {
    /// Up to 9 channels per frame (accel xyz, rotation-rate xyz, attitude-change rotation vector xyz),
    /// as selected by `FeatureConfig.channels`, in the gravity-canonical frame and high-passed.
    public var sequence: FeatureSequence
    /// Per-frame activity before trimming.
    public var energies: [Double]
    public var energyPeak: Double
    public var maxGap: Double
    /// Largest head rotation from the segment start, before filtering (degrees).
    public var headRotationDegrees: Double
    public var location: SensorLocation
    /// Seconds between the end of the detected word and the end of the capture window
    /// (0 when nothing was trimmed). Used to measure end-of-word → audio delay (D39).
    public var trailingSeconds: Double = 0
}

public enum Features {
    public static let dims = 9

    /// Activity score: rotation (rad/s) and acceleration (g) on comparable scales.
    public static func energy(_ seq: FeatureSequence, frame i: Int) -> Double {
        let r = (pow(seq[frame: i, dim: 3], 2) + pow(seq[frame: i, dim: 4], 2) + pow(seq[frame: i, dim: 5], 2)).squareRoot()
        let a = (pow(seq[frame: i, dim: 0], 2) + pow(seq[frame: i, dim: 1], 2) + pow(seq[frame: i, dim: 2], 2)).squareRoot()
        return r + 5 * a
    }

    public static func extract(_ raw: [MotionSample], config: FeatureConfig = FeatureConfig()) -> SegmentFeatures? {
        let resampled = Signal.resample(raw, rate: config.rate)
        let s = resampled.samples
        guard s.count >= 6 else { return nil }

        // D7: rotate so rest gravity points down; removes earbud seating and head posture.
        let restCount = max(1, min(s.count, Int(config.restSeconds * config.rate)))
        var g = Vec3.zero
        for i in 0..<restCount { g += s[i].gravity }
        let canonical = config.canonicalize ? Mat3.aligning(g, to: Vec3(0, 0, -1)) : .identity
        let q0 = s[0].attitude

        var channels = [[Double]](repeating: [], count: dims)
        var headDegrees = 0.0
        for sample in s {
            let a = canonical * sample.accel
            let r = canonical * sample.rotation
            let rel = (q0.conjugate * sample.attitude).rotationVector
            headDegrees = max(headDegrees, rel.length * 180 / .pi)
            let v = canonical * rel
            for (d, value) in [a.x, a.y, a.z, r.x, r.y, r.z, v.x, v.y, v.z].enumerated() { channels[d].append(value) }
        }

        // D8: remove drift and slow head movement.
        channels = channels.map { Signal.highPass($0, cutoff: config.highPassHz, rate: config.rate) }
        if config.lowPassHz > 0 { channels = channels.map { Signal.lowPass($0, cutoff: config.lowPassHz, rate: config.rate) } }

        // Energy uses all channels so trimming doesn't depend on the channel selection.
        let full = FeatureSequence(frames: (0..<s.count).map { i in channels.map { $0[i] } })
        let energies = (0..<full.count).map { energy(full, frame: $0) }

        var keep: [Int] = []
        if config.channels.contains(.acceleration) { keep += [0, 1, 2] }
        if config.channels.contains(.rotation) { keep += [3, 4, 5] }
        if config.channels.contains(.attitude) { keep += [6, 7, 8] }
        if keep.isEmpty { keep = Array(0..<dims) }
        var frames: [[Double]] = (0..<s.count).map { i in keep.map { channels[$0][i] } }

        var trailing = 0.0
        if config.trim, let range = activeRange(energies, config: config) {
            frames = Array(frames[range])
            trailing = Double(s.count - 1 - range.upperBound) / config.rate
        }
        let sequence = derive(frames, config: config)
        return SegmentFeatures(
            sequence: sequence,
            energies: energies,
            energyPeak: energies.max() ?? 0,
            maxGap: resampled.maxGap,
            headRotationDegrees: headDegrees,
            location: s[0].location,
            trailingSeconds: trailing)
    }

    /// Optional derived channels and per-take normalisation (D33).
    static func derive(_ base: [[Double]], config: FeatureConfig) -> FeatureSequence {
        guard let width = base.first?.count else { return FeatureSequence(frames: base) }
        var frames = base
        var vectorDims = width
        if config.derivatives {
            for i in frames.indices {
                let prev = base[max(0, i - 1)], next = base[min(base.count - 1, i + 1)]
                frames[i] += (0..<width).map { (next[$0] - prev[$0]) * config.rate / 20 }
            }
            vectorDims += width
        }
        if config.magnitudes {
            for i in frames.indices {
                let row = base[i]
                for g in stride(from: 0, to: width - 2, by: 3) {
                    let v = Vec3(row[g], row[g + 1], row[g + 2])
                    frames[i].append(v.length)
                }
            }
        }
        var seq = FeatureSequence(frames: frames, vectorDims: vectorDims)
        switch config.normalization {
        case .none: break
        case .global:
            let rms = (seq.values.map { $0 * $0 }.reduce(0, +) / Double(max(seq.values.count, 1))).squareRoot()
            if rms > 1e-12 { seq.values = seq.values.map { $0 / rms } }
        case .perChannel:
            for d in 0..<seq.dims {
                let ch = seq.channel(d)
                let mean = ch.reduce(0, +) / Double(ch.count)
                let sd = (ch.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(ch.count)).squareRoot()
                for i in 0..<seq.count { seq[frame: i, dim: d] = sd > 1e-12 ? (seq[frame: i, dim: d] - mean) / sd : 0 }
            }
        }
        return seq
    }

    /// Frames above a segment-relative threshold, so training and decoding trim the same way.
    static func activeRange(_ energies: [Double], config: FeatureConfig) -> ClosedRange<Int>? {
        let padding = config.trimPadding
        guard energies.count > config.minFrames + 2 else { return nil }
        // Smooth over ~0.2 s: raw energy dips to zero mid-syllable and spikes on noise.
        let smooth = movingAverage(energies, radius: config.smoothRadius)
        let sorted = smooth.sorted()
        let floor = sorted[sorted.count / 5], peak = sorted[sorted.count - 1]
        guard peak > floor * 1.5 else { return nil }
        let threshold = floor + config.trimThreshold * (peak - floor)
        guard let first = smooth.firstIndex(where: { $0 > threshold }),
              let last = smooth.lastIndex(where: { $0 > threshold }) else { return nil }
        let lo = max(0, first - padding), hi = min(energies.count - 1, last + padding)
        return hi - lo + 1 >= config.minFrames ? lo...hi : nil
    }

    static func movingAverage(_ x: [Double], radius: Int) -> [Double] {
        x.indices.map { i in
            let lo = max(0, i - radius), hi = min(x.count - 1, i + radius)
            return x[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
    }

    /// Per-channel standard deviation over a set of sequences (the training fold only, D12).
    public static func channelScales(_ seqs: [FeatureSequence]) -> [Double] {
        let dims = seqs.first?.dims ?? Features.dims
        var sum = [Double](repeating: 0, count: dims), sq = sum
        var n = 0.0
        for seq in seqs {
            for i in 0..<seq.count {
                for d in 0..<dims { let v = seq[frame: i, dim: d]; sum[d] += v; sq[d] += v * v }
                n += 1
            }
        }
        guard n > 1 else { return [Double](repeating: 1, count: dims) }
        return (0..<dims).map { d in max((sq[d] / n - pow(sum[d] / n, 2)).squareRoot(), 1e-6) }
    }

    /// Divide each channel by its training spread; `clip` > 0 soft-limits values to ±clip
    /// (c·tanh(x/c)) so a big head-movement spike can't dominate the DTW distance (D42).
    public static func scaled(_ seq: FeatureSequence, by scales: [Double], clip: Double = 0) -> FeatureSequence {
        var out = seq
        for i in 0..<seq.count {
            for d in 0..<seq.dims {
                let v = seq[frame: i, dim: d] / scales[d]
                out[frame: i, dim: d] = clip > 0 ? clip * tanh(v / clip) : v
            }
        }
        return out
    }

    /// Median per-frame energy of a still recording: the noise floor for the quality gate.
    public static func noiseFloor(_ rest: [MotionSample], config: FeatureConfig = FeatureConfig()) -> Double? {
        var c = config; c.trim = false
        guard let f = extract(rest, config: c) else { return nil }
        return max(median(f.energies), 1e-4)
    }
}
