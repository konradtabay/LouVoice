import Foundation

/// Whole-sentence recognition (PRD item 2, D40).
///
/// A sentence capture is turned into one feature sequence, then a dynamic program finds the best
/// split into words: every candidate segment is scored by DTW against that word's templates, plus
/// a per-word insertion penalty and the next-word context (bigram). With a known phrase the same
/// machinery does **forced alignment**, cutting a flowing sentence take into labelled word segments
/// that become training data.
public struct SentenceConfig: Codable, Hashable, Sendable {
    /// Longest sentence capture, seconds. The window ends earlier once you stop mouthing (D43).
    public var windowSeconds = 6.0
    /// End the sentence after this much stillness. TODO(team): 0.8 s; raise it if you pause between words.
    public var stopAfterQuietSeconds = 0.8
    /// Stop when quiet; off = always record the full window.
    public var stopWhenQuiet = true
    /// Shortest / longest single word, seconds.
    public var minWordSeconds = 0.08
    public var maxWordSeconds = 1.2
    /// Most words in one sentence.
    public var maxWords = 8
    /// Cost added per word: higher → fewer, longer words. 0 suits fast, flowing speech (D40).
    public var insertionPenalty = 0.0
    /// Weight of −log P(word | previous) per unit of context strength: Strong (0.5) → 4 (D40).
    public var contextWeight = 8.0
    /// Templates per word used for segment scoring (the most recent real takes).
    public var templatesPerWord = 12
    /// Mean of the k best template distances per segment.
    public var k = 2
    /// How much a template may be squashed / stretched to fit a segment (segment length ÷ template length).
    public var minCompression = 0.25   // D43: fast, flowing words are ~¼ of an isolated take
    public var maxStretch = 2.0
    public init() {}
}

public struct SentenceWord: Sendable, Hashable {
    public var label: String
    /// Frame range in the sentence's feature sequence.
    public var start: Int, end: Int
    /// Mean per-frame DTW cost of the segment against this word (lower = better match).
    public var cost: Double
    /// Runner-up word for the same segment (for correction UI).
    public var alternatives: [String]
}

public struct SentenceResult: Sendable {
    public var words: [SentenceWord]
    public var text: String { words.map(\.label).joined(separator: " ") }
    /// Frame rate of the sequence the frame indices refer to, and the trimmed start offset (seconds).
    public var rate: Double
    public var startOffset: Double
    /// Seconds between the last word's end and the end of the capture window.
    public var trailingSeconds: Double

    public init(words: [SentenceWord], rate: Double, startOffset: Double, trailingSeconds: Double) {
        self.words = words; self.rate = rate; self.startOffset = startOffset; self.trailingSeconds = trailingSeconds
    }
}

public struct SentenceDecoder: Sendable {
    public let config: SentenceConfig
    public let pipeline: PipelineConfig
    let scales: [Double]
    let clip: Double
    let templates: [String: [FeatureSequence]]
    public var words: [String] { templates.keys.sorted() }

    /// Builds from a trained classifier: its channel scales and up to `templatesPerWord` real
    /// (non-augmented) references per word. `_none` is excluded.
    public init?(classifier: Classifier, pipeline: PipelineConfig, config: SentenceConfig = SentenceConfig()) {
        var byWord: [String: [FeatureSequence]] = [:]
        var seenOwners = Set<Int>()
        for ref in classifier.references where ref.label != noneLabel && !ref.synthetic && !seenOwners.contains(ref.owner) {
            seenOwners.insert(ref.owner)                      // first reference per owner is the real take
            byWord[ref.label, default: []].append(ref.sequence)
        }
        guard byWord.count >= 2 else { return nil }
        templates = byWord.mapValues { Array($0.suffix(config.templatesPerWord)) }
        scales = classifier.scales
        clip = classifier.config.softClip
        self.config = config
        self.pipeline = pipeline
    }

    /// Feature sequence of a whole sentence capture: same pipeline as words, trimmed to the
    /// active span as a whole (not per word).
    public func scaled(_ seq: FeatureSequence) -> FeatureSequence { Features.scaled(seq, by: scales, clip: clip) }

