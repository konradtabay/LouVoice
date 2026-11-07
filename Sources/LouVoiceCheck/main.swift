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
        for (pw, penalty) in [(0.0, 0.0), (1.0, 0.0), (0.2, 0.0), (0.2, -1.5), (0.1, -1.5), (0.2, -3.0), (0.05, -3.0)] {
            var ctx = ContextModel(); ctx.strength = .strong; ctx.includeParts = pw > 0; ctx.partWeight = pw
            var sc = SentenceConfig(); sc.insertionPenalty = penalty
            var cells: [String] = []
            for (name, sentences) in [("full", [phrase]), ("parts", parts)] {
                for speed in [1.0, 2.0] {
                    if let b = Tuner.sentenceBenchmark(train, phrase: phrase, config: .defaults, sentence: sc, context: ctx, speed: speed, perBlock: 8, sentences: sentences) {
                        cells.append(String(format: "%@ ×%.0f %3.0f%%/%3.0f%%", name, speed, b.wordAccuracy * 100, b.exact * 100))
                    }
                }
            }
            print(String(format: "part weight %.2f, word penalty %+.1f | ", pw, penalty) + cells.joined(separator: " | "))
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
