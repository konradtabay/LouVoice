import Foundation
import LouVoiceCore
import Observation

/// Decode loop (PLAN §6): trigger (Space / stem / button) → beep → the same timed window as
/// enrollment → classify off the main thread → nod/shake (or Y/N) confirmation window.
@MainActor @Observable
final class Decoder {
    enum Outcome: String { case pending, confirmed, rejected, unconfirmed, discarded }

    struct Result: Identifiable {
        let id = UUID()
        var prediction: Prediction
        var outcome: Outcome
        var samples: [MotionSample]
        var features: SegmentFeatures
        var simulatedWord: String?
        var date = Date()
    }

    enum Phase: Equatable { case idle, recording, thinking, confirming(until: Date) }

    private(set) var phase: Phase = .idle
    private(set) var results: [Result] = []
    private(set) var lastGesture: HeadGesture?

    /// Context screen: only these words (plus `_none`) can be decoded. Empty = all words.
    var activeWords: Set<String> = []
    var maxScore: Double = 3.0
    var minMargin: Double = 0.0
    var speakResult = true
    var addConfirmedToTraining = true
    /// Simulator only: what the fake user mouths on the next trigger (nil = random active word).
    var simulatedWord: String?

    static let confirmSeconds = 3.0

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var detector = HeadGestureDetector()
    @ObservationIgnored private var confirmTask: Task<Void, Never>?

    init(model: AppModel) { self.model = model }

    var transcript: String {
        results.reversed().filter { $0.outcome == .confirmed || $0.outcome == .unconfirmed }
            .compactMap { $0.prediction.best?.label }.joined(separator: " ")
    }

    func clear() { results.removeAll() }

    func trigger() {
        guard phase == .idle || isConfirming, let classifier = model.classifier else { return }
        if isConfirming { finishConfirm(.unconfirmed) }
        let hub = model.hub, cues = model.cues
        phase = .recording
        Task { [weak self] in
            guard let self else { return }
            cues.play(.start)
            var simWord: String?
            if hub.isSimulated {
                let pool = self.activeWords.isEmpty ? self.model.words : Array(self.activeWords)
                simWord = self.simulatedWord ?? pool.randomElement()
                hub.simulate(simWord.map { .word($0) })
            }
            let samples = await hub.capture(preroll: self.model.capture.preroll, window: self.model.capture.window)
            cues.play(.end)
            self.phase = .thinking
            guard let features = Features.extract(samples, config: self.model.config.features) else {
                self.phase = .idle
                return
            }
            let active = self.activeWords.isEmpty ? nil : self.activeWords
            let (maxScore, minMargin) = (self.maxScore, self.minMargin)
            let prediction = await Task.detached(priority: .userInitiated) {
                classifier.predict(features.sequence, active: active, maxScore: maxScore, minMargin: minMargin)
            }.value

            var result = Result(prediction: prediction, outcome: .pending, samples: samples,
                                features: features, simulatedWord: simWord)
            if prediction.accepted, let word = prediction.best?.label {
                if self.speakResult { cues.say(word) }
                self.results.insert(result, at: 0)
                self.startConfirm()
            } else {
                result.outcome = .discarded
                self.results.insert(result, at: 0)
                cues.play(.reject)
                self.phase = .idle
            }
        }
    }

    var isConfirming: Bool { if case .confirming = phase { true } else { false } }

    private func startConfirm() {
        detector.reset()
        lastGesture = nil
        phase = .confirming(until: Date().addingTimeInterval(Self.confirmSeconds))
        confirmTask?.cancel()
        confirmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.confirmSeconds))
            guard !Task.isCancelled else { return }
            self?.finishConfirm(.unconfirmed)
        }
    }

    /// Y/N keys or nod/shake.
    func confirm(_ yes: Bool) {
        guard isConfirming else { return }
        finishConfirm(yes ? .confirmed : .rejected)
    }

    /// Every motion sample passes through here; gestures only count during confirmation.
    func ingest(_ s: MotionSample) {
        guard isConfirming else { return }
        if let g = detector.push(s) {
            lastGesture = g
            confirm(g == .nod)
        }
    }

    /// Simulator buttons.
    func simulateGesture(_ g: HeadGesture) {
        model.hub.simulate(g == .nod ? .nod : .shake)
    }

    private func finishConfirm(_ outcome: Outcome) {
        confirmTask?.cancel()
        confirmTask = nil
        phase = .idle
        guard let i = results.firstIndex(where: { $0.outcome == .pending }) else { return }
        results[i].outcome = outcome
        switch outcome {
        case .confirmed:
            model.cues.play(.accept)
            let r = results[i]
            if addConfirmedToTraining, let label = r.prediction.best?.label {
                // Confirmed decodes become training data (D15), in their own daily block.
                let day = String(Enrollment.stamp().prefix(8))
                model.addTake(Take(label: label, block: "confirmed-\(day)", session: day, samples: r.samples),
                              features: r.features)
            }
        case .rejected:
            model.cues.play(.reject)
        default:
            break
        }
    }
}
