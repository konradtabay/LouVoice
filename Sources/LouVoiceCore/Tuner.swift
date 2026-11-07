import Foundation

/// Re-evaluates recorded takes under different pipeline settings (D29).
///
/// Auto-tune is greedy coordinate search: for each variable in turn, try its candidate values with
/// everything else fixed, keep the best, and repeat. Every trial is the honest leave-one-block-out
/// score. Picking the best of many trials on the same takes is still slightly optimistic, so the
/// winner should be confirmed on fresh quiz takes (D31).
public enum Tuner {
    public struct Trial: Sendable, Identifiable {
        public let id = UUID()
        public var config: PipelineConfig
        public var change: String
        public var accuracy: Double
        public var wordAccuracy: Double
        public var noneRecall: Double?
    }

    /// Takes with labels and blocks, before feature extraction.
    public struct RawTake: Sendable {
        public var id: String, label: String, block: String, samples: [MotionSample]
        public init(id: String, label: String, block: String, samples: [MotionSample]) {
            self.id = id; self.label = label; self.block = block; self.samples = samples
        }
        public init(_ t: Take) { self.init(id: t.id.uuidString, label: t.label, block: t.block, samples: t.samples) }
    }

    public static func evaluate(_ takes: [RawTake], config: PipelineConfig, permutations: Int = 0,
                                progress: (@Sendable (Double) -> Void)? = nil) -> EvaluationReport? {
        let eval = takes.compactMap { t in
            Features.extract(t.samples, config: config.features).map {
                EvalTake(id: t.id, label: t.label, block: t.block, features: $0.sequence)
            }
        }
        return Evaluation.run(eval, config: config.classifier, permutations: permutations, progress: progress)
    }

    /// Accuracy of a classifier trained on `training` against held-out `test` takes (quiz score).
    public static func heldOut(training: [RawTake], test: [RawTake], config: PipelineConfig)
        -> (correct: Int, total: Int, perLabel: [String: (Int, Int)])? {
        let train = training.compactMap { t in
            Features.extract(t.samples, config: config.features).map { LabeledFeatures(id: t.id, label: t.label, features: $0.sequence) }
        }
        guard let classifier = Classifier(training: train, config: config.classifier) else { return nil }
        var correct = 0, total = 0
        var per: [String: (Int, Int)] = [:]
        for t in test {
            guard let f = Features.extract(t.samples, config: config.features) else { continue }
            let hit = classifier.predict(f.sequence).best?.label == t.label
            total += 1
            if hit { correct += 1 }
            per[t.label, default: (0, 0)].0 += hit ? 1 : 0
            per[t.label, default: (0, 0)].1 += 1
        }
        return (correct, total, per)
    }

    struct Knob {
        var name: String
        var values: [String]
        var apply: (inout PipelineConfig, Int) -> Void
    }

    static let knobs: [Knob] = {
        func knob<T>(_ name: String, _ values: [T], label: @escaping (T) -> String,
                     _ set: @escaping (inout PipelineConfig, T) -> Void) -> Knob {
            Knob(name: name, values: values.map(label)) { c, i in set(&c, values[i]) }
        }
        let channelSets: [FeatureChannels] = [.all, [.acceleration, .rotation], [.rotation, .attitude], .rotation, .acceleration, .attitude]
        return [
            knob("sample rate", [25.0, 50.0], label: { String(format: "%.0f Hz", $0) }) { $0.features.rate = $1 },
            knob("high-pass", [0.0, 0.3, 0.5, 0.8, 1.2, 1.6, 2.0, 3.0], label: { $0 == 0 ? "off" : String(format: "%.1f Hz", $0) }) { $0.features.highPassHz = $1 },
            knob("channels", channelSets, label: { $0.label }) { $0.features.channels = $1 },
            knob("trim", [-1.0, 0.15, 0.25, 0.35, 0.45, 0.55, 0.65], label: { $0 < 0 ? "off" : String(format: "%.0f%%", $0 * 100) }) {
                if $1 < 0 { $0.features.trim = false } else { $0.features.trim = true; $0.features.trimThreshold = $1 }
            },
            knob("energy smoothing", [0.1, 0.2, 0.3, 0.4], label: { String(format: "%.1f s", $0) }) { $0.features.smoothSeconds = $1 },
            knob("trim padding", [0.0, 0.08, 0.16, 0.24], label: { String(format: "%.2f s", $0) }) { $0.features.trimPaddingSeconds = $1 },
            knob("re-seat correction", [true, false], label: { $0 ? "on" : "off" }) { $0.features.canonicalize = $1 },
            knob("k nearest", [1, 2, 3, 5], label: { "k=\($0)" }) { $0.classifier.k = $1 },
            knob("augment copies", [0, 2, 4, 8], label: { "×\($0)" }) { $0.classifier.augmentCopies = $1 },
            knob("augment rotation", [0.0, 6.0, 12.0, 20.0], label: { String(format: "±%.0f°", $0) }) { $0.classifier.augment.maxRotationDegrees = $1 },
            knob("DTW band", [0.1, 0.2, 0.3], label: { String(format: "%.0f%%", $0 * 100) }) { $0.classifier.band = $1 },
        ]
    }()

    /// Greedy coordinate search from `base`. Ranks by accuracy, ties broken by word accuracy.
    /// Returns every trial, best first.
    public static func autoTune(_ takes: [RawTake], base: PipelineConfig = .defaults, passes: Int = 2,
                                progress: (@Sendable (Double, String) -> Void)? = nil) -> [Trial] {
        var trials: [Trial] = []
        var seen: [PipelineConfig: Trial] = [:]
        func score(_ c: PipelineConfig, _ change: String) -> Trial? {
            if let t = seen[c] { return t }
            guard let r = evaluate(takes, config: c) else { return nil }
            let t = Trial(config: c, change: change, accuracy: r.accuracy, wordAccuracy: r.wordAccuracy, noneRecall: r.noneRecall)
            seen[c] = t
            trials.append(t)
            return t
        }
        func better(_ a: Trial, _ b: Trial) -> Bool {
            a.accuracy != b.accuracy ? a.accuracy > b.accuracy : a.wordAccuracy > b.wordAccuracy
        }

        guard var best = score(base, "starting settings") else { return [] }
        let total = Double(passes * knobs.reduce(0) { $0 + $1.values.count })
        var done = 0.0
        for pass in 1...passes {
            var improved = false
            for knob in knobs {
                for i in knob.values.indices {
                    var c = best.config
                    knob.apply(&c, i)
                    done += 1
                    progress?(done / total, "pass \(pass): \(knob.name) = \(knob.values[i])")
                    if let t = score(c, "\(knob.name) → \(knob.values[i])"), better(t, best) {
                        best = t
                        improved = true
                    }
                }
            }
            if !improved { break }
        }
        return trials.sorted(by: better)
    }
}
