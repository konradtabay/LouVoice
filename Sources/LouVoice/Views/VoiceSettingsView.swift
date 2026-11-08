import SwiftUI

/// ElevenLabs voice setup (PRD item 1). The key goes to the Keychain only and is never shown;
/// the voice ID is kept in UserDefaults.
struct VoiceSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var keyField = ""
    @State private var hasKey = false
    static let testPhrase = "hello can you hear me"

    var body: some View {
        let v = model.voice
        SectionCard(title: "Your voice (ElevenLabs)") {
            Toggle("Speak in my voice", isOn: Binding(get: { v.settings.enabled }, set: { v.settings.enabled = $0 }))

            Text("API key").font(.caption).foregroundStyle(.secondary)
            HStack {
                SecureField(hasKey ? "•••••••• saved (paste to replace)" : "Paste ElevenLabs API key", text: $keyField)
                Button("Save") {
                    v.setAPIKey(keyField)
                    keyField = ""
                    hasKey = v.hasKey
                    v.refreshCache(words: model.words)
                }
                .disabled(keyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasKey {
                    Button("Remove") { v.removeAPIKey(); hasKey = v.hasKey }
                }
            }

            Text("Voice ID").font(.caption).foregroundStyle(.secondary)
            TextField("From your ElevenLabs voice clone", text: Binding(
                get: { v.voiceID },
                set: { v.voiceID = $0.trimmingCharacters(in: .whitespacesAndNewlines); v.refreshCache(words: model.words) }))

            HStack {
                Button(v.isPreparing ? "Preparing…" : "Prepare voice") {
                    Task { await v.prepare(vocabulary: model.words) }
                }
                .disabled(!v.isConfigured || v.isPreparing || model.words.isEmpty)
                Button("Test") { Task { await v.speak(Self.testPhrase) } }
                    .disabled(v.isPreparing)
            }
            if v.isPreparing { ProgressView(value: v.prepareProgress) }

            Text(v.isConfigured
                 ? "Cached \(v.cachedWords.count) of \(model.words.count) words. Cached words play instantly, offline."
                 : "Not set up yet: decoded words use the system voice until a key and voice ID are added.")
                .font(.caption).foregroundStyle(.secondary)
            if let ms = v.lastLatencyMs {
                Text(String(format: "Last playback started %.0f ms after speak()", ms))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let text = v.lastTextOnly {
                Text("No audio for \"\(text)\" — shown as text only.").font(.caption).foregroundStyle(.orange)
            }
            if !v.status.isEmpty { Text(v.status).font(.caption).foregroundStyle(.secondary) }
            if let e = v.lastError { Text(e).font(.caption).foregroundStyle(.red) }
            delayStats
        }
        .onAppear { hasKey = v.hasKey }
    }

    @ViewBuilder private var delayStats: some View {
        let delays = model.decoder.results.compactMap(\.voiceDelay).prefix(10)
        if !delays.isEmpty {
            let sorted = delays.sorted()
            let median = sorted[sorted.count / 2], worst = sorted.last!
            Text(String(format: "Delay, last %d: median %.2f s, worst %.2f s (target < %.1f s)",
                        delays.count, median, worst, Decoder.delayTarget))
                .font(.caption.monospacedDigit())
                .foregroundStyle(worst < Decoder.delayTarget ? .green : .orange)
        }
    }
}
