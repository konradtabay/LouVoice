import LouVoiceCore
import SwiftUI

struct DecodeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let d = model.decoder
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 16) {
                ResultCard()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                SectionCard(title: "Transcript") {
                    Text(d.transcript.isEmpty ? "Accepted words appear here." : d.transcript)
                        .font(.title2)
                        .foregroundStyle(d.transcript.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    HStack { Spacer(); Button("Clear") { d.clear() }.disabled(d.results.isEmpty) }
                }
                history
            }
            .padding(20)
            Divider()
            ScrollView { controls.padding(16) }.frame(width: 300)
        }
        .navigationTitle("Decode")
    }

    private var history: some View {
        let d = model.decoder
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(d.results.prefix(20)) { r in
                    HStack {
                        Text(r.prediction.best.map { displayLabel($0.label) } ?? "?").bold()
                        if let sim = r.simulatedWord { Text("(sim: \(sim))").foregroundStyle(.secondary) }
                        Spacer()
                        Text(String(format: "margin %.2f", r.prediction.margin)).foregroundStyle(.secondary)
                        Text(outcomeText(r)).foregroundStyle(outcomeColor(r.outcome)).frame(width: 110, alignment: .trailing)
                    }
                    .font(.caption)
                }
            }
        }
        .frame(height: 120)
    }

    @ViewBuilder private var controls: some View {
        @Bindable var d = model.decoder
        VStack(alignment: .leading, spacing: 16) {
            SectionCard(title: "Mode") {
                Picker("Decode", selection: $d.sentenceMode) {
                    Text("Whole sentence").tag(true)
                    Text("One word per press").tag(false)
                }
                .pickerStyle(.segmented)
                Text(d.sentenceMode ? String(format: "Press once and mouth the whole sentence (up to %.1f s; ends when you stop).", model.config.sentence.windowSeconds)
                                    : "The original mode: one word per press.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VoiceSetupCard()
            SectionCard(title: "Next-word prediction") {
                Picker("Strength", selection: Binding(get: { model.config.context.strength },
                                                      set: { v in model.updateConfig { $0.context.strength = v } })) {
                    ForEach(ContextModel.Strength.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text(model.config.context.strength.detail).font(.caption).foregroundStyle(.secondary)
                Toggle("Demo: only say one of these phrases", isOn: Binding(
                    get: { model.config.sentence.onlyExpectedPhrases }, set: { v in model.updateConfig { $0.sentence.onlyExpectedPhrases = v } }))
                Text(model.config.sentence.onlyExpectedPhrases
                     ? "Sentence mode picks whichever expected phrase fits your motion best (phrases with untrained words are skipped)."
                     : "Free decoding: any words in any order, guided by the phrases.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Say \"no sentence\" for random movement", isOn: Binding(
                    get: { model.config.sentence.rejectNothing }, set: { v in model.updateConfig { $0.sentence.rejectNothing = v } }))
                if model.config.sentence.rejectNothing {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "Strictness: %.1f (lower = stricter)", model.config.sentence.rejectThreshold)).font(.caption)
                        Slider(value: Binding(get: { model.config.sentence.rejectThreshold },
                                              set: { v in model.updateConfig { $0.sentence.rejectThreshold = v } }), in: 0...1.2, step: 0.1)
                        Text("0.6: keeps 93% of real sentences, rejects all recorded random movement.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Toggle("Also expect parts (\"hello can\", \"you hear me\")", isOn: Binding(
                    get: { model.config.context.includeParts }, set: { v in model.updateConfig { $0.context.includeParts = v } }))
                Text(model.config.context.includeParts
                     ? "Parts can be recognised, but full sentences get less reliable until there's sentence-training data."
                     : "Only whole phrases: most reliable for the full sentence.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Expected phrases, one per line").font(.subheadline)
                TextEditor(text: Binding(get: { model.config.context.phrases.joined(separator: "\n") },
                                         set: { v in model.updateConfig { $0.context.phrases = v.components(separatedBy: .newlines) } }))
                    .font(.callout).frame(height: 60)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                HStack {
                    Text(d.currentContext.map { "After \"\($0)\"" } ?? "Start of phrase").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart phrase") { d.resetContext() }.font(.caption)
                }
            }
            SectionCard(title: "Context screen (active words)") {
                FlowChips(words: model.words, active: d.activeWords) { word in
                    if d.activeWords.contains(word) { d.activeWords.remove(word) } else { d.activeWords.insert(word) }
                }
                HStack {
                    Button("All words") { d.activeWords = [] }.disabled(d.activeWords.isEmpty)
                    Spacer()
                    Text(d.activeWords.isEmpty ? "All \(model.words.count) active" : "\(d.activeWords.count) active")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            SectionCard(title: "Trigger") {
                Toggle("AirPods stem press (experimental)", isOn: Binding(
                    get: { model.stem.isEnabled },
                    set: { $0 ? model.stem.enable() : model.stem.disable() }))
                Text("Space always works. The stem press needs LouVoice to be the \"now playing\" app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SectionCard(title: "Acceptance") {
                VStack(alignment: .leading) {
                    Text(String(format: "Max distance: %.1f", d.maxScore))
                    Slider(value: $d.maxScore, in: 0.5...5)
                    Text(String(format: "Min margin: %.2f", d.minMargin))
                    Slider(value: $d.minMargin, in: 0...0.3)
                }
                Toggle("Speak decoded word", isOn: $d.speakResult)
                Toggle("Add confirmed words to training", isOn: $d.addConfirmedToTraining)
            }
            if model.isSimulated {
                SectionCard(title: "Simulator") {
                    Picker("Fake user mouths", selection: $d.simulatedWord) {
                        Text("Random active word").tag(String?.none)
                        ForEach(model.words, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    HStack {
                        Button("Nod") { d.simulateGesture(.nod) }
                        Button("Shake") { d.simulateGesture(.shake) }
                    }
                    .disabled(!d.isConfirming)
                }
            }
        }
    }

    private func outcomeText(_ r: Decoder.Result) -> String {
        switch r.outcome {
        case .pending: "waiting…"
        case .confirmed: "✓ nodded"
        case .rejected: "✗ shook"
        case .unconfirmed: "kept"
        case .discarded: r.prediction.rejectReason ?? "rejected"
        }
    }

    private func outcomeColor(_ o: Decoder.Outcome) -> Color {
        switch o {
        case .confirmed: .green
        case .rejected, .discarded: .red
        default: .secondary
        }
    }
}

private struct ResultCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let d = model.decoder
        VStack(spacing: 14) {
            switch d.phase {
            case .recording:
                Label("Mouth it now", systemImage: "record.circle.fill").font(.largeTitle.weight(.semibold)).foregroundStyle(.red)
            case .thinking:
                ProgressView().controlSize(.large)
            case .idle, .confirming:
                if let r = d.results.first {
                    resultBody(r)
                } else {
                    Image(systemName: "airpodspro").font(.system(size: 54)).foregroundStyle(.secondary)
                    Text(model.classifier == nil ? "Enroll at least two words first"
                         : d.sentenceMode ? "Press Space (or the stem) and mouth the whole sentence" : "Press Space (or the stem) and mouth a word")
                        .font(.title3).foregroundStyle(.secondary)
                }
            }
            let next = d.expectedNext().prefix(3)
            if !next.isEmpty, d.phase == .idle || d.isConfirming {
                Text("Expected next: " + next.map { "\($0.word) \(Int(($0.p * 100).rounded()))%" }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if model.classifier != nil, d.phase == .idle {
                Button(d.sentenceMode ? "Decode a sentence" : "Decode a word") { d.trigger() }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.secondary.opacity(0.06)))
    }

    @ViewBuilder private func resultBody(_ r: Decoder.Result) -> some View {
        let d = model.decoder
        if r.outcome == .discarded {
            Text("—").font(.system(size: 72, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            Text(r.prediction.rejectReason ?? "Not recognised").font(.title3).foregroundStyle(.secondary)
        } else if let sentence = r.sentence {
            // Each word with its runner-ups: one tap fixes a word (PRD fast correction, D40).
            HStack(alignment: .top, spacing: 18) {
                ForEach(Array(sentence.words.enumerated()), id: \.offset) { idx, w in
                    VStack(spacing: 4) {
                        Text(w.label).font(.system(size: 40, weight: .bold, design: .rounded))
                        ForEach(w.alternatives, id: \.self) { alt in
                            Button(alt) { d.correct(resultID: r.id, index: idx, to: alt) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
        } else {
            Text(r.prediction.best?.label ?? "?").font(.system(size: 80, weight: .bold, design: .rounded))
        }
        if !r.isSentence { HStack(spacing: 16) {
            ForEach(r.prediction.ranked.prefix(3)) { item in
                VStack {
                    Text(displayLabel(item.label)).font(.callout)
                    Text(String(format: "%.2f", item.score)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        } }
        if let delay = r.voiceDelay {
            let ok = delay < Decoder.delayTarget
            Label(String(format: "Voice %.2f s after the word ended · %@", delay, r.voiceSource?.rawValue ?? ""),
                  systemImage: ok ? "speaker.wave.2.fill" : "tortoise.fill")
                .font(.callout).foregroundStyle(ok ? .green : .orange)
        }
        if let motion = r.motionBest, let final = r.prediction.best?.label, motion != final, r.outcome != .discarded {
            Text("Motion alone said \"\(displayLabel(motion))\"; the phrase context picked \"\(final)\"")
                .font(.callout).foregroundStyle(.orange)
        }
        if d.isConfirming {
            Label("Nod to accept · shake to reject  (Y / N)", systemImage: "person.fill.questionmark")
                .font(.title3).foregroundStyle(.blue)
        } else if r.outcome == .confirmed {
            Label("Confirmed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if r.outcome == .rejected {
            Label("Rejected", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

private struct FlowChips: View {
    var words: [String]
    var active: Set<String>
    var toggle: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(words, id: \.self) { word in
                let on = active.isEmpty || active.contains(word)
                Button { toggle(word) } label: {
                    Text(word).font(.callout).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(Capsule().fill(on ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// ElevenLabs voice setup (PRD item 1). The key goes to the Keychain, never to disk or the repo.
private struct VoiceSetupCard: View {
    @Environment(AppModel.self) private var model
    @State private var keyField = ""

    var body: some View {
        let v = model.voice
        SectionCard(title: "Your voice (ElevenLabs)") {
            Toggle("Speak in my voice", isOn: Binding(get: { v.settings.enabled }, set: { v.settings.enabled = $0 }))
            HStack {
                SecureField(v.hasKey ? "API key saved ✓ (paste to replace)" : "ElevenLabs API key", text: $keyField)
                Button("Save") { v.setAPIKey(keyField); keyField = ""; v.refreshCache(words: model.words) }
                    .disabled(keyField.isEmpty)
            }
            TextField("Voice ID (from your ElevenLabs voice clone)", text: Binding(
                get: { v.settings.voiceID },
                set: { v.settings.voiceID = $0.trimmingCharacters(in: .whitespaces); v.refreshCache(words: model.words) }))
            HStack {
                Button(v.isPreparing ? "Generating…" : "Generate voice for all words") {
                    Task { await v.prepare(words: model.words) }
                }
                .disabled(!v.isConfigured || v.isPreparing)
                Button("Play test") { Task { await v.speak(model.words.first ?? "hello") } }
            }
            if v.isPreparing { ProgressView(value: v.prepareProgress) }
            Text(v.isConfigured
                 ? "Cached \(v.cachedWords.count) of \(model.words.count) words. Cached words play instantly, offline."
                 : "Not set up yet: decoded words use the system voice until a key and voice ID are added.")
                .font(.caption).foregroundStyle(.secondary)
            if !v.status.isEmpty { Text(v.status).font(.caption).foregroundStyle(.secondary) }
            if let e = v.lastError { Text(e).font(.caption).foregroundStyle(.red) }
            delayStats
        }
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
