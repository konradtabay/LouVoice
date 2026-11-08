import AVFoundation
import Foundation
import LouVoiceCore
import Observation
import os

/// Speaks decoded words in the user's ElevenLabs voice clone (PRD item 1, D39).
///
/// Every vocabulary word is synthesized once and cached on disk (VoiceCache), so playback is
/// instant and works offline. Uncached words are fetched live, cached, then played. If that fetch
/// fails (offline, bad key, server error) the word is shown on screen without audio; nothing here
/// throws or crashes on network errors.
@MainActor @Observable
final class VoiceService {
    enum Source: String {
        case cache = "your voice (cached)"
        case live = "your voice (live)"
        case textOnly = "text only (no audio)"
        case system = "system voice"
    }

    struct Settings: Codable, Equatable {
        var enabled = true
        var modelID = VoiceCache.defaultModelID
        var outputFormat = VoiceCache.defaultOutputFormat
    }

    var settings: Settings { didSet { saveSettings() } }
    /// The ElevenLabs voice clone ID (UserDefaults; not secret).
    var voiceID: String { didSet { saveVoiceID() } }
    private(set) var cachedWords: Set<String> = []
    private(set) var isPreparing = false
    private(set) var prepareProgress = 0.0
    private(set) var status = ""
    private(set) var lastError: String?
    /// speak() call → playback start, milliseconds, for the most recent spoken word.
    private(set) var lastLatencyMs: Double?
    /// Set when a word couldn't be voiced; the UI shows it as text.
    private(set) var lastTextOnly: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var sequencePlayer: AVQueuePlayer?
    @ObservationIgnored private let fallback = AVSpeechSynthesizer()
    @ObservationIgnored private let log = Logger(subsystem: "LouVoice", category: "voice")
    static let settingsKey = "voiceSettings.v2"
    static let voiceIDKey = "elevenLabsVoiceID"

    private var isolated: Bool { ProcessInfo.processInfo.environment["LOUVOICE_DATA_DIR"] != nil }

    init() {
        let isolated = ProcessInfo.processInfo.environment["LOUVOICE_DATA_DIR"] != nil
        if !isolated, let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let s = try? JSONDecoder().decode(Settings.self, from: data) { settings = s } else { settings = Settings() }
        voiceID = isolated ? "" : (UserDefaults.standard.string(forKey: Self.voiceIDKey) ?? "")
    }

    // MARK: Key (Keychain, or ELEVENLABS_API_KEY for development; never in the bundle or the repo)

