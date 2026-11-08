import CryptoKit
import Foundation

/// ElevenLabs text-to-speech request building and on-disk cache paths for the user's voice clone.
///
/// Pure Swift: no networking, no playback, no Keychain. The app's VoiceService sends the request
/// this builds and stores the returned MP3 at `cacheURL`.
public enum VoiceCache {
    public static let defaultModelID = "eleven_flash_v2_5"
    public static let defaultOutputFormat = "mp3_44100_128"
    static let endpoint = "https://api.elevenlabs.io/v1/text-to-speech/"

    /// ~/Library/Application Support/LouVoice/VoiceCache
    public static var defaultRoot: URL {
        URL.applicationSupportDirectory
            .appending(path: "LouVoice", directoryHint: .isDirectory)
            .appending(path: "VoiceCache", directoryHint: .isDirectory)
    }

    /// Voice IDs are alphanumeric. Anything else is dropped so an ID can never escape the cache
    /// directory (e.g. "../x") or change the request path.
    public static func sanitizedVoiceID(_ voiceID: String) -> String {
        voiceID.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Hex SHA-256 of `lowercased(text) + modelID` (+ "@speed" when not 1), used as the cache file
    /// name. Lowercased so "Hello" and "hello" share one clip (team decision; the decoder emits
    /// lowercase anyway). A different speed is a different clip (D60).
    public static func cacheKey(text: String, modelID: String = defaultModelID, speed: Double? = nil) -> String {
        var key = text.lowercased() + modelID
        if let speed, speed != 1 { key += String(format: "@%.2f", speed) }
        return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// <root>/<voiceID>/<cacheKey>.mp3
    /// Returns nil when the voice ID is empty after sanitising.
    public static func cacheURL(text: String, voiceID: String, modelID: String = defaultModelID,
                                speed: Double? = nil, root: URL = defaultRoot) -> URL? {
        let id = sanitizedVoiceID(voiceID)
        guard !id.isEmpty else { return nil }
        return root.appending(path: id, directoryHint: .isDirectory)
            .appending(path: cacheKey(text: text, modelID: modelID, speed: speed) + ".mp3", directoryHint: .notDirectory)
    }

    /// POST https://api.elevenlabs.io/v1/text-to-speech/{voiceId}?output_format=mp3_44100_128
    /// Returns nil when the voice ID is empty after sanitising. The request carries the API key in
    /// a header, so never log the request or its headers.
    /// `speed` (ElevenLabs `voice_settings.speed`, 0.7–1.2; nil or 1 = normal) slows or speeds the
    /// speech without changing its pitch.
    public static func request(text: String, voiceID: String, apiKey: String, modelID: String = defaultModelID,
                               outputFormat: String = defaultOutputFormat, speed: Double? = nil) -> URLRequest? {
        let id = sanitizedVoiceID(voiceID)
        guard !id.isEmpty, var components = URLComponents(string: endpoint + id) else { return nil }
        components.queryItems = [URLQueryItem(name: "output_format", value: outputFormat)]
        var json: [String: Any] = ["text": text, "model_id": modelID]
        if let speed, speed != 1 { json["voice_settings"] = ["speed": min(1.2, max(0.7, speed))] }
        guard let url = components.url,
              let body = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // TODO(team): 20 s timeout picked as a default; live fetches during decode may want less.
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }
}
