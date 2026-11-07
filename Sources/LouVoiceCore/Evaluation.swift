import Foundation

public struct EvalTake: Sendable {
    public var id: String
    public var label: String
    /// Enrollment block (one pass, re-seat between passes). Held out as a unit (D12).
    public var block: String
    public var features: FeatureSequence
    public init(id: String, label: String, block: String, features: FeatureSequence) {
        self.id = id; self.label = label; self.block = block; self.features = features
    }
}

public struct ConfusedPair: Sendable, Hashable, Identifiable {
    public var a: String, b: String, count: Int
    public var id: String { a + "|" + b }
    public init(a: String, b: String, count: Int) { self.a = a; self.b = b; self.count = count }
}

public struct EvaluationReport: Sendable {
    public enum Mode: String, Sendable { case leaveBlockOut = "Leave-one-block-out", leaveOneOut = "Leave-one-out (optimistic — only one block)" }
    public var mode: Mode
    public var labels: [String]
    /// confusion[actual][predicted]
    public var confusion: [[Int]]
    public var accuracy: Double
    /// Accuracy on real-word takes only.
    public var wordAccuracy: Double
    /// Fraction of `_none` takes correctly rejected.
    public var noneRecall: Double?
    /// Fraction of `_none` takes that came out as a word.
    public var falseAcceptRate: Double?
    public var perLabelAccuracy: [String: Double]
    public var confusedPairs: [ConfusedPair]
    /// Majority-class rate.
    public var chance: Double
    public var permutationMean: Double
    public var pValue: Double
    public var permutations: Int
    /// Leave-one-out within each block — shown only as a contrast to expose leakage.
    public var optimisticAccuracy: Double?
    public var takeCount: Int
    public var blockCount: Int
}

