import Foundation
import LouVoiceCore
import Observation

/// Decode loop (PLAN §6): trigger (Space / button; the stem toggles Speak aloud, D51) → beep → the same timed window as
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
        /// Best word by motion alone, before context (shown when context changed the answer).
        var motionBest: String?
        /// The previous word context used, nil = start of phrase.
        var contextWord: String?
        /// End of mouthed word → start of audio, seconds (PRD target < 1.5 s), and how it was voiced.
        var voiceDelay: Double?
        var voiceSource: VoiceService.Source?
        /// Sentence mode: the decoded words with their segments and alternatives (D40).
        var sentence: LouVoiceCore.SentenceResult?
        var isSentence: Bool { sentence != nil }
    }

    /// PRD success test: end of mouthed word to start of audio.
    static let delayTarget = 1.5

    enum Phase: Equatable { case idle, recording, thinking, confirming(until: Date) }

    private(set) var phase: Phase = .idle
    private(set) var results: [Result] = []
    private(set) var lastGesture: HeadGesture?

    /// Context screen: only these words (plus `_none`) can be decoded. Empty = all words.
    var activeWords: Set<String> = []
    var maxScore: Double = 3.0
    var minMargin: Double = 0.0
    /// "Speak aloud": off = words are shown but not spoken. Saved across launches.
    var speakResult = UserDefaults.standard.object(forKey: "speakAloud") as? Bool ?? true {
        didSet { UserDefaults.standard.set(speakResult, forKey: "speakAloud") }
    }
    /// One press = a whole sentence (D40). Off = the original one-word-per-press mode (kept as fallback).
    var sentenceMode = true
    var addConfirmedToTraining = true
    /// Simulator only: what the fake user mouths on the next trigger (nil = random active word).
    var simulatedWord: String?

    static let confirmSeconds = 3.0
    /// After this long without a word, context resets to the start of a phrase.
    static let contextIdleSeconds = 12.0

    /// Previous decoded word for next-word prediction (D37). nil = start of phrase.
    private(set) var contextWord: String?
    @ObservationIgnored private var contextTime = Date.distantPast

    /// Context to use for the next decode (resets after a pause).
    var currentContext: String? {
        Date().timeIntervalSince(contextTime) > Self.contextIdleSeconds ? nil : contextWord
    }

    func resetContext() { contextWord = nil; contextTime = .distantPast }

    /// What the context model expects next, best first.
    func expectedNext() -> [(word: String, p: Double)] {
        let ctx = model.config.context
        guard ctx.weight > 0 else { return [] }
        let allowed = wordModeAllowed
        let vocab = allowed.map { a in model.words.filter { a.contains($0) } } ?? model.words
        return ctx.expected(after: currentContext, vocabulary: vocab)
    }

    /// Word mode only decodes the words of the first expected phrase ("hello can you hear me").
    /// TODO(team): "for now" — widen to every trained word (or both sentences) once single-word
    /// accuracy on the newer words (my, name, is, konrad, how, are, today) is good enough.
    var wordModeWords: [String] {
        let trained = Set(model.words)
        return (model.config.context.tokenized.first ?? []).filter { trained.contains($0) }
    }

    /// Words a word-mode decode may output (`_none` is always added by the classifier).
    /// The Context screen's `activeWords` narrows it further. nil = no restriction
    /// (only when fewer than two of the phrase's words are trained, so word mode still works).
    private var wordModeAllowed: Set<String>? {
        var allowed = Set(wordModeWords)
        if allowed.count < 2 { allowed = [] }
        if !activeWords.isEmpty { allowed = allowed.isEmpty ? activeWords : allowed.intersection(activeWords) }
        return allowed.isEmpty ? nil : allowed
    }

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var detector = HeadGestureDetector()
    @ObservationIgnored private var confirmTask: Task<Void, Never>?

    init(model: AppModel) { self.model = model }

    var transcript: String {
        results.reversed().filter { $0.outcome == .confirmed || $0.outcome == .unconfirmed }
            .compactMap { $0.prediction.best?.label }.joined(separator: " ")
    }

    func clear() { results.removeAll(); resetContext() }

    func trigger() {
        if sentenceMode { triggerSentence(); return }
        guard phase == .idle || isConfirming, let classifier = model.classifier else { return }
        if isConfirming { finishConfirm(.unconfirmed) }
        let hub = model.hub, cues = model.cues
        phase = .recording
        Task { [weak self] in
            guard let self else { return }
            cues.play(.start)
            var simWord: String?
            if hub.isSimulated {
                let pool = self.wordModeAllowed.map { Array($0) } ?? self.model.words
                simWord = self.simulatedWord ?? pool.randomElement()
                hub.simulate(simWord.map { .word($0) })
            }
            let samples = await hub.capture(preroll: self.model.capture.preroll, window: self.model.capture.window)
            let captureEnd = Date()
            cues.play(.end)
            self.phase = .thinking
            guard let features = Features.extract(samples, config: self.model.config.features) else {
                self.phase = .idle
                return
            }
            if self.rejectForHeadMovement(features, samples: samples) { return }
            let active = self.wordModeAllowed
            // D51: the CNN decides single words when it knows every word that may come out.
            // Otherwise (e.g. a newly taught word) the DTW classifier below is used, as before.
            if let cnn = self.cnnForWordMode(active: active),
               let cnnFeatures = Features.extract(samples, config: PipelineConfig.defaults.features) {
                await self.finishWord(prediction: await Task.detached(priority: .userInitiated) {
                    Self.cnnPrediction(cnn, cnnFeatures.sequence, allowed: active)
                }.value, motionBest: nil, samples: samples, features: features, simWord: simWord,
                   captureEnd: captureEnd, previous: self.currentContext)
                return
            }
            let (maxScore, minMargin) = (self.maxScore, self.minMargin)
            var context = self.model.config.context
            let previous = self.currentContext
            // Speak › Word: words come in any order, so no next-word context (D50). On recordings,
            // Strong context out of order scored 36% against 68% for motion alone. The developer
            // Decode screen keeps its context slider for experiments.
            if self.model.screen == .speak { context.weight = 0 }
            let (prediction, motionBest) = await Task.detached(priority: .userInitiated) { () -> (Prediction, String?) in
                let motion = classifier.rank(features.sequence, active: active)
                let ranked = context.rescore(motion, previous: previous)
                let margin = Classifier.margin(ranked)
                var reason: String?
                if let best = ranked.first {
                    if best.label == noneLabel { reason = "Looked like non-word movement" }
                    else if (motion.first?.score ?? .infinity) > maxScore { reason = "Too far from every trained word" }
                    else if margin < minMargin { reason = "Too close between \(ranked[0].label) and \(ranked[1].label)" }
                } else { reason = "No usable motion" }
                return (Prediction(ranked: ranked, margin: margin, accepted: reason == nil, rejectReason: reason), motion.first?.label)
            }.value

            await self.finishWord(prediction: prediction, motionBest: motionBest, samples: samples, features: features,
                                  simWord: simWord, captureEnd: captureEnd, previous: previous)
        }
    }

    /// Single-word CNN to use for this decode, or nil to use DTW (D51).
    private func cnnForWordMode(active: Set<String>?) -> CNNWordModel? {
        // Trained on real AirPods takes only: the simulator's synthetic motion keeps using DTW.
        guard model.useWordCNN, !model.isSimulated, let cnn = model.wordCNN else { return nil }
        let known = Set(cnn.labels)
        let needed = active ?? Set(model.words)
        return needed.isSubset(of: known) ? cnn : nil
    }

    /// CNN answer for one take. Lower score = better (1 − probability among the allowed words).
    /// TODO(team): `cnnMinConfidence` below which it says "not sure" instead of guessing.
    nonisolated static func cnnPrediction(_ cnn: CNNWordModel, _ seq: FeatureSequence, allowed: Set<String>?) -> Prediction {
        let ranked = cnn.rank(seq, allowed: allowed.map { $0.union([noneLabel]) })
        let margin = Classifier.margin(ranked)
        var reason: String?
        if let best = ranked.first {
            if best.label == noneLabel { reason = "Looked like non-word movement" }
            else if 1 - best.score < cnnMinConfidence { reason = "Not sure: try again" }
        } else { reason = "No usable motion" }
        return Prediction(ranked: ranked, margin: margin, accepted: reason == nil, rejectReason: reason)
    }

    nonisolated static let cnnMinConfidence = 0.0

    private func finishWord(prediction: Prediction, motionBest: String?, samples: [MotionSample], features: SegmentFeatures,
                            simWord: String?, captureEnd: Date, previous: String?) async {
        let cues = model.cues
        var result = Result(prediction: prediction, outcome: .pending, samples: samples,
                            features: features, simulatedWord: simWord, motionBest: motionBest, contextWord: previous)
        if prediction.accepted, let word = prediction.best?.label {
            self.results.insert(result, at: 0)
            if self.speakResult {
                let spoken = await self.model.voice.speak(word) // VOICE HOOK (Neel)
                // Quiet tail of the window after the word + processing + time to start playback.
                // Bluetooth output latency (~0.1–0.2 s) comes on top and isn't measurable here.
                let delay = features.trailingSeconds + Date().timeIntervalSince(captureEnd)
                if let i = self.results.firstIndex(where: { $0.id == result.id }) {
                    self.results[i].voiceDelay = delay
                    self.results[i].voiceSource = spoken.source
                }
            }
            self.startConfirm()
        } else {
            result.outcome = .discarded
            self.results.insert(result, at: 0)
            cues.play(.reject)
            self.phase = .idle
        }
    }

    /// Sentence mode: beep, mouth the whole sentence, every word comes out in order.
    private func triggerSentence() {
        guard phase == .idle || isConfirming, let classifier = model.classifier else { return }
        if isConfirming { finishConfirm(.unconfirmed) }
        let hub = model.hub, cues = model.cues
        var config = model.config
        // Speak screen: a sentence is always one of the expected phrases in full, or nothing (D45, D47).
        // The developer Decode screen keeps its own switches for these.
        if model.screen == .speak {
            config.sentence.onlyExpectedPhrases = true
            config.sentence.rejectNothing = true
        }
        guard let decoder = SentenceDecoder(classifier: classifier, pipeline: config, config: config.sentence) else { return }
        phase = .recording
        Task { [weak self] in
            guard let self else { return }
            cues.play(.start)
            var simText: String?
            if hub.isSimulated, let phrase = config.context.tokenized.first {
                simText = phrase.joined(separator: " ")
                Task { @MainActor in for w in phrase { hub.simulate(.word(w)); try? await Task.sleep(for: .milliseconds(520)) } }
            }
            let sc = config.sentence
            let samples = sc.stopWhenQuiet
                ? await hub.captureUntilQuiet(preroll: self.model.capture.preroll, maxWindow: sc.windowSeconds, quiet: sc.stopAfterQuietSeconds)
                : await hub.capture(preroll: self.model.capture.preroll, window: sc.windowSeconds)
            let captureEnd = Date()
            cues.play(.end)
            self.phase = .thinking
            guard let features = Features.extract(samples, config: config.features) else { self.phase = .idle; return }
            if self.rejectForHeadMovement(features, samples: samples) { return }
            let active = self.activeWords.isEmpty ? nil : self.activeWords
            let refs = self.model.sentenceReferences
            let sentence = await Task.detached(priority: .userInitiated) {
                decoder.decodeSentence(samples, context: config.context, active: active, references: refs)
            }.value
            let rejected = sentence?.rejectReason
            let words = rejected == nil ? (sentence?.words.map(\.label) ?? []) : []
            let text = words.joined(separator: " ")
            let prediction = Prediction(ranked: [RankedLabel(label: text, score: 0)], margin: 1,
                                        accepted: !words.isEmpty, rejectReason: rejected ?? (words.isEmpty ? "No words found" : nil))
            var result = Result(prediction: prediction, outcome: .pending, samples: samples, features: features,
                                simulatedWord: simText, contextWord: nil, sentence: sentence)
            guard !words.isEmpty else {
                result.outcome = .discarded
                self.results.insert(result, at: 0)
                cues.play(.reject); self.phase = .idle
                return
            }
            self.results.insert(result, at: 0)
            if self.speakResult {
                let spoken = await self.model.voice.speak(words: words)
                let delay = (sentence?.trailingSeconds ?? 0) + Date().timeIntervalSince(captureEnd)
                if let i = self.results.firstIndex(where: { $0.id == result.id }) {
                    self.results[i].voiceDelay = delay
                    self.results[i].voiceSource = spoken.source
                }
            }
            self.startConfirm()
        }
    }

    /// Correction (sentence mode): replace word `index` of the latest sentence with an alternative.
    func correct(resultID: UUID, index: Int, to word: String) {
        guard let i = results.firstIndex(where: { $0.id == resultID }), var s = results[i].sentence, index < s.words.count else { return }
        s.words[index].label = word
        results[i].sentence = s
        let text = s.words.map(\.label).joined(separator: " ")
        results[i].prediction = Prediction(ranked: [RankedLabel(label: text, score: 0)], margin: 1, accepted: true, rejectReason: nil)
        results[i].voiceDelay = nil
    }

    /// "Hold still" gate (D42): with Tune › Robustness › decode head limit set, a capture whose head
    /// turned more than that is refused with a reason instead of guessed.
    private func rejectForHeadMovement(_ features: SegmentFeatures, samples: [MotionSample]) -> Bool {
        let limit = model.config.robustness.decodeMaxHeadDegrees
        guard limit > 0, features.headRotationDegrees > limit else { return false }
        let reason = String(format: "Head moved %.0f° — hold still and try again", features.headRotationDegrees)
        results.insert(Result(prediction: Prediction(ranked: [], margin: 0, accepted: false, rejectReason: reason),
                              outcome: .discarded, samples: samples, features: features), at: 0)
        model.cues.play(.reject)
        phase = .idle
        return true
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
        if outcome == .confirmed || outcome == .unconfirmed,
           let word = results[i].sentence?.words.last?.label ?? results[i].prediction.best?.label {
            contextWord = word
            contextTime = Date()
        }
        switch outcome {
        case .confirmed:
            model.cues.play(.accept)
            let r = results[i]
            if addConfirmedToTraining, let sentence = r.sentence {
                // Confirmed sentence: each decoded segment becomes a word take (D40).
                let day = String(Enrollment.stamp().prefix(8))
                for (w, cut) in zip(sentence.words, SentenceDecoder.cut(r.samples, result: sentence)) {
                    if let f = Features.extract(cut, config: model.config.features) {
                        model.addTake(Take(label: w.label, block: "confirmed-\(day)", session: day, samples: cut), features: f)
                    }
                }
                model.addTake(Take(label: sentence.text, block: "confirmed-\(day)", session: day, samples: r.samples, isSentence: true),
                              features: r.features)
            } else if addConfirmedToTraining, let label = r.prediction.best?.label {
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