    public func features(_ samples: [MotionSample]) -> (seq: FeatureSequence, startOffset: Double, trailing: Double)? {
        guard let f = Features.extract(samples, config: pipeline.features) else { return nil }
        let start = Double(f.energies.count - f.sequence.count) / pipeline.features.rate - f.trailingSeconds
        return (Features.scaled(f.sequence, by: scales, clip: clip), max(0, start), f.trailingSeconds)
    }

    // MARK: Segment scoring

    /// cost[i][len][w]: mean of k best DTW distances of frames i..<i+len to word w (per-frame units).
    /// One open-ended DTW pass per (start, template) scores every segment length at once.
    func segmentCosts(_ seq: FeatureSequence, vocabulary: [String]) -> (lo: Int, hi: Int, costs: [[[Double]]]) {
        let rate = pipeline.features.rate
        let lo = max(3, Int(config.minWordSeconds * rate)), hi = max(lo, Int(config.maxWordSeconds * rate))
        let n = seq.count, dims = seq.dims
        var costs = [[[Double]]](repeating: [], count: n)
        seq.values.withUnsafeBufferPointer { sv in
            for i in 0..<n {
                let maxLen = min(hi, n - i)
                var row = [[Double]](repeating: [Double](repeating: .infinity, count: vocabulary.count), count: hi + 1)
                guard maxLen >= lo else { costs[i] = row; continue }
                for (w, word) in vocabulary.enumerated() {
                    guard let temps = templates[word] else { continue }
                    // per length: k best distances
                    var bestByLen = [[Double]](repeating: [], count: maxLen + 1)
                    for t in temps {
                        let m = t.count
                        guard m > 0 else { continue }
                        t.values.withUnsafeBufferPointer { tv in
                            // D[r][c] over segment frames r (from i) and template frames c.
                            var prev = [Double](repeating: .infinity, count: m)
                            var cur = prev
                            for r in 0..<maxLen {
                                let si = (i + r) * dims
                                for c in 0..<m {
                                    let ti = c * dims
                                    var sum = 0.0
                                    for d in 0..<dims { let x = sv[si + d] - tv[ti + d]; sum += x * x }
                                    let cost = sum.squareRoot()
                                    let best: Double
                                    if r == 0 && c == 0 { best = 0 }
                                    else if r == 0 { best = cur[c - 1] }
                                    else if c == 0 { best = prev[0] }
                                    else { best = min(prev[c], cur[c - 1], prev[c - 1]) }
                                    cur[c] = cost + best
                                }
                                let len = r + 1
                                // Keep lengths within 0.5×–2× the template (slope sanity), normalise by path length.
                                if len >= lo, Double(len) >= config.minCompression * Double(m), Double(len) <= config.maxStretch * Double(m) {
                                    bestByLen[len].append(cur[m - 1] / Double(len + m))
                                }
                                swap(&prev, &cur)
                            }
                        }
                    }
                    for len in lo...maxLen where !bestByLen[len].isEmpty {
                        let ks = bestByLen[len].sorted().prefix(config.k)
                        row[len][w] = ks.reduce(0, +) / Double(ks.count)
                    }
                }
                costs[i] = row
            }
        }
        return (lo, hi, costs)
    }

    // MARK: Decode (unknown words)

