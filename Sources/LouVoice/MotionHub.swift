import CoreMotion
import Foundation
import LouVoiceCore
import Observation

/// Single source of motion samples for the app: real AirPods (CoreMotion) or the simulator.
/// Keeps a short history for plots and pre-roll, and serves timed capture windows (D13).
@MainActor @Observable
final class MotionHub {
    enum Source: String, CaseIterable, Identifiable {
        case airpods = "AirPods"
        case simulator = "Simulator"
        var id: String { rawValue }
    }

    enum Status: Equatable {
        case idle, unsupported, denied, waiting, streaming, error(String)
        var label: String {
            switch self {
            case .idle: "Stopped"
            case .unsupported: "Headphone motion not supported on this Mac"
            case .denied: "Motion access denied — System Settings › Privacy & Security › Motion & Fitness"
            case .waiting: "Waiting for AirPods (put them in, connected to this Mac)"
            case .streaming: "Streaming"
            case .error(let message): message
            }
        }
    }

    static let historySeconds = 10.0

    var source: Source = .airpods {
        didSet { if source != oldValue { restart() } }
    }
    private(set) var status: Status = .idle
    private(set) var latest: MotionSample?
    private(set) var history: [MotionSample] = []
    private(set) var sampleRate: Double = 0
    private(set) var maxRecentGap: Double = 0

    /// Called for every sample (gesture detection).
    @ObservationIgnored var onSample: ((MotionSample) -> Void)?
    @ObservationIgnored let simulator = MotionSimulator(seed: UInt64.random(in: 1...UInt64.max))

    /// Created only when AirPods are selected, so simulator mode never touches CoreMotion or the
    /// Motion permission (TCC kills an app that asks without a usage description in scope).
    @ObservationIgnored private var manager: CMHeadphoneMotionManager?
    @ObservationIgnored private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "LouVoice.motion"
        q.maxConcurrentOperationCount = 1
        return q
    }()
    @ObservationIgnored private let delegate = ConnectionDelegate()
    @ObservationIgnored private var simTimer: Timer?
    @ObservationIgnored private var captures: [Capture] = []

    private final class Capture {
        let end: Double
        var samples: [MotionSample]
        let continuation: CheckedContinuation<[MotionSample], Never>
        var done = false
        init(end: Double, samples: [MotionSample], continuation: CheckedContinuation<[MotionSample], Never>) {
            self.end = end; self.samples = samples; self.continuation = continuation
        }
    }

    var isSimulated: Bool { source == .simulator }

    @ObservationIgnored private var running = false

    func start() {
        guard !running else { return }
        running = true
        switch source {
        case .airpods: startAirPods()
        case .simulator: startSimulator()
        }
    }

    func stop() {
        running = false
        manager?.stopDeviceMotionUpdates()
        manager?.stopConnectionStatusUpdates()
        simTimer?.invalidate()
        simTimer = nil
        status = .idle
        sampleRate = 0
    }

    private func restart() {
        stop()
        history.removeAll()
        latest = nil
        start()
    }

    // MARK: Sources

    private func startAirPods() {
        let manager = self.manager ?? CMHeadphoneMotionManager()
        self.manager = manager
        guard manager.isDeviceMotionAvailable else { status = .unsupported; return }
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .denied, .restricted: status = .denied; return
        default: break
        }
        status = .waiting
        delegate.onChange = { [weak self] connected in
            DispatchQueue.main.async { self?.connectionChanged(connected) }
        }
        manager.delegate = delegate
        manager.startConnectionStatusUpdates()
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            // Convert on the motion queue, hop to main for state.
            let sample = motion.map(Self.convert)
            let failure = error as NSError?
            DispatchQueue.main.async { self?.handle(sample, failure) }
        }
    }

    nonisolated private static func convert(_ m: CMDeviceMotion) -> MotionSample {
        let q = m.attitude.quaternion
        // CMDeviceMotion.sensorLocation is iOS-only, so the Mac can't tell which earbud reports (D21).
        return MotionSample(
            t: m.timestamp,
            accel: Vec3(m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z),
            rotation: Vec3(m.rotationRate.x, m.rotationRate.y, m.rotationRate.z),
            gravity: Vec3(m.gravity.x, m.gravity.y, m.gravity.z),
            attitude: Quat(q.w, q.x, q.y, q.z),
            pitch: m.attitude.pitch, roll: m.attitude.roll, yaw: m.attitude.yaw,
            location: .unknown)
    }

    private func connectionChanged(_ connected: Bool) {
        if !connected { status = .waiting; sampleRate = 0 }
    }

    private func handle(_ sample: MotionSample?, _ error: NSError?) {
        if let error {
            status = error.domain == CMErrorDomain && error.code == Int(CMErrorMotionActivityNotAuthorized.rawValue)
                ? .denied : .error(error.localizedDescription)
            return
        }
        if let sample { ingest(sample) }
    }

    private func startSimulator() {
        status = .streaming
        simTimer = Timer.scheduledTimer(withTimeInterval: 1 / simulator.rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let s = self.simulator.step() else { return }
                self.ingest(s)
            }
        }
    }

    // MARK: Ingest

    private func ingest(_ s: MotionSample) {
        status = .streaming
        if let prev = latest { maxRecentGap = max(maxRecentGap * 0.98, s.t - prev.t) }
        latest = s
        history.append(s)
        if let cut = history.firstIndex(where: { $0.t >= s.t - Self.historySeconds }), cut > 0 {
            history.removeFirst(cut)
        }
        let recent = history.suffix(50)
        if let first = recent.first, let last = recent.last, last.t > first.t {
            sampleRate = Double(recent.count - 1) / (last.t - first.t)
        }

        for c in captures where !c.done {
            c.samples.append(s)
            if s.t >= c.end { finish(c) }
        }
        captures.removeAll { $0.done }
        onSample?(s)
    }

    private func finish(_ c: Capture) {
        guard !c.done else { return }
        c.done = true
        c.continuation.resume(returning: c.samples)
    }

    /// Record `preroll` seconds already in history plus the next `window` seconds of motion.
    /// Times are on the sample clock, so Bluetooth latency doesn't shift the window.
    func capture(preroll: Double = 0.3, window: Double = 1.8) async -> [MotionSample] {
        let now = latest?.t ?? 0
        let pre = history.filter { $0.t >= now - preroll }
        return await withCheckedContinuation { continuation in
            let c = Capture(end: now + window, samples: pre, continuation: continuation)
            captures.append(c)
            // If samples stop arriving, return what we have.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(window + 1.5))
                self?.finish(c)
                self?.captures.removeAll { $0.done }
            }
        }
    }

    /// In simulator mode, perform the movement the user was prompted for.
    func simulate(_ action: SimAction?) {
        guard isSimulated, let action else { return }
        simulator.perform(action)
    }
}

private final class ConnectionDelegate: NSObject, CMHeadphoneMotionManagerDelegate {
    var onChange: ((Bool) -> Void)?
    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) { onChange?(true) }
    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) { onChange?(false) }
}
