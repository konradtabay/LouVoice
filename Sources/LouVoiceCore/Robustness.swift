import Foundation

/// Robustness to head movement (D42).
///
/// `Interference.mix` adds the head/face movement recorded in one take (typically a `_none` take:
/// turn, nod, look up, chew, swallow, smile) onto another, at a chosen strength. For small motions
/// the extra rotation rate and acceleration simply add, and the extra rotation composes onto the
/// attitude. That makes realistic "mouthing while moving" data out of real recordings, for testing
/// and, optionally, as noisy training copies.
public enum Interference {
    /// `alpha` scales the interference (1 = as recorded). `offset` shifts it in time (seconds).
    public static func mix(_ base: [MotionSample], with noise: [MotionSample], alpha: Double, offset: Double = 0) -> [MotionSample] {
        guard let b0 = base.first?.t, let n0 = noise.first?.t, let q0 = noise.first?.attitude, alpha != 0 else { return base }
        let nt = noise.map { $0.t - n0 }
        var j = 0
        return base.map { s in
            let t = s.t - b0 + offset
            while j + 1 < noise.count, nt[j + 1] <= t { j += 1 }
            guard t >= 0, t <= (nt.last ?? 0) else { return s }
            let n = noise[j]
            var out = s
            out.rotation = s.rotation + n.rotation * alpha
            out.accel = s.accel + n.accel * alpha
            let extra = Quat(rotationVector: (q0.conjugate * n.attitude).rotationVector * alpha)
            out.attitude = (s.attitude * extra).normalized
            out.gravity = extra.conjugate.rotate(s.gravity)
            out.pitch = s.pitch + (n.pitch - noise[0].pitch) * alpha
            out.yaw = s.yaw + remainder(n.yaw - noise[0].yaw, 2 * .pi) * alpha
            out.roll = s.roll + (n.roll - noise[0].roll) * alpha
            return out
        }
    }
}

/// Training-set options for movement robustness (Tune › Robustness).
public struct RobustnessConfig: Codable, Hashable, Sendable {
    /// Noisy copies per word take, made by mixing in a random recorded `_none` take (D42: 2).
    public var noiseCopies = 2
    /// Strength range of the mixed-in movement.
    public var minStrength = 0.3
    public var maxStrength = 0.8
    /// Decode: reject a capture whose head rotated more than this (degrees); 0 = off.
    public var decodeMaxHeadDegrees = 0.0
    public init() {}
}

public enum TrainingSet {
    /// Word takes → classifier training features, plus noisy copies when configured.
    public static func build(_ takes: [Tuner.RawTake], config: PipelineConfig, seed: UInt64 = 11,
                             existing: (Tuner.RawTake) -> FeatureSequence? = { _ in nil }) -> [LabeledFeatures] {
        var out: [LabeledFeatures] = takes.compactMap { t in
            if let f = existing(t) { return LabeledFeatures(id: t.id, label: t.label, features: f) }
            return Features.extract(t.samples, config: config.features).map { LabeledFeatures(id: t.id, label: t.label, features: $0.sequence) }
        }
        let r = config.robustness
        let noises = takes.filter { $0.label == noneLabel }
        guard r.noiseCopies > 0, !noises.isEmpty else { return out }
        var rng = SeededRNG(seed: seed)
        for t in takes where t.label != noneLabel {
            for c in 0..<r.noiseCopies {
                let noise = noises.randomElement(using: &rng)!
                let alpha = rng.uniform(r.minStrength, r.maxStrength)
                let mixed = Interference.mix(t.samples, with: noise.samples, alpha: alpha, offset: rng.uniform(-0.3, 0.3))
                if let f = Features.extract(mixed, config: config.features) {
                    out.append(LabeledFeatures(id: "\(t.id)-noise\(c)", label: t.label, features: f.sequence))
                }
            }
        }
        return out
    }
}

extension Tuner {
    public struct RobustnessRow: Sendable { public var strength: Double; public var words: Double; public var gated: Double; public var answered: Double }

    /// Leave-one-block-out word accuracy when real recorded movement (`_none` takes from *other*
    /// blocks) is mixed into each held-out word take at each strength. `gated` is the accuracy over
    /// takes the head-movement gate lets through, `answered` the fraction it lets through.
    public static func robustness(_ takes: [RawTake], config: PipelineConfig, strengths: [Double],
                                  gateDegrees: Double = 0, seed: UInt64 = 21) -> [RobustnessRow] {
        var rng = SeededRNG(seed: seed)
        var hits = [Int](repeating: 0, count: strengths.count), total = hits
        var gHits = hits, gTotal = hits
        for block in Set(takes.map(\.block)).sorted() {
            let trainRaw = takes.filter { $0.block != block }
            let train = TrainingSet.build(trainRaw, config: config)
            guard let clf = Classifier(training: train, config: config.classifier) else { continue }
            let noises = trainRaw.filter { $0.label == noneLabel }
            guard !noises.isEmpty else { continue }
            for t in takes where t.block == block && t.label != noneLabel {
                let noise = noises.randomElement(using: &rng)!
                let offset = rng.uniform(-0.3, 0.3)
                for (k, a) in strengths.enumerated() {
                    let mixed = Interference.mix(t.samples, with: noise.samples, alpha: a, offset: offset)
                    guard let f = Features.extract(mixed, config: config.features) else { continue }
                    let hit = clf.predict(f.sequence).best?.label == t.label
                    total[k] += 1; if hit { hits[k] += 1 }
                    if gateDegrees <= 0 || f.headRotationDegrees <= gateDegrees { gTotal[k] += 1; if hit { gHits[k] += 1 } }
                }
            }
        }
        return strengths.indices.map { k in
            RobustnessRow(strength: strengths[k], words: Double(hits[k]) / Double(max(total[k], 1)),
                          gated: Double(gHits[k]) / Double(max(gTotal[k], 1)), answered: Double(gTotal[k]) / Double(max(total[k], 1)))
        }
    }
}
