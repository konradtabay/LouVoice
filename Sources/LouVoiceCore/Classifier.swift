import Foundation

/// Label for "not a word" movements: chewing, swallowing, head turns, nods… (D11).
public let noneLabel = "_none"

public struct ClassifierConfig: Codable, Sendable, Hashable {
    public var k: Int = 3
    public var augmentCopies: Int = 8
    public var band: Double = 0.2
    public var augment = AugmentConfig()
    public var seed: UInt64 = 1
    public init() {}
}

public struct LabeledFeatures: Sendable {
    public var id: String
    public var label: String
    public var features: FeatureSequence
    public init(id: String, label: String, features: FeatureSequence) {
        self.id = id; self.label = label; self.features = features
    }
}

public struct RankedLabel: Hashable, Sendable, Identifiable {
    public var label: String
    public var score: Double
    public var id: String { label }
}

public struct Prediction: Sendable {
    public var ranked: [RankedLabel]
    /// 1 − best/second-best score.
    public var margin: Double
    public var accepted: Bool
    public var rejectReason: String?
    public var best: RankedLabel? { ranked.first }
}

/// Mean-of-k-nearest DTW classifier over real + augmented references (D10).
public struct Classifier: Sendable {
    struct Reference: Sendable { var label: String; var owner: Int; var sequence: FeatureSequence }

    public let config: ClassifierConfig
    public let labels: [String]
    let scales: [Double]
    let references: [Reference]

    public init?(training: [LabeledFeatures], config: ClassifierConfig = ClassifierConfig()) {
        let usable = training.filter { $0.features.count >= 4 }
        guard Set(usable.map(\.label)).count >= 2 else { return nil }
        self.config = config
        self.labels = Array(Set(usable.map(\.label))).sorted()
        self.scales = Features.channelScales(usable.map(\.features))
        self.references = Self.buildReferences(usable, scales: scales, config: config)
    }

    static func buildReferences(_ takes: [LabeledFeatures], scales: [Double], config: ClassifierConfig) -> [Reference] {
        var refs: [Reference] = []
        for (owner, take) in takes.enumerated() {
            let base = Features.scaled(take.features, by: scales)
            refs.append(Reference(label: take.label, owner: owner, sequence: base))
            var rng = SeededRNG(seed: config.seed ^ stableHash(take.id))
            for _ in 0..<config.augmentCopies {
                refs.append(Reference(label: take.label, owner: owner,
                                      sequence: Augment.augment(base, config: config.augment, rng: &rng)))
            }
        }
        return refs
    }

    /// Classes ranked by mean of the k smallest distances. `active` restricts to a word subset
    /// (context screens); `_none` is always kept.
    public func rank(_ query: FeatureSequence, active: Set<String>? = nil) -> [RankedLabel] {
        let q = Features.scaled(query, by: scales)
        let allowed = active.map { $0.union([noneLabel]) }
        var nearest: [String: [Double]] = [:]
        for ref in references {
            if let allowed, !allowed.contains(ref.label) { continue }
            var list = nearest[ref.label] ?? []
            let cutoff = list.count >= config.k ? list[list.count - 1] : .infinity
            let d = DTW.distance(q, ref.sequence, band: config.band, cutoff: cutoff)
            guard d.isFinite else { nearest[ref.label] = list; continue }
            let at = list.firstIndex { $0 > d } ?? list.count
            list.insert(d, at: at)
            if list.count > config.k { list.removeLast() }
            nearest[ref.label] = list
        }
        return nearest.compactMap { label, ds in
            ds.isEmpty ? nil : RankedLabel(label: label, score: ds.reduce(0, +) / Double(ds.count))
        }.sorted { $0.score < $1.score }
    }

    public func predict(_ query: FeatureSequence, active: Set<String>? = nil,
                        maxScore: Double = .infinity, minMargin: Double = 0) -> Prediction {
        let ranked = rank(query, active: active)
        let margin = Self.margin(ranked)
        var reason: String?
        if let best = ranked.first {
            if best.label == noneLabel { reason = "Looked like non-word movement" }
            else if best.score > maxScore { reason = "Too far from every trained word" }
            else if margin < minMargin { reason = "Too close between \(ranked[0].label) and \(ranked[1].label)" }
        } else {
            reason = "No usable motion"
        }
        return Prediction(ranked: ranked, margin: margin, accepted: reason == nil, rejectReason: reason)
    }

    static func margin(_ ranked: [RankedLabel]) -> Double {
        guard ranked.count >= 2, ranked[1].score > 0 else { return ranked.isEmpty ? 0 : 1 }
        return max(0, 1 - ranked[0].score / ranked[1].score)
    }
}
