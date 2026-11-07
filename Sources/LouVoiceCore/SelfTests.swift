import Foundation

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
}
