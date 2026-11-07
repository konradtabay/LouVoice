import Foundation

/// Next-word prediction from expected phrases (D37): a smoothed bigram model P(word | previous).
/// Motion scores are turned into likelihoods and combined with the prior, so a look-alike word
/// that doesn't fit the sentence is ruled out, while a strong motion match can still win
/// (smoothing keeps every word possible).
public struct ContextModel: Codable, Hashable, Sendable {
    /// Expected phrases, one per entry, words separated by spaces.
    public var phrases: [String] = ["hello can you hear me"]
    /// How much the prior counts against the motion evidence (0 = off). Default = Strong (D38).
    public var weight: Double = 0.5
    /// Softness of the motion likelihood: smaller trusts the DTW ranking more.
    public var temperature: Double = 0.1
    /// Add-α smoothing so out-of-order words stay possible.
    public var smoothing: Double = 0.1
    /// Also expect any contiguous part of each phrase ("hello can", "you hear me"), in order (D44).
    public var includeParts: Bool = true
    /// Shortest part that counts as a phrase of its own.
    public var minPartWords: Int = 2
    /// How much a part counts relative to a full phrase (D44).
    public var partWeight: Double = 1
    public init() {}

    enum CodingKeys: String, CodingKey { case phrases, weight, temperature, smoothing, includeParts, minPartWords, partWeight }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ContextModel()
        phrases = try c.decodeIfPresent([String].self, forKey: .phrases) ?? d.phrases
        weight = try c.decodeIfPresent(Double.self, forKey: .weight) ?? d.weight
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? d.temperature
        smoothing = try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? d.smoothing
        includeParts = try c.decodeIfPresent(Bool.self, forKey: .includeParts) ?? d.includeParts
        minPartWords = try c.decodeIfPresent(Int.self, forKey: .minPartWords) ?? d.minPartWords
        partWeight = try c.decodeIfPresent(Double.self, forKey: .partWeight) ?? d.partWeight
    }

    public static let start = "<s>"

    /// Presets measured on real takes (D37): how much context may override the motion.
    public enum Strength: String, CaseIterable, Codable, Sendable {
        case off, balanced, strong, phraseLock
        public var label: String {
            switch self { case .off: "Off"; case .balanced: "Balanced"; case .strong: "Strong"; case .phraseLock: "Phrase lock" }
        }
        public var detail: String {
            switch self {
            case .off: "Motion only."
            case .balanced: "Helps when you say the phrase in order, costs nothing when you don't."
            case .strong: "Much better in order; out-of-order words get harder."
            case .phraseLock: "Near-certain for the expected phrase, but mostly ignores your mouth. Demo only."
            }
        }
        var values: (Double, Double) {
            switch self { case .off: (0, 0.05); case .balanced: (0.3, 0.05); case .strong: (0.5, 0.1); case .phraseLock: (1.0, 0.1) }
        }
    }

    public var strength: Strength {
        get { Strength.allCases.first { $0.values == (weight, temperature) } ?? .balanced }
        set { (weight, temperature) = newValue.values }
    }

    /// The phrases as written.
    public var tokenized: [[String]] {
        phrases.map { $0.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) }.filter { !$0.isEmpty }
    }

    /// Every sentence the model expects with its weight: the phrases (1) plus, if enabled, their
    /// contiguous parts (`partWeight` each).
    public var expectedSentences: [(words: [String], weight: Double)] {
        let base = tokenized
        var out = base.map { ($0, 1.0) }
        guard includeParts else { return out }
        for words in base where words.count > minPartWords {
            for len in max(1, minPartWords)..<words.count {
                for start in 0...(words.count - len) { out.append((Array(words[start..<(start + len)]), partWeight)) }
            }
        }
        return out
    }

    /// P(next | previous) over `vocabulary`. `previous == nil` means start of a phrase.
    /// After a phrase-final word, the next word is predicted like a phrase start.
    public func probabilities(after previous: String?, vocabulary: [String]) -> [String: Double] {
        var counts: [String: Double] = [:]
        let prev = previous ?? Self.start
        var sawPrev = false
        for words in tokenized {
            let seq = [Self.start] + words
            for i in 0..<(seq.count - 1) where seq[i] == prev {
                counts[seq[i + 1], default: 0] += 1
                sawPrev = true
            }
            if words.last == prev, prev != Self.start, let first = words.first { counts[first, default: 0] += 1; sawPrev = true }
        }
        if !sawPrev, prev != Self.start { return probabilities(after: nil, vocabulary: vocabulary) }
        let total = counts.values.reduce(0, +) + smoothing * Double(vocabulary.count)
        return Dictionary(uniqueKeysWithValues: vocabulary.map { ($0, ((counts[$0] ?? 0) + smoothing) / max(total, 1e-12)) })
    }

    /// Most likely next words, best first.
    public func expected(after previous: String?, vocabulary: [String]) -> [(word: String, p: Double)] {
        probabilities(after: previous, vocabulary: vocabulary).map { ($0.key, $0.value) }.sorted { $0.p > $1.p }
    }

    /// Re-rank motion results with the prior. Scores become −log(posterior), so lower is still
    /// better and the classifier's margin rule keeps working. `_none` gets a neutral prior.
    public func rescore(_ ranked: [RankedLabel], previous: String?) -> [RankedLabel] {
        guard weight > 0, let best = ranked.first?.score else { return ranked }
        let vocab = ranked.map(\.label).filter { $0 != noneLabel }
        guard !vocab.isEmpty else { return ranked }
        let prior = probabilities(after: previous, vocabulary: vocab)
        let neutral = 1.0 / Double(vocab.count)
        let t = max(temperature, 1e-4)
        let logs = ranked.map { r -> (String, Double) in
            let acoustic = -(r.score - best) / t
            let p = r.label == noneLabel ? neutral : (prior[r.label] ?? neutral)
            return (r.label, acoustic + weight * log(max(p, 1e-12)))
        }
        let maxLog = logs.map(\.1).max() ?? 0
        let z = logs.map { exp($0.1 - maxLog) }.reduce(0, +)
        return logs.map { RankedLabel(label: $0.0, score: -(($0.1 - maxLog) - log(z))) }.sorted { $0.score < $1.score }
    }
}

