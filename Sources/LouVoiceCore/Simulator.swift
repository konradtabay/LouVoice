import Foundation

/// Movements the simulator can perform.
public enum SimAction: Sendable, Hashable {
    case word(String)
    case noise(NoiseKind)
    case nod, shake
}

/// Prompted non-word movements for the `_none` class (D11).
public enum NoiseKind: String, CaseIterable, Sendable, Codable {
    case chew, swallow, turn, nod, smile, lookUp

    public var prompt: String {
        switch self {
        case .chew: "Chew (mouth closed)"
        case .swallow: "Swallow"
        case .turn: "Turn your head left and back"
        case .nod: "Nod once"
        case .smile: "Smile wide, then relax"
        case .lookUp: "Look up and back"
        }
    }
}

/// Synthetic AirPods motion (D17). Words get a deterministic signature from their syllables and
/// how open the vowels are; each take varies in tempo, amplitude and onset; re-seating rotates the
/// sensor. **Accuracy on simulated data proves nothing about real AirPods** — it exists to
/// exercise the pipeline and the UI without hardware.
public final class MotionSimulator: @unchecked Sendable {
    public let rate: Double
    public private(set) var time: Double = 0
    public var location: SensorLocation = .left
    /// Probability that a given sample is dropped (Bluetooth loss).
    public var dropProbability: Double = 0.01

    private var rng: SeededRNG
    private var head = Quat.identity
    private var seat: Quat
    private var events: [Event] = []
    private let lock = NSLock()

    /// Head-frame angular velocity (rad/s) and acceleration (g) as a function of time since start.
    private struct Event {
        var start: Double
        var duration: Double
        var motion: (Double) -> (omega: Vec3, accel: Vec3)
    }

    public init(seed: UInt64 = 42, rate: Double = 25) {
        self.rate = rate
        rng = SeededRNG(seed: seed)
        seat = Quat.identity
        reseat()
    }

    /// Take the earbuds out and put them back: a new random sensor orientation (±15°).
    public func reseat() {
        lock.lock(); defer { lock.unlock() }
        let angle = rng.uniform(-15, 15) * .pi / 180
        seat = Quat(rotationVector: rng.unitVector() * angle)
    }

    /// Start a movement now (plus a human-like onset delay for words).
    public func perform(_ action: SimAction) {
        lock.lock(); defer { lock.unlock() }
        events.append(contentsOf: Self.events(for: action, at: time, rng: &rng))
    }

    /// Advance one sample period. Returns nil when the sample is "dropped".
    public func step() -> MotionSample? {
        lock.lock(); defer { lock.unlock() }
        let dt = 1 / rate
        time += dt

        var omega = Vec3(rng.normal() * 0.012, rng.normal() * 0.012, rng.normal() * 0.012)
        var accel = Vec3(rng.normal() * 0.004, rng.normal() * 0.004, rng.normal() * 0.004)
        // Slow postural sway (removed by the high-pass).
        omega += Vec3(0.02 * sin(time * 0.7), 0.01 * sin(time * 0.4), 0.015 * sin(time * 0.3))
        events.removeAll { time > $0.start + $0.duration }
        for e in events where time >= e.start {
            let m = e.motion(time - e.start)
            omega += m.omega; accel += m.accel
        }

        head = (head * Quat(rotationVector: omega * dt)).normalized
        let device = (head * seat).normalized
        let toDevice = seat.conjugate
        let rv = head.rotationVector
        let sample = MotionSample(
            t: time + rng.normal() * 0.002,
            accel: toDevice.rotate(accel),
            rotation: toDevice.rotate(omega),
            gravity: device.conjugate.rotate(Vec3(0, 0, -1)),
            attitude: device,
            pitch: rv.x, roll: rv.y, yaw: rv.z,
            location: location)
        return rng.uniform(0, 1) < dropProbability ? nil : sample
    }

    /// Record a whole capture window the way the app does: rest pre-roll, then the movement.
    public func recordTake(_ action: SimAction?, preroll: Double = 0.3, window: Double = 1.8) -> [MotionSample] {
        var out: [MotionSample] = []
        for _ in 0..<Int(preroll * rate) { if let s = step() { out.append(s) } }
        if let action { perform(action) }
        for _ in 0..<Int(window * rate) { if let s = step() { out.append(s) } }
        return out
    }

    // MARK: Movement models

