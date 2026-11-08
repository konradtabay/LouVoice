import LouVoiceCore
import SwiftUI

/// Practise words. One big prompt, one big button, the word list beside it.
/// Every other option (blocks, quizzes, sentences, focus words, scores) is in
/// Settings › Practice or Settings › Advanced › Training console.
struct TrainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            LVScroll { WordList().padding(32) }
                .frame(width: 380)
                .overlay(alignment: .trailing) { Rectangle().fill(LV.ink).frame(width: 1) }
            VStack(spacing: 24) {
                TrainPrompt().frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(alignment: .bottom, spacing: 24) {
                    TrainControls().frame(maxWidth: .infinity)
                    SignalPreview().frame(width: 320)
                }
            }
            .padding(40)
        }
    }
}

// MARK: Signal preview

/// Small live rotation plot so the user can see the AirPods feel their jaw (Train and Speak).
struct SignalPreview: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hub = model.hub
        SignalPlot(title: "Signal", unit: hub.status == .streaming ? String(format: "%.0f Hz", hub.sampleRate) : "AirPods off",
                   samples: hub.history, range: 1.6, channels: [
                       ("x", LV.heart, { $0.rotation.x }), ("y", LV.violet, { $0.rotation.y }), ("z", LV.ink, { $0.rotation.z }),
                   ], compact: true, height: 90)
    }
}

// MARK: Word list

private struct WordList: View {
    @Environment(AppModel.self) private var model
    @State private var newWord = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your words").font(LV.display(40))
                Text("Words LouVoice is learning to understand.").font(LV.small).foregroundStyle(LV.muted)
            }
            VStack(spacing: 0) {
                ForEach(model.words, id: \.self) { word in
                    HStack(spacing: 12) {
                        Text(word).font(LV.sans(22, .medium))
                        Spacer()
                        // No remove button here: too easy to hit by accident. Remove in Settings › Advanced › Training console.
                        WordStatus(takes: model.takeCount(word))
                    }
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) { Rectangle().fill(LV.ink.opacity(0.15)).frame(height: 1) }
                }
                if model.words.isEmpty {
                    Text("No words yet. Add one below.").font(LV.body).foregroundStyle(LV.muted).padding(.vertical, 12)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: "Add a word")
                HStack(spacing: 10) {
                    TextField("For example: water", text: $newWord)
                        .textFieldStyle(LVTextFieldStyle())
                        .onSubmit(add)
                    Button("Add", action: add).lvButton(.outline).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Short words that look different on the lips are easiest.").font(LV.small).foregroundStyle(LV.muted)
            }
        }
    }

    private func add() {
        model.addWord(newWord)
        newWord = ""
    }
}

private struct WordStatus: View {
    var takes: Int
    var body: some View {
        let learned = takes >= EnrollView.newWordTakes
        Text(learned ? "Learned" : takes == 0 ? "New" : "Practising")
            .font(LV.sans(14, .semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(learned ? LV.pearl : LV.ink)
            .background(learned ? LV.heart : Color.clear)
            .overlay(Rectangle().strokeBorder(learned ? LV.heart : LV.ink.opacity(0.4), lineWidth: 1))
    }
}

// MARK: Controls

private struct TrainControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let e = model.enrollment
        let canRecord = model.hub.status == .streaming && !e.isRunning
        let newWords = model.words.filter { model.takeCount($0) < EnrollView.newWordTakes }
        VStack(spacing: 14) {
            if e.isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressBar(value: Double(e.completed) / Double(max(e.total, 1)))
                    Text("\(e.completed) of \(e.total) done").font(LV.body).foregroundStyle(LV.muted)
                }
                Button { e.stop() } label: { Label("Stop practice", systemImage: "stop.fill") }
                    .lvButton(.outline, .large)
            } else {
                HStack(spacing: 16) {
                    Button { start(model.words) } label: { Label("Start practice", systemImage: "play.fill") }
                        .lvButton(.primary, .huge)
                        .disabled(!canRecord || model.words.isEmpty)
                    if !newWords.isEmpty && newWords.count < model.words.count {
                        Button("New words only (\(newWords.count))") { start(newWords) }
                            .lvButton(.outline, .large)
                            .disabled(!canRecord)
                    }
                }
                if model.hub.status != .streaming {
                    Text("Connect your AirPods first. Check the Signals tab.").font(LV.body).foregroundStyle(LV.warn)
                } else {
                    Text("About \(minutes) minutes. Short breaks are built in.").font(LV.body).foregroundStyle(LV.muted)
                }
            }
        }
    }

    private var minutes: Int {
        let e = model.enrollment
        let prompts = e.blockCount * (model.words.count * (e.reps + (e.quizAfterBlock ? 1 : 0)) + e.noisePerBlock)
        return max(1, Int((Double(prompts) * 4.4 / 60).rounded()))
    }

    private func start(_ words: [String]) {
        let e = model.enrollment
        e.start(words: words, reps: e.reps, blocks: e.blockCount,
                noisePerBlock: words.count == model.words.count ? e.noisePerBlock : min(e.noisePerBlock, 2))
    }
}