    public func decode(_ seq: FeatureSequence, context: ContextModel, active: Set<String>? = nil) -> [SentenceWord] {
        let vocab = words.filter { active?.contains($0) ?? true }
        let n = seq.count
        guard n >= 3, !vocab.isEmpty else { return [] }
        let (lo, hi, costs) = segmentCosts(seq, vocabulary: vocab)
        let W = vocab.count
        let trie = PhraseTrie(weighted: context.expectedSentences, vocabulary: vocab, smoothing: context.smoothing)
        let S = trie.stateCount
        let lm = config.contextWeight * context.weight
        let M = config.maxWords
        // best[j][state][m]: cost of frames 0..<j as m words, ending in prefix-tree state `state`.
        var best = [[[Double]]](repeating: [[Double]](repeating: [Double](repeating: .infinity, count: M + 1), count: S), count: n + 1)
        var back = [[[(i: Int, s: Int, w: Int)]]](repeating: [[(Int, Int, Int)]](repeating: [(Int, Int, Int)](repeating: (-1, -1, -1), count: M + 1), count: S), count: n + 1)
        best[0][PhraseTrie.root][0] = 0
        for j in 1...n where j >= lo {
            for len in lo...min(hi, j) {
                let i = j - len
                for m in 0..<M {
                    for st in 0..<S where best[i][st][m].isFinite {
                        for w in 0..<W {
                            let seg = costs[i][len][w]
                            guard seg.isFinite else { continue }
                            let (next, logP) = trie.step(st, w)
                            let c = best[i][st][m] + seg * Double(len) + config.insertionPenalty - lm * logP
                            if c < best[j][next][m + 1] { best[j][next][m + 1] = c; back[j][next][m + 1] = (i, st, w) }
                        }
                    }
                }
            }
        }
        // Finish: add the cost of ending the sentence in each state (end-of-sentence, D41).
        var end: (s: Int, m: Int, c: Double) = (-1, -1, .infinity)
        for st in 0..<S { for m in 1...M where best[n][st][m].isFinite {
            let c = best[n][st][m] - lm * trie.endLog(st)
            if c < end.c { end = (st, m, c) }
        } }
        guard end.s >= 0 else { return [] }
        var out: [SentenceWord] = []
        var j = n, st = end.s, m = end.m
        while m >= 1 {
            let (i, prev, w) = back[j][st][m]
            guard i >= 0 else { break }
            let len = j - i
            let alts = vocab.indices.filter { $0 != w && costs[i][len][$0].isFinite }
                .sorted { costs[i][len][$0] < costs[i][len][$1] }.prefix(2).map { vocab[$0] }
            out.append(SentenceWord(label: vocab[w], start: i, end: j, cost: costs[i][len][w], alternatives: alts))
            j = i; st = prev; m -= 1
        }
        return out.reversed()
    }

    public func decode(_ samples: [MotionSample], context: ContextModel, active: Set<String>? = nil) -> SentenceResult? {
        guard let f = features(samples) else { return nil }
        return SentenceResult(words: decode(f.seq, context: context, active: active), rate: pipeline.features.rate,
                              startOffset: f.startOffset, trailingSeconds: f.trailing)
    }

    // MARK: Forced alignment (known words)

    /// Best split of `seq` into exactly `phrase` (in order). Returns nil if it can't fit.
    public func align(_ seq: FeatureSequence, phrase: [String]) -> [SentenceWord]? {
        let vocab = Array(Set(phrase)).sorted()
        guard phrase.allSatisfy({ templates[$0] != nil }), seq.count >= phrase.count * 3 else { return nil }
        let (lo, hi, costs) = segmentCosts(seq, vocabulary: vocab)
        let idx = Dictionary(uniqueKeysWithValues: vocab.enumerated().map { ($1, $0) })
        let n = seq.count, K = phrase.count
        var best = [[Double]](repeating: [Double](repeating: .infinity, count: K + 1), count: n + 1)
        var back = [[Int]](repeating: [Int](repeating: -1, count: K + 1), count: n + 1)
        best[0][0] = 0
        for j in 1...n {
            for k in 1...K {
                let w = idx[phrase[k - 1]]!
                for len in stride(from: lo, through: min(hi, j), by: 1) {
                    let i = j - len
                    guard best[i][k - 1].isFinite, costs[i][len][w].isFinite else { continue }
                    let c = best[i][k - 1] + costs[i][len][w] * Double(len)
                    if c < best[j][k] { best[j][k] = c; back[j][k] = i }
                }
            }
        }
        guard best[n][K].isFinite else { return nil }
        var out: [SentenceWord] = []
        var j = n
        for k in stride(from: K, through: 1, by: -1) {
            let i = back[j][k]
            let w = idx[phrase[k - 1]]!
            out.append(SentenceWord(label: phrase[k - 1], start: i, end: j, cost: costs[i][j - i][w], alternatives: []))
            j = i
        }
        return out.reversed()
    }

    /// Cuts the raw samples of each aligned word (plus a little context) so they can be stored as
    /// ordinary word takes and go through the normal word pipeline.
    public static func cut(_ samples: [MotionSample], result: SentenceResult, pad: Double = 0.15, preroll: Double = 0.3) -> [[MotionSample]] {
        guard let t0 = samples.first?.t else { return [] }
        return result.words.map { w in
            let start = t0 + result.startOffset + Double(w.start) / result.rate - preroll
            let end = t0 + result.startOffset + Double(w.end) / result.rate + pad
            return samples.filter { $0.t >= start && $0.t <= end }
        }
    }
}

