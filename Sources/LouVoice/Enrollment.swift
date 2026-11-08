import Foundation
import LouVoiceCore
import Observation

/// Prompted, timed enrollment (PLAN §5) with continuous accuracy testing (D31):
/// - **Test-then-train:** before a take is stored, the model built from the *other* blocks
///   predicts it. Every take is therefore an honest test, and accuracy updates live.
/// - **Quiz rounds:** optional test-only prompts after each block (or on their own) against the
///   model trained on everything so far. Quiz takes are saved with `isTest` and never trained on.
@MainActor @Observable
final class Enrollment {
    enum Mode: String { case train, quiz, sentence }

    struct Prompt: Identifiable, Hashable {
        let id = UUID()
        var label: String
        var text: String
        var action: SimAction
        var attempts = 0
        /// Set for contrast drills: the other word of the confused pair, prompted right next to this one.
        var contrastWith: String? = nil
    }

    /// Adaptive block plan (D36): extra reps for weak words, contrast drills for confused pairs.
    struct BlockPlan: Equatable {
        var extra: [String: Int] = [:]
        var pairs: [[String]] = []
        var basis = ""
        var isEmpty: Bool { extra.values.allSatisfy { $0 == 0 } && pairs.isEmpty }
        var summary: String {
            if isEmpty { return basis.isEmpty ? "No adjustments yet" : "All words strong: no extra reps (\(basis))" }
            var parts = extra.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map { "\($0.key) +\($0.value)" }
            parts += pairs.map { "\($0[0]) ↔ \($0[1]) drill ×\(Enrollment.contrastReps)" }
            return parts.joined(separator: " · ") + " (\(basis))"
        }
    }

    struct LiveResult: Identifiable {
        let id = UUID()
        var label: String
        var predicted: String
        var isQuiz: Bool
        var block: Int
        var correct: Bool { label == predicted }
    }

    enum Phase: Equatable {
        case idle
        case ready(Prompt, quiz: Bool)
        case recording(Prompt, quiz: Bool)
        case feedback(ok: Bool, message: String, heard: String?, correct: Bool?)
        case blockBreak(next: Int)
        case quizIntro
        case finished
    }

    var reps = 3
    var blockCount = 3
    var noisePerBlock = 4
    var quizAfterBlock = true
    /// Words that get extra reps in training blocks (the confused ones).
    var focusWords: Set<String> = []
    var focusExtraReps = 2
    /// Plan each training block from current accuracy (D36).
    var adaptive = true
    nonisolated static let contrastReps = 2
    private(set) var plan = BlockPlan()

    /// Articulation hints: give each word its own distinct, repeatable movement (D35).
    static let hints: [String: String] = [
        "hello": "Two beats: drop the jaw on \"hel\", open wide on \"LO\"",
        "can": "One big jaw drop: \"KAAAN\"",
        "you": "Push the lips forward into a tight \"OO\", jaw nearly still",
        "hear": "Small open, then pull the corners back: \"HEE-er\"",
        "me": "Press the lips together hard, then a wide smile: \"m-EE\"",
        "my": "Lips together, then drop the jaw wide: \"m-AI\"",
        "name": "Lips together twice: \"N-AY-m\", jaw half open in the middle",
        "is": "Tiny and quick: small smile, teeth almost closed, \"IZ\"",
        "konrad": "Two strong beats: big drop on \"KON\", then \"rad\"",
        "how": "Open wide, then round the lips: \"HA-OW\"",
        "are": "One long open jaw: \"AAR\"",
        "today": "Two beats: small \"tuh\", then wide \"DAY\"",
    ]

    private(set) var mode: Mode = .train
    private(set) var phase: Phase = .idle
    private(set) var block = 0
    private(set) var totalBlocks = 0
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var rejected = 0
    private(set) var log: [String] = []
    private(set) var results: [LiveResult] = []

    /// Sentence training (D40): honest decode of each sentence before its words are learned.
    struct SentenceResult: Identifiable {
        let id = UUID()
        var said: [String], heard: [String], block: Int
        var wordAccuracy: Double { SentenceScore.wordAccuracy(said: said, heard: heard) }
        var exact: Bool { said == heard }
    }
    private(set) var sentenceResults: [SentenceResult] = []
    /// Phrases prompted in the current sentence session.
    private(set) var sentencePhrases: [[String]] = []
    var sentenceReps = 5
    var sentenceBlocks = 3
    /// Prompt random contiguous parts of the phrase ("hello can", "you hear me") as well as the whole (D44).
    var varySentenceLength = false
    /// Share of takes that are the full phrase when varying length.
    static let fullPhraseShare = 0.4