    /// The key, read from the Keychain once per launch. Every rebuild of the ad-hoc-signed app is
    /// a "new app" to the Keychain, which asks before letting it read the key; reading once means
    /// one prompt ("Always Allow") instead of one per spoken word.
    @ObservationIgnored private var keyLoaded = false
    @ObservationIgnored private var cachedKey: String?
    private var apiKey: String? {
        if let env = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"], !env.isEmpty { return env }
        if !keyLoaded { cachedKey = KeychainStore.read(); keyLoaded = true }
        return cachedKey
    }
    var hasKey: Bool { apiKey != nil }
    var isConfigured: Bool { hasKey && !VoiceCache.sanitizedVoiceID(voiceID).isEmpty }

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if KeychainStore.save(trimmed) {
            cachedKey = trimmed; keyLoaded = true; lastError = nil
            status = "API key saved in Keychain"
        } else {
            status = "Couldn't save the API key to the Keychain"
        }
    }

    func removeAPIKey() {
        KeychainStore.delete()
        cachedKey = nil; keyLoaded = true
        status = "API key removed"
    }

    // MARK: Cache

    /// <data dir>/VoiceCache — ~/Library/Application Support/LouVoice/VoiceCache unless LOUVOICE_DATA_DIR is set.
    private var cacheRoot: URL { DatasetStore.directory.appending(path: "VoiceCache", directoryHint: .isDirectory) }

    private func cacheURL(_ text: String) -> URL? {
        VoiceCache.cacheURL(text: text, voiceID: voiceID, modelID: settings.modelID, root: cacheRoot)
    }

    private func isCached(_ text: String) -> Bool {
        guard let url = cacheURL(text) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Settings › "Test my voice": fetches one word live (bypassing the cache) and plays it, and
    /// says exactly what went wrong if it fails.
    func testConnection() async {
        lastError = nil
        guard hasKey else { status = "No API key saved"; return }
        guard !VoiceCache.sanitizedVoiceID(voiceID).isEmpty else { status = "No voice ID saved"; return }
        status = "Asking ElevenLabs…"
        let start = Date()
        if let url = cacheURL("hello") { try? FileManager.default.removeItem(at: url) }
        guard let url = await fetch("hello") else { status = "ElevenLabs test failed"; return }
        cachedWords.insert("hello")
        let ok = play(url)
        status = ok ? String(format: "ElevenLabs works: \"hello\" in your voice, %.1f s", Date().timeIntervalSince(start))
                    : "Got audio from ElevenLabs but couldn't play it"
    }

    func refreshCache(words: [String]) {
        cachedWords = Set(words.filter(isCached))
    }

    /// Synthesizes every word/phrase not already cached, with progress. Cached ones are skipped.
    func prepare(vocabulary: [String]) async {
        guard isConfigured, !isPreparing else {
            if !isConfigured { status = "Add an API key and voice ID first" }
            return
        }
        var seen = Set<String>()
        let unique = vocabulary.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        let missing = unique.filter { !isCached($0) }
        guard !missing.isEmpty else {
            refreshCache(words: unique)
            status = "All \(unique.count) words already cached"
            return
        }
        isPreparing = true
        prepareProgress = 0
        lastError = nil
        var failed = 0
        for (i, word) in missing.enumerated() {
            status = "Generating \"\(word)\" (\(i + 1) of \(missing.count))…"
            if await fetch(word) == nil { failed += 1 }
            prepareProgress = Double(i + 1) / Double(missing.count)
            // Stop early if the first few all fail: likely offline or a bad key.
            if failed >= 3, failed == i + 1 { break }
        }
        isPreparing = false
        refreshCache(words: unique)
        status = failed == 0
            ? "Cached \(cachedWords.count) of \(unique.count) words"
            : "Cached \(cachedWords.count) of \(unique.count) words; \(failed) failed (\(lastError ?? "unknown error"))"
    }

    /// Existing callers (AppModel, Enrollment) use this name.
    func prepare(words: [String]) async { await prepare(vocabulary: words) }

    func clearCache() {
        if let dir = cacheURL("x")?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: dir) }
        cachedWords = []
        status = "Cache cleared"
    }

    // MARK: Speak

    /// Plays `text` from the cache instantly; if uncached, fetches, caches, then plays. If that
    /// fails, the text is shown without audio. Returns how it was voiced and seconds to playback.
    @discardableResult
    func speak(_ text: String) async -> (source: Source, seconds: Double) {
        let start = Date()
        lastTextOnly = nil
        guard settings.enabled else { return speakSystem(text, start) }
        // TODO(team): with no key/voice set up at all, the system voice keeps decode audible for
        // demos. Once set up, a failed fetch shows text only (team decision, 2026-11-07).
        guard isConfigured else { return speakSystem(text, start) }
        var source = Source.cache
        var url = cacheURL(text).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        if url == nil {
            source = .live
            url = await fetch(text)
            if url != nil { cachedWords.insert(text) }
        }
        guard let url, play(url) else { return finish(text, .textOnly, start, played: false) }
        return finish(text, source, start, played: true)
    }

    /// A sentence: the cached word clips back to back (fetching any missing ones). If any word
    /// can't be voiced, the sentence is shown as text only.
    @discardableResult
    func speak(words: [String]) async -> (source: Source, seconds: Double) {
        let start = Date()
        let text = words.joined(separator: " ")
        lastTextOnly = nil
        guard settings.enabled, isConfigured else { return speakSystem(text, start) }
        var urls: [URL] = []
        var source = Source.cache
        for w in words {
            if let u = cacheURL(w), FileManager.default.fileExists(atPath: u.path) { urls.append(u); continue }
            source = .live
            guard let u = await fetch(w) else { return finish(text, .textOnly, start, played: false) }
            cachedWords.insert(w)
            urls.append(u)
        }
        let queue = AVQueuePlayer(items: urls.map { AVPlayerItem(url: $0) })
        queue.play()
        sequencePlayer = queue
        return finish(text, source, start, played: true)
    }

    private func finish(_ text: String, _ source: Source, _ start: Date, played: Bool) -> (source: Source, seconds: Double) {
        let seconds = Date().timeIntervalSince(start)
        if played {
            lastLatencyMs = seconds * 1000
            log.info("speak → playback \(Int((seconds * 1000).rounded()), privacy: .public) ms (\(source.rawValue, privacy: .public))")
        } else {
            lastTextOnly = text
            log.info("speak → no audio after \(Int((seconds * 1000).rounded()), privacy: .public) ms; showing text only")
        }
        return (source, seconds)
    }

    private func speakSystem(_ text: String, _ start: Date) -> (source: Source, seconds: Double) {
        fallback.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.rate = 0.45
        fallback.speak(u)
        return finish(text, .system, start, played: true)
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
            // A corrupt cache file would fail forever; remove it so the next call refetches.
            try? FileManager.default.removeItem(at: url)
            return false
        }
    }

    // MARK: ElevenLabs API

    /// Sends the VoiceCache request and writes the MP3 into the cache. Returns nil on any failure
    /// (recorded in `lastError`, without the key).
    private func fetch(_ text: String) async -> URL? {
        guard let key = apiKey, let url = cacheURL(text),
              let request = VoiceCache.request(text: text, voiceID: voiceID, apiKey: key,
                                               modelID: settings.modelID, outputFormat: settings.outputFormat) else {
            lastError = "Add an ElevenLabs API key and voice ID first."
            return nil
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, !data.isEmpty else {
                let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
                lastError = "ElevenLabs returned \(code)\(body.isEmpty ? "" : ": \(body.prefix(160))")"
                return nil
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost].contains(e.code) {
            lastError = "Offline: \(e.localizedDescription)"
            return nil
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func saveSettings() {
        guard !isolated, let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    private func saveVoiceID() {
        guard !isolated else { return }
        UserDefaults.standard.set(voiceID, forKey: Self.voiceIDKey)
    }
}
