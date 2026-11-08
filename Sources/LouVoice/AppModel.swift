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
    /// The three tabs the user sees, plus Settings (opened from the gear). TODO(team): "Speak" is the "use" tab.
    enum Screen: String, CaseIterable, Identifiable {
        case signals = "Signals", train = "Train", speak = "Speak", settings = "Settings"
        var id: String { rawValue }
        static let tabs: [Screen] = [.signals, .train, .speak]
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
    }

    func start() {
        guard !started else { return }
        started = true
        hub.onSample = { [weak self] s in self?.decoder.ingest(s) }
        stem.onPress = { [weak self] in self?.stemPressed() }
        if CommandLine.arguments.contains("--smoke") { SmokeTest(model: self).run() }
        if let dir = Snapshot.directory { Snapshot.run(model: self, to: dir) }
        hub.start()
        installKeyMonitor()
        rebuildClassifier()
        voice.refreshCache(words: words)
        if voice.isConfigured { Task { await voice.prepare(words: words) } }
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
        if voice.isConfigured { Task { await voice.prepare(words: words) } }
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
        return switch (screen, advancedPage) {
        case (.speak, _), (.settings, .speakingConsole): .speak
        case (.train, _), (.settings, .trainingConsole): .train
        default: .none
        }
    }

    private func stemPressed() {
        switch keyTarget {
        case .speak: decoder.trigger()
        case .train: enrollment.continueAfterBreak()
        case .none: break
        }
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
