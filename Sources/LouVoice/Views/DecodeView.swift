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
                    Text(model.classifier == nil ? "Enroll at least two words first" : "Press Space (or the stem) and mouth a word")
                        .font(.title3).foregroundStyle(.secondary)
                }
            }
            if model.classifier != nil, d.phase == .idle {
                Button("Decode a word") { d.trigger() }.buttonStyle(.borderedProminent).controlSize(.large)
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
        } else {
            Text(r.prediction.best?.label ?? "?").font(.system(size: 80, weight: .bold, design: .rounded))
        }
        HStack(spacing: 16) {
            ForEach(r.prediction.ranked.prefix(3)) { item in
                VStack {
                    Text(displayLabel(item.label)).font(.callout)
                    Text(String(format: "%.2f", item.score)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
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