public enum Evaluation {
    /// Holds out whole blocks, computes all test→reference distances once, then reuses them for
    /// the true labelling and every permuted one.
    public static func run(_ takes: [EvalTake], config: ClassifierConfig = ClassifierConfig(),
                           permutations: Int = 200, seed: UInt64 = 7,
                           progress: (@Sendable (Double) -> Void)? = nil) -> EvaluationReport? {
        let takes = takes.filter { $0.features.count >= 4 }
        let labels = Array(Set(takes.map(\.label))).sorted()
        let counts = Dictionary(grouping: takes, by: \.label).mapValues(\.count)
        guard labels.count >= 2, counts.values.allSatisfy({ $0 >= 2 }) else { return nil }
        let labelIndex = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($1, $0) })
        let truth = takes.map { labelIndex[$0.label]! }
        let n = takes.count

        let blocks = Array(Set(takes.map(\.block))).sorted()
        let mode: EvaluationReport.Mode = blocks.count >= 2 ? .leaveBlockOut : .leaveOneOut

        // For each test take: (owner, distance) to every eligible training reference, sorted by distance.
        var neighbours = [[(owner: Int, d: Double)]](repeating: [], count: n)
        let asLabeled = takes.map { LabeledFeatures(id: $0.id, label: $0.label, features: $0.features) }

        func fill(test: [Int], train: [Int], excludeSelf: Bool) {
            let scales = Features.channelScales(train.map { takes[$0].features })
            let refs = Classifier.buildReferences(train.map { asLabeled[$0] }, scales: scales, config: config)
                .map { (owner: train[$0.owner], seq: $0.sequence) }
            for i in test {
                let q = Features.scaled(takes[i].features, by: scales, clip: config.softClip)
                var list: [(owner: Int, d: Double)] = []
                list.reserveCapacity(refs.count)
                for r in refs where !(excludeSelf && r.owner == i) {
                    list.append((r.owner, DTW.distance(q, r.seq, band: config.band)))
                }
                neighbours[i] = list.sorted { $0.d < $1.d }
            }
        }

        switch mode {
        case .leaveBlockOut:
            for (b, block) in blocks.enumerated() {
                let test = (0..<n).filter { takes[$0].block == block }
                let train = (0..<n).filter { takes[$0].block != block }
                fill(test: test, train: train, excludeSelf: false)
                progress?(Double(b + 1) / Double(blocks.count) * 0.85)
            }
        case .leaveOneOut:
            fill(test: Array(0..<n), train: Array(0..<n), excludeSelf: true)
            progress?(0.85)
        }

        let k = config.k
        func predict(_ assignment: [Int]) -> [Int] {
            (0..<n).map { i in
                var sums = [Double](repeating: 0, count: labels.count)
                var got = [Int](repeating: 0, count: labels.count)
                var filled = 0
                for (owner, d) in neighbours[i] {
                    let c = assignment[owner]
                    if got[c] < k {
                        sums[c] += d; got[c] += 1
                        if got[c] == k { filled += 1; if filled == labels.count { break } }
                    }
                }
                var best = 0, bestScore = Double.infinity
                for c in labels.indices where got[c] > 0 {
                    let s = sums[c] / Double(got[c])
                    if s < bestScore { bestScore = s; best = c }
                }
                return best
            }
        }
        func accuracy(_ predicted: [Int], _ actual: [Int]) -> Double {
            Double(zip(predicted, actual).filter { $0 == $1 }.count) / Double(n)
        }

        let predicted = predict(truth)
        let observed = accuracy(predicted, truth)
        var confusion = [[Int]](repeating: [Int](repeating: 0, count: labels.count), count: labels.count)
        for (p, a) in zip(predicted, truth) { confusion[a][p] += 1 }

        var rng = SeededRNG(seed: seed)
        var nullAcc: [Double] = []
        for p in 0..<permutations {
            let shuffled = truth.shuffled(using: &rng)
            nullAcc.append(accuracy(predict(shuffled), shuffled))
            if p % 20 == 0 { progress?(0.85 + 0.15 * Double(p) / Double(max(permutations, 1))) }
        }
        let atLeast = nullAcc.filter { $0 >= observed }.count

        // Summaries.
        let noneIdx = labelIndex[noneLabel]
        let wordTakes = (0..<n).filter { truth[$0] != noneIdx }
        let noneTakes = (0..<n).filter { truth[$0] == noneIdx }
        let wordAccuracy = wordTakes.isEmpty ? 0 : Double(wordTakes.filter { predicted[$0] == truth[$0] }.count) / Double(wordTakes.count)
        let noneRecall = noneTakes.isEmpty ? nil : Double(noneTakes.filter { predicted[$0] == truth[$0] }.count) / Double(noneTakes.count)
        let perLabel = Dictionary(uniqueKeysWithValues: labels.enumerated().map { c, label -> (String, Double) in
            let row = confusion[c], total = row.reduce(0, +)
            return (label, total == 0 ? 0 : Double(row[c]) / Double(total))
        })
        var pairs: [ConfusedPair] = []
        for a in labels.indices { for b in (a + 1)..<max(a + 1, labels.count) {
            let c = confusion[a][b] + confusion[b][a]
            if c > 0 { pairs.append(ConfusedPair(a: labels[a], b: labels[b], count: c)) }
        } }
        pairs.sort { $0.count > $1.count }

        progress?(1)
        return EvaluationReport(
            mode: mode, labels: labels, confusion: confusion, accuracy: observed,
            wordAccuracy: wordAccuracy, noneRecall: noneRecall, falseAcceptRate: noneRecall.map { 1 - $0 },
            perLabelAccuracy: perLabel, confusedPairs: pairs,
            chance: Double(counts.values.max()!) / Double(n),
            permutationMean: nullAcc.isEmpty ? 0 : nullAcc.reduce(0, +) / Double(nullAcc.count),
            pValue: Double(atLeast + 1) / Double(permutations + 1), permutations: permutations,
            optimisticAccuracy: mode == .leaveBlockOut ? withinBlockAccuracy(takes, config: config) : nil,
            takeCount: n, blockCount: blocks.count)
    }

    /// Leave-one-out inside each block, real takes only. Back-to-back takes are near-duplicates,
    /// so this number is inflated; it's reported only to show the gap.
    static func withinBlockAccuracy(_ takes: [EvalTake], config: ClassifierConfig) -> Double? {
        let scales = Features.channelScales(takes.map(\.features))
        let scaled = takes.map { Features.scaled($0.features, by: scales) }
        var correct = 0, total = 0
        for (i, take) in takes.enumerated() {
            var best: [String: [Double]] = [:]
            for (j, other) in takes.enumerated() where j != i && other.block == take.block {
                best[other.label, default: []].append(DTW.distance(scaled[i], scaled[j], band: config.band))
            }
            guard best.count >= 2 else { continue }
            let winner = best.min { a, b in
                mean(a.value.sorted().prefix(config.k)) < mean(b.value.sorted().prefix(config.k))
            }!.key
            total += 1
            if winner == take.label { correct += 1 }
        }
        return total == 0 ? nil : Double(correct) / Double(total)
    }

    private static func mean(_ xs: ArraySlice<Double>) -> Double { xs.isEmpty ? .infinity : xs.reduce(0, +) / Double(xs.count) }
}
