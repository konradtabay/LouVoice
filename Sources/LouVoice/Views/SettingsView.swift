import LouVoiceCore
import SwiftUI

/// Everything that isn't Signals, Train or Speak. Plain-language options up top; the original
/// full screens are one click away under "Advanced" for caregivers and the team.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let page = model.advancedPage {
            AdvancedPageView(page: page)
        } else {
            LVScroll {
                VStack(alignment: .leading, spacing: 28) {
                    PageTitle(title: "Settings")
                    HStack(alignment: .top, spacing: 28) {
                        VStack(spacing: 28) { VoiceCard(); SpeakingCard() }
                        VStack(spacing: 28) { PracticeCard(); AdvancedCard() }
                    }
                }
                .padding(40)
                .frame(maxWidth: 1240)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: Voice

private struct VoiceCard: View {
    @Environment(AppModel.self) private var model
    @State private var keyField = ""
    @State private var hasKey = false
    @State private var showSetup = false

    var body: some View {
        let v = model.voice
        LVCard(title: "Your voice", subtitle: "LouVoice speaks in your own voice, made with ElevenLabs.") {
            Toggle("Speak in my voice", isOn: Binding(get: { v.settings.enabled }, set: { v.settings.enabled = $0 }))
                .toggleStyle(LVToggleStyle())
            StatusBadge(tone: v.isConfigured ? .good : .neutral,
                        text: v.isConfigured ? "Voice is set up · \(v.cachedWords.count) of \(model.words.count) words ready"
                                             : "Not set up yet: using the Mac's voice")
            HStack(spacing: 12) {
                Button { Task { await v.speak(VoiceSettingsView.testPhrase) } } label: { Label("Hear my voice", systemImage: "play.fill") }
                    .lvButton(.primary).disabled(v.isPreparing)
                Button(showSetup ? "Hide set-up" : "Set up voice") { showSetup.toggle() }.lvButton(.outline)
            }
            if showSetup {
                VStack(alignment: .leading, spacing: 12) {
                    Eyebrow(text: "ElevenLabs API key")
                    HStack(spacing: 10) {
                        SecureField(hasKey ? "Saved. Paste a new one to replace it." : "Paste the API key", text: $keyField)
                            .textFieldStyle(LVTextFieldStyle())
                        Button("Save") {
                            v.setAPIKey(keyField); keyField = ""; hasKey = v.hasKey; v.refreshCache(words: model.words)
                        }
                        .lvButton(.outline).disabled(keyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if hasKey { Button("Remove") { v.removeAPIKey(); hasKey = v.hasKey }.lvButton(.danger) }
                    }
                    Eyebrow(text: "Voice ID")
                    TextField("From your ElevenLabs voice clone", text: Binding(
                        get: { v.voiceID },
                        set: { v.voiceID = $0.trimmingCharacters(in: .whitespacesAndNewlines); v.refreshCache(words: model.words) }))
                        .textFieldStyle(LVTextFieldStyle())
                    Button(v.isPreparing ? "Getting words ready…" : "Get all words ready") {
                        Task { await v.prepare(vocabulary: model.words) }
                    }
                    .lvButton(.outline).disabled(!v.isConfigured || v.isPreparing || model.words.isEmpty)
                    if v.isPreparing { ProgressBar(value: v.prepareProgress) }
                    if let e = v.lastError { Text(e).font(LV.small).foregroundStyle(LV.bad) }
                }
                .padding(.top, 4)
            }
        }
        .onAppear { hasKey = v.hasKey }
    }
}

// MARK: Speaking

private struct SpeakingCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var d = model.decoder
        LVCard(title: "Speaking") {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: "Each time I press start, I say")
                LVChoice(options: [(true, "A whole sentence"), (false, "One word")], selection: $d.sentenceMode)
            }
            Toggle("Say my words out loud", isOn: $d.speakResult).toggleStyle(LVToggleStyle())
            Toggle("Start with the AirPod stem", isOn: Binding(
                get: { model.stem.isEnabled }, set: { $0 ? model.stem.enable() : model.stem.disable() }))
                .toggleStyle(LVToggleStyle())
            Toggle("Keep learning from words I say \"yes\" to", isOn: $d.addConfirmedToTraining).toggleStyle(LVToggleStyle())
        }
    }
}

// MARK: Practice

private struct PracticeCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var e = model.enrollment
        LVCard(title: "Practice", subtitle: "Shorter practice is easier. More practice makes LouVoice more accurate.") {
            LVStepper(label: "Rounds", value: $e.blockCount, range: 1...6)
            LVStepper(label: "Times each word per round", value: $e.reps, range: 1...6)
            Toggle("Read each word aloud in my AirPods", isOn: Binding(
                get: { model.cues.speakPrompts }, set: { model.cues.speakPrompts = $0 }))
                .toggleStyle(LVToggleStyle())
            Toggle("Quick check after each round", isOn: $e.quizAfterBlock).toggleStyle(LVToggleStyle())
        }
        .disabled(e.isRunning)
    }
}

// MARK: Advanced

private struct AdvancedCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LVCard(title: "Advanced", subtitle: "For caregivers and the LouVoice team.") {
            VStack(spacing: 0) {
                ForEach(AppModel.AdvancedPage.allCases) { page in
                    Button { model.advancedPage = page } label: {
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(page.rawValue).font(LV.sans(19, .semibold))
                                Text(page.detail).font(LV.small).foregroundStyle(LV.muted).multilineTextAlignment(.leading)
                            }
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) { Rectangle().fill(LV.ink.opacity(0.15)).frame(height: 1) }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: "Motion source")
                LVChoice(options: MotionHub.Source.allCases.map { ($0, $0.rawValue) },
                         selection: Binding(get: { model.hub.source }, set: { model.setSource($0) }))
                Text("Simulator makes fake movement for testing. Use AirPods for real use.").font(LV.small).foregroundStyle(LV.muted)
            }
        }
    }
}

/// One of the original full screens, with a way back.
private struct AdvancedPageView: View {
    @Environment(AppModel.self) private var model
    var page: AppModel.AdvancedPage

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button { model.advancedPage = nil } label: { Label("Settings", systemImage: "arrow.left") }.lvButton(.outline)
                Text(page.rawValue).font(LV.display(32))
                Spacer()
            }
            .padding(.horizontal, 32).padding(.vertical, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(LV.ink).frame(height: 1) }
            Group {
                switch page {
                case .trainingConsole: EnrollView()
                case .speakingConsole: DecodeView()
                case .signalDetails: SensorsView()
                case .accuracy: EvaluateView()
                case .fineTune: TuneView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.35))
        }
    }
}
