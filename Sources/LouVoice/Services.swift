import AppKit
import AVFoundation
import MediaPlayer

/// Audio cues and optional spoken prompts. Output only — no microphone (D1).
@MainActor
final class CueService {
    var speakPrompts = true
    /// Silences everything (smoke test).
    var muted = false
    private let synth = AVSpeechSynthesizer()

    enum Cue: String {
        case start = "Tink", end = "Pop", accept = "Glass", reject = "Basso", ready = "Purr"
    }

    func play(_ cue: Cue) {
        guard !muted else { return }
        NSSound(named: NSSound.Name(cue.rawValue))?.play()
    }

    func say(_ text: String) {
        guard speakPrompts, !muted else { return }
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.rate = 0.45
        synth.speak(u)
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
