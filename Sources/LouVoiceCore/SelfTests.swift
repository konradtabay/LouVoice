import Foundation
import CryptoKit

/// M1 acceptance checks. Defined in the library so they run both under `swift test` and under
/// `swift run LouVoiceCheck` (Command Line Tools have no XCTest).
public enum SelfTests {
    public struct Failure: Error, CustomStringConvertible { public let description: String }

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(description: message()) }
    }

    public static let all: [(name: String, run: () throws -> Void)] = [
        ("resampling makes a uniform grid and reports gaps", resampling),
        ("high-pass removes DC and drift, keeps jaw-band motion", highPass),
        ("re-seat rotation is undone by gravity canonicalisation", reseatCanonicalisation),
        ("DTW: identical is 0 and tolerates time-warp", dtw),
        ("classifier separates simulated words", classifier),
        ("evaluation: p < 0.01 with signal, p > 0.05 on noise", evaluation),
        ("nod and shake are detected, mouthing is not", gestures),
        ("quality gate rejects head movement and weak takes", quality),
        ("dataset samples round-trip through JSON", codable),
        ("voice cache: same text → same path, other voice/text → other path", voiceCachePaths),
        ("voice cache: ElevenLabs request has the right URL, headers and body", voiceCacheRequest),
        ("word CNN: a calibration only applies to the weights it was made for", cnnCalibrationIdentity),
    ]

    static func resampling() throws {
        var raw: [MotionSample] = []
        var t = 0.0
        for i in 0..<60 {
            if i == 30 { t += 0.2 }                      // a dropout
            raw.append(MotionSample(t: t, accel: Vec3(t, 0, 0)))
            t += 0.04 + (i % 3 == 0 ? 0.004 : -0.002)    // jitter
        }
        let r = Signal.resample(raw, rate: 25)
        for i in 1..<r.samples.count {
            try expect(abs(r.samples[i].t - r.samples[i - 1].t - 0.04) < 1e-9, "grid not uniform at \(i)")
        }
        try expect(r.maxGap > 0.2, "gap not reported: \(r.maxGap)")
        // Linear signal survives interpolation exactly.
        for s in r.samples { try expect(abs(s.accel.x - s.t) < 1e-9, "interpolation wrong at t=\(s.t)") }
    }

    static func highPass() throws {
        let rate = 25.0
        let n = 75
        let drift = (0..<n).map { 0.5 + 0.02 * Double($0) }                         // DC + slow ramp
        let jaw = (0..<n).map { 0.1 * sin(2 * .pi * 4 * Double($0) / rate) }        // 4 Hz
        let out = Signal.highPass(zip(drift, jaw).map(+), cutoff: 0.8, rate: rate)
        let mid = 15..<(n - 15)
        let residual = mid.map { abs(out[$0] - jaw[$0]) }.max()!
        try expect(residual < 0.03, "high-pass residual too large: \(residual)")
        let flat = Signal.highPass([Double](repeating: 3, count: 50), cutoff: 0.8, rate: rate)
        try expect(flat.allSatisfy { abs($0) < 1e-9 }, "DC not removed")
    }

    static func reseatCanonicalisation() throws {
        // The same take, seen through a sensor re-seated by 12° about an axis perpendicular to
        // gravity, must give (nearly) the same features.
        let sim = MotionSimulator(seed: 5); sim.dropProbability = 0
        let original = sim.recordTake(.word("banana"))
        let seat = Quat(rotationVector: Vec3(0, 1, 0) * (12 * Double.pi / 180))
        let reseated = original.map { s -> MotionSample in
            var r = s
            r.accel = seat.conjugate.rotate(s.accel)
            r.rotation = seat.conjugate.rotate(s.rotation)
            r.gravity = seat.conjugate.rotate(s.gravity)
            r.attitude = (s.attitude * seat).normalized
            return r
        }
        var cfg = FeatureConfig(); cfg.trim = false
        let fa = Features.extract(original, config: cfg)!.sequence
        let fb = Features.extract(reseated, config: cfg)!.sequence

        func rms(_ x: [Double]) -> Double { (x.map { $0 * $0 }.reduce(0, +) / Double(max(x.count, 1))).squareRoot() }
        let signal = rms(fa.values)
        let canonicalDiff = rms(zip(fa.values, fb.values).map(-))
        // Baseline: what the difference would be without canonicalisation (raw device-frame rotation rate).
        let rawDiff = rms(zip(original, reseated).flatMap { a, b in
            [a.rotation.x - b.rotation.x, a.rotation.y - b.rotation.y, a.rotation.z - b.rotation.z] })
        let rawSignal = rms(original.flatMap { [$0.rotation.x, $0.rotation.y, $0.rotation.z] })
        try expect(rawDiff > 0.1 * rawSignal, "test setup: the seat should change raw data (\(rawDiff))")
        // Gravity can't see a twist about itself, so allow a small residual (augmentation covers it).
        try expect(canonicalDiff < 0.1 * signal, "canonical features still differ: \(canonicalDiff) vs signal \(signal)")
    }

    static func dtw() throws {
        func seq(_ n: Int, freq: Double, phase: Double = 0) -> FeatureSequence {
            FeatureSequence(frames: (0..<n).map { i in
                let x = sin(2 * .pi * freq * Double(i) / Double(n) + phase)
                return [x, 0.5 * x, 0, 0, 0, 0, 0, 0, 0]
            })
        }
        let a = seq(40, freq: 2), stretched = seq(52, freq: 2), other = seq(40, freq: 3, phase: 1)
        try expect(DTW.distance(a, a) == 0, "identical not 0")
        try expect(DTW.distance(a, stretched) < DTW.distance(a, other) * 0.5, "not warp tolerant")
        let exact = DTW.distance(a, other)
        try expect(DTW.distance(a, other, cutoff: exact * 0.1) == .infinity, "early abandon didn't trigger")
        try expect(abs(DTW.distance(a, other, cutoff: exact * 2) - exact) < 1e-12, "early abandon changed result")
    }

    public static func simulatedTakes(words: [String], reps: Int, blocks: Int, noise: Bool, seed: UInt64) -> [EvalTake] {
        let sim = MotionSimulator(seed: seed)
        var takes: [EvalTake] = []
        var rng = SeededRNG(seed: seed)
        for b in 0..<blocks {
            sim.reseat()
            var prompts: [SimAction] = words.flatMap { w in Array(repeating: SimAction.word(w), count: reps) }
            if noise { prompts += NoiseKind.allCases.prefix(4).map { SimAction.noise($0) } }
            for action in prompts.shuffled(using: &rng) {
                let samples = sim.recordTake(action)
                guard let f = Features.extract(samples) else { continue }
                let label: String
                switch action { case .word(let w): label = w; default: label = noneLabel }
                takes.append(EvalTake(id: "s\(seed)-b\(b)-\(takes.count)", label: label, block: "b\(b)", features: f.sequence))
            }
        }
        return takes
    }

    static func classifier() throws {
        let words = ["yes", "banana", "hello", "stop"]
        let train = simulatedTakes(words: words, reps: 4, blocks: 2, noise: true, seed: 11)
        guard let c = Classifier(training: train.map { LabeledFeatures(id: $0.id, label: $0.label, features: $0.features) }) else {
            throw Failure(description: "classifier not built")
        }
        let test = simulatedTakes(words: words, reps: 2, blocks: 1, noise: false, seed: 99)
        let correct = test.filter { c.predict($0.features).best?.label == $0.label }.count
        try expect(Double(correct) / Double(test.count) >= 0.75, "only \(correct)/\(test.count) correct")
        // Active-word filter never returns an inactive word.
        let p = c.predict(test[0].features, active: ["yes", "stop"])
        try expect(p.ranked.allSatisfy { ["yes", "stop", noneLabel].contains($0.label) }, "active filter leaked")
    }

    static func evaluation() throws {
        let real = simulatedTakes(words: ["yes", "banana", "hello"], reps: 3, blocks: 3, noise: false, seed: 3)
        guard let signal = Evaluation.run(real, permutations: 100) else { throw Failure(description: "no report") }
        try expect(signal.mode == .leaveBlockOut, "should hold out blocks")
        try expect(signal.pValue < 0.01, "signal p = \(signal.pValue), acc \(signal.accuracy)")

        // Same takes, labels assigned at random: there is nothing to learn.
        var rng = SeededRNG(seed: 4)
        let labels = ["a", "b", "c"]
        let null = real.map { t -> EvalTake in var t = t; t.label = labels.randomElement(using: &rng)!; return t }
        guard let noise = Evaluation.run(null, permutations: 100) else { throw Failure(description: "no null report") }
        try expect(noise.pValue > 0.05, "noise p = \(noise.pValue)")
    }

    static func gestures() throws {
        func detect(_ action: SimAction) -> HeadGesture? {
            let sim = MotionSimulator(seed: 8); sim.dropProbability = 0
            var detector = HeadGestureDetector()
            var found: HeadGesture?
            for s in sim.recordTake(action, window: 2.0) { if let g = detector.push(s) { found = found ?? g } }
            return found
        }
        try expect(detect(.nod) == .nod, "nod not detected (got \(String(describing: detect(.nod))))")
        try expect(detect(.shake) == .shake, "shake not detected (got \(String(describing: detect(.shake))))")
        try expect(detect(.word("banana")) == nil, "mouthing detected as a gesture")
    }

    static func quality() throws {
        let sim = MotionSimulator(seed: 2); sim.dropProbability = 0
        for word in ["banana", "yes", "me"] {
            let take = Features.extract(sim.recordTake(.word(word)))!
            try expect(Quality.check(take, isNone: false) == nil,
                       "good take '\(word)' rejected: \(Quality.check(take, isNone: false) ?? "")")
        }
        let turn = Features.extract(sim.recordTake(.noise(.turn)))!
        try expect(Quality.check(turn, isNone: false) != nil, "head turn accepted as a word take")
        try expect(Quality.check(turn, isNone: true) == nil, "head turn rejected as a noise take")
        for _ in 0..<5 {
            let still = Features.extract(sim.recordTake(nil))!
            try expect(Quality.check(still, isNone: false) != nil,
                       String(format: "still take accepted (strength %.1f)", Quality.strength(still)))
        }
    }

    static func codable() throws {
        let s = MotionSample(t: 1.5, accel: Vec3(1, 2, 3), rotation: Vec3(4, 5, 6), gravity: Vec3(0, 0, -1),
                             attitude: Quat(1, 0, 0, 0), pitch: 0.1, roll: 0.2, yaw: 0.3, location: .right)
        let back = try JSONDecoder().decode(MotionSample.self, from: JSONEncoder().encode(s))
        try expect(back == s, "round trip changed the sample")
    }

    static func voiceCachePaths() throws {
        let root = URL(fileURLWithPath: "/tmp/lv-voicecache-check", isDirectory: true)
        func path(_ text: String, _ voice: String, _ model: String = VoiceCache.defaultModelID) -> URL? {
            VoiceCache.cacheURL(text: text, voiceID: voice, modelID: model, root: root)
        }
        let a = path("hello", "voiceA")
        try expect(a != nil, "no path for a valid voice ID")
        try expect(a == path("hello", "voiceA"), "same text and voice gave different paths")
        try expect(a != path("hello", "voiceB"), "different voices share a path")
        try expect(a?.deletingLastPathComponent().lastPathComponent == "voiceA", "voice folder missing from path")
        try expect(a != path("help", "voiceA"), "different texts share a path")
        try expect(a == path("Hello", "voiceA"), "case changed the path (cache is case-insensitive)")
        try expect(a != path("hello", "voiceA", "eleven_multilingual_v2"), "different models share a path")
        let expected = SHA256.hash(data: Data("helloeleven_flash_v2_5".utf8)).map { String(format: "%02x", $0) }.joined()
        try expect(a?.lastPathComponent == expected + ".mp3", "file name is not sha256(lowercased text + modelId).mp3")
        try expect(VoiceCache.defaultRoot.path.hasSuffix("Library/Application Support/LouVoice/VoiceCache"),
                   "default root is \(VoiceCache.defaultRoot.path)")
        try expect(path("x", "../../etc")?.path.hasPrefix(root.path + "/") == true, "voice ID escaped the cache root")
        try expect(path("x", "../") == nil, "empty-after-sanitising voice ID accepted")
    }

    static func voiceCacheRequest() throws {
        let key = "test-key-not-real"
        guard let r = VoiceCache.request(text: "hello can you hear me", voiceID: "abc123", apiKey: key) else {
            throw Failure(description: "no request built")
        }
        try expect(r.httpMethod == "POST", "method is \(r.httpMethod ?? "nil")")
        try expect(r.url?.absoluteString == "https://api.elevenlabs.io/v1/text-to-speech/abc123?output_format=mp3_44100_128",
                   "URL is \(r.url?.absoluteString ?? "nil")")
        try expect(r.value(forHTTPHeaderField: "xi-api-key") == key, "xi-api-key header missing or wrong")
        try expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json", "Content-Type wrong")
        try expect(r.value(forHTTPHeaderField: "Accept") == "audio/mpeg", "Accept wrong")
        let body = try r.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] }
        try expect(body == ["text": "hello can you hear me", "model_id": "eleven_flash_v2_5"], "body is \(body ?? [:])")
        try expect(VoiceCache.request(text: "hi", voiceID: "", apiKey: key) == nil, "request built without a voice ID")
        // D60: a slower sentence sends voice_settings.speed and is cached separately.
        guard let slow = VoiceCache.request(text: "hello can you hear me", voiceID: "abc123", apiKey: key, speed: 0.85),
              let slowBody = try slow.httpBody.flatMap({ try JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else {
            throw Failure(description: "no slow request built")
        }
        try expect((slowBody["voice_settings"] as? [String: Double])?["speed"] == 0.85, "speed is \(slowBody["voice_settings"] ?? "missing")")
        try expect(VoiceCache.cacheKey(text: "hello can you hear me", speed: 0.85) != VoiceCache.cacheKey(text: "hello can you hear me"),
                   "slow and normal clips share a cache key")
        try expect(VoiceCache.cacheKey(text: "hello", speed: 1) == VoiceCache.cacheKey(text: "hello"), "speed 1 changed the cache key")
    }

    /// Runs everything, printing one line per check. Returns the failure count.
    @discardableResult
    public static func runAll(log: (String) -> Void = { print($0) }) -> Int {
        var failures = 0
        for test in all {
            let start = Date()
            do {
                try test.run()
                log(String(format: "PASS  %@  (%.2fs)", test.name, Date().timeIntervalSince(start)))
            } catch {
                failures += 1
                log("FAIL  \(test.name): \(error)")
            }
        }
        log(failures == 0 ? "All \(all.count) checks passed." : "\(failures) of \(all.count) checks failed.")
        return failures
    }

    /// Tiny 4-layer weights file (width 2, 2 input channels, 6 labels) in the training script's format.
    static func tinyCNN(id: String?, channels: [String]? = nil) throws -> CNNWordModel {
        func t(_ n: Int, _ v: Double = 0.1) -> [Double] { [Double](repeating: v, count: n) }
        var state: [String: Any] = [:]
        let ks = [5, 5, 5, 3]
        for (i, k) in ks.enumerated() {
            state["convs.\(i).weight"] = t(2 * 2 * k); state["convs.\(i).bias"] = t(2)
            state["norms.\(i).weight"] = t(2, 1); state["norms.\(i).bias"] = t(2, 0)
            state["norms.\(i).running_mean"] = t(2, 0); state["norms.\(i).running_var"] = t(2, 1)
        }
        state["head.weight"] = t(6 * 5); state["head.bias"] = t(6, 0)
        var root: [String: Any] = ["labels": ["hello", "can", "you", "hear", "me", "_none"], "T": 8,
                                   "members": [["scale": [1.0, 1.0], "state": state]]]
        if let id { root["id"] = id }
        if let channels { root["channels"] = channels }
        return try CNNWordModel(data: JSONSerialization.data(withJSONObject: root))
    }

    static func cnnCalibrationIdentity() throws {
        let old = try tinyCNN(id: nil), new = try tinyCNN(id: "d62-a", channels: ["acceleration", "rotation", "attitude"])
        try expect(old.channels == PipelineConfig.defaults.features.channels, "file without channels should use the defaults")
        try expect(new.featureConfig.channels == [.acceleration, .rotation, .attitude], "channels not read from the file")
        try expect((try? old.applying(calibration: old.calibrationData())) != nil, "pre-D62 calibration no longer loads")
        try expect((try? new.applying(calibration: new.calibrationData())) != nil, "own calibration rejected")
        try expect((try? new.applying(calibration: old.calibrationData())) == nil, "old model's calibration applied to new weights")
        try expect((try? old.applying(calibration: new.calibrationData())) == nil, "new model's calibration applied to old weights")
        try expect((try? try tinyCNN(id: "d62-b").applying(calibration: new.calibrationData())) == nil, "calibration applied across model ids")
    }
}