extension Tuner {
    /// Leave-one-block-out ranked results for every take (each fold's model never saw the take's block).
    public static func loboRankings(_ takes: [RawTake], config: PipelineConfig) -> [(take: RawTake, ranked: [RankedLabel])] {
        var out: [(RawTake, [RankedLabel])] = []
        for block in Set(takes.map(\.block)).sorted() {
            let train = takes.filter { $0.block != block }.compactMap { t in
                Features.extract(t.samples, config: config.features).map { LabeledFeatures(id: t.id, label: t.label, features: $0.sequence) }
            }
            guard let clf = Classifier(training: train, config: config.classifier) else { continue }
            for t in takes where t.block == block {
                guard let f = Features.extract(t.samples, config: config.features) else { continue }
                out.append((t, clf.rank(f.sequence)))
            }
        }
        return out
    }

    public struct ContextScore: Sendable { public var words: Double; public var phrases: Double; public var draws: Int }

    /// Simulates saying `phrase` word by word, drawing one held-out take per word from the same block.
    /// `chained`: the context is the previous *decoded* word (realistic); otherwise the true word.
    public static func contextScore(_ rankings: [(take: RawTake, ranked: [RankedLabel])], phrase: [String],
                                    context: ContextModel, chained: Bool, randomOrder: Bool = false,
                                    draws: Int = 400, seed: UInt64 = 3) -> ContextScore? {
        var rng = SeededRNG(seed: seed)
        let byBlock = Dictionary(grouping: rankings, by: { $0.take.block })
        let usable = byBlock.values.filter { group in phrase.allSatisfy { w in group.contains { $0.take.label == w } } }
        guard !usable.isEmpty else { return nil }
        var wordHits = 0, wordTotal = 0, phraseHits = 0
        for _ in 0..<draws {
            let group = usable.randomElement(using: &rng)!
            var previous: String?
            var allRight = true
            // randomOrder: same words in a random sequence; tests that context doesn't override the motion.
            let sequence = randomOrder ? (0..<phrase.count).map { _ in phrase.randomElement(using: &rng)! } : phrase
            for word in sequence {
                let r = group.filter { $0.take.label == word }.randomElement(using: &rng)!
                let ranked = context.rescore(r.ranked, previous: previous)
                let guess = ranked.first?.label ?? ""
                if guess == word { wordHits += 1 } else { allRight = false }
                wordTotal += 1
                previous = chained ? (guess == noneLabel ? previous : guess) : word
            }
            if allRight { phraseHits += 1 }
        }
        return ContextScore(words: Double(wordHits) / Double(wordTotal), phrases: Double(phraseHits) / Double(draws), draws: draws)
    }
}
