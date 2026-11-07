import AVFoundation
import Foundation
import LouVoiceCore
import Observation
import Security

/// Speaks decoded words in the user's ElevenLabs voice clone (PRD item 1, D39).
///
/// The vocabulary is fixed, so every word/phrase is synthesized once and cached on disk. Playback
/// is then instant and works without Wi-Fi. Words added since the last cache are fetched live
/// (and cached). Without a key or voice, it falls back to the system voice so decode still talks.
@MainActor @Observable
final class VoiceService {
    enum Source: String { case cache = "your voice (cached)", live = "your voice (live)", system = "system voice" }

    struct Settings: Codable, Equatable {
        var enabled = true
        var voiceID = ""
        // TODO(team): confirm the model. Flash v2.5 is ElevenLabs' low-latency model; cached audio
        // could use a higher-quality model since speed doesn't matter at cache time.
        var modelID = "eleven_flash_v2_5"
        var outputFormat = "mp3_44100_128"
    }

    var settings: Settings { didSet { save() } }
    private(set) var cachedWords: Set<String> = []
    private(set) var isPreparing = false
    private(set) var prepareProgress = 0.0
    private(set) var status = ""
    private(set) var lastError: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var sequencePlayer: AVQueuePlayer?
    @ObservationIgnored private let fallback = AVSpeechSynthesizer()
    static let keychainService = "LouVoice.ElevenLabs"
    static let settingsKey = "voiceSettings.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let s = try? JSONDecoder().decode(Settings.self, from: data) { settings = s } else { settings = Settings() }
    }

    // MARK: Key (Keychain or ELEVENLABS_API_KEY; never in the bundle or the repo)

    var apiKey: String? {
        if let env = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"], !env.isEmpty { return env }
        return Keychain.read(service: Self.keychainService, account: "api-key")
    }
    var hasKey: Bool { apiKey != nil }
    var isConfigured: Bool { hasKey && !settings.voiceID.trimmingCharacters(in: .whitespaces).isEmpty }

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.write(trimmed.isEmpty ? nil : trimmed, service: Self.keychainService, account: "api-key")
        status = trimmed.isEmpty ? "API key removed" : "API key saved in Keychain"
    }

    // MARK: Cache

    private var cacheDirectory: URL {
        let dir = DatasetStore.directory.appending(path: "voice/\(Self.safe(settings.voiceID))", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cacheURL(_ text: String) -> URL {
        let key = "\(settings.modelID)|\(settings.outputFormat)|\(text.lowercased())"
        return cacheDirectory.appending(path: String(stableHash(key), radix: 16) + ".mp3")
    }

    func refreshCache(words: [String]) {
        cachedWords = Set(words.filter { FileManager.default.fileExists(atPath: cacheURL($0).path) })
    }

    /// Synthesize every word not yet cached (run after enrollment and when the vocabulary changes).
    func prepare(words: [String]) async {
        guard isConfigured, !isPreparing else { return }
        let missing = words.filter { !FileManager.default.fileExists(atPath: cacheURL($0).path) }
        guard !missing.isEmpty else { refreshCache(words: words); status = "All \(words.count) words cached"; return }
        isPreparing = true
        prepareProgress = 0
        lastError = nil
        for (i, word) in missing.enumerated() {
            status = "Generating \"\(word)\"…"
            do { _ = try await synthesize(word) } catch { lastError = "\(word): \(error.localizedDescription)"; break }
            prepareProgress = Double(i + 1) / Double(missing.count)
        }
        isPreparing = false
        refreshCache(words: words)
        status = lastError == nil ? "Cached \(cachedWords.count) of \(words.count) words" : "Stopped: \(lastError!)"
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        cachedWords = []
        status = "Cache cleared"
    }

    // MARK: Speak

    /// Plays `text` and returns how it was produced plus the seconds until playback started.
    @discardableResult
    func speak(_ text: String) async -> (source: Source, seconds: Double) {
        let start = Date()
        if settings.enabled, isConfigured {
            let url = cacheURL(text)
            var source = Source.cache
            if !FileManager.default.fileExists(atPath: url.path) {
                source = .live
                do { _ = try await synthesize(text); cachedWords.insert(text) } catch {
                    lastError = error.localizedDescription
                    return speakSystem(text, start)
                }
            }
            if play(url) { return (source, Date().timeIntervalSince(start)) }
        }
        return speakSystem(text, start)
    }

    /// A sentence: the cached word clips back to back; falls back to speaking the whole text.
    @discardableResult
    func speak(words: [String]) async -> (source: Source, seconds: Double) {
        let start = Date()
        let text = words.joined(separator: " ")
        guard settings.enabled, isConfigured else { return speakSystem(text, start) }
        var urls: [URL] = []
        var source = Source.cache
        for w in words {
            let url = cacheURL(w)
            if !FileManager.default.fileExists(atPath: url.path) {
                source = .live
                guard (try? await synthesize(w)) != nil else { return speakSystem(text, start) }
                cachedWords.insert(w)
            }
            urls.append(url)
        }
        let queue = AVQueuePlayer(items: urls.map { AVPlayerItem(url: $0) })
        queue.play()
        sequencePlayer = queue
        return (source, Date().timeIntervalSince(start))
    }

    private func speakSystem(_ text: String, _ start: Date) -> (source: Source, seconds: Double) {
        fallback.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.rate = 0.45
        fallback.speak(u)
        return (.system, Date().timeIntervalSince(start))
    }

    private func play(_ url: URL) -> Bool {
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            guard p.play() else { return false }
            player = p
            return true
        } catch {
            lastError = "Playback failed: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: ElevenLabs API

    enum VoiceError: LocalizedError {
        case notConfigured, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: "Add an ElevenLabs API key and voice ID first."
            case .http(let code, let body): "ElevenLabs returned \(code)\(body.isEmpty ? "" : ": \(body.prefix(160))")"
            }
        }
    }

    /// POST /v1/text-to-speech/{voice_id}; writes the audio into the cache and returns its URL.
    private func synthesize(_ text: String) async throws -> URL {
        guard let key = apiKey, isConfigured else { throw VoiceError.notConfigured }
        var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(settings.voiceID)")!
        components.queryItems = [URLQueryItem(name: "output_format", value: settings.outputFormat)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "model_id": settings.modelID])
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, !data.isEmpty else {
            throw VoiceError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        let url = cacheURL(text)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func save() {
        guard ProcessInfo.processInfo.environment["LOUVOICE_DATA_DIR"] == nil,
              let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    private static func safe(_ s: String) -> String {
        let v = s.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return v.isEmpty ? "no-voice" : v
    }
}

/// Minimal generic-password Keychain access.
enum Keychain {
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let s = String(data: data, encoding: .utf8)
        return (s?.isEmpty ?? true) ? nil : s
    }

    static func write(_ value: String?, service: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(add as CFDictionary, nil)
    }
}