struct ProgressBar: View {
    var value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.5))
                Rectangle().fill(LV.heart).frame(width: g.size.width * max(0, min(1, value)))
            }
            .overlay(Rectangle().strokeBorder(LV.ink, lineWidth: 1.5))
        }
        .frame(height: 18)
    }
}

// MARK: Prompt

/// The big card that tells the user what to do right now.
private struct TrainPrompt: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let e = model.enrollment
        VStack(spacing: 22) {
            switch e.phase {
            case .idle:
                Eyebrow(text: "Practice")
                Text("Ready when you are").font(LV.display(56))
                VStack(alignment: .leading, spacing: 14) {
                    tip("1", "A word appears here, and you hear a beep.")
                    tip("2", "After the beep, mouth the word silently. Move your jaw clearly.")
                    tip("3", "Keep your head still. Only your jaw moves.")
                }
                .padding(.top, 8)
            case .ready(let p, _):
                promptWord(p)
                Text("Get ready…").font(LV.sans(26)).foregroundStyle(LV.muted)
            case .recording(let p, _):
                promptWord(p)
                HStack(spacing: 12) {
                    Circle().fill(LV.violet).frame(width: 22, height: 22)
                    Text("Mouth it now").font(LV.sans(30, .semibold))
                }
            case .feedback(let ok, _, _, let correct):
                // Encouraging only: scores are in the Training console.
                Image(systemName: ok ? "checkmark" : "arrow.counterclockwise")
                    .font(.system(size: 64, weight: .medium))
                    .foregroundStyle(ok ? (correct == false ? LV.heart : LV.good) : LV.warn)
                Text(ok ? (correct == false ? "Got it. Keep going." : "Good") : "Let's try that one again later")
                    .font(LV.display(44)).multilineTextAlignment(.center)
            case .quizIntro:
                Eyebrow(text: "Quick check")
                Text("Let's see what LouVoice remembers").font(LV.display(44)).multilineTextAlignment(.center)
                Text("Same as before: mouth each word after the beep.").font(LV.body).foregroundStyle(LV.muted)
            case .blockBreak(let next):
                Eyebrow(text: "Break")
                Text("Take a rest").font(LV.display(56))
                Text("Take both AirPods out, then put them back in.\nWhen you're ready, press Space.")
                    .font(LV.sans(22)).multilineTextAlignment(.center).foregroundStyle(LV.ink.opacity(0.8))
                Button("Continue to round \(next)") { e.continueAfterBreak() }
                    .lvButton(.primary, .large).keyboardShortcut(.defaultAction)
            case .finished:
                Image(systemName: "checkmark.seal").font(.system(size: 64, weight: .light)).foregroundStyle(LV.heart)
                Text("All done. Nice work.").font(LV.display(56))
                Button("Start speaking") { model.screen = .speak }.lvButton(.primary, .large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LV.card)
        .overlay(Rectangle().strokeBorder(LV.ink, lineWidth: 1))
    }

    private func promptWord(_ p: Enrollment.Prompt) -> some View {
        VStack(spacing: 14) {
            Text(p.label == noneLabel ? "Move naturally, don't say a word" : p.text)
                .font(LV.display(p.label == noneLabel || p.label.contains(" ") ? 56 : 120))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.4)
            if let h = Enrollment.hints[p.label] {
                Text(h).font(LV.sans(22)).foregroundStyle(LV.heart).multilineTextAlignment(.center)
            }
        }
    }

    private func tip(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(n).font(LV.display(34)).foregroundStyle(LV.heart).frame(width: 30)
            Text(text).font(LV.sans(22))
        }
    }
}
