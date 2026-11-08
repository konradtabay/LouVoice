import LouVoiceCore
import SwiftUI

struct EnrollView: View {
    /// Words with fewer training takes than this count as new. TODO(team): 9 = 3 blocks × 3 reps.
    static let newWordTakes = 9
    @Environment(AppModel.self) private var model
    @State private var newWord = ""
    @State private var teachWord = ""
    @State private var quizReps = 2
    @State private var sentencePhrase = ""

    var body: some View {
        let e = model.enrollment
        HStack(alignment: .top, spacing: 0) {
            ScrollView { settings.padding(16) }
                .frame(width: 300)
            Divider()
            VStack(spacing: 14) {
                PromptCard(phase: e.phase)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if e.isRunning || e.phase == .finished {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(e.completed), total: Double(max(e.total, 1)))
                        Text("\(e.mode == .quiz ? "Quiz" : "Block \(e.block) of \(e.totalBlocks)") · \(e.completed)/\(e.total) prompts · \(e.rejected) re-takes")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !e.log.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(e.log.prefix(30).enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(height: 90)
                }
            }
            .padding(20)
            Divider()
            ScrollView { LiveAccuracyPanel().padding(16) }
                .frame(width: 260)
        }
        .navigationTitle("Enroll")
    }

    @ViewBuilder private var settings: some View {
        @Bindable var e = model.enrollment
        let canRecord = model.hub.status == .streaming && !e.isRunning
        VStack(alignment: .leading, spacing: 16) {
            SectionCard(title: "Vocabulary") {
                ForEach(model.words, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Text("\(model.takeCount(word))").foregroundStyle(.secondary).monospacedDigit()
                        Button { model.removeWord(word) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).disabled(e.isRunning)
                    }
                }
                HStack {
                    Text("(not a word)").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.takeCount(noneLabel))").foregroundStyle(.secondary).monospacedDigit()
                }
                HStack {
                    TextField("Add word", text: $newWord).onSubmit(addWord)
                    Button("Add", action: addWord).disabled(newWord.isEmpty)
                }
                Text("Numbers are training takes. Words with different syllable counts and jaw openings are easiest.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SectionCard(title: "Training session") {
                Stepper("Blocks: \(e.blockCount)", value: $e.blockCount, in: 1...6)
                Stepper("Reps per word per block: \(e.reps)", value: $e.reps, in: 1...6)
                Stepper("Non-word prompts per block: \(e.noisePerBlock)", value: $e.noisePerBlock, in: 0...6)
                Toggle("Quiz after each block", isOn: $e.quizAfterBlock)
                Toggle("Adaptive reps (auto)", isOn: $e.adaptive)
                Text(e.isRunning && e.mode == .train ? "This block: \(e.plan.summary)"
                     : "Before each block, re-scores your data: weak words get +1 to +3 reps, and the most-confused pairs are drilled back to back.")
                    .font(.caption).foregroundStyle(e.isRunning ? Color.orange : Color.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Manual focus words (+\(e.focusExtraReps) reps each, on top of adaptive)").font(.subheadline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(model.words, id: \.self) { word in
                            let on = e.focusWords.contains(word)
                            Button { if on { e.focusWords.remove(word) } else { e.focusWords.insert(word) } } label: {
                                Text(word).font(.callout).padding(.horizontal, 8).padding(.vertical, 4).frame(maxWidth: .infinity)
                                    .background(Capsule().fill(on ? Color.orange.opacity(0.3) : Color.secondary.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button("Pick weakest from last evaluation") {
                        if let r = model.evaluation {
                            let weak = model.words.filter { (r.perLabelAccuracy[$0] ?? 1) < 0.7 }
                            e.focusWords = Set(weak.isEmpty ? Array(model.words.sorted { (r.perLabelAccuracy[$0] ?? 1) < (r.perLabelAccuracy[$1] ?? 1) }.prefix(2)) : weak)
                        }
                    }
                    .disabled(model.evaluation == nil)
                    .font(.caption)
                }
                HStack {
                    Toggle("Speak prompts in AirPods", isOn: Binding(get: { model.cues.speakPrompts },
                                                                    set: { model.cues.speakPrompts = $0 }))
                    Spacer()
                    Button("Test sound") { model.cues.test() }
                }
                let prompts = e.blockCount * (model.words.count * (e.reps + (e.quizAfterBlock ? 1 : 0)) + e.noisePerBlock
                                              + e.focusWords.intersection(model.words).count * e.focusExtraReps)
                Text("≈ \(max(1, Int(Double(prompts) * 4.4 / 60))) min. Every take is tested before it's learned.")
                    .font(.caption).foregroundStyle(.secondary)
                if e.isRunning {
                    Button("Stop", role: .destructive) { e.stop() }
                } else {
                    let newWords = model.words.filter { model.takeCount($0) < Self.newWordTakes }
                    HStack {
                        Button("Start training") {
                            e.start(words: model.words, reps: e.reps, blocks: e.blockCount, noisePerBlock: e.noisePerBlock)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canRecord || model.words.isEmpty)
                        // New words only (fewer than 9 takes), with a few non-word prompts so `_none` keeps up.
                        Button("Train new words only (\(newWords.count))") {
                            e.start(words: newWords, reps: e.reps, blocks: e.blockCount, noisePerBlock: min(e.noisePerBlock, 2))
                        }
                        .disabled(!canRecord || newWords.isEmpty)
                    }
                    if !newWords.isEmpty {
                        Text("New: " + newWords.joined(separator: ", ")).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            SectionCard(title: "Sentence training (flowing)") {
                Picker("Phrase", selection: $sentencePhrase) {
                    Text("All demo phrases (mixed)").tag("")
                    ForEach(model.config.context.phrases.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Sentences per block: \(e.sentenceReps)", value: $e.sentenceReps, in: 1...12)
                Toggle("Vary the length (\"hello can\", \"you hear me\", …)", isOn: $e.varySentenceLength)
                Stepper("Blocks: \(e.sentenceBlocks)", value: $e.sentenceBlocks, in: 1...6)
                Text(String(format: "Up to %.1f s, ends when you stop (Tune › Sentence). ≈ %d min.", model.config.sentence.windowSeconds,
                            max(1, Int(Double(e.sentenceReps * e.sentenceBlocks) * (model.config.sentence.windowSeconds + 3.5) / 60))))
                    .font(.caption).foregroundStyle(.secondary)
                Button("Start sentence training") {
                    let all = model.config.context.phrases.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    e.startSentences(phrases: sentencePhrase.isEmpty ? all : [sentencePhrase], reps: e.sentenceReps, blocks: e.sentenceBlocks)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canRecord || model.classifier == nil)
                Text("Mouth the whole sentence after the beep, flowing, at your natural fast pace. Each one is scored first, then cut into words and learned.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SectionCard(title: "Quiz only (test, no training)") {
                Stepper("Reps per word: \(quizReps)", value: $quizReps, in: 1...5)
                Button("Run quiz") { e.startQuiz(words: model.words, reps: quizReps) }
                    .disabled(!canRecord || model.classifier == nil)
                Text("Measures the current model on fresh takes it has never seen. Re-seat first for the honest number.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SectionCard(title: "Teach a new word") {
                HStack {
                    TextField("Word", text: $teachWord)
                    Button("Teach (3 takes)") {
                        let word = teachWord.trimmingCharacters(in: .whitespaces).lowercased()
                        model.addWord(word)
                        e.start(words: [word], reps: 3, blocks: 1, noisePerBlock: 0, prefix: "teach")
                        teachWord = ""
                    }
                    .disabled(teachWord.isEmpty || !canRecord)
                }
            }
        }
    }

    private func addWord() {
        model.addWord(newWord)
        newWord = ""
    }
}

/// Live accuracy while training: test-then-train results and quiz results.
private struct LiveAccuracyPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let e = model.enrollment
        VStack(alignment: .leading, spacing: 14) {
            Text("Live accuracy").font(.headline)
            if e.mode == .sentence || !e.sentenceResults.isEmpty {
                let sc = e.sentenceScore()
                MetricTile(title: "Sentence words", value: percent(sc.words), detail: "\(sc.count) sentences, unseen block")
                MetricTile(title: "Whole sentence right", value: percent(sc.exact))
                ForEach(e.sentenceResults.suffix(6).reversed()) { r in
                    Text((r.exact ? "✓ " : "✗ ") + (r.heard.isEmpty ? "—" : r.heard.joined(separator: " ")))
                        .font(.caption.monospaced()).foregroundStyle(r.exact ? .green : .secondary)
                }
                if Set(e.sentenceResults.map(\.block)).count > 1 {
                    ForEach(Array(Set(e.sentenceResults.map(\.block))).sorted(), id: \.self) { b in
                        let s = e.sentenceScore(block: b)
                        Text("Block \(b): words \(percent(s.words)) · whole \(percent(s.exact))").font(.caption.monospacedDigit())
                    }
                }
            } else if e.results.isEmpty {
                Text("Each take is predicted by a model that hasn't seen this block before it's saved. Scores appear from block 2 (or right away if you already have data).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                let t = e.score(quiz: false), q = e.score(quiz: true), last = e.score(quiz: nil, last: 10)
                MetricTile(title: "Test-then-train", value: percent(t.rate), detail: "\(t.correct)/\(t.total) takes, unseen block")
                MetricTile(title: "Quiz", value: percent(q.rate), detail: "\(q.correct)/\(q.total) test-only takes")
                MetricTile(title: "Last 10", value: percent(last.rate), detail: "Rolling")

                VStack(alignment: .leading, spacing: 4) {
                    Text("Per word").font(.subheadline.weight(.semibold))
                    ForEach(model.words + [noneLabel], id: \.self) { word in
                        let s = e.score(quiz: nil, label: word)
                        if s.total > 0 {
                            HStack {
                                Text(displayLabel(word)).frame(width: 90, alignment: .leading)
                                AccuracyBar(rate: s.rate ?? 0)
                                Text("\(s.correct)/\(s.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .trailing)
                            }
                        }
                    }
                }
                let blocks = e.blockScores()
                if blocks.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("By block (is more data helping?)").font(.subheadline.weight(.semibold))
                        ForEach(blocks, id: \.block) { b in
                            HStack {
                                Text("Block \(b.block)")
                                Spacer()
                                Text("test \(percent(b.test.rate))  quiz \(percent(b.quiz.rate))")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct AccuracyBar: View {
    var rate: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12))
                RoundedRectangle(cornerRadius: 3)
                    .fill(rate >= 0.9 ? Color.green : rate >= 0.7 ? Color.orange : Color.red)
                    .frame(width: g.size.width * rate)
            }
        }
        .frame(height: 10)
    }
}

private struct PromptCard: View {
    @Environment(AppModel.self) private var model
    var phase: Enrollment.Phase

    var body: some View {
        VStack(spacing: 14) {
            switch phase {
            case .idle:
                Image(systemName: "airpodspro").font(.system(size: 54)).foregroundStyle(.secondary)
                Text("Ready to train").font(.title2.weight(.semibold))
                coaching
            case .ready(let p, let quiz):
                quizTag(quiz)
                Text(p.text).font(.system(size: p.label == noneLabel || p.label.contains(" ") ? 40 : 72, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                hint(p)
                Text("Get ready… mouth it after the beep").foregroundStyle(.secondary)
            case .recording(let p, let quiz):
                quizTag(quiz)
                Text(p.text).font(.system(size: p.label == noneLabel || p.label.contains(" ") ? 40 : 72, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                hint(p)
                Label("Now", systemImage: "record.circle.fill").font(.title2).foregroundStyle(.red)
            case .feedback(let ok, let message, let heard, let correct):
                Image(systemName: !ok ? "exclamationmark.triangle.fill" : correct == false ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 54)).foregroundStyle(!ok ? .orange : correct == false ? .red : .green)
                Text(message).font(.title3).multilineTextAlignment(.center)
                if let heard {
                    Text("Model heard: \(displayLabel(heard))").font(.title2.weight(.semibold))
                        .foregroundStyle(correct == true ? .green : .red)
                }
                if !ok { Text("This prompt will come back later in the block.").foregroundStyle(.secondary) }
            case .quizIntro:
                Image(systemName: "questionmark.circle.fill").font(.system(size: 54)).foregroundStyle(.blue)
                Text("Quick quiz").font(.title.weight(.semibold))
                Text("One take per word, tested against everything learned so far. Not used for training.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            case .blockBreak(let next):
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 54)).foregroundStyle(.blue)
                Text("Re-seat your AirPods").font(.title.weight(.semibold))
                Text("Take both out, put them back in, then continue to block \(next).\nThis is what makes the accuracy number honest.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Continue (Space or stem)") { model.enrollment.continueAfterBreak() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .finished:
                Image(systemName: "checkmark.seal.fill").font(.system(size: 54)).foregroundStyle(.green)
                Text(model.enrollment.mode == .quiz ? "Quiz complete" : model.enrollment.mode == .sentence ? "Sentence training complete" : "Training complete")
                    .font(.title.weight(.semibold))
                HStack {
                    Button("Evaluate") { if model.devMode { model.devScreen = .evaluate } else { model.advancedPage = .accuracy }; model.runEvaluation() }
                    Button("Auto-tune") { if model.devMode { model.devScreen = .tune } else { model.advancedPage = .fineTune }; model.runAutoTune() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.secondary.opacity(0.06)))
    }

    @ViewBuilder private func hint(_ p: Enrollment.Prompt) -> some View {
        if p.label.contains(" ") {
            Text("Whole sentence, flowing, at your fast natural pace").font(.title3).foregroundStyle(.blue)
        }
        if let other = p.contrastWith {
            Text("CONTRAST DRILL: make it clearly different from \"\(other)\"").font(.caption.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.orange.opacity(0.25)))
        }
        if let h = Enrollment.hints[p.label] {
            Text(h).font(.title3).foregroundStyle(.blue).multilineTextAlignment(.center)
        }
    }

    @ViewBuilder private func quizTag(_ quiz: Bool) -> some View {
        if quiz {
            Text("QUIZ: test only").font(.caption.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.blue.opacity(0.2)))
        }
    }

    private var coaching: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Mouth each word silently with an exaggerated jaw, like talking through glass.", systemImage: "mouth")
            Label("Keep your head still; only your jaw moves.", systemImage: "person.fill")
            Label("Say it once, right after the beep.", systemImage: "speaker.wave.2")
            Label("Between blocks you'll re-seat the AirPods, then get a short quiz.", systemImage: "arrow.triangle.2.circlepath")
        }
        .font(.callout).foregroundStyle(.secondary)
        .padding(.top, 6)
    }
}
