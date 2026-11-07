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
    enum Mode: String { case train, quiz }

    struct Prompt: Identifiable, Hashable {
        let id = UUID()
        var label: String
        var text: String
        var action: SimAction
        var attempts = 0
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
        case calibrating
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

    private(set) var mode: Mode = .train
    private(set) var phase: Phase = .idle
    private(set) var block = 0
    private(set) var totalBlocks = 0
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var rejected = 0
    private(set) var log: [String] = []
    private(set) var results: [LiveResult] = []

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
        totalBlocks = blocks
        total = blocks * (words.count * reps + noisePerBlock) + (quizzes ? blocks * words.count : 0)
        completed = 0; rejected = 0; block = 0; log = []; results = []
        task = Task { [weak self] in
            await self?.run(words: words, reps: reps, blocks: blocks, noise: noisePerBlock,
                            session: session, prefix: prefix, quizzes: quizzes)
            self?.task = nil
        }
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

    private func run(words: [String], reps: Int, blocks: Int, noise: Int, session: String, prefix: String, quizzes: Bool) async {
        let hub = model.hub, cues = model.cues

        if mode == .train, model.dataset.noiseFloor == nil || prefix == "enroll" {
            phase = .calibrating
            cues.say("Stay still for two seconds")
            try? await Task.sleep(for: .seconds(1.2))
            cues.play(.start)
            let rest = await hub.capture(preroll: 0, window: 2.0)
            cues.play(.end)
            model.setNoiseFloor(Features.noiseFloor(rest, config: model.config.features))
            if Task.isCancelled { return }
        }

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
                await runPrompts(Self.prompts(words: words, reps: reps, noise: 0).shuffled(), block: b,
                                 blockID: "quiz-\(session)", session: session, quiz: true, classifier: classifier)
                continue
            }

            // Test-then-train: predict each new take with a model that has never seen this block.
            let blockID = "\(prefix)-\(session)-b\(b)"
            let honest = await buildClassifier(excluding: blockID)
            await runPrompts(Self.prompts(words: words, reps: reps, noise: noise).shuffled(), block: b,
                             blockID: blockID, session: session, quiz: false, classifier: honest)
            if Task.isCancelled { return }

            if quizzes {
                phase = .quizIntro
                cues.say("Quick quiz. These takes are only for testing")
                try? await Task.sleep(for: .seconds(1.6))
                let classifier = await buildClassifier(excluding: nil)
                await runPrompts(Self.prompts(words: words, reps: 1, noise: 0).shuffled(), block: b,
                                 blockID: "quiz-\(session)-b\(b)", session: session, quiz: true, classifier: classifier)
            }
        }
        if Task.isCancelled { return }
        cues.play(.ready)
        cues.say(mode == .quiz ? "Quiz done" : "Enrollment done")
        phase = .finished
    }

    private func buildClassifier(excluding block: String?) async -> Classifier? {
        let training = model.trainingFeatures(excludingBlock: block)
        let config = model.config.classifier
        return await Task.detached(priority: .userInitiated) { Classifier(training: training, config: config) }.value
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
            if let problem = Quality.check(features, noiseFloor: model.dataset.noiseFloor, isNone: isNone) {
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

    static func prompts(words: [String], reps: Int, noise: Int) -> [Prompt] {
        var out: [Prompt] = []
        for w in words { for _ in 0..<reps { out.append(Prompt(label: w, text: w, action: .word(w))) } }
        for kind in NoiseKind.allCases.shuffled().prefix(noise) {
            out.append(Prompt(label: noneLabel, text: kind.prompt, action: .noise(kind)))
        }
        return out
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
