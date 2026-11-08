import Foundation

/// Word mode (D49) on real takes: only the words of one phrase (plus `_none`) can come out.
/// Every isolated-word take of those words is decoded by a model that never saw its block,
/// the same way `Decoder.trigger()` does it, under a few training-set / context choices.
public enum WordModeBenchmark {
    public struct Row: Sendable {
        public var name: String
        public var correct = 0, wrong = 0, refused = 0
        public var total: Int { correct + wrong + refused }
        public var perWord: [String: (Int, Int)] = [:]
        /// (margin after context, was it right) for every decode that wasn't refused.
        public var margins: [(Double, Bool)] = []
    }

    /// `pool`: which training takes the fold may use. `previous`: context word for the decode.
    public struct Variant: Sendable {
        public var name: String
        public var pool: @Sendable (Take) -> Bool
        public var contextWeight: Double
        public var previous: Previous
        public enum Previous: Sendable { case none, randomOther, inOrder }
        public init(name: String, pool: @escaping @Sendable (Take) -> Bool, contextWeight: Double, previous: Previous) {
            self.name = name; self.pool = pool; self.contextWeight = contextWeight; self.previous = previous
        }
    }

    /// Isolated-word blocks: enrollment and quiz, not cuts from sentences or confirmed decodes.
    public static func isIsolated(_ t: Take) -> Bool { t.block.hasPrefix("enroll-") || t.block.hasPrefix("quiz-") }

    public static func run(_ dataset: Dataset, words: [String], variants: [Variant], config: PipelineConfig = .defaults,
                           maxScore: Double = 3.0) -> [Row] {
        let vocab = Set(words)
        let all = dataset.takes.filter { !$0.isSentence }
        let tests = all.filter { isIsolated($0) && vocab.contains($0.label) }
        let folds = Set(tests.map(\.block)).sorted()
        var rows = variants.map { Row(name: $0.name) }
        var rng = SeededRNG(seed: 7)
        for block in folds {
            for (vi, v) in variants.enumerated() {
                // Quiz takes are never trained on; a word block's fold leaves out that block.
                let train = all.filter { !$0.isTest && $0.block != block && v.pool($0) }.map(Tuner.RawTake.init)
                guard let clf = Classifier(training: TrainingSet.build(train, config: config), config: config.classifier) else { continue }
                var ctx = config.context
                ctx.weight = v.contextWeight
                for t in tests where t.block == block {
                    guard let f = Features.extract(t.samples, config: config.features) else { rows[vi].refused += 1; continue }
                    let motion = clf.rank(f.sequence, active: vocab)
                    let prev: String?
                    switch v.previous {
                    case .none: prev = nil
                    case .randomOther: prev = words.filter { $0 != t.label }.randomElement(using: &rng)
                    case .inOrder: prev = words.firstIndex(of: t.label).flatMap { $0 > 0 ? words[$0 - 1] : nil }
                    }
                    let ranked = ctx.rescore(motion, previous: prev)
                    let best = ranked.first?.label
                    var cell = rows[vi].perWord[t.label] ?? (0, 0)
                    cell.1 += 1
                    if best == nil || best == noneLabel || (motion.first?.score ?? .infinity) > maxScore { rows[vi].refused += 1 }
                    else {
                        if best == t.label { rows[vi].correct += 1; cell.0 += 1 } else { rows[vi].wrong += 1 }
                        rows[vi].margins.append((Classifier.margin(ranked), best == t.label))
                    }
                    rows[vi].perWord[t.label] = cell
                }
            }
        }
        return rows
    }
}
