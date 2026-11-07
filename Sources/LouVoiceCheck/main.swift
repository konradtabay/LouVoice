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
    guard let data = try? Data(contentsOf: url), let dataset = try? JSONDecoder().decode(Dataset.self, from: data) else {
        print("Can't read dataset at \(url.path)"); exit(1)
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
    }

    var old = PipelineConfig.defaults
    old.features.highPassHz = 0.8; old.classifier.augmentCopies = 4
    report("original defaults (HP 0.8 Hz, aug ×4)", old)
    report("current defaults", .defaults)

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
