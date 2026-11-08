import LouVoiceCore
import SwiftUI

/// Everyday use: press, mouth, hear it. Big words, big buttons, nothing technical.
/// Mode, voice and recogniser options are in Settings.
struct SpeakView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var d = model.decoder
        VStack(spacing: 24) {
            HStack {
                Spacer()
                Toggle(isOn: $d.speakResult) {
                    Label("Speak aloud", systemImage: d.speakResult ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(LV.sans(18, .semibold))
                }
                .toggleStyle(LVToggleStyle())
                .fixedSize()
                .help("Off: your words are shown on screen but not spoken. Press an AirPod stem to switch.")
            }
            SpeakCard().frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(alignment: .bottom, spacing: 24) {
                LVCard {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Eyebrow(text: "What you've said")
                            Text(d.transcript.isEmpty ? "Your words will appear here." : d.transcript)
                                .font(LV.sans(30))
                                .foregroundStyle(d.transcript.isEmpty ? LV.muted : LV.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        Button("Clear") { d.clear() }.lvButton(.outline).disabled(d.results.isEmpty)
                    }
                }
                .frame(maxWidth: .infinity)
                // Same live jaw-motion plot as on Train.
                SignalPreview().frame(width: 320)
            }
        }
        .padding(40)
    }
}

private struct SpeakCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let d = model.decoder
        VStack(spacing: 26) {
            switch d.phase {
            case .recording:
                HStack(spacing: 16) {
                    Circle().fill(LV.violet).frame(width: 28, height: 28)
                    Text("Mouth it now").font(LV.display(72))
                }
            case .thinking:
                ProgressView().controlSize(.large).tint(LV.heart)
                Text("Listening…").font(LV.sans(26)).foregroundStyle(LV.muted)
            case .idle, .confirming:
                if let r = d.results.first { result(r) } else { welcome }
            }
            if d.isConfirming {
                VStack(spacing: 14) {
                    Text("Is that right? Nod for yes, shake for no.").font(LV.sans(24)).foregroundStyle(LV.ink.opacity(0.8))
                    HStack(spacing: 20) {
                        Button { d.confirm(true) } label: { Label("Yes", systemImage: "checkmark") }.lvButton(.primary, .large)
                        Button { d.confirm(false) } label: { Label("No", systemImage: "xmark") }.lvButton(.outline, .large)
                    }
                }
            } else if model.classifier != nil, d.phase == .idle {
                Button { d.trigger() } label: { Label("Start speaking", systemImage: "waveform") }
                    .lvButton(.primary, .huge)
                Text("Or press Space.").font(LV.body).foregroundStyle(LV.muted)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LV.card)
        .overlay(Rectangle().strokeBorder(LV.ink, lineWidth: 1))
    }

    @ViewBuilder private var welcome: some View {
        if model.classifier == nil {
            Text("Practise first").font(LV.display(64))
            Text("LouVoice needs to learn at least two of your words.").font(LV.sans(22)).foregroundStyle(LV.muted)
            Button("Go to Train") { model.screen = .train }.lvButton(.primary, .large)
        } else {
            Text(model.decoder.sentenceMode ? "Say a sentence" : "Say a word").font(LV.display(72))
        }
    }

    @ViewBuilder private func result(_ r: Decoder.Result) -> some View {
        let d = model.decoder
        if r.outcome == .discarded {
            Text("Didn't catch that").font(LV.display(64))
            Text("Try again, moving your jaw a little more clearly.").font(LV.sans(22)).foregroundStyle(LV.muted)
        } else if let sentence = r.sentence {
            // Tap a word underneath to fix it (PRD fast correction).
            HStack(alignment: .top, spacing: 28) {
                ForEach(Array(sentence.words.enumerated()), id: \.offset) { idx, w in
                    VStack(spacing: 10) {
                        Text(w.label).font(LV.display(72))
                        ForEach(w.alternatives.prefix(2), id: \.self) { alt in
                            Button(alt) { d.correct(resultID: r.id, index: idx, to: alt) }.lvButton(.outline)
                        }
                    }
                }
            }
            if sentence.words.contains(where: { !$0.alternatives.isEmpty }) {
                Text("Wrong word? Tap the right one underneath it.").font(LV.body).foregroundStyle(LV.muted)
            }
        } else {
            Text(displayLabel(r.prediction.best?.label ?? "?")).font(LV.display(120))
        }
        if r.outcome == .confirmed {
            Label("Said", systemImage: "checkmark").font(LV.sans(20, .semibold)).foregroundStyle(LV.good)
        } else if r.outcome == .rejected {
            Label("Cancelled", systemImage: "xmark").font(LV.sans(20, .semibold)).foregroundStyle(LV.muted)
        }
    }
}
