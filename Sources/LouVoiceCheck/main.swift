import Foundation
import LouVoiceCore

// Self-test runner for machines without XCTest (Command Line Tools only).
//   swift run LouVoiceCheck             run all checks
//   swift run LouVoiceCheck --sim-eval  leave-block-out evaluation on simulated words
let args: [String] = Array(CommandLine.arguments.dropFirst())
let defaultWords: [String] = ["hello", "can", "you", "hear", "me"]
if args.contains("--sim-eval") {
    let custom: [String] = args.filter { !$0.hasPrefix("-") && !$0.isEmpty }
    let words: [String] = custom.isEmpty ? defaultWords : custom
    let takes = SelfTests.simulatedTakes(words: words, reps: 3, blocks: 3, noise: true, seed: 21)
    guard let r = Evaluation.run(takes, permutations: 50) else {
        print("not enough data:", Dictionary(grouping: takes, by: \.label).mapValues { $0.map(\.features.count) })
        exit(1)
    }
    print("SIMULATED DATA — proves the pipeline runs, not that AirPods work.")
    print(String(format: "%@: accuracy %.0f%%  words %.0f%%  none-recall %@  optimistic %@  chance %.0f%%  p=%.3f",
                 r.mode.rawValue, r.accuracy * 100, r.wordAccuracy * 100,
                 r.noneRecall.map { String(format: "%.0f%%", $0 * 100) } ?? "-",
                 r.optimisticAccuracy.map { String(format: "%.0f%%", $0 * 100) } ?? "-",
                 r.chance * 100, r.pValue))
    for (label, acc) in r.perLabelAccuracy.sorted(by: { $0.key < $1.key }) { print(String(format: "  %-10@ %.0f%%", label, acc * 100)) }
    print("Most confused:", r.confusedPairs.prefix(5).map { "\($0.a)↔\($0.b)×\($0.count)" }.joined(separator: ", "))
    exit(0)
}
// --eval <dataset.json> [--tune]: honest evaluation of recorded takes, optionally auto-tuned.
// --cnn-probs <weights.json> <features.json> <out.json>: Swift CNN probabilities for every exported
// take, to check the Swift forward pass against the Python one (D53).
if let i = args.firstIndex(of: "--cnn-probs"), i + 3 < args.count {
    let path = { (s: String) in URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }
    let model = try! CNNWordModel(contentsOf: path(args[i + 1]))
    let root = try! JSONSerialization.jsonObject(with: Data(contentsOf: path(args[i + 2]))) as! [String: Any]
    let start = Date()
    var out: [[Double]] = []
    for t in root["takes"] as! [[String: Any]] {
        let values = (t["values"] as! [NSNumber]).map(\.doubleValue)
        let seq = FeatureSequence(values: values, dims: t["dims"] as! Int, vectorDims: t["vectorDims"] as? Int)
        out.append(seq.count >= 4 ? model.probabilities(seq) : [])
    }
    try! JSONSerialization.data(withJSONObject: ["labels": model.labels, "probs": out]).write(to: path(args[i + 3]))
    print(String(format: "%d takes in %.2f s (%.1f ms each)", out.count, Date().timeIntervalSince(start),
                 Date().timeIntervalSince(start) / Double(max(out.count, 1)) * 1000))
    exit(0)
}