/// Word-level sentence accuracy: matching words by position after alignment (Levenshtein).
public enum SentenceScore {
    public static func editDistance(_ a: [String], _ b: [String]) -> Int {
        var d = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var prev = d[0]; d[0] = i + 1
            for (j, y) in b.enumerated() {
                let cur = d[j + 1]
                d[j + 1] = min(d[j] + 1, d[j + 1] + 1, prev + (x == y ? 0 : 1))
                prev = cur
            }
        }
        return d[b.count]
    }
    /// 1 − word error rate, floored at 0.
    public static func wordAccuracy(said: [String], heard: [String]) -> Double {
        guard !said.isEmpty else { return heard.isEmpty ? 1 : 0 }
        return max(0, 1 - Double(editDistance(said, heard)) / Double(said.count))
    }
}

extension Tuner {
    public struct SentenceBenchmark: Sendable {
        public var wordAccuracy: Double, exact: Double, boundaryErrorMs: Double, alignedExact: Double
        public var decodeSeconds: Double, sentences: Int
        /// Failed decodes (heard), for diagnosis.
        public var failures: [String] = []
    }

    /// Stitched-sentence benchmark (no real sentence takes needed): for each held-out block, the
    /// model trains on the other blocks; sentences are built by concatenating one held-out word
    /// take per phrase word, optionally time-compressed (`speed` > 1 = faster).
    public static func sentenceBenchmark(_ takes: [RawTake], phrase: [String], config: PipelineConfig,
                                         sentence: SentenceConfig = SentenceConfig(), context: ContextModel,
                                         speed: Double = 1, perBlock: Int = 12, seed: UInt64 = 5,
                                         sentences: [[String]]? = nil, randomLength: ClosedRange<Int>? = nil) -> SentenceBenchmark? {
        var rng = SeededRNG(seed: seed)
        var failures: [String] = []
        var acc = 0.0, exact = 0, total = 0, boundaryErr = 0.0, boundaries = 0, alignedExact = 0, seconds = 0.0
        for block in Set(takes.map(\.block)).sorted() {
            let test = takes.filter { $0.block == block }
            guard phrase.allSatisfy({ w in test.contains { $0.label == w } }) else { continue }
            let train = TrainingSet.build(takes.filter { $0.block != block }, config: config)
            guard let clf = Classifier(training: train, config: config.classifier),
                  let dec = SentenceDecoder(classifier: clf, pipeline: config, config: sentence) else { continue }
            let feats = Dictionary(grouping: test.compactMap { t in Features.extract(t.samples, config: config.features).map { (t.label, $0.sequence) } },
                                   by: { $0.0 }).mapValues { $0.map(\.1) }
            _ = 0
            for _ in 0..<perBlock {
                // What is "said": the phrase, one of `sentences`, or a random word sequence (off-script test).
                var said = phrase
                if let sentences, let pick = sentences.randomElement(using: &rng) { said = pick }
                if let randomLength {
                    let vocab = Array(Set(phrase))
                    said = (0..<Int.random(in: randomLength, using: &rng)).map { _ in vocab.randomElement(using: &rng)! }
                }
                var values: [Double] = []
                var cuts: [Int] = []
                var dims = 0, vdims = 0
                for w in said {
                    guard var seq = feats[w]?.randomElement(using: &rng) else { continue }
                    if speed != 1 { seq = resample(seq, factor: 1 / speed) }
                    dims = seq.dims; vdims = seq.vectorDims
                    values += seq.values
                    cuts.append(values.count / dims)
                }
                let joined = dec.scaled(FeatureSequence(values: values, dims: dims, vectorDims: vdims))
                let start = Date()
                let heard = dec.decode(joined, context: context).map(\.label)
                seconds += Date().timeIntervalSince(start)
                acc += SentenceScore.wordAccuracy(said: said, heard: heard)
                if heard == said { exact += 1 } else if failures.count < 40 { failures.append(said.joined(separator: " ") + " → " + heard.joined(separator: " ")) }
                if let aligned = dec.align(joined, phrase: said) {
                    for (k, w) in aligned.enumerated() where k < cuts.count - 1 {
                        boundaryErr += abs(Double(w.end - cuts[k])) / config.features.rate * 1000; boundaries += 1
                    }
                    if zip(aligned.dropLast().map(\.end), cuts.dropLast()).allSatisfy({ abs($0 - $1) <= 3 }) { alignedExact += 1 }
                }
                total += 1
            }
        }
        guard total > 0 else { return nil }
        return SentenceBenchmark(wordAccuracy: acc / Double(total), exact: Double(exact) / Double(total),
                                 boundaryErrorMs: boundaries == 0 ? 0 : boundaryErr / Double(boundaries),
                                 alignedExact: Double(alignedExact) / Double(total),
                                 decodeSeconds: seconds / Double(total), sentences: total, failures: failures)
    }

