import LouVoiceCore
import SwiftUI

/// Everyday use: press, mouth, hear it. Big words, big buttons, nothing technical.
/// Mode, voice and recogniser options are in Settings.
struct SpeakView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var d = model.decoder
        VStack(spacing: 24) {
            HStack(spacing: 16) {
                Spacer()
                // D55/D58: start a fresh calibration from here (Settings › Speaking has one too).
                if model.wordCNNBase != nil {
                    Button {
                        model.resetCalibration()
                        model.startCalibration()
                    } label: { Label("Recalibrate", systemImage: "arrow.triangle.2.circlepath") }
                    .lvButton(.outline)
                    .fixedSize()
                    .disabled(model.isCalibrating || model.enrollment.isRunning || d.phase != .idle)
                    .help(model.calibratedAt.map { "Last calibrated " + $0.formatted(date: .abbreviated, time: .shortened) + ". About 80 seconds." }
                          ?? "Fit LouVoice to how your AirPods sit. About 80 seconds.")
                }
                SpeakAloudMenu()
            }
            // D55: the first time Speak is used in word mode, a short calibration comes first.
            if model.needsCalibration || model.needsSentenceCalibration || model.isCalibrating {
                CalibrationCard().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SpeakCard().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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

/// One-time calibration: mouth each word a few times so the word model fits how the AirPods sit.
private struct CalibrationCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let e = model.enrollment
        if model.isCalibrating && e.isRunning {
            VStack(spacing: 16) {
                TrainPrompt().frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 16) {
                    ProgressBar(value: Double(e.completed) / Double(max(e.total, 1)))
                    Text("\(e.completed) of \(e.total)").font(LV.body).foregroundStyle(LV.muted).monospacedDigit()
                    Button("Stop") { e.stop() }.lvButton(.outline)
                }
            }
        } else {
            VStack(spacing: 22) {
                let sentences = model.decoder.sentenceMode
                Eyebrow(text: "One-time setup")
                Text(model.isCalibrating ? "Adjusting to your AirPods…" : sentences ? "Quick sentence calibration" : "Quick calibration")
                    .font(LV.display(60))
                if model.isCalibrating {
                    ProgressView().controlSize(.large).tint(LV.heart)
                } else {
                    Text(sentences
                         ? "Mouth each sentence \(AppModel.sentenceCalibrationReps) times so LouVoice fits how your AirPods sit. About a minute."
                         : "Mouth each word \(AppModel.calibrationReps) times so LouVoice fits how your AirPods sit. About 80 seconds.")
                        .font(LV.sans(24)).multilineTextAlignment(.center).frame(maxWidth: 640)
                    Button {
                        if sentences { model.startSentenceCalibration() } else { model.startCalibration() }
                    } label: { Label("Start calibration", systemImage: "play.fill") }
                        .lvButton(.primary, .huge)
                        .disabled(model.hub.status != .streaming || e.isRunning)
                    if model.hub.status != .streaming {
                        Text("Connect your AirPods first.").font(LV.body).foregroundStyle(LV.warn)
                    }
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LV.card)
            .overlay(Rectangle().strokeBorder(LV.ink, lineWidth: 1))
        }
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
