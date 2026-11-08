import AppKit
import Foundation
import LouVoiceCore
import Observation

/// Capture timing (D13). Changing it affects new takes only.
struct CaptureSettings: Codable, Hashable {
    var preroll = 0.3
    var window = 1.8
}

@MainActor @Observable
final class AppModel {
    /// The four tabs the user sees, plus Settings (opened from the gear). TODO(team): "Speak" is the "use" tab.
    enum Screen: String, CaseIterable, Identifiable {
        case signals = "Signals", train = "Train", speak = "Speak", history = "History", settings = "Settings"
        var id: String { rawValue }
        static let tabs: [Screen] = [.signals, .train, .speak, .history]
    }

    /// Settings › Advanced: the original full screens, kept intact for caregivers and the team.
    enum AdvancedPage: String, CaseIterable, Identifiable {
        case trainingConsole = "Training console", speakingConsole = "Speaking console",
             signalDetails = "Signal details", accuracy = "Accuracy check", fineTune = "Fine-tune"
        var id: String { rawValue }
        var detail: String {
            switch self {
            case .trainingConsole: "Every practice option: blocks, quizzes, sentence practice, focus words, live scores."
            case .speakingConsole: "Every speaking option: phrases, prediction, acceptance limits, active words."
            case .signalDetails: "Live motion graphs, sample rate and gaps."
            case .accuracy: "Measure how well LouVoice knows each word."
            case .fineTune: "Tune the recogniser's settings on recorded practice."
            }
        }
    }

    let hub = MotionHub()
    let cues = CueService()
    let stem = StemPress()
    let voice = VoiceService()
    @ObservationIgnored private(set) lazy var enrollment = Enrollment(model: self)
    @ObservationIgnored private(set) lazy var decoder = Decoder(model: self)

    var screen: Screen = .train
    /// Open Settings sub-page (nil = the simple Settings list).
    var advancedPage: AdvancedPage?
    /// Dev mode: the original sidebar UI (five screens, system styling). Toggled by clicking the
    /// LouVoice logo; "Simple UI" in its sidebar comes back. Remembered between launches.
    var devMode = UserDefaults.standard.bool(forKey: "devMode") {
        didSet { UserDefaults.standard.set(devMode, forKey: "devMode") }
    }
    var devScreen: DevScreen = .enroll

    /// First-run walkthrough of the simple UI. Shown once; Help in the header shows it again.
    /// Never shown for --smoke / --snapshot runs.
    var showOnboarding = !UserDefaults.standard.bool(forKey: "onboardingDone")
        && !CommandLine.arguments.contains("--smoke") && !CommandLine.arguments.contains("--snapshot")

    func finishOnboarding() {
        showOnboarding = false
        UserDefaults.standard.set(true, forKey: "onboardingDone")
        screen = .train
    }