    static func resample(_ seq: FeatureSequence, factor: Double) -> FeatureSequence {
        let n = max(3, Int((Double(seq.count) * factor).rounded()))
        var values = [Double](repeating: 0, count: n * seq.dims)
        for k in 0..<n {
            let pos = Double(k) * Double(seq.count - 1) / Double(max(n - 1, 1))
            let i = min(Int(pos), seq.count - 2), f = pos - Double(i)
            for d in 0..<seq.dims { values[k * seq.dims + d] = seq[frame: i, dim: d] * (1 - f) + seq[frame: i + 1, dim: d] * f }
        }
        return FeatureSequence(values: values, dims: seq.dims, vectorDims: seq.vectorDims)
    }
}


/// Full-history phrase model for sentence decoding (D41): a prefix tree of the expected phrases
/// with an end-of-sentence mark. The probability of the next word depends on everything said so
/// far, and ending early or running on past the end of a phrase is penalised. Leaving the tree
/// (an unexpected word) is allowed via smoothing and lands in a "free" state where every word,
/// and ending, are equally likely, so off-script sentences can still be decoded.
struct PhraseTrie {
    static let root = 0
    private var children: [[Int: Int]] = [[:]]     // node → word index → child node
    private var visits: [Double] = [0]              // how many phrases pass through each node
    private var ends: [Double] = [0]                // how many phrases end at each node
    private let vocabularyCount: Int
    private let smoothing: Double
    var stateCount: Int { children.count + 1 }      // + free state
    private var free: Int { children.count }

    init(phrases: [[String]], vocabulary: [String], smoothing: Double) {
        self.init(weighted: phrases.map { ($0, 1.0) }, vocabulary: vocabulary, smoothing: smoothing)
    }

    init(weighted phrases: [(words: [String], weight: Double)], vocabulary: [String], smoothing: Double) {
        vocabularyCount = vocabulary.count
        self.smoothing = max(smoothing, 1e-3)
        let index = Dictionary(uniqueKeysWithValues: vocabulary.enumerated().map { ($1, $0) })
        for (phrase, weight) in phrases {
            let ids = phrase.compactMap { index[$0] }
            guard ids.count == phrase.count, !ids.isEmpty, weight > 0 else { continue }   // skip phrases with untrained words
            var node = Self.root
            visits[node] += weight
            for w in ids {
                if let c = children[node][w] { node = c } else {
                    children.append([:]); visits.append(0); ends.append(0)
                    children[node][w] = children.count - 1
                    node = children.count - 1
                }
                visits[node] += weight
            }
            ends[node] += weight
        }
    }

    /// Next state and log P(word | history).
    func step(_ state: Int, _ w: Int) -> (Int, Double) {
        let options = Double(vocabularyCount + 1)                       // words + end
        if state == free { return (free, log(1 / options)) }
        let total = visits[state] + smoothing * options
        if let c = children[state][w] { return (c, log((visits[c] + smoothing) / total)) }
        return (free, log(smoothing / total))
    }

    /// log P(end of sentence | history).
    func endLog(_ state: Int) -> Double {
        let options = Double(vocabularyCount + 1)
        if state == free { return log(1 / options) }
        return log((ends[state] + smoothing) / (visits[state] + smoothing * options))
    }
}
