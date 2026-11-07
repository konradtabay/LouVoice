import Foundation

/// One recorded capture window with its prompted (or confirmed) label.
public struct Take: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var label: String
    /// Enrollment block: one pass between re-seats. Held out as a unit in evaluation (D12).
    public var block: String
    public var session: String
    public var createdAt = Date()
    public var samples: [MotionSample]
    /// Quiz take: held out from training and used only to measure accuracy (D31).
    public var isTest = false

    public init(label: String, block: String, session: String, samples: [MotionSample], isTest: Bool = false) {
        self.label = label; self.block = block; self.session = session; self.samples = samples; self.isTest = isTest
    }

    enum CodingKeys: String, CodingKey { case id, label, block, session, createdAt, samples, isTest }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        block = try c.decode(String.self, forKey: .block)
        session = try c.decode(String.self, forKey: .session)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        samples = try c.decode([MotionSample].self, forKey: .samples)
        isTest = try c.decodeIfPresent(Bool.self, forKey: .isTest) ?? false
    }

    public static func == (a: Take, b: Take) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

public struct Dataset: Codable, Sendable {
    public var version = 1
    public var vocabulary: [String]
    public var takes: [Take]
    /// Median rest energy from the last calibration (quality gate, D14).
    public var noiseFloor: Double?

    public init(vocabulary: [String], takes: [Take], noiseFloor: Double?) {
        self.vocabulary = vocabulary; self.takes = takes; self.noiseFloor = noiseFloor
    }

    public static let defaultVocabulary = ["hello", "can", "you", "hear", "me"]
    public static let empty = Dataset(vocabulary: defaultVocabulary, takes: [], noiseFloor: nil)

    public var trainingTakes: [Take] { takes.filter { !$0.isTest } }
    public var testTakes: [Take] { takes.filter(\.isTest) }
}

/// Everything that changes what the recognizer sees or how it decides (D29).
public struct PipelineConfig: Codable, Hashable, Sendable {
    public var features = FeatureConfig()
    public var classifier = ClassifierConfig()
    public var quality = QualityConfig()
    public init() {}

    enum CodingKeys: String, CodingKey { case features, classifier, quality }
    // Tolerant decoding so saved settings survive new fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        features = (try? c.decode(FeatureConfig.self, forKey: .features)) ?? FeatureConfig()
        classifier = (try? c.decode(ClassifierConfig.self, forKey: .classifier)) ?? ClassifierConfig()
        quality = (try? c.decode(QualityConfig.self, forKey: .quality)) ?? QualityConfig()
    }
    public static let defaults = PipelineConfig()

    /// Short human-readable summary.
    public var summary: String {
        let f = features, c = classifier
        var extras = ""
        if f.normalization != .none { extras += " · norm " + f.normalization.label }
        if f.derivatives { extras += " · +Δ" }
        if f.magnitudes { extras += " · +|v|" }
        return String(format: "%.0f Hz · HP %@ · %@%@ · trim %@ · k=%d · aug ×%d (±%.0f°) · band %.0f%%",
                      f.rate, f.highPassHz > 0 ? String(format: "%.1f Hz", f.highPassHz) : "off",
                      f.channels.label, extras, f.trim ? String(format: "%.0f%%", f.trimThreshold * 100) : "off",
                      c.k, c.augmentCopies, c.augment.maxRotationDegrees, c.band * 100)
    }
}