// --calibration-sim <weights.json> <features.json> [k]: D55 in Swift. For every ordered pair of
// tonight's quizzes, calibrate on the first k takes per word of one and test on all of the other.
if let i = args.firstIndex(of: "--calibration-sim"), i + 2 < args.count {
    let path = { (s: String) in URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }
    let model = try! CNNWordModel(contentsOf: path(args[i + 1]))
    let k = i + 3 < args.count ? Int(args[i + 3]) ?? 4 : 4
    let root = try! JSONSerialization.jsonObject(with: Data(contentsOf: path(args[i + 2]))) as! [String: Any]
    struct Row { var seq: FeatureSequence; var label: String; var block: String; var test: Bool }
    let rows: [Row] = (root["takes"] as! [[String: Any]]).compactMap { t in
        let seq = FeatureSequence(values: (t["values"] as! [NSNumber]).map(\.doubleValue), dims: t["dims"] as! Int,
                                  vectorDims: t["vectorDims"] as? Int)
        let label = t["label"] as! String
        guard seq.count >= 4, model.labels.contains(label) else { return nil }
        return Row(seq: seq, label: label, block: t["block"] as! String, test: t["test"] as! Bool)
    }
    let quizzes = Set(rows.filter { $0.block.hasPrefix("quiz-") && $0.block >= "quiz-20261107-23" }.map(\.block)).sorted()
    var rng = SeededRNG(seed: 0)
    let replay = Array(rows.filter { !$0.test }.shuffled(using: &rng).prefix(150)).map { ($0.seq, $0.label) }
    let words = model.labels.filter { $0 != noneLabel }
    var base = (0, 0), cal = (0, 0)
    var perWord: [String: (Int, Int, Int)] = [:]
    let start = Date()
    for a in quizzes { for b in quizzes where b != a {
        let qa = rows.filter { $0.block == a }, qb = rows.filter { $0.block == b }
        let calib = words.flatMap { w in qa.filter { $0.label == w }.prefix(k).map { ($0.seq, $0.label) } }
        let adapted = model.calibrated(calibration: calib, replay: replay)
        for t in qb {
            let p0 = model.rank(t.seq).first?.label == t.label, p1 = adapted.rank(t.seq).first?.label == t.label
            base.0 += p0 ? 1 : 0; cal.0 += p1 ? 1 : 0; base.1 += 1; cal.1 += 1
            var c = perWord[t.label] ?? (0, 0, 0); c.0 += p0 ? 1 : 0; c.1 += p1 ? 1 : 0; c.2 += 1; perWord[t.label] = c
        }
    } }
    print("quizzes: \(quizzes.joined(separator: ", ")); \(k) calibration takes per word; \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
    print("not calibrated: \(base.0)/\(base.1)   calibrated: \(cal.0)/\(cal.1)")
    print(words.map { w in let c = perWord[w] ?? (0, 0, 0); return "\(w) \(c.0)→\(c.1)/\(c.2)" }.joined(separator: "  "))
    exit(0)
}

// --word-check <old.json> <new.json> [weights.json]: every word-mode take (5 words + _none) that is in
// new.json but not old.json, decoded by DTW trained on old.json's training takes and by the CNN —
// the honest live check for D53. Labels of "confirmed" takes are what was accepted, not ground truth.
if let i = args.firstIndex(of: "--word-check"), i + 2 < args.count {
    let path = { (s: String) in URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }
    let load = { (s: String) in try! JSONDecoder().decode(Dataset.self, from: Data(contentsOf: path(s))) }
    let old = load(args[i + 1]), new = load(args[i + 2])
    let cnn = try! CNNWordModel(contentsOf: path(i + 3 < args.count && !args[i + 3].hasPrefix("--") ? args[i + 3] : "Resources/Models/word_cnn.json"))
    let words = ContextModel().tokenized.first ?? []
    let allowed = Set(words)
    let config = PipelineConfig.defaults
    let train = old.trainingTakes.map(Tuner.RawTake.init)
    let clf = Classifier(training: TrainingSet.build(train, config: config), config: config.classifier)!
    let oldIDs = Set(old.takes.map(\.id))
    let fresh = new.takes.filter { !oldIDs.contains($0.id) && !$0.isSentence && (allowed.contains($0.label) || $0.label == noneLabel) }
    var dtwRight = 0, cnnRight = 0
    var cnnPicks: [String: Int] = [:], dtwPicks: [String: Int] = [:]
    print("\(fresh.count) new word-mode takes. label | DTW | CNN (top 3 probabilities)")
    for t in fresh.sorted(by: { $0.createdAt < $1.createdAt }) {
        guard let fd = Features.extract(t.samples, config: config.features) else { print("\(t.label): no features"); continue }
        let d = clf.rank(fd.sequence, active: allowed).first?.label ?? "-"
        let ranked = cnn.rank(fd.sequence, allowed: allowed.union([noneLabel]))
        let c = ranked.first?.label ?? "-"
        dtwRight += d == t.label ? 1 : 0; cnnRight += c == t.label ? 1 : 0
        dtwPicks[d, default: 0] += 1; cnnPicks[c, default: 0] += 1
        let top = ranked.prefix(3).map { String(format: "%@ %.2f", displayLabel($0.label), 1 - $0.score) }.joined(separator: ", ")
        print(String(format: "%@ %-8@ | %-8@ | %-8@ (%@)", t.block.prefix(9) == "confirmed" ? "accepted" : "prompted",
                     displayLabel(t.label), displayLabel(d), displayLabel(c), top))
    }
    print("agree with label: DTW \(dtwRight)/\(fresh.count), CNN \(cnnRight)/\(fresh.count)")
    print("DTW answers:", dtwPicks.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    print("CNN answers:", cnnPicks.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    exit(0)
}

func displayLabel(_ l: String) -> String { l == noneLabel ? "(none)" : l }

if let i = args.firstIndex(of: "--eval"), i + 1 < args.count {
    let url = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
    guard let data = try? Data(contentsOf: url), var dataset = try? JSONDecoder().decode(Dataset.self, from: data) else {
        print("Can't read dataset at \(url.path)"); exit(1)
    }
    // --merge <other.json> (repeatable): pool sessions; blocks stay distinct.
    for (j, a) in args.enumerated() where a == "--merge" && j + 1 < args.count {
        let u = URL(fileURLWithPath: (args[j + 1] as NSString).expandingTildeInPath)
        if let d = try? Data(contentsOf: u), let other = try? JSONDecoder().decode(Dataset.self, from: d) {
            dataset.takes += other.takes
            print("merged \(other.takes.count) takes from \(u.lastPathComponent)")
        }
    }
    let train = dataset.trainingTakes.map(Tuner.RawTake.init)
    let blocks = Set(train.map(\.block)).count
    print("\(train.count) training takes, \(blocks) blocks, \(dataset.testTakes.count) quiz takes")

    // --word-mode: Speak › Word accuracy on isolated takes of "hello can you hear me" (D49, D50).
    if args.contains("--word-mode") {
        let words = ContextModel().tokenized.first ?? defaultWords
        let strong = ContextModel().weight
        let everything: @Sendable (Take) -> Bool = { _ in true }
        let isolated: @Sendable (Take) -> Bool = WordModeBenchmark.isIsolated
        let variants: [WordModeBenchmark.Variant] = [
            .init(name: "all takes, Strong context, any order", pool: everything, contextWeight: strong, previous: .randomOther),
            .init(name: "all takes, no context", pool: everything, contextWeight: 0, previous: .none),
            .init(name: "all takes, Strong context, in phrase order", pool: everything, contextWeight: strong, previous: .inOrder),
            .init(name: "all takes, Balanced, any order", pool: everything, contextWeight: 0.3, previous: .randomOther),
            .init(name: "isolated takes only, no context", pool: isolated, contextWeight: 0, previous: .none),
        ]
        for r in WordModeBenchmark.run(dataset, words: words, variants: variants) {
            print(String(format: "%-42@ right %3d/%d = %3.0f%%   wrong %d   refused %d", r.name, r.correct, r.total,
                         Double(r.correct) / Double(max(r.total, 1)) * 100, r.wrong, r.refused))
            print("    " + words.map { w in let c = r.perWord[w] ?? (0, 0); return "\(w) \(c.0)/\(c.1)" }.joined(separator: "  "))
            // "Not sure, say it again" below a margin: how often a spoken word is right vs how often it asks again.
            for gate in [0.0, 0.1, 0.2, 0.3, 0.5, 0.75, 1.0, 1.5, 2.0] {
                let kept = r.margins.filter { $0.0 >= gate }
                let right = kept.filter(\.1).count
                print(String(format: "      margin ≥ %.2f: spoken %3d/%d, right when spoken %3.0f%%, overall right %3.0f%%", gate,
                             kept.count, r.total, Double(right) / Double(max(kept.count, 1)) * 100, Double(right) / Double(max(r.total, 1)) * 100))
            }
        }
        exit(0)
    }

    // --export-features <out.json>: the default pipeline's features for every word take (training
    // and quiz), for training models outside Swift on exactly what the recogniser sees.
    if let j = args.firstIndex(of: "--export-features"), j + 1 < args.count {
        var config = PipelineConfig.defaults.features
        // --channels arv: accelerometer + rotation + attitude (the word CNN's input since D63).
        if let c = args.firstIndex(of: "--channels"), c + 1 < args.count, args[c + 1] == "arv" {
            config.channels = [.acceleration, .rotation, .attitude]
        }
        var rows: [[String: Any]] = []
        for (take, isTest) in dataset.trainingTakes.map({ ($0, false) }) + dataset.testTakes.map({ ($0, true) }) {
            guard let f = Features.extract(take.samples, config: config) else { continue }
            let seq = f.sequence
            rows.append(["id": take.id.uuidString, "label": take.label, "block": take.block, "test": isTest,
                         "dims": seq.dims, "vectorDims": seq.vectorDims, "values": seq.values])
        }
        let out = URL(fileURLWithPath: (args[j + 1] as NSString).expandingTildeInPath)
        try! JSONSerialization.data(withJSONObject: ["rate": config.rate, "takes": rows]).write(to: out)
        print("exported \(rows.count) takes to \(out.path)")
        exit(0)
    }

    func report(_ name: String, _ config: PipelineConfig) {
        guard let r = Tuner.evaluate(train, config: config, permutations: 200) else { print("not enough data"); return }
        print("\n== \(name): \(config.summary)")
        print(String(format: "%@  accuracy %.0f%%  words %.0f%%  non-word rejected %@  optimistic %@  chance %.0f%%  p=%.3f",
                     r.mode.rawValue, r.accuracy * 100, r.wordAccuracy * 100,
                     r.noneRecall.map { String(format: "%.0f%%", $0 * 100) } ?? "-",
                     r.optimisticAccuracy.map { String(format: "%.0f%%", $0 * 100) } ?? "-", r.chance * 100, r.pValue))
        for (label, acc) in r.perLabelAccuracy.sorted(by: { $0.key < $1.key }) { print(String(format: "  %-8@ %.0f%%", label, acc * 100)) }
        print("  most confused:", r.confusedPairs.prefix(5).map { "\($0.a)↔\($0.b)×\($0.count)" }.joined(separator: ", "))
        if !dataset.testTakes.isEmpty, let q = Tuner.heldOut(training: train, test: dataset.testTakes.map(Tuner.RawTake.init), config: config) {
            print("  quiz (held-out takes): \(q.correct)/\(q.total) = \(Int((Double(q.correct) / Double(max(q.total, 1)) * 100).rounded()))%")
        }
    }

    // --reject: scores that separate real demo sentences from random movement and single words (D47).
    if args.contains("--reject") {
        let phrases = ContextModel().tokenized
        let sentences = dataset.sentenceTakes.filter { t in phrases.contains(t.label.split(separator: " ").map(String.init)) }
        var rows: [(kind: String, perFrame: Double, ratio: Double, active: Double)] = []
        for block in Set(dataset.takes.map(\.block)).sorted() {
            let testSent = sentences.filter { $0.block == block }
            let testNeg = dataset.takes.filter { $0.block == block && !$0.isSentence && !$0.isTest }
            guard !testSent.isEmpty || !testNeg.isEmpty,
                  let clf = Classifier(training: TrainingSet.build(train.filter { $0.block != block }, config: .defaults)),
                  let dec = SentenceDecoder(classifier: clf, pipeline: .defaults) else { continue }
            let refTakes = sentences.filter { $0.block != block }.map { (label: $0.label, samples: $0.samples) }
            let refs = dec.sentenceReferences(refTakes)
            let phraseRefs = phrases.map { refs[$0.joined(separator: " ")] ?? [] }
            // "Nothing said" references: recorded movement plus single words (other blocks), sampled.
            var nrng = SeededRNG(seed: 3)
            let negTakes = dataset.takes.filter { $0.block != block && !$0.isTest && !$0.isSentence && !$0.block.hasPrefix("sentence-") }
            let noneRefs = (negTakes.filter { $0.label == noneLabel } + Array(negTakes.filter { $0.label != noneLabel }.shuffled(using: &nrng).prefix(120)))
                .compactMap { dec.features($0.samples)?.seq }
            func score(_ samples: [MotionSample]) -> (Double, Double, Double)? {
                guard let f = dec.features(samples), f.seq.count >= 6 else { return nil }
                let costs = phrases.compactMap { p in dec.align(f.seq, phrase: p).map { $0.reduce(0) { $0 + $1.cost * Double($1.end - $1.start) } / Double(f.seq.count) } }
                let dPhrase = SentenceDecoder.sentenceDistances(f.seq, references: phraseRefs).min() ?? .infinity
                let dNone = SentenceDecoder.sentenceDistances(f.seq, references: [noneRefs]).first ?? .infinity
                return (costs.min() ?? .infinity, dPhrase / max(dNone, 1e-9), Double(f.seq.count) / 25)
            }
            for t in testSent { if let sc = score(t.samples) { rows.append(("sentence", sc.0, sc.1, sc.2)) } }
            for t in testNeg.prefix(40) {
                if let sc = score(t.samples) { rows.append((t.label == noneLabel ? "movement" : "single word", sc.0, sc.1, sc.2)) }
            }
        }
        for kind in ["sentence", "movement", "single word"] {
            let r = rows.filter { $0.kind == kind }
            guard !r.isEmpty else { continue }
            func q(_ xs: [Double], _ p: Double) -> Double { let s = xs.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))] }
            let pf = r.map(\.perFrame), ra = r.map(\.ratio), ac = r.map(\.active)
            print(String(format: "%-11@ n=%3d | align cost/frame p5 %.2f p50 %.2f p95 %.2f | phrase÷movement distance p5 %.2f p50 %.2f p95 %.2f | active s p5 %.2f p50 %.2f",
                         kind, r.count, q(pf, 0.05), q(pf, 0.5), q(pf, 0.95), q(ra, 0.05), q(ra, 0.5), q(ra, 0.95), q(ac, 0.05), q(ac, 0.5)))
        }
        // Rules: accept only if align cost/frame < P AND phrase÷movement < R AND active ≥ A.
        let sent = rows.filter { $0.kind == "sentence" }, neg = rows.filter { $0.kind != "sentence" }
        var results: [(Int, Int, Int, String)] = []
        for p in [0.9, 1.0, 1.1, 1.2, 1.4] { for r in [1.2, 1.4, 1.6, 2.0, 99] { for a in [0.0, 0.6, 0.8, 0.9] {
            let ok = { (x: (kind: String, perFrame: Double, ratio: Double, active: Double)) in x.perFrame < p && x.ratio < r && x.active >= a }
            let keep = sent.filter(ok).count
            let mv = neg.filter { $0.kind == "movement" && ok($0) }.count, sw = neg.filter { $0.kind == "single word" && ok($0) }.count
            results.append((keep, mv, sw, String(format: "cost/frame < %.1f, ratio < %@, active ≥ %.1f s", p, r == 99 ? "∞" : String(format: "%.1f", r), a)))
        } } }
        let mvTotal = neg.filter { $0.kind == "movement" }.count, swTotal = neg.filter { $0.kind == "single word" }.count
        // One combined score: log(cost/frame ÷ 0.5) + log(phrase÷nothing distance). Lower = more sentence-like.
        func z(_ x: (kind: String, perFrame: Double, ratio: Double, active: Double)) -> Double {
            x.perFrame.isFinite && x.ratio.isFinite ? log(x.perFrame / 0.5) + log(x.ratio) : 99
        }
        let sz = sent.map(z).sorted()
        print(String(format: "combined score: sentences max %.2f (p90 %.2f) · movement min %.2f · single words min %.2f",
                     sz.last ?? 0, sz[Int(Double(sz.count) * 0.9)], neg.filter { $0.kind == "movement" }.map(z).min() ?? 0,
                     neg.filter { $0.kind == "single word" }.map(z).min() ?? 0))
        for t in [0.0, 0.2, 0.4, 0.5, 0.6, 0.7, 0.8, 1.0] {
            let keep = sent.filter { z($0) < t }.count
            let mv = neg.filter { $0.kind == "movement" && z($0) < t }.count, sw = neg.filter { $0.kind == "single word" && z($0) < t }.count
            print(String(format: "score < %.1f → sentences kept %2d/%d · movement accepted %2d/%d · single words accepted %3d/%d",
                         t, keep, sent.count, mv, mvTotal, sw, swTotal))
        }
        exit(0)
    }

    // --demo: the two-sentence choice on real sentence takes, held-out by block (D46).
    if args.contains("--demo") {
        let phrases = ContextModel().tokenized
        let sentences = dataset.sentenceTakes.filter { t in phrases.contains(t.label.split(separator: " ").map(String.init)) }
        print("\(sentences.count) real sentence takes: " + phrases.map { p in "\(sentences.filter { $0.label == p.joined(separator: " ") }.count)× \"\(p.joined(separator: " "))\"" }.joined(separator: ", "))
        var confusion = [[Int]](repeating: [0, 0], count: 2)
        var trieConf = confusion
        var combos: [Double: [[Int]]] = [0.5: confusion, 1: confusion, 2: confusion]
        var sentOnly = confusion
        var comboMargins: [(Double, Bool)] = []
        var margins: [(Double, Bool)] = []
        var durations: [(Double, Int)] = []
        for block in Set(sentences.map(\.block)).sorted() {
            // Hold out the sentence block AND the word takes cut from it.
            guard let clf = Classifier(training: TrainingSet.build(train.filter { $0.block != block }, config: .defaults)),
                  let dec = SentenceDecoder(classifier: clf, pipeline: .defaults) else { continue }
            var free = SentenceConfig(); free.onlyExpectedPhrases = false
            let trie = SentenceDecoder(classifier: clf, pipeline: .defaults, config: free)!
            var ctx = ContextModel(); ctx.strength = .strong
            for t in sentences where t.block == block {
                let truth = phrases.firstIndex(of: t.label.split(separator: " ").map(String.init))!
                guard let f = dec.features(t.samples), let pick = dec.choose(f.seq, among: phrases) else { continue }
                confusion[truth][pick.index] += 1
                margins.append((pick.margin, pick.index == truth))
                durations.append((Double(f.seq.count) / 25, truth))
                // Whole-sentence references: recorded sentences from other blocks.
                let refs: [[FeatureSequence]] = phrases.map { p in
                    sentences.filter { $0.block != block && $0.label == p.joined(separator: " ") }.compactMap { dec.features($0.samples)?.seq }
                }
                let sd = SentenceDecoder.sentenceDistances(f.seq, references: refs)
                sentOnly[truth][sd[0] <= sd[1] ? 0 : 1] += 1
                for w in combos.keys {
                    if let c = dec.chooseCombined(f.seq, among: phrases, references: refs, sentenceWeight: w) {
                        combos[w]![truth][c.index] += 1
                        if w == 1 { comboMargins.append((c.margin, c.index == truth)) }
                    }
                }
                let heard = trie.decodeSentence(t.samples, context: ctx)?.words.map(\.label) ?? []
                trieConf[truth][phrases.firstIndex(of: heard) ?? (1 - truth)] += 1
            }
        }
        func show(_ name: String, _ c: [[Int]]) {
            let right = c[0][0] + c[1][1], n = c.flatMap { $0 }.reduce(0, +)
            print("\(name): \(right)/\(n) right · sentence 1 → [\(c[0][0]) right, \(c[0][1]) wrong] · sentence 2 → [\(c[1][1]) right, \(c[1][0]) wrong]")
        }
        show("choose by alignment", confusion)
        show("whole-phrase decoder", trieConf)
        show("whole-sentence matching only", sentOnly)
        for w in combos.keys.sorted() { show(String(format: "combined (sentence weight %.1f)", w), combos[w]!) }
        let cw = comboMargins.filter { !$0.1 }.map(\.0), cr = comboMargins.filter(\.1).map(\.0).sorted()
        print(String(format: "combined margin: right min %.2f median %.2f, wrong max %@", cr.first ?? 0, cr.isEmpty ? 0 : cr[cr.count / 2],
                     cw.isEmpty ? "none" : String(format: "%.2f", cw.max()!)))
        let wrong = margins.filter { !$0.1 }.map(\.0), rightM = margins.filter(\.1).map(\.0).sorted()
        print(String(format: "margin: right median %.2f (min %.2f), wrong max %.2f", rightM.isEmpty ? 0 : rightM[rightM.count / 2], rightM.first ?? 0, wrong.max() ?? 0))
        for k in 0..<2 {
            let ds = durations.filter { $0.1 == k }.map(\.0).sorted()
            if !ds.isEmpty { print(String(format: "active duration, sentence %d: min %.2f s, median %.2f s, max %.2f s", k + 1, ds.first!, ds[ds.count / 2], ds.last!)) }
        }
        exit(0)
    }

    // --real-sentences: decode every recorded sentence take with a model that never saw its block (D45).
    if args.contains("--real-sentences") {
        let sentences = dataset.sentenceTakes
        print("\(sentences.count) recorded sentence takes in \(Set(sentences.map(\.block)).count) blocks")
        let fullPhrase = "hello can you hear me"
        // Demo mode stand-in: choose the full phrase against all of its own parts as decoys.
        do {
            let full = fullPhrase.split(separator: " ").map(String.init)
            var decoys: [[String]] = []
            for len in 2..<full.count { for st in 0...(full.count - len) { decoys.append(Array(full[st..<(st + len)])) } }
            var right = 0, n = 0
            var margins: [Double] = []
            for block in Set(sentences.map(\.block)).sorted() {
                guard let clf = Classifier(training: TrainingSet.build(train.filter { $0.block != block }, config: .defaults)),
                      let dec = SentenceDecoder(classifier: clf, pipeline: .defaults) else { continue }
                for t in sentences where t.block == block {
                    guard let f = dec.features(t.samples), let pick = dec.choose(f.seq, among: [full] + decoys) else { continue }
                    n += 1; if pick.index == 0 { right += 1 }
                    margins.append(pick.margin)
                }
            }
            margins.sort()
            print(String(format: "demo choice, full phrase vs %d of its parts: %d/%d right, margin median %.2f", decoys.count, right, n,
                         margins.isEmpty ? 0 : margins[margins.count / 2]))
        }
        // Realistic stand-in for the second demo sentence: 7-word sequences of trained words in another order.
        do {
            let full = fullPhrase.split(separator: " ").map(String.init)
            var rng = SeededRNG(seed: 9)
            var choiceRight = 0, trieRight = 0, n = 0
            for block in Set(sentences.map(\.block)).sorted() {
                guard let clf = Classifier(training: TrainingSet.build(train.filter { $0.block != block }, config: .defaults)) else { continue }
                var free = SentenceConfig(); free.onlyExpectedPhrases = false
                guard let choiceDec = SentenceDecoder(classifier: clf, pipeline: .defaults),
                      let trieDec = SentenceDecoder(classifier: clf, pipeline: .defaults, config: free) else { continue }
                for t in sentences where t.block == block {
                    let other = (0..<7).map { i in [["you", "me", "hello"], ["hear", "can"]][i % 2].randomElement(using: &rng)! }
                    var ctx = ContextModel(); ctx.strength = .strong; ctx.phrases = [fullPhrase, other.joined(separator: " ")]
                    n += 1
                    if let f = choiceDec.features(t.samples), let pick = choiceDec.choose(f.seq, among: [full, other]), pick.index == 0 { choiceRight += 1 }
                    if trieDec.decodeSentence(t.samples, context: ctx)?.words.map(\.label) == full { trieRight += 1 }
                }
            }
            print("two-sentence demo stand-in (your sentence vs a 7-word decoy): choose-by-alignment \(choiceRight)/\(n), whole-phrase decoder \(trieRight)/\(n)")
        }
        var mode = SentenceConfig(); mode.onlyExpectedPhrases = false
        for (name, include) in [("whole phrases only", false), ("phrases + parts", true)] {
            var ctx = ContextModel(); ctx.strength = .strong; ctx.includeParts = include; ctx.phrases = [fullPhrase]
            var acc = 0.0, exact = 0, n = 0, fullExact = 0, fullN = 0, partExact = 0, partN = 0
            var misses: [String] = []
            for block in Set(sentences.map(\.block)).sorted() {
                let trainRaw = train.filter { $0.block != block }
                guard let clf = Classifier(training: TrainingSet.build(trainRaw, config: .defaults)),
                      let dec = SentenceDecoder(classifier: clf, pipeline: .defaults, config: mode) else { continue }
                for t in sentences where t.block == block {
                    let said = t.label.split(separator: " ").map(String.init)
                    let heard = dec.decode(t.samples, context: ctx)?.words.map(\.label) ?? []
                    acc += SentenceScore.wordAccuracy(said: said, heard: heard); n += 1
                    let ok = heard == said
                    if ok { exact += 1 } else if misses.count < 8 { misses.append("\(t.label) → \(heard.joined(separator: " "))") }
                    if t.label == fullPhrase { fullN += 1; if ok { fullExact += 1 } } else { partN += 1; if ok { partExact += 1 } }
                }
            }
            print(String(format: "%@: words %.0f%%, whole sentence %d/%d · full phrase %d/%d · parts %d/%d",
                         name, acc / Double(max(n, 1)) * 100, exact, n, fullExact, fullN, partExact, partN))
            for m in misses.prefix(6) { print("   miss: \(m)") }
        }
        exit(0)
    }

    if args.contains("--lengths") {
        // How long each trained word is after trimming (the sentence decoder needs segments ≥ 0.5× a template).
        var by: [String: [Double]] = [:]
        for t in dataset.trainingTakes where t.label != noneLabel {
            if let f = Features.extract(t.samples) { by[t.label, default: []].append(Double(f.sequence.count) / 25) }
        }
        for (w, ls) in by.sorted(by: { $0.key < $1.key }) {
            let s = ls.sorted()
            print(String(format: "%-6@ n=%3d  trimmed length median %.2f s  p10 %.2f  p90 %.2f  → shortest allowed sentence segment %.2f s",
                         w, s.count, s[s.count / 2], s[s.count / 10], s[s.count * 9 / 10], s[s.count / 10] * 0.5))
        }
        exit(0)
    }

    if args.contains("--quality") {
        // Take strength (D32) for every recorded take under the current defaults.
        let q = QualityConfig()
        let tails = dataset.takes.filter { $0.label != noneLabel }.compactMap { Features.extract($0.samples)?.trailingSeconds }.sorted()
        if !tails.isEmpty {
            print(String(format: "quiet time after the word, inside the 1.8 s window: median %.2f s, p90 %.2f s, max %.2f s",
                         tails[tails.count / 2], tails[Int(Double(tails.count) * 0.9)], tails.last!))
        }
        let strengths = dataset.takes.compactMap { t in Features.extract(t.samples).map { (t.label, Quality.strength($0)) } }
        for group in ["words", noneLabel] {
            let g = strengths.filter { group == "words" ? $0.0 != noneLabel : $0.0 == noneLabel }.map(\.1).sorted()
            func pct(_ p: Double) -> Double { g.isEmpty ? 0 : g[min(g.count - 1, Int(Double(g.count) * p))] }
            print(String(format: "%-6@ n=%2d  strength min %.1f p10 %.1f p50 %.1f  below %.1f×: %d",
                         group, g.count, g.first ?? 0, pct(0.1), pct(0.5), q.minStrength, g.filter { $0 < q.minStrength }.count))
        }
        exit(0)
    }

    var old = PipelineConfig.defaults
    old.features.highPassHz = 0.8; old.classifier.augmentCopies = 4
    report("original defaults (HP 0.8 Hz, aug ×4)", old)
    report("current defaults", .defaults)

    // --cross <other.json>: train on this dataset only, test on every take of the other session.
    if let j = args.firstIndex(of: "--cross"), j + 1 < args.count {
        let u = URL(fileURLWithPath: (args[j + 1] as NSString).expandingTildeInPath)
        if let d = try? Data(contentsOf: u), let other = try? JSONDecoder().decode(Dataset.self, from: d) {
            var configs: [(String, PipelineConfig)] = [("current defaults", .defaults)]
            var tuned = PipelineConfig.defaults
            tuned.features.highPassHz = 2.0; tuned.features.channels = [.rotation, .attitude]; tuned.features.trimThreshold = 0.35
            configs.append(("session-2 tuned", tuned))
            for (name, c) in configs {
                if let q = Tuner.heldOut(training: train, test: other.takes.map(Tuner.RawTake.init), config: c) {
                    let per = q.perLabel.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.0)/\($0.value.1)" }.joined(separator: "  ")
                    print(String(format: "cross-session %@: %d/%d = %.0f%%   %@", name, q.correct, q.total,
                                 Double(q.correct) / Double(max(q.total, 1)) * 100, per))
                }
            }
        }
    }

    // --candidates: compare a few robust settings (pooled LOBO + quiz), to choose defaults without
    // trusting a single auto-tune winner.
    if args.contains("--candidates") {
        func make(_ rate: Double, _ hp: Double, _ ch: FeatureChannels, _ mag: Bool, _ trim: Double, _ k: Int) -> (String, PipelineConfig) {
            var c = PipelineConfig.defaults
            c.features.rate = rate; c.features.highPassHz = hp; c.features.channels = ch
            c.features.magnitudes = mag; c.features.trimThreshold = trim; c.classifier.k = k
            return (c.summary, c)
        }
        let ra: FeatureChannels = [.rotation, .attitude]
        func lp(_ c: (String, PipelineConfig), _ hz: Double) -> (String, PipelineConfig) {
            var x = c.1; x.features.lowPassHz = hz; return (x.summary, x)
        }
        let base = make(25, 1.2, ra, true, 0.35, 3)
        func aug(_ c: (String, PipelineConfig), _ n: Int) -> (String, PipelineConfig) {
            var x = c.1; x.classifier.augmentCopies = n; return (x.summary, x)
        }
        _ = base
        let list = [aug(make(25, 0.8, ra, true, 0.35, 3), 4), make(25, 0.8, ra, true, 0.35, 3), aug(make(25, 1.0, ra, true, 0.35, 3), 4),
                    make(25, 1.0, ra, true, 0.35, 3), aug(make(25, 1.2, ra, true, 0.35, 3), 4), aug(make(25, 0.8, ra, true, 0.25, 3), 4),
                    aug(make(25, 0.8, .all, true, 0.35, 3), 4), aug(make(25, 0.5, ra, true, 0.35, 3), 4), make(25, 1.6, .all, false, 0.25, 3), make(25, 1.2, ra, false, 0.35, 3), make(25, 1.2, ra, true, 0.35, 3),
                    make(50, 1.2, ra, true, 0.35, 3), make(25, 1.6, ra, true, 0.35, 3), make(25, 1.2, ra, true, 0.35, 1),
                    make(25, 2.0, ra, true, 0.35, 3)]
        for (name, c) in list {
            guard let r = Tuner.evaluate(train, config: c) else { continue }
            let q = Tuner.heldOut(training: train, test: dataset.testTakes.map(Tuner.RawTake.init), config: c)
            print(String(format: "LOBO %.0f%%  words %.0f%%  none %@  quiz %@   %@", r.accuracy * 100, r.wordAccuracy * 100,
                         r.noneRecall.map { String(format: "%.0f%%", $0 * 100) } ?? "-",
                         q.map { "\($0.correct)/\($0.total)" } ?? "-", name))
        }
        exit(0)
    }

    // --context: how much next-word prediction helps when saying the phrase in order (D37).
    if args.contains("--context") {
        let rankings = Tuner.loboRankings(train, config: .defaults)
        let phrase = ContextModel().tokenized
        guard let words = phrase.first else { exit(1) }
        var off = ContextModel(); off.weight = 0
        func show(_ name: String, _ c: ContextModel) {
            guard let inOrder = Tuner.contextScore(rankings, phrase: words, context: c, chained: true),
                  let shuffled = Tuner.contextScore(rankings, phrase: words, context: c, chained: true, randomOrder: true) else { return }
            print(String(format: "%@  in order: words %3.0f%% phrase %3.0f%%   random order: words %3.0f%%",
                         name, inOrder.words * 100, inOrder.phrases * 100, shuffled.words * 100))
        }
        for strength in ContextModel.Strength.allCases {
            var c = ContextModel(); c.strength = strength
            show(strength.label.padding(toLength: 33, withPad: " ", startingAt: 0), c)
        }
        exit(0)
    }

    // --robust: accuracy when real recorded movement is mixed into held-out words, with fixes (D42).
    if args.contains("--robust") {
        let strengths = [0.0, 0.25, 0.5, 1.0]
        func variant(_ name: String, _ change: (inout PipelineConfig) -> Void) -> (String, PipelineConfig) {
            var c = PipelineConfig.defaults; change(&c); return (name, c)
        }
        var variants = [
            variant("baseline") { _ in },
            variant("noise training ×2") { $0.robustness.noiseCopies = 2 },
            variant("noise ×2 + clip 3σ") { $0.robustness.noiseCopies = 2; $0.classifier.softClip = 3 },
            variant("noise ×4 + clip 3σ") { $0.robustness.noiseCopies = 4; $0.classifier.softClip = 3 },
            variant("noise ×4 (0.2–1.0) + clip 3σ") { $0.robustness.noiseCopies = 4; $0.robustness.minStrength = 0.2; $0.robustness.maxStrength = 1.0; $0.classifier.softClip = 3 },
            variant("noise ×6 (0.2–1.0) + clip 3σ") { $0.robustness.noiseCopies = 6; $0.robustness.minStrength = 0.2; $0.robustness.maxStrength = 1.0; $0.classifier.softClip = 3 },
            variant("noise ×4 (0.2–1.0) + clip 3σ, aug ×4") { $0.robustness.noiseCopies = 4; $0.robustness.minStrength = 0.2; $0.robustness.maxStrength = 1.0; $0.classifier.softClip = 3; $0.classifier.augmentCopies = 4 },
        ]
        if args.contains("--quick") { variants = Array(variants.prefix(1)) }
        print("words accuracy with recorded movement mixed in at strength: " + strengths.map { String(format: "%.2f", $0) }.joined(separator: " / "))
        for (name, c) in variants {
            let rows = Tuner.robustness(train, config: c, strengths: strengths)
            print(name.padding(toLength: 28, withPad: " ", startingAt: 0) + rows.map { String(format: "%3.0f%%", $0.words * 100) }.joined(separator: "  "))
        }
        for gate in args.contains("--gate") ? [15.0, 10.0] : [] {
            let rows = Tuner.robustness(train, config: .defaults, strengths: strengths, gateDegrees: gate)
            print(String(format: "baseline + head gate %2.0f°      ", gate) + rows.map { String(format: "%3.0f%% (answers %3.0f%%)", $0.gated * 100, $0.answered * 100) }.joined(separator: "  "))
        }
        exit(0)
    }

    // --parts: parts of the phrase ("hello can", "you hear me") vs the full phrase (D44).
    if args.contains("--parts") {
        let phrase = ContextModel().tokenized.first ?? []
        var parts: [[String]] = []
        for len in 2...phrase.count { for st in 0...(phrase.count - len) { parts.append(Array(phrase[st..<(st + len)])) } }
        if args.contains("--tempo") {
            for (dw, tw) in [(5.0, 8.0), (5.0, 20.0), (10.0, 20.0), (3.0, 20.0)] {
                for err in [1.0, 1.3, 0.77] {
                    var ctx = ContextModel(); ctx.strength = .strong; ctx.includeParts = true
                    var cells: [String] = []
                    for (name, sentences) in [("full", [phrase]), ("parts", parts)] {
                        for speed in [1.0, 2.0] {
                            var sc = SentenceConfig(); sc.durationWeight = dw; sc.tempoPriorWeight = tw
                            sc.expectedTempo = err / speed           // the pace sentence training would measure (± error)
                            if let b = Tuner.sentenceBenchmark(train, phrase: phrase, config: .defaults, sentence: sc, context: ctx, speed: speed, perBlock: 8, sentences: sentences) {
                                cells.append(String(format: "%@ ×%.0f %3.0f%%/%3.0f%%", name, speed, b.wordAccuracy * 100, b.exact * 100))
                            }
                        }
                    }
                    print(String(format: "duration %4.1f prior %4.1f, pace estimate off by ×%.2f | ", dw, tw, err) + cells.joined(separator: " | "))
                }
            }
            exit(0)
        }
        let grid: [(Double, Double, Double)] = args.contains("--grid")
            ? [(0, 0, 0), (1, 0, 0), (1, 0, 2), (1, 0, 5), (1, 0, 10), (0.5, 0, 5), (0.5, 0, 10), (1, 0, 20)]
            : [(0, 0, 0), (1, 0, 0), (1, 0, 5)]
        for (pw, penalty, dw) in grid {
            var ctx = ContextModel(); ctx.strength = .strong; ctx.includeParts = pw > 0; ctx.partWeight = pw
            var sc = SentenceConfig(); sc.insertionPenalty = penalty; sc.durationWeight = dw
            var cells: [String] = []
            for (name, sentences) in [("full", [phrase]), ("parts", parts)] {
                for speed in [1.0, 2.0] {
                    if let b = Tuner.sentenceBenchmark(train, phrase: phrase, config: .defaults, sentence: sc, context: ctx, speed: speed, perBlock: 8, sentences: sentences) {
                        cells.append(String(format: "%@ ×%.0f %3.0f%%/%3.0f%%", name, speed, b.wordAccuracy * 100, b.exact * 100))
                    }
                }
            }
            print(String(format: "parts %.2f, tempo model %4.1f | ", pw, dw) + cells.joined(separator: " | "))
        }
        exit(0)
    }

    // --honesty: does the phrase model still read the motion? (D41)
    if args.contains("--honesty") {
        let phrase = ContextModel().tokenized.first ?? []
        let extra = [["hello"], ["can", "you", "hear", "me"], ["hear", "me"], phrase]
        for penalty in args.contains("--quick") ? [0.0] : [0.0, 1.0, 2.0] {
            var sc = SentenceConfig(); sc.insertionPenalty = penalty
            for strength in args.contains("--quick") ? [ContextModel.Strength.off, .strong] : [ContextModel.Strength.off, .balanced, .strong] {
                var one = ContextModel(); one.strength = strength
                var many = one; many.phrases = extra.map { $0.joined(separator: " ") }
                let rows: [(String, Tuner.SentenceBenchmark?)] = [
                    ("phrase, normal", Tuner.sentenceBenchmark(train, phrase: phrase, config: .defaults, sentence: sc, context: one, perBlock: 10)),
                    ("phrase, 1.33x", Tuner.sentenceBenchmark(train, phrase: phrase, config: .defaults, sentence: sc, context: one, speed: 1.33, perBlock: 10)),
                    ("4 phrases known, say any", Tuner.sentenceBenchmark(train, phrase: phrase, config: .defaults, sentence: sc, context: many, perBlock: 10, sentences: extra)),
                    ("off-script random 3-5 words", Tuner.sentenceBenchmark(train, phrase: phrase, config: .defaults, sentence: sc, context: one, perBlock: 10, randomLength: 3...5)),
                ]
                let cells = rows.map { name, b in b.map { String(format: "%@ %.0f%%/%.0f%%", name, $0.wordAccuracy * 100, $0.exact * 100) } ?? "\(name) -" }
                print(String(format: "penalty %.0f · %-8@ | ", penalty, strength.label) + cells.joined(separator: " | "))
            }
        }
        print("(cells: words / whole sentence right)")
        exit(0)
    }

    // --speed: sentence accuracy as speech gets faster, for several squash limits (D43).
    if args.contains("--speed") {
        let phrase = ContextModel().tokenized.first ?? []
        var strong = ContextModel(); strong.strength = .strong
        for (comp, minWord) in [(0.5, 0.16), (0.35, 0.12), (0.25, 0.08), (0.2, 0.08)] {
            var sc = SentenceConfig(); sc.minCompression = comp; sc.minWordSeconds = minWord
            var cells: [String] = []
            for speed in [1.0, 1.5, 2.0, 2.5, 3.0] {
                if let b = Tuner.sentenceBenchmark(train, phrase: phrase, config: .defaults, sentence: sc, context: strong, speed: speed, perBlock: 8) {
                    cells.append(String(format: "×%.1f %3.0f%%/%3.0f%%", speed, b.wordAccuracy * 100, b.exact * 100))
                }
            }
            print(String(format: "squash ≥%.2f, word ≥%.2fs | ", comp, minWord) + cells.joined(separator: " | "))
        }
        print("(speed = how much faster than your isolated words; cells = words / whole sentence)")
        exit(0)
    }

    // --sentences: stitched-sentence benchmark of the sentence decoder (D40).
    if args.contains("--sentences") {
        let phrase = ContextModel().tokenized.first ?? []
        var strong = ContextModel(); strong.strength = .strong
        var off = ContextModel(); off.strength = .off
        var grid: [(String, SentenceConfig)] = [("defaults", SentenceConfig())]
        if args.contains("--grid") {
            grid = []
            for ip in [0.0, 1.5, 3.0, 6.0] { for cw in [0.0, 1.0, 2.0, 4.0] {
                var c = SentenceConfig(); c.insertionPenalty = ip; c.contextWeight = cw / 0.5   // Strong = weight 0.5
                grid.append((String(format: "insert %.1f ctx %.1f", ip, cw), c))
            } }
        }
        for (name, sc) in grid {
            for (cname, ctx) in [("strong", strong), ("off", off)] where !(cname == "off" && args.contains("--grid")) {
                for speed in [1.0, 1.33] {
                    guard let b = Tuner.sentenceBenchmark(train, phrase: phrase, config: .defaults, sentence: sc, context: ctx, speed: speed, perBlock: args.contains("--grid") ? 6 : 12) else { continue }
                    print(String(format: "%@ · context %@ · speed ×%.2f → words %.0f%%  whole sentence %.0f%%  | align: boundary err %.0f ms, all-boundaries-ok %.0f%%  | %.2f s/decode (n=%d)",
                                 name, cname, speed, b.wordAccuracy * 100, b.exact * 100, b.boundaryErrorMs, b.alignedExact * 100, b.decodeSeconds, b.sentences))
                    if args.contains("--failures"), cname == "strong" {
                        let counts = Dictionary(grouping: b.failures, by: { $0 }).mapValues(\.count).sorted { $0.value > $1.value }
                        for (heard, n) in counts.prefix(10) { print("     ×\(n)  heard: \"\(heard)\"") }
                    }
                }
            }
        }
        exit(0)
    }

    if args.contains("--ensemble") {
        func cfg(_ hp: Double, _ rate: Double = 25, _ ch: FeatureChannels = [.rotation, .attitude], _ mag: Bool = true) -> PipelineConfig {
            var c = PipelineConfig.defaults; c.features.highPassHz = hp; c.features.rate = rate; c.features.channels = ch; c.features.magnitudes = mag; return c
        }
        let sets: [(String, [PipelineConfig])] = [
            ("single (defaults)", [.defaults]),
            ("HP 1.2 + 2.0", [cfg(1.2), cfg(2.0)]),
            ("HP 1.2 + 1.6 + 2.0", [cfg(1.2), cfg(1.6), cfg(2.0)]),
            ("HP 1.2 @25 + @50 + 2.0", [cfg(1.2), cfg(1.2, 50), cfg(2.0)]),
            ("mixed channels", [cfg(1.2), cfg(2.0), cfg(1.6, 25, .all, false)]),
            ("HP 0.8/1.2/1.6/2.0/3.0", [cfg(0.8), cfg(1.2), cfg(1.6), cfg(2.0), cfg(3.0)]),
        ]
        let quizTakes = dataset.testTakes.map(Tuner.RawTake.init)
        for (name, configs) in sets {
            guard let r = Tuner.ensembleLOBO(train, configs: configs) else { continue }
            var quiz = "-"
            if let e = EnsembleClassifier(training: train, configs: configs), !quizTakes.isEmpty {
                let hits = quizTakes.filter { e.rank($0.samples).first?.label == $0.label }.count
                quiz = "\(hits)/\(quizTakes.count)"
            }
            print(String(format: "LOBO %.0f%%  words %.0f%%  quiz %@   %@", r.accuracy * 100, r.words * 100, quiz, name))
        }
        exit(0)
    }

    if args.contains("--tune") {
        let start = Date()
        let trials = Tuner.autoTune(train)
        print(String(format: "\nAuto-tune: %d settings tried in %.0fs. Top 8:", trials.count, Date().timeIntervalSince(start)))
        for t in trials.prefix(8) {
            print(String(format: "  %.0f%% (words %.0f%%)  %@", t.accuracy * 100, t.wordAccuracy * 100, t.config.summary))
        }
        if let best = trials.first { report("best (confirm on fresh quiz takes before trusting it)", best.config) }
    }
    exit(0)
}

exit(SelfTests.runAll() == 0 ? 0 : 1)