    private static func events(for action: SimAction, at now: Double, rng: inout SeededRNG) -> [Event] {
        switch action {
        case .word(let word): return wordEvents(word, at: now, rng: &rng)
        case .nod: return [oscillation(axis: Vec3(1, 0, 0), degrees: 14, cycles: 1, duration: 0.8, at: now)]
        case .shake: return [oscillation(axis: Vec3(0, 0, 1), degrees: 18, cycles: 1, duration: 0.9, at: now)]
        case .noise(let kind):
            let onset = now + rng.uniform(0.15, 0.35)
            switch kind {
            case .chew:
                return (0..<4).map { i in bump(axis: Vec3(0.4, 0.2, 0.9).unit, peak: 0.35, accel: Vec3(0, 0.01, 0.02),
                                              duration: 0.32, at: onset + Double(i) * 0.38) }
            case .swallow:
                return [bump(axis: Vec3(1, 0, 0), peak: 0.25, accel: Vec3(0, 0.02, -0.01), duration: 0.7, at: onset)]
            case .turn:
                return [oscillation(axis: Vec3(0, 0, 1), degrees: 30, cycles: 0.5, duration: 1.2, at: onset)]
            case .nod:
                return [oscillation(axis: Vec3(1, 0, 0), degrees: 14, cycles: 1, duration: 0.8, at: onset)]
            case .smile:
                return [bump(axis: Vec3(0, 1, 0.3).unit, peak: 0.12, accel: Vec3(0.015, 0, 0.01), duration: 0.9, at: onset)]
            case .lookUp:
                return [oscillation(axis: Vec3(-1, 0, 0), degrees: 20, cycles: 0.5, duration: 1.1, at: onset)]
            }
        }
    }

    /// Syllables from vowel groups; bump size from how open the vowel is.
    static func syllables(_ word: String) -> [Double] {
        let openness: [Character: Double] = ["a": 1.0, "o": 0.85, "e": 0.6, "u": 0.5, "i": 0.45, "y": 0.45]
        var result: [Double] = []
        var inVowel = false
        for ch in word.lowercased() {
            if let o = openness[ch] {
                if inVowel { result[result.count - 1] = max(result[result.count - 1], o) } else { result.append(o) }
                inVowel = true
            } else {
                inVowel = false
            }
        }
        // Silent final "e" ("stope" style) — drop it when there's another syllable.
        if result.count > 1, word.lowercased().hasSuffix("e"), !word.lowercased().hasSuffix("ee") { result.removeLast() }
        return result.isEmpty ? [0.5] : result
    }

    private static func wordEvents(_ word: String, at now: Double, rng: inout SeededRNG) -> [Event] {
        var sig = SeededRNG(seed: stableHash(word))
        // Per-word articulation: mostly a pitch-axis jaw rotation, with a word-specific mix.
        let axis = Vec3(1, sig.uniform(-0.35, 0.35), sig.uniform(-0.25, 0.25)).unit
        let syllableBase = sig.uniform(0.2, 0.28)
        let tempo = rng.uniform(0.87, 1.13), gain = rng.uniform(0.85, 1.15)
        var t = now + rng.uniform(0.15, 0.4)
        var out: [Event] = []
        for openness in syllables(word) {
            let d = syllableBase * (0.75 + 0.5 * openness) * tempo
            let size: Double = openness * gain
            out.append(bump(axis: axis, peak: 0.32 * size, accel: Vec3(0, 0.012, 0.018) * size,
                            duration: d, at: t))
            t += d + 0.04 * tempo
        }
        return out
    }

    /// Open-then-close movement: angular velocity is the derivative of a raised cosine.
    private static func bump(axis: Vec3, peak: Double, accel: Vec3, duration: Double, at start: Double) -> Event {
        Event(start: start, duration: duration) { tau in
            let phase = 2 * Double.pi * tau / duration
            let v = sin(phase)
            return (axis * (peak * v), accel * cos(phase))
        }
    }

    /// Head rotation of `degrees` peak that goes out and comes back over `cycles`.
    private static func oscillation(axis: Vec3, degrees: Double, cycles: Double, duration: Double, at start: Double) -> Event {
        let amplitude = degrees * .pi / 180
        return Event(start: start, duration: duration) { tau in
            // angle(t) = A·sin²(π·c·t/D) for half-cycles, A·sin(2π·c·t/D) for full cycles.
            let w = 2 * Double.pi * cycles / duration
            let rate = cycles == 0.5 ? amplitude * (Double.pi / duration) * sin(2 * Double.pi * tau / duration)
                                     : amplitude * w * cos(w * tau)
            return (axis * rate, .zero)
        }
    }
}
