import AppKit
import AVFoundation
import MediaPlayer

/// Audio cues and optional spoken prompts. Output only — no microphone (D1).
///
/// Cues are tones generated into an `AVAudioEngine` that stays running (D34). A running output
/// stream keeps the AirPods' Bluetooth audio link awake: an idle link takes a moment to wake, which
/// can swallow a short system sound entirely. The engine and the speech synthesizer are rebuilt
/// whenever the output route changes (AirPods reconnect, device switch).
@MainActor
final class CueService {
    var speakPrompts = true
    /// Silences everything (smoke test).
    var muted = false
    var volume: Float = 0.6

    enum Cue { case start, end, accept, reject, ready }

    private var synth = AVSpeechSynthesizer()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var observer: NSObjectProtocol?
    private(set) var lastError: String?

    func play(_ cue: Cue) {
        guard !muted else { return }
        ensureEngine()
        guard let player, let format, let buffer = Self.tone(cue, format: format, volume: volume) else {
            NSSound(named: NSSound.Name(Self.fallbackName(cue)))?.play()
            return
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    func say(_ text: String) {
        guard speakPrompts, !muted else { return }
        ensureEngine()
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.rate = 0.45
        synth.speak(u)
    }

    /// "Test sound" button: a start beep, an accept chime and a short phrase.
    func test() {
        let wasMuted = muted
        muted = false
        play(.start)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.play(.accept) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            let keep = self.speakPrompts
            self.speakPrompts = true
            self.say("Sound check")
            self.speakPrompts = keep
            self.muted = wasMuted
        }
    }

    private func ensureEngine() {
        if let engine, engine.isRunning { return }
        teardown()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 44_100, channels: 2) else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            lastError = "Audio engine failed: \(error.localizedDescription)"
            print("LouVoice: \(lastError!)")
            return
        }
        player.play()
        self.engine = engine; self.player = player; self.format = format
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Output route changed: rebuild on next cue, and give speech a fresh synthesizer.
                self?.teardown()
                self?.synth = AVSpeechSynthesizer()
            }
        }
        lastError = nil
    }

    private func teardown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        player?.stop()
        engine?.stop()
        engine = nil; player = nil; format = nil
    }

    private static func tone(_ cue: Cue, format: AVAudioFormat, volume: Float) -> AVAudioPCMBuffer? {
        let notes: [(Double, Double)]
        switch cue {
        case .start: notes = [(880, 0.10)]
        case .end: notes = [(587, 0.08)]
        case .accept: notes = [(660, 0.08), (990, 0.14)]
        case .reject: notes = [(196, 0.28)]
        case .ready: notes = [(523, 0.10), (659, 0.10), (784, 0.16)]
        }
        let sr = format.sampleRate
        let frames = AVAudioFrameCount(notes.reduce(0) { $0 + $1.1 } * sr)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames
        var i = 0
        for (freq, dur) in notes {
            let n = Int(dur * sr)
            for k in 0..<n {
                let t = Double(k) / sr
                let fade = min(1, Double(k) / (0.005 * sr), Double(n - k) / (0.012 * sr))   // click-free
                let v = Float(sin(2 * .pi * freq * t) * fade) * volume
                for c in 0..<Int(format.channelCount) where i < Int(frames) { channels[c][i] = v }
                i += 1
            }
        }
        return buffer
    }

    private static func fallbackName(_ cue: Cue) -> String {
        switch cue { case .start: "Tink"; case .end: "Pop"; case .accept: "Glass"; case .reject: "Basso"; case .ready: "Purr" }
    }
}

/// AirPods stem press → capture trigger (D15). macOS routes media remote commands to the
/// "now playing" app, so while enabled we claim now-playing and keep a silent output stream
/// alive. Output only; the microphone is never opened.
@MainActor
final class StemPress {
    var onPress: (() -> Void)?
    private(set) var isEnabled = false
    private var engine: AVAudioEngine?
    private var lastPress = Date.distantPast
    private var targets: [(MPRemoteCommand, Any)] = []

    func enable() {
        guard !isEnabled else { return }
        isEnabled = true
        startSilence()
        let center = MPRemoteCommandCenter.shared()
        for command in [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand] {
            command.isEnabled = true
            let token = command.addTarget { [weak self] _ in
                DispatchQueue.main.async { self?.pressed() }
                return .success
            }
            targets.append((command, token))
        }
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = [MPMediaItemPropertyTitle: "LouVoice", MPMediaItemPropertyArtist: "Press the stem to speak"]
        info.playbackState = .playing
    }

    func disable() {
        guard isEnabled else { return }
        isEnabled = false
        for (command, token) in targets { command.removeTarget(token) }
        targets.removeAll()
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        engine?.stop()
        engine = nil
    }

    private func pressed() {
        // play/pause can arrive in pairs; debounce.
        guard Date().timeIntervalSince(lastPress) > 0.5 else { return }
        lastPress = Date()
        MPNowPlayingInfoCenter.default().playbackState = .playing
        onPress?()
    }

    private func startSilence() {
        let engine = AVAudioEngine()
        let format = engine.outputNode.inputFormat(forBus: 0)
        let source = AVAudioSourceNode { _, _, frameCount, buffers -> OSStatus in
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                memset(buffer.mData, 0, Int(buffer.mDataByteSize))
            }
            _ = frameCount
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do { try engine.start(); self.engine = engine } catch { self.engine = nil }
    }
}