    enum DevScreen: String, CaseIterable, Identifiable {
        case sensors = "Sensors", enroll = "Enroll", evaluate = "Evaluate", tune = "Tune", decode = "Decode"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .sensors: "waveform.path.ecg"
            case .enroll: "list.bullet.clipboard"
            case .evaluate: "checkmark.seal"
            case .tune: "slider.horizontal.3"
            case .decode: "text.bubble"
            }
        }
    }
    private(set) var dataset: Dataset
    private(set) var classifier: Classifier?
    /// Single-word CNN (D53), shipped as Resources/Models/word_cnn.json. nil = file missing or
    /// unreadable; word mode then uses the DTW classifier as before.
    /// The shipped weights; `wordCNN` is what decoding uses (with this Mac's calibration, D55).
    let wordCNNBase: CNNWordModel? = AppModel.loadWordCNN()
    private(set) var wordCNN: CNNWordModel?
    /// When the saved calibration was made; nil = not calibrated.
    private(set) var calibratedAt: Date?
    private(set) var isCalibrating = false
    private(set) var calibrationStatus = ""
    /// Developer switch (Decode console): use the CNN for single words when it knows every allowed word.
    var useWordCNN = true
    /// Recorded whole sentences (scaled features by phrase) for the demo's second vote (D46).
    private(set) var sentenceReferences: [String: [FeatureSequence]] = [:]
    private(set) var isTraining = false
    private(set) var evaluation: EvaluationReport?
    private(set) var quizScore: (correct: Int, total: Int, perLabel: [String: (Int, Int)])?
    private(set) var isEvaluating = false
    private(set) var evaluationProgress = 0.0

    /// Pipeline variables (Tune screen). Changing them re-extracts features and retrains.
    private(set) var config: PipelineConfig
    var capture: CaptureSettings { didSet { Self.store(capture, key: Self.captureKey) } }

    // Auto-tune state.
    private(set) var tuneTrials: [Tuner.Trial] = []
    private(set) var isTuning = false
    private(set) var tuneProgress = 0.0
    private(set) var tuneStatus = ""

    @ObservationIgnored private var featureCache: [UUID: SegmentFeatures] = [:]
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    static let configKey = "pipelineConfig.v1", captureKey = "captureSettings.v1"

    init() {
        // --smoke (and LOUVOICE_SOURCE=simulator) start on the simulator without touching CoreMotion.
        let simulated = CommandLine.arguments.contains("--smoke")
            || ProcessInfo.processInfo.environment["LOUVOICE_SOURCE"] == "simulator"
        if simulated { hub.source = .simulator }
        // LOUVOICE_SCREEN=signals|train|speak|settings opens that screen (screenshots, demos).
        if let raw = ProcessInfo.processInfo.environment["LOUVOICE_SCREEN"],
           let s = Screen.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() }) { screen = s }
        dataset = DatasetStore.load(simulated: simulated)
        let isolated = ProcessInfo.processInfo.environment["LOUVOICE_DATA_DIR"] != nil
        config = isolated ? .defaults : (Self.load(PipelineConfig.self, key: Self.configKey) ?? .defaults)
        capture = isolated ? CaptureSettings() : (Self.load(CaptureSettings.self, key: Self.captureKey) ?? CaptureSettings())
        wordCNN = wordCNNBase
        loadCalibration()
    }

    func start() {
        guard !started else { return }
        started = true
        hub.onSample = { [weak self] s in self?.decoder.ingest(s) }
        stem.onPress = { [weak self] in self?.stemPressed() }
        // The stem is on unless the user turned it off. Not in isolated runs (smoke test, snapshots),
        // which shouldn't take over the Mac's "now playing" media controls.
        if StemPress.wanted, ProcessInfo.processInfo.environment["LOUVOICE_DATA_DIR"] == nil { stem.enable() }
        if CommandLine.arguments.contains("--smoke") { SmokeTest(model: self).run() }
        // --voice-check: the real ElevenLabs path (Keychain key, saved voice ID, live fetch, playback),
        // printed to stdout, then quit. Never prints the key.
        if CommandLine.arguments.contains("--voice-check") {
            Task { @MainActor in
                let v = self.voice
                setvbuf(stdout, nil, _IOLBF, 0); print("voice-check: key saved: \(v.hasKey), voice ID saved: \(!v.voiceID.isEmpty) (\(v.voiceID.count) chars), my voice on: \(v.settings.enabled), speak aloud: \(self.decoder.speakResult)")
                await v.testConnection()
                print("voice-check: \(v.status)" + (v.lastError.map { " — \($0)" } ?? ""))
                try? await Task.sleep(for: .seconds(2)) // let "hello" finish playing
                exit(v.lastError == nil && v.status.hasPrefix("ElevenLabs works") ? 0 : 1)
            }
        }
        if let dir = Snapshot.directory { Snapshot.run(model: self, to: dir) }
        hub.start()
        installKeyMonitor()
        rebuildClassifier()
        voice.refreshCache(words: words)
        if voice.isConfigured { Task { await voice.prepare(words: voiceVocabulary) } }
    }

    var isSimulated: Bool { hub.isSimulated }

    func setSource(_ source: MotionHub.Source) {
        guard source != hub.source else { return }
        enrollment.stop()
        hub.source = source
        dataset = DatasetStore.load(simulated: source == .simulator)
        featureCache.removeAll()
        clearResults()
        rebuildClassifier()
    }

    // MARK: Config

    func setConfig(_ new: PipelineConfig) {
        guard new != config else { return }
        if new.features != config.features { featureCache.removeAll() }
        config = new
        Self.store(config, key: Self.configKey)
        clearResults()
        rebuildClassifier()
    }

    func updateConfig(_ change: (inout PipelineConfig) -> Void) {
        var c = config
        change(&c)
        setConfig(c)
    }

    private func clearResults() {
        evaluation = nil
        quizScore = nil
    }

    // MARK: Dataset

    var words: [String] { dataset.vocabulary }
    /// Everything worth caching in the user's voice: every word plus every expected phrase as one
    /// clip, so a decoded sentence plays as a whole sentence instantly (D56).
    var voiceVocabulary: [String] { words + Self.speakPhrases(config.context.phrases) }

    /// The phrases Speak's sentence mode can say. Both demo sentences are always included (D56),
    /// whatever the phrase list has been edited to in dev mode.
    static func speakPhrases(_ configured: [String]) -> [String] {
        var out: [String] = []
        for p in ContextModel().phrases + configured {
            let t = p.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !t.isEmpty, !out.contains(t) { out.append(t) }
        }
        return out
    }

    func features(for take: Take) -> SegmentFeatures? {
        if let f = featureCache[take.id] { return f }
        let f = Features.extract(take.samples, config: config.features)
        featureCache[take.id] = f
        return f
    }

    func addTake(_ take: Take, features: SegmentFeatures) {
        dataset.takes.append(take)
        featureCache[take.id] = features
        persist(retrain: !take.isTest && !take.isSentence)
    }

    func deleteTakes(where predicate: (Take) -> Bool) {
        dataset.takes.removeAll(where: predicate)
        persist()
    }

    /// Quiz takes become training data (more data is the biggest lever with ~9 takes per word).
    func promoteQuizTakes() {
        for i in dataset.takes.indices where dataset.takes[i].isTest { dataset.takes[i].isTest = false }
        persist()
    }

    func setNoiseFloor(_ value: Double?) {
        dataset.noiseFloor = value
        DatasetStore.save(dataset, simulated: isSimulated)
    }

    func addWord(_ raw: String) {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty, word != noneLabel, !dataset.vocabulary.contains(word) else { return }
        dataset.vocabulary.append(word)
        DatasetStore.save(dataset, simulated: isSimulated)
        // New words get their voice audio generated right away (PRD: cache at enrollment).
        if voice.isConfigured { Task { await voice.prepare(words: voiceVocabulary) } }
    }

    func removeWord(_ word: String) {
        dataset.vocabulary.removeAll { $0 == word }
        DatasetStore.save(dataset, simulated: isSimulated)
    }

    func takeCount(_ label: String) -> Int { dataset.trainingTakes.filter { $0.label == label }.count }
    var blocks: [String] { Array(Set(dataset.takes.map(\.block))).sorted() }

    private func persist(retrain: Bool = true) {
        DatasetStore.save(dataset, simulated: isSimulated)
        clearResults()
        if retrain { rebuildClassifier() }
    }

    // MARK: Training / evaluation

    /// Everything needed to build training features off the main thread: raw takes, the cached
    /// features of real takes, and the config. Noisy copies (D42) are made in `buildTraining`.
    func trainingInputs(excludingBlock block: String? = nil) -> (takes: [Tuner.RawTake], cached: [String: FeatureSequence], config: PipelineConfig) {
        let takes = dataset.trainingTakes.filter { $0.block != block }
        var cached: [String: FeatureSequence] = [:]
        for t in takes { if let f = features(for: t) { cached[t.id.uuidString] = f.sequence } }
        return (takes.map(Tuner.RawTake.init), cached, config)
    }

    nonisolated static func buildTraining(_ input: (takes: [Tuner.RawTake], cached: [String: FeatureSequence], config: PipelineConfig)) -> [LabeledFeatures] {
        TrainingSet.build(input.takes, config: input.config) { input.cached[$0.id] }
    }

    func rebuildClassifier() {
        rebuildTask?.cancel()
        let input = trainingInputs()
        var sentences = dataset.sentenceTakes.map { (label: $0.label, samples: $0.samples) }
        // "Nothing said" references (D47): recorded movement + a sample of single words.
        let negatives = dataset.takes.filter { !$0.isTest && !$0.isSentence && !$0.block.hasPrefix("sentence-") }
        sentences += negatives.filter { $0.label == noneLabel }.map { (label: noneLabel, samples: $0.samples) }
        sentences += negatives.filter { $0.label != noneLabel }.shuffled().prefix(120).map { (label: noneLabel, samples: $0.samples) }
        isTraining = true
        rebuildTask = Task { [weak self] in
            let (built, refs) = await Task.detached(priority: .userInitiated) { () -> (Classifier?, [String: [FeatureSequence]]) in
                let clf = Classifier(training: AppModel.buildTraining(input), config: input.config.classifier)
                let refs = clf.flatMap { SentenceDecoder(classifier: $0, pipeline: input.config, config: input.config.sentence) }?
                    .sentenceReferences(sentences) ?? [:]
                return (clf, refs)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.classifier = built
            self.sentenceReferences = refs
            self.isTraining = false
        }
    }

    func runEvaluation() {
        guard !isEvaluating else { return }
        let takes = dataset.trainingTakes.compactMap { take in
            features(for: take).map { EvalTake(id: take.id.uuidString, label: take.label, block: take.block, features: $0.sequence) }
        }
        let training = dataset.trainingTakes.map(Tuner.RawTake.init)
        let tests = dataset.testTakes.map(Tuner.RawTake.init)
        let config = config
        isEvaluating = true
        evaluationProgress = 0
        let box = WeakModel(self)
        Task { [weak self] in
            let (report, quiz) = await Task.detached(priority: .userInitiated) {
                let r = Evaluation.run(takes, config: config.classifier, permutations: 200) { p in
                    Task { @MainActor in box.model?.evaluationProgress = p }
                }
                let q = tests.isEmpty ? nil : Tuner.heldOut(training: training, test: tests, config: config)
                return (r, q)
            }.value
            self?.evaluation = report
            self?.quizScore = quiz
            self?.isEvaluating = false
        }
    }

    // MARK: Auto-tune

    func runAutoTune() {
        guard !isTuning else { return }
        let takes = dataset.trainingTakes.map(Tuner.RawTake.init)
        let base = config
        isTuning = true
        tuneProgress = 0
        tuneStatus = "Starting…"
        let box = WeakModel(self)
        Task { [weak self] in
            let trials = await Task.detached(priority: .userInitiated) {
                Tuner.autoTune(takes, base: base) { p, status in
                    Task { @MainActor in box.model?.tuneProgress = p; box.model?.tuneStatus = status }
                }
            }.value
            self?.tuneTrials = trials
            self?.isTuning = false
            self?.tuneStatus = trials.isEmpty ? "Not enough data (need 2+ blocks)" : "Tried \(trials.count) settings"
        }
    }

    // MARK: Input

    /// Where Space / the stem press goes: speaking or practising, on the simple tab or its console.
    private enum KeyTarget { case speak, train, none }
    private var keyTarget: KeyTarget {
        if devMode {
            switch devScreen { case .decode: return .speak; case .enroll: return .train; default: return .none }
        }
        if isCalibrating { return .train }
        return switch (screen, advancedPage) {
        case (.speak, _), (.settings, .speakingConsole): .speak
        case (.train, _), (.settings, .trainingConsole): .train
        default: .none
        }
    }

    /// AirPods stem press: turns "Speak aloud" on or off, on any screen (D51), and says which.
    /// Starting a capture is Space or the on-screen button.
    private func stemPressed() {
        decoder.speakResult.toggle()
        cues.say(decoder.speakResult ? "Speaking on" : "Speaking off")
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if NSApp.keyWindow?.firstResponder is NSText { return event }
            let consumed: Bool = MainActor.assumeIsolated {
                switch (event.keyCode, self.keyTarget) {
                case (49, .speak): if !event.isARepeat { self.decoder.trigger() }; return true            // Space
                case (49, .train): self.enrollment.continueAfterBreak(); return true
                case (16, .speak): self.decoder.confirm(true); return true                                // Y
                case (45, .speak): self.decoder.confirm(false); return true                               // N
                default: return false
                }
            }
            return consumed ? nil : event
        }
    }

    // MARK: Word CNN calibration (D55)

    static let calibrationReps = 4
    private static var calibrationURL: URL { DatasetStore.directory.appending(path: "word_cnn_calibration.json") }

    /// Word mode on real AirPods with no calibration yet: Speak asks for one first.
    var needsCalibration: Bool {
        wordCNNBase != nil && calibratedAt == nil && !isSimulated && !decoder.sentenceMode && useWordCNN
    }

    // MARK: Sentence calibration (D57)

    /// Each Speak sentence recorded this many times in a sentence calibration.
    static let sentenceCalibrationReps = 3
    private static var sentenceCalibrationURL: URL { DatasetStore.directory.appending(path: "sentence_calibration.json") }
    /// When the sentences were last recorded in the current fit; nil = never.
    private(set) var sentenceCalibratedAt: Date? = AppModel.loadSentenceCalibrationDate()

    private static func loadSentenceCalibrationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: sentenceCalibrationURL.path))?[.modificationDate] as? Date
    }

    /// Sentence mode on real AirPods, never calibrated: Speak asks to record each sentence first.
    var needsSentenceCalibration: Bool {
        sentenceCalibratedAt == nil && !isSimulated && decoder.sentenceMode && classifier != nil
    }

    /// Records each Speak sentence `sentenceCalibrationReps` times (full length, shuffled). They become
    /// sentence references in today's fit (and are cut into word takes, as in sentence training).
    func startSentenceCalibration() {
        guard !isCalibrating, !enrollment.isRunning, classifier != nil else { return }
        let phrases = Self.speakPhrases(config.context.phrases)
        isCalibrating = true
        calibrationStatus = ""
        enrollment.startSentences(phrases: phrases, reps: Self.sentenceCalibrationReps * phrases.count, blocks: 1, balanced: true)
        Task { [weak self] in
            while self?.enrollment.isRunning == true { try? await Task.sleep(for: .milliseconds(200)) }
            guard let self else { return }
            if self.enrollment.phase == .finished {
                // Sentence takes don't retrain on their own; rebuild so the new references are used.
                self.rebuildClassifier()
                try? Data("{}".utf8).write(to: Self.sentenceCalibrationURL, options: .atomic)
                self.sentenceCalibratedAt = Date()
            }
            self.isCalibrating = false
        }
    }

    private func loadCalibration() {
        guard let base = wordCNNBase, let data = try? Data(contentsOf: Self.calibrationURL) else { return }
        do {
            wordCNN = try base.applying(calibration: data)
            calibratedAt = (try? FileManager.default.attributesOfItem(atPath: Self.calibrationURL.path))?[.modificationDate] as? Date
        } catch {
            print("calibration not loaded: \(error)")
        }
    }

    /// Records `calibrationReps` takes of each word-mode word (no quiz, no extras), adapts the CNN
    /// to them, and saves the result. The takes are kept as training data.
    func startCalibration() {
        guard let base = wordCNNBase, !isCalibrating, !enrollment.isRunning else { return }
        let words = decoder.wordModeWords.filter { base.labels.contains($0) }
        guard !words.isEmpty else { return }
        let started = Date()
        isCalibrating = true
        calibrationStatus = ""
        enrollment.start(words: words, reps: Self.calibrationReps, blocks: 1, noisePerBlock: 0, prefix: "calibrate", plain: true)
        Task { [weak self] in
            while self?.enrollment.isRunning == true { try? await Task.sleep(for: .milliseconds(200)) }
            guard let self else { return }
            guard self.enrollment.phase == .finished else {   // stopped part-way
                self.isCalibrating = false
                return
            }
            let features = base.featureConfig
            let calib = self.dataset.takes.filter { $0.block.hasPrefix("calibrate-") && $0.createdAt >= started }
                .compactMap { t in Features.extract(t.samples, config: features).map { ($0.sequence, t.label) } }
            // D63: never replay nod-confirmed takes (their label is the model's own guess; they cost the CNN ~10 points).
            let pool = self.dataset.trainingTakes.filter {
                base.labels.contains($0.label) && !$0.block.hasPrefix("calibrate-") && !$0.block.hasPrefix("confirmed-")
            }
            var rng = SystemRandomNumberGenerator()
            let replayTakes = Array(pool.shuffled(using: &rng).prefix(150))
            self.calibrationStatus = "Adjusting to your AirPods…"
            let adapted = await Task.detached(priority: .userInitiated) { () -> CNNWordModel in
                let replay = replayTakes.compactMap { t in Features.extract(t.samples, config: features).map { ($0.sequence, t.label) } }
                return base.calibrated(calibration: calib, replay: replay)
            }.value
            do {
                try adapted.calibrationData().write(to: Self.calibrationURL, options: .atomic)
            } catch {
                print("calibration not saved: \(error)")
            }
            self.wordCNN = adapted
            self.calibratedAt = Date()
            self.calibrationStatus = ""
            self.isCalibrating = false
        }
    }

    /// Back to the shipped model, and forget the sentence calibration; Speak asks again (word and sentence mode).
    func resetCalibration() {
        try? FileManager.default.removeItem(at: Self.calibrationURL)
        wordCNN = wordCNNBase
        calibratedAt = nil
        try? FileManager.default.removeItem(at: Self.sentenceCalibrationURL)
        sentenceCalibratedAt = nil
    }

    // MARK: Word CNN

    private static func loadWordCNN() -> CNNWordModel? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Models/word_cnn.json"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Models/word_cnn.json"),
        ].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        do { return try CNNWordModel(contentsOf: url) } catch {
            print("word CNN not loaded: \(error)")
            return nil
        }
    }

    // MARK: Persistence of settings

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func store<T: Encodable>(_ value: T, key: String) {
        guard ProcessInfo.processInfo.environment["LOUVOICE_DATA_DIR"] == nil,
              let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// Lets a background progress callback reach the main-actor model without capturing it.
private final class WeakModel: @unchecked Sendable {
    weak var model: AppModel?
    init(_ model: AppModel) { self.model = model }
}
