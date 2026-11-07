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

    if args.contains("--quality") {
        // Take strength (D32) for every recorded take under the current defaults.
        let q = QualityConfig()
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
        let list = [make(25, 1.6, .all, false, 0.25, 3), make(25, 1.2, ra, false, 0.35, 3), make(25, 1.2, ra, true, 0.35, 3),
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
