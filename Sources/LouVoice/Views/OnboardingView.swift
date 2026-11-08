import SwiftUI

/// First-run walkthrough for the simple UI: four short steps, one idea each.
/// Shown once automatically; the Help button in the header plays it again.
/// Each step switches to the tab it talks about, so the real screen shows behind it.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0

    private struct Step {
        var screen: AppModel.Screen
        var title: String
        var lines: [String]
    }

    private let steps: [Step] = [
        Step(screen: .signals, title: "Put in your AirPods",
             lines: ["Both earbuds in, connected to this Mac."]),
        Step(screen: .train, title: "Practise your words",
             lines: ["Press Start practice.", "When you hear the beep, mouth the word silently."]),
        Step(screen: .speak, title: "Speak",
             lines: ["Press Start speaking, Space, or the AirPod stem.", "Mouth your word. LouVoice says it in your voice."]),
        Step(screen: .speak, title: "Yes or no",
             lines: ["Nod if it's right. Shake your head if it's wrong."]),
    ]

    var body: some View {
        let s = steps[step]
        let last = step == steps.count - 1
        ZStack {
            LV.ink.opacity(0.45).ignoresSafeArea()
                .onTapGesture {}  // block clicks to the app behind
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    Eyebrow(text: "\(step + 1) of \(steps.count)")
                    Spacer()
                    Button("Skip") { finish() }.lvButton(.ghost)
                }
                Text(s.title).font(LV.display(60))
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(s.lines, id: \.self) { Text($0).font(LV.sans(26)) }
                }
                if step == 0 { airpodsStatus }
                Spacer(minLength: 0)
                HStack(spacing: 16) {
                    if step > 0 { Button("Back") { go(step - 1) }.lvButton(.outline, .large) }
                    Spacer()
                    Button(last ? "Done" : "Next") { last ? finish() : go(step + 1) }
                        .lvButton(.primary, .large)
                        .keyboardShortcut(.defaultAction)
                }
                Dots(count: steps.count, current: step)
            }
            .padding(48)
            .frame(width: 720, height: 520)
            .background(PaperBackground())
            .overlay(Rectangle().strokeBorder(LV.ink, lineWidth: 1.5))
            .background(LV.heart.offset(x: 8, y: 8))
        }
        .onAppear { model.screen = steps[step].screen }
        .onExitCommand { finish() }
    }

    private var airpodsStatus: some View {
        let on = model.hub.status == .streaming
        return StatusBadge(tone: on ? .good : .warn, text: on ? "AirPods connected" : "Waiting for AirPods…")
    }

    private func go(_ i: Int) {
        step = i
        model.advancedPage = nil
        model.screen = steps[i].screen
    }

    private func finish() {
        model.finishOnboarding()
    }
}

private struct Dots: View {
    var count: Int
    var current: Int
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Rectangle().fill(i == current ? LV.ink : LV.ink.opacity(0.2)).frame(width: i == current ? 28 : 10, height: 6)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}
