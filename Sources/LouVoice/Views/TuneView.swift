import LouVoiceCore
import SwiftUI

/// Every pipeline variable, re-evaluated on your recorded takes, plus auto-tune (D29).
struct TuneView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView { controls.padding(16) }.frame(width: 340)
            Divider()
            ScrollView { results.padding(20) }
        }
        .navigationTitle("Tune")
    }

    // MARK: Variables

    private func binding<T>(_ get: @escaping (PipelineConfig) -> T, _ set: @escaping (inout PipelineConfig, T) -> Void) -> Binding<T> {
        Binding(get: { get(model.config) }, set: { v in model.updateConfig { set(&$0, v) } })
    }

    @ViewBuilder private var controls: some View {
        @Bindable var model = model
        let c = model.config
        VStack(alignment: .leading, spacing: 16) {
            SectionCard(title: "Signal") {
                Picker("Sample rate", selection: binding({ $0.features.rate }, { $0.features.rate = $1 })) {
                    Text("25 Hz").tag(25.0); Text("50 Hz").tag(50.0)
                }
                labeledSlider("High-pass", value: binding({ $0.features.highPassHz }, { $0.features.highPassHz = $1 }),
                              range: 0...3, step: 0.1, format: c.features.highPassHz == 0 ? "off" : String(format: "%.1f Hz", c.features.highPassHz))
                Toggle("Re-seat correction (gravity)", isOn: binding({ $0.features.canonicalize }, { $0.features.canonicalize = $1 }))
                Picker("Normalise each take", selection: binding({ $0.features.normalization }, { $0.features.normalization = $1 })) {
                    ForEach(FeatureConfig.Normalization.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Add rate-of-change channels", isOn: binding({ $0.features.derivatives }, { $0.features.derivatives = $1 }))
                Toggle("Add magnitude channels (rotation-free)", isOn: binding({ $0.features.magnitudes }, { $0.features.magnitudes = $1 }))
                Text("Channels").font(.subheadline)
                HStack {
                    channelToggle("Accel", .acceleration)
                    channelToggle("Rotation", .rotation)
                    channelToggle("Attitude", .attitude)
                }
            }
            SectionCard(title: "Trimming") {
                Toggle("Trim to the active part", isOn: binding({ $0.features.trim }, { $0.features.trim = $1 }))
                labeledSlider("Threshold", value: binding({ $0.features.trimThreshold }, { $0.features.trimThreshold = $1 }),
                              range: 0.05...0.7, step: 0.05, format: String(format: "%.0f%%", c.features.trimThreshold * 100))
                labeledSlider("Smoothing", value: binding({ $0.features.smoothSeconds }, { $0.features.smoothSeconds = $1 }),
                              range: 0...0.5, step: 0.05, format: String(format: "%.2f s", c.features.smoothSeconds))
                labeledSlider("Padding", value: binding({ $0.features.trimPaddingSeconds }, { $0.features.trimPaddingSeconds = $1 }),
                              range: 0...0.3, step: 0.02, format: String(format: "%.2f s", c.features.trimPaddingSeconds))
            }
            SectionCard(title: "Recognizer") {
                Stepper("k nearest: \(c.classifier.k)", value: binding({ $0.classifier.k }, { $0.classifier.k = $1 }), in: 1...7)
                Stepper("Augmented copies: \(c.classifier.augmentCopies)",
                        value: binding({ $0.classifier.augmentCopies }, { $0.classifier.augmentCopies = $1 }), in: 0...16)
                labeledSlider("Augment rotation", value: binding({ $0.classifier.augment.maxRotationDegrees }, { $0.classifier.augment.maxRotationDegrees = $1 }),
                              range: 0...30, step: 1, format: String(format: "±%.0f°", c.classifier.augment.maxRotationDegrees))
                labeledSlider("Augment time-warp", value: binding({ $0.classifier.augment.warp.upperBound - 1 }, {
                    $0.classifier.augment.warp = (1 - $1)...(1 + $1) }),
                              range: 0...0.3, step: 0.01, format: String(format: "±%.0f%%", (c.classifier.augment.warp.upperBound - 1) * 100))
                labeledSlider("DTW band", value: binding({ $0.classifier.band }, { $0.classifier.band = $1 }),
                              range: 0.05...0.5, step: 0.05, format: String(format: "%.0f%%", c.classifier.band * 100))
            }
            SectionCard(title: "Quality gate (new takes only)") {
                Toggle("Reject takes that are too subtle", isOn: binding({ $0.quality.checkStrength }, { $0.quality.checkStrength = $1 }))
                labeledSlider("Min strength", value: binding({ $0.quality.minStrength }, { $0.quality.minStrength = $1 }),
                              range: 1.5...8, step: 0.5, format: String(format: "%.1f×", c.quality.minStrength))
                Toggle("Reject head movement", isOn: binding({ $0.quality.checkHeadMovement }, { $0.quality.checkHeadMovement = $1 }))
                labeledSlider("Max head movement", value: binding({ $0.quality.maxHeadDegrees }, { $0.quality.maxHeadDegrees = $1 }),
                              range: 5...40, step: 1, format: String(format: "%.0f°", c.quality.maxHeadDegrees))
                Text("Strength = peak jaw activity ÷ the take's own quiet part. Your recorded words range 3.4×–20×, median 8×.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SectionCard(title: "Robustness to movement") {
                Stepper("Noisy training copies: \(c.robustness.noiseCopies)",
                        value: binding({ $0.robustness.noiseCopies }, { $0.robustness.noiseCopies = $1 }), in: 0...8)
                labeledSlider("Movement strength (max)", value: binding({ $0.robustness.maxStrength }, { $0.robustness.maxStrength = max($1, $0.robustness.minStrength) }),
                              range: 0.2...1.5, step: 0.1, format: String(format: "%.1f–%.1f×", c.robustness.minStrength, c.robustness.maxStrength))
                labeledSlider("Soft clip", value: binding({ $0.classifier.softClip }, { $0.classifier.softClip = $1 }),
                              range: 0...6, step: 0.5, format: c.classifier.softClip == 0 ? "off" : String(format: "%.1fσ", c.classifier.softClip))
                labeledSlider("Decode: refuse if head moved more than", value: binding({ $0.robustness.decodeMaxHeadDegrees }, { $0.robustness.decodeMaxHeadDegrees = $1 }),
                              range: 0...40, step: 5, format: c.robustness.decodeMaxHeadDegrees == 0 ? "off" : String(format: "%.0f°", c.robustness.decodeMaxHeadDegrees))
                Text("Noisy copies mix your recorded turns/nods/chewing into training takes, so words are learned with movement on top.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SectionCard(title: "Sentence") {
                labeledSlider("Longest sentence", value: binding({ $0.sentence.windowSeconds }, { $0.sentence.windowSeconds = $1 }),
                              range: 2...10, step: 0.5, format: String(format: "%.1f s", c.sentence.windowSeconds))
                Toggle("Stop when I stop mouthing", isOn: binding({ $0.sentence.stopWhenQuiet }, { $0.sentence.stopWhenQuiet = $1 }))
                labeledSlider("…after stillness of", value: binding({ $0.sentence.stopAfterQuietSeconds }, { $0.sentence.stopAfterQuietSeconds = $1 }),
                              range: 0.4...2, step: 0.1, format: String(format: "%.1f s", c.sentence.stopAfterQuietSeconds))
                labeledSlider("Fastest word (squash limit)", value: binding({ $0.sentence.minCompression }, { $0.sentence.minCompression = $1 }),
                              range: 0.15...0.6, step: 0.05, format: String(format: "%.0f%% of a trained take", c.sentence.minCompression * 100))
                labeledSlider("Per-word penalty", value: binding({ $0.sentence.insertionPenalty }, { $0.sentence.insertionPenalty = $1 }),
                              range: 0...6, step: 0.5, format: String(format: "%.1f", c.sentence.insertionPenalty))
                labeledSlider("Context weight", value: binding({ $0.sentence.contextWeight }, { $0.sentence.contextWeight = $1 }),
                              range: 0...16, step: 1, format: String(format: "%.0f", c.sentence.contextWeight))
                labeledSlider("Longest word", value: binding({ $0.sentence.maxWordSeconds }, { $0.sentence.maxWordSeconds = $1 }),
                              range: 0.6...2, step: 0.1, format: String(format: "%.1f s", c.sentence.maxWordSeconds))
                Text("Lower penalty suits fast, flowing speech. Context weight scales with the Decode strength (Strong ×0.5).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SectionCard(title: "Capture (new takes only)") {
                labeledSlider("Window", value: $model.capture.window, range: 1.0...3.0, step: 0.1,
                              format: String(format: "%.1f s", model.capture.window))
                labeledSlider("Pre-roll", value: $model.capture.preroll, range: 0.1...0.6, step: 0.05,
                              format: String(format: "%.2f s", model.capture.preroll))
            }
            HStack {
                Button("Reset to defaults") { model.setConfig(.defaults); model.capture = CaptureSettings() }
                Spacer()
            }
        }
    }

    private func channelToggle(_ name: String, _ ch: FeatureChannels) -> some View {
        Toggle(name, isOn: binding({ $0.features.channels.contains(ch) }, { c, on in
            if on { c.features.channels.insert(ch) } else if c.features.channels != ch { c.features.channels.remove(ch) }
        }))
        .toggleStyle(.button)
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title); Spacer(); Text(format).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range, step: step)
        }
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionCard(title: "Current settings") {
                Text(model.config.summary).font(.callout.monospaced())
                HStack {
                    Button(model.isEvaluating ? "Evaluating…" : "Evaluate these settings") { model.runEvaluation() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isEvaluating || model.blocks.count < 2)
                    if model.isEvaluating { ProgressView(value: model.evaluationProgress).frame(width: 120) }
                }
                if let r = model.evaluation {
                    HStack(spacing: 12) {
                        MetricTile(title: "Leave-one-block-out", value: percent(r.accuracy), emphasis: true)
                        MetricTile(title: "Words only", value: percent(r.wordAccuracy))
                        MetricTile(title: "Non-word rejected", value: percent(r.noneRecall))
                        if let q = model.quizScore {
                            MetricTile(title: "Quiz (held out)", value: percent(Double(q.correct) / Double(max(q.total, 1))),
                                       detail: "\(q.correct)/\(q.total)")
                        }
                    }
                }
            }
            SectionCard(title: "Auto-tune") {
                Text("Tries each variable in turn on your recorded takes (leave-one-block-out) and keeps whatever scores best. With ~10 takes per word, one take moves a word's score by about 10 points, so treat small differences as noise and confirm the winner with a quiz.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(model.isTuning ? "Tuning…" : "Run auto-tune") { model.runAutoTune() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isTuning || model.blocks.count < 2)
                    if model.isTuning { ProgressView(value: model.tuneProgress).frame(width: 160) }
                    Text(model.tuneStatus).font(.caption).foregroundStyle(.secondary)
                }
                if !model.tuneTrials.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            Text("Accuracy").font(.caption.bold()); Text("Words").font(.caption.bold())
                            Text("Settings").font(.caption.bold()); Text("")
                        }
                        ForEach(model.tuneTrials.prefix(12)) { t in
                            GridRow {
                                Text(percent(t.accuracy)).monospacedDigit().bold()
                                Text(percent(t.wordAccuracy)).monospacedDigit()
                                VStack(alignment: .leading) {
                                    Text(t.config.summary).font(.caption.monospaced())
                                    Text(t.change).font(.caption2).foregroundStyle(.secondary)
                                }
                                Button(t.config == model.config ? "In use" : "Use") { model.setConfig(t.config) }
                                    .disabled(t.config == model.config)
                            }
                        }
                    }
                }
            }
        }
    }
}