    static let readyPause = 0.9, maxAttempts = 3

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var breakContinuation: CheckedContinuation<Void, Never>?

    init(model: AppModel) { self.model = model }

    var isRunning: Bool { task != nil }

    // MARK: Live scores

    struct Score { var correct = 0, total = 0; var rate: Double? { total == 0 ? nil : Double(correct) / Double(total) } }

    func score(quiz: Bool?, label: String? = nil, last: Int? = nil) -> Score {
        var rs = results.filter { (quiz == nil || $0.isQuiz == quiz!) && (label == nil || $0.label == label!) }
        if let last { rs = Array(rs.suffix(last)) }
        return Score(correct: rs.filter(\.correct).count, total: rs.count)
    }

    /// Per-block honest accuracy, to see whether more data is helping.
    func blockScores() -> [(block: Int, test: Score, quiz: Score)] {
        Set(results.map(\.block)).sorted().map { b in
            let t = results.filter { $0.block == b && !$0.isQuiz }, q = results.filter { $0.block == b && $0.isQuiz }
            return (b, Score(correct: t.filter(\.correct).count, total: t.count),
                    Score(correct: q.filter(\.correct).count, total: q.count))
        }
    }

    // MARK: Control

    /// Training enrollment, a quick "teach a new word" (one block, no noise), or a quiz.
    func start(words: [String], reps: Int, blocks: Int, noisePerBlock: Int, prefix: String = "enroll", mode: Mode = .train) {
        guard task == nil, !words.isEmpty else { return }
        let session = Self.stamp()
        self.mode = mode
        let quizzes = mode == .train && quizAfterBlock
        let focus = mode == .train ? focusWords.intersection(words) : []
        let extra = focusExtraReps
        totalBlocks = blocks
        total = blocks * (words.count * reps + focus.count * extra + noisePerBlock) + (quizzes ? blocks * words.count : 0)
        completed = 0; rejected = 0; block = 0; log = []; results = []
        task = Task { [weak self] in
            await self?.run(words: words, reps: reps, blocks: blocks, noise: noisePerBlock,
                            session: session, prefix: prefix, quizzes: quizzes, focus: focus, extra: extra)
            self?.task = nil
        }
    }

    /// Mouth the whole phrase, flowing, each take (D40). Each take is decoded by a model that
    /// hasn't seen this block, then aligned to the known words and cut into word takes.
    func startSentences(phrase: String, reps: Int, blocks: Int) {
        startSentences(phrases: [phrase], reps: reps, blocks: blocks)
    }

    /// Several phrases: each take picks one at random (balanced per block), e.g. both demo sentences (D45).
    func startSentences(phrases: [String], reps: Int, blocks: Int) {
        let list = phrases.map { $0.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) }.filter { $0.count >= 2 }
        guard task == nil, let words = list.first else { return }
        sentencePhrases = list
        let session = Self.stamp()
        mode = .sentence
        totalBlocks = blocks
        total = blocks * reps
        completed = 0; rejected = 0; block = 0; log = []; results = []; sentenceResults = []
        task = Task { [weak self] in
            await self?.runSentences(phrase: words.joined(separator: " "), words: words, reps: reps, blocks: blocks, session: session)
            self?.task = nil
        }
    }

    /// The words to prompt for one sentence take.
    private func pickSentence(_ words: [String]) -> [String] {
        let words = sentencePhrases.count > 1 ? (sentencePhrases.randomElement() ?? words) : words
        guard varySentenceLength, words.count > 2, Double.random(in: 0..<1) >= Self.fullPhraseShare else { return words }
        let len = Int.random(in: 2...(words.count - 1))
        let start = Int.random(in: 0...(words.count - len))
        return Array(words[start..<(start + len)])
    }

    private func runSentences(phrase: String, words fullWords: [String], reps: Int, blocks: Int, session: String) async {
        let hub = model.hub, cues = model.cues
        for b in 1...blocks {
            block = b
            if b > 1 {
                phase = .blockBreak(next: b)
                cues.say("Take out both AirPods, put them back in, then press continue")
                if hub.isSimulated { hub.simulator.reseat() }
                await withCheckedContinuation { breakContinuation = $0 }
                if Task.isCancelled { return }
            }
            let blockID = "sentence-\(session)-b\(b)"
            let honest = await buildClassifier(excluding: blockID)
            var done = 0, attempts = 0
            var words = pickSentence(fullWords)
            while done < reps {
                if Task.isCancelled { return }
                if attempts == 0 { words = pickSentence(fullWords) }
                let phrase = words.joined(separator: " ")
                let prompt = Prompt(label: phrase, text: phrase, action: .word(words[0]))
                phase = .ready(prompt, quiz: false)
                cues.say(phrase)
                try? await Task.sleep(for: .seconds(Self.readyPause + 1.2))
                if Task.isCancelled { return }
                phase = .recording(prompt, quiz: false)
                cues.play(.start)
                if hub.isSimulated { simulateSentence(words) }
                var sc = model.config.sentence
                sc.windowSeconds = max(2.5, sc.windowSeconds * Double(words.count) / 5.0 + 1.5)
                let samples = sc.stopWhenQuiet
                    ? await hub.captureUntilQuiet(preroll: model.capture.preroll, maxWindow: sc.windowSeconds, quiet: sc.stopAfterQuietSeconds)
                    : await hub.capture(preroll: model.capture.preroll, window: sc.windowSeconds)
                cues.play(.end)
                if Task.isCancelled { return }

                let config = model.config
                guard let features = Features.extract(samples, config: config.features) else {
                    phase = .feedback(ok: false, message: "No motion data — are the AirPods connected?", heard: nil, correct: nil)
                    try? await Task.sleep(for: .seconds(1.2)); continue
                }
                var q = config.quality; q.checkHeadMovement = false     // a 4 s sentence moves the head a little
                if let problem = Quality.check(features, config: q, isNone: false), attempts < Self.maxAttempts {
                    rejected += 1; attempts += 1
                    log.insert("✗ sentence: \(problem)", at: 0)
                    phase = .feedback(ok: false, message: problem, heard: nil, correct: nil)
                    try? await Task.sleep(for: .seconds(1.4)); continue
                }
                attempts = 0

                // 1. Honest test: decode with a model that never saw this block.
                var heard: [String]?
                if let honest, let dec = SentenceDecoder(classifier: honest, pipeline: config, config: config.sentence) {
                    // While practising parts, the honest test must allow parts too.
                    var ctx = config.context
                    ctx.phrases = Array(Set(sentencePhrases.map { $0.joined(separator: " ") } + ctx.phrases))
                    if varySentenceLength { ctx.includeParts = true }
                    // Honest: whole-sentence references only from other blocks.
                    let others = model.dataset.sentenceTakes.filter { $0.block != blockID }.map { (label: $0.label, samples: $0.samples) }
                    heard = await Task.detached(priority: .userInitiated) {
                        dec.decodeSentence(samples, context: ctx, references: dec.sentenceReferences(others))?.words.map(\.label)
                    }.value
                }
                if let heard { sentenceResults.append(SentenceResult(said: words, heard: heard, block: b)) }

                // 2. Learn: align to the known words with the current model and store each word.
                var added = 0
                if let full = model.classifier ?? honest, let dec = SentenceDecoder(classifier: full, pipeline: config, config: config.sentence) {
                    let cuts: [(String, [MotionSample])] = await Task.detached(priority: .userInitiated) {
                        guard let f = dec.features(samples), let aligned = dec.align(f.seq, phrase: words) else { return [] }
                        let result = LouVoiceCore.SentenceResult(words: aligned, rate: config.features.rate,
                                                                 startOffset: f.startOffset, trailingSeconds: f.trailing)
                        return Array(zip(aligned.map(\.label), SentenceDecoder.cut(samples, result: result)))
                    }.value
                    for (label, cut) in cuts {
                        guard let wf = Features.extract(cut, config: config.features) else { continue }
                        model.addTake(Take(label: label, block: blockID, session: session, samples: cut), features: wf)
                        added += 1
                    }
                }
                model.addTake(Take(label: phrase, block: blockID, session: session, samples: samples, isSentence: true), features: features)
                done += 1; completed += 1

                let heardText = heard?.joined(separator: " ")
                let correct = heard.map { $0 == words }
                log.insert("sentence: heard \"\(heardText ?? "—")\" · learned \(added)/\(words.count) words", at: 0)
                phase = .feedback(ok: true, message: added == words.count ? "Learned all \(added) words" : "Learned \(added) of \(words.count) words",
                                  heard: heardText, correct: correct)
                try? await Task.sleep(for: .seconds(1.3))
            }
        }
        if Task.isCancelled { return }
        cues.play(.ready)
        cues.say("Sentence training done")
        phase = .finished
        if model.voice.isConfigured { await model.voice.prepare(words: model.words) }
    }

    /// Simulator: perform the phrase's words one after another at a fast pace.
    private func simulateSentence(_ words: [String]) {
        let hub = model.hub
        Task { @MainActor in
            for w in words {
                hub.simulate(.word(w))
                try? await Task.sleep(for: .milliseconds(520))
            }
        }
    }

    /// Mean word accuracy and exact-sentence rate of the honest sentence decodes.
    func sentenceScore(block: Int? = nil) -> (words: Double?, exact: Double?, count: Int) {
        let rs = sentenceResults.filter { block == nil || $0.block == block! }
        guard !rs.isEmpty else { return (nil, nil, 0) }
        return (rs.map(\.wordAccuracy).reduce(0, +) / Double(rs.count), Double(rs.filter(\.exact).count) / Double(rs.count), rs.count)
    }

    func startQuiz(words: [String], reps: Int) {
        start(words: words, reps: reps, blocks: 1, noisePerBlock: 0, prefix: "quiz", mode: .quiz)
    }

    func stop() {
        task?.cancel()
        task = nil
        breakContinuation?.resume()
        breakContinuation = nil
        phase = .idle
    }

    func continueAfterBreak() {
        breakContinuation?.resume()
        breakContinuation = nil
    }

    // MARK: Flow

    private func run(words: [String], reps: Int, blocks: Int, noise: Int, session: String, prefix: String, quizzes: Bool,
                     focus: Set<String>, extra: Int) async {
        let hub = model.hub, cues = model.cues

        // No separate "stay still" calibration: the strength check is self-normalising (D32).

        for b in 1...blocks {
            block = b
            if b > 1 {
                phase = .blockBreak(next: b)
                cues.say("Take out both AirPods, put them back in, then press continue")
                if hub.isSimulated { hub.simulator.reseat() }
                await withCheckedContinuation { breakContinuation = $0 }
                if Task.isCancelled { return }
            }

            if mode == .quiz {
                let classifier = await buildClassifier(excluding: nil)
                await runPrompts(Self.prompts(words: words, reps: reps, noise: 0), block: b,
                                 blockID: "quiz-\(session)", session: session, quiz: true, classifier: classifier)
                continue
            }

            // Test-then-train: predict each new take with a model that has never seen this block.
            let blockID = "\(prefix)-\(session)-b\(b)"
            let honest = await buildClassifier(excluding: blockID)
            plan = adaptive ? await makePlan(words: words) : BlockPlan()
            let prompts = Self.prompts(words: words, reps: reps, noise: noise, focus: focus, extra: extra, plan: plan)
            total += prompts.count - (words.count * reps + focus.count * extra + noise)
            if !plan.isEmpty { log.insert("Block \(b) plan: \(plan.summary)", at: 0) }
            await runPrompts(prompts, block: b,
                             blockID: blockID, session: session, quiz: false, classifier: honest)
            if Task.isCancelled { return }

            if quizzes {
                phase = .quizIntro
                cues.say("Quick quiz. These takes are only for testing")
                try? await Task.sleep(for: .seconds(1.6))
                let classifier = await buildClassifier(excluding: nil)
                await runPrompts(Self.prompts(words: words, reps: 1, noise: 0), block: b,
                                 blockID: "quiz-\(session)-b\(b)", session: session, quiz: true, classifier: classifier)
            }
        }
        if Task.isCancelled { return }
        cues.play(.ready)
        cues.say(mode == .quiz ? "Quiz done" : "Enrollment done")
        phase = .finished
        // Cache the user's voice for every word now, so decode playback is instant and offline.
        if model.voice.isConfigured { await model.voice.prepare(words: model.words) }
    }

    private func buildClassifier(excluding block: String?) async -> Classifier? {
        let input = model.trainingInputs(excludingBlock: block)
        return await Task.detached(priority: .userInitiated) {
            Classifier(training: AppModel.buildTraining(input), config: input.config.classifier)
        }.value
    }

    private func runPrompts(_ prompts: [Prompt], block b: Int, blockID: String, session: String,
                            quiz: Bool, classifier: Classifier?) async {
        let hub = model.hub, cues = model.cues
        var queue = prompts
        while !queue.isEmpty {
            if Task.isCancelled { return }
            var prompt = queue.removeFirst()
            phase = .ready(prompt, quiz: quiz)
            cues.say(prompt.text)
            try? await Task.sleep(for: .seconds(Self.readyPause + (prompt.label == noneLabel ? 0.6 : 0)))
            if Task.isCancelled { return }

            phase = .recording(prompt, quiz: quiz)
            cues.play(.start)
            hub.simulate(prompt.action)
            let samples = await hub.capture(preroll: model.capture.preroll, window: model.capture.window)
            cues.play(.end)
            if Task.isCancelled { return }

            let isNone = prompt.label == noneLabel
            guard let features = Features.extract(samples, config: model.config.features) else {
                phase = .feedback(ok: false, message: "No motion data — are the AirPods connected?", heard: nil, correct: nil)
                try? await Task.sleep(for: .seconds(1.2))
                queue.append(prompt)
                continue
            }
            if let problem = Quality.check(features, config: model.config.quality, isNone: isNone) {
                rejected += 1
                prompt.attempts += 1
                log.insert("✗ \(prompt.text): \(problem)", at: 0)
                phase = .feedback(ok: false, message: problem, heard: nil, correct: nil)
                if prompt.attempts < Self.maxAttempts { queue.append(prompt) } else { completed += 1 }
                try? await Task.sleep(for: .seconds(1.4))
                continue
            }

            // Test before train.
            var heard: String?
            if let classifier {
                let seq = features.sequence
                heard = await Task.detached(priority: .userInitiated) { classifier.predict(seq).best?.label }.value
            }
            if let heard {
                results.append(LiveResult(label: prompt.label, predicted: heard, isQuiz: quiz, block: b))
            }
            model.addTake(Take(label: prompt.label, block: blockID, session: session, samples: samples, isTest: quiz),
                          features: features)
            completed += 1
            let mark = heard.map { $0 == prompt.label ? "✓" : "✗ heard \(displayLabel($0))" } ?? "(no model yet)"
            log.insert("\(quiz ? "quiz" : "take") \(displayLabel(prompt.label)): \(mark)", at: 0)
            phase = .feedback(ok: true, message: quiz ? "Quiz take saved" : "Got it",
                              heard: heard, correct: heard.map { $0 == prompt.label })
            try? await Task.sleep(for: .seconds(heard == nil ? 0.5 : 0.9))
        }
    }

    /// Score the data so far and decide where this block's extra reps go.
    /// Uses held-out-block accuracy when there are 2+ blocks, else this session's live results.
    private func makePlan(words: [String]) async -> BlockPlan {
        let takes = model.dataset.trainingTakes.compactMap { take in
            model.features(for: take).map { EvalTake(id: take.id.uuidString, label: take.label, block: take.block, features: $0.sequence) }
        }
        let config = model.config.classifier
        var perLabel: [String: Double] = [:]
        var pairs: [ConfusedPair] = []
        var basis = ""
        if Set(takes.map(\.block)).count >= 2,
           let r = await Task.detached(priority: .userInitiated, operation: { Evaluation.run(takes, config: config, permutations: 0) }).value {
            perLabel = r.perLabelAccuracy
            pairs = r.confusedPairs
            basis = "from \(takes.count) takes"
        } else if !results.isEmpty {
            for w in words {
                let s = score(quiz: nil, label: w)
                if let rate = s.rate { perLabel[w] = rate }
            }
            var counts: [String: Int] = [:]
            for r in results where !r.correct && r.label != noneLabel && r.predicted != noneLabel {
                counts[[r.label, r.predicted].sorted().joined(separator: "|"), default: 0] += 1
            }
            pairs = counts.map { k, v in let ab = k.split(separator: "|").map(String.init); return ConfusedPair(a: ab[0], b: ab[1], count: v) }
                .sorted { $0.count > $1.count }
            basis = "from this session's live results"
        } else {
            return BlockPlan()
        }
        var plan = BlockPlan(basis: basis)
        for w in words {
            let acc = perLabel[w] ?? 1
            plan.extra[w] = acc < 0.5 ? 3 : acc < 0.7 ? 2 : acc < 0.85 ? 1 : 0
        }
        plan.pairs = pairs.filter { words.contains($0.a) && words.contains($0.b) && $0.count >= 2 }
            .prefix(2).map { [$0.a, $0.b] }
        return plan
    }

    static func prompts(words: [String], reps: Int, noise: Int, focus: Set<String> = [], extra: Int = 0,
                        plan: BlockPlan = BlockPlan()) -> [Prompt] {
        // Units are shuffled as a whole so contrast pairs stay back to back.
        var units: [[Prompt]] = []
        for w in words {
            let n = reps + (focus.contains(w) ? extra : 0) + (plan.extra[w] ?? 0)
            for _ in 0..<n { units.append([Prompt(label: w, text: w, action: .word(w))]) }
        }
        for pair in plan.pairs {
            for _ in 0..<contrastReps {
                let ordered = Bool.random() ? pair : pair.reversed()
                units.append(ordered.enumerated().map { i, w in
                    Prompt(label: w, text: w, action: .word(w), contrastWith: ordered[1 - i])
                })
            }
        }
        var out: [Prompt] = []
        for kind in NoiseKind.allCases.shuffled().prefix(noise) {
            units.append([Prompt(label: noneLabel, text: kind.prompt, action: .noise(kind))])
        }
        for unit in units.shuffled() { out += unit }
        return out
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
