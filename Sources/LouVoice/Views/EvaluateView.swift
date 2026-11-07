import LouVoiceCore
import SwiftUI

struct EvaluateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button(model.isEvaluating ? "Evaluating…" : "Run evaluation") { model.runEvaluation() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isEvaluating || model.dataset.takes.isEmpty)
                    if model.isEvaluating { ProgressView(value: model.evaluationProgress).frame(width: 160) }
                    Spacer()
                    Text("\(model.dataset.trainingTakes.count) training + \(model.dataset.testTakes.count) quiz takes · \(model.blocks.count) blocks")
                        .foregroundStyle(.secondary)
                }

                if let r = model.evaluation {
                    ReportView(report: r)
                }
                if !model.dataset.testTakes.isEmpty {
                    SectionCard(title: "Quiz takes (held out, never trained on)") {
                        if let q = model.quizScore {
                            HStack(spacing: 12) {
                                MetricTile(title: "Quiz accuracy", value: percent(Double(q.correct) / Double(max(q.total, 1))),
                                           detail: "\(q.correct)/\(q.total) takes vs the model trained on everything else", emphasis: true)
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(q.perLabel.keys.sorted(), id: \.self) { label in
                                        let (c, t) = q.perLabel[label]!
                                        HStack {
                                            Text(displayLabel(label)).frame(width: 90, alignment: .leading)
                                            AccuracyBar(rate: Double(c) / Double(max(t, 1)))
                                            Text("\(c)/\(t)").font(.caption.monospacedDigit()).frame(width: 36)
                                        }
                                    }
                                }
                            }
                        } else {
                            Text("Run evaluation to score the \(model.dataset.testTakes.count) quiz takes.").foregroundStyle(.secondary)
                        }
                        Button("Use quiz takes for training too") { model.promoteQuizTakes() }
                        Text("More data is the biggest lever. Promote quiz takes once you've read their score.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if !model.isEvaluating {
                    Text("Holds out one whole enrollment block at a time (re-seat between blocks), so the number reflects real use, not back-to-back repeats.")
                        .foregroundStyle(.secondary)
                }

                SectionCard(title: "Blocks") {
                    if model.blocks.isEmpty { Text("No takes yet. Run an enrollment.").foregroundStyle(.secondary) }
                    ForEach(model.blocks, id: \.self) { block in
                        HStack {
                            Text(block).font(.callout.monospaced())
                            Spacer()
                            Text("\(model.dataset.takes.filter { $0.block == block }.count) takes").foregroundStyle(.secondary)
                            Button { model.deleteTakes { $0.block == block } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                    if !model.blocks.isEmpty {
                        HStack {
                            Button("Show dataset in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([DatasetStore.url(simulated: model.isSimulated)])
                            }
                            Spacer()
                            Button("Delete all takes", role: .destructive) { model.deleteTakes { _ in true } }
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Evaluate")
    }
}

private struct ReportView: View {
    var report: EvaluationReport

    var body: some View {
        let r = report
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                MetricTile(title: r.mode == .leaveBlockOut ? "Leave-one-block-out accuracy" : "Leave-one-out (only 1 block!)",
                           value: percent(r.accuracy), detail: "Goal: ≥ 90% on 8 words", emphasis: true)
                MetricTile(title: "Words only", value: percent(r.wordAccuracy))
                MetricTile(title: "Non-word rejected", value: percent(r.noneRecall),
                           detail: r.falseAcceptRate.map { "False accepts \(percent($0)) · goal ≤ 10%" })
            }
            HStack(spacing: 12) {
                MetricTile(title: "Optimistic (within block)", value: percent(r.optimisticAccuracy),
                           detail: "Inflated by back-to-back repeats; shown for contrast", dimmed: true)
                MetricTile(title: "Chance", value: percent(r.chance), detail: "Majority class")
                MetricTile(title: "p-value", value: r.pValue < 0.001 ? "< 0.001" : String(format: "%.3f", r.pValue),
                           detail: "\(r.permutations) label shuffles; p < 0.05 means the signal is real")
            }
            if r.mode == .leaveOneOut {
                Label("Only one block recorded. Enroll at least 2 blocks with a re-seat between them for an honest number.",
                      systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }

            HStack(alignment: .top, spacing: 16) {
                SectionCard(title: "Per word") {
                    ForEach(r.labels, id: \.self) { label in
                        let acc = r.perLabelAccuracy[label] ?? 0
                        HStack {
                            Text(displayLabel(label)).frame(width: 110, alignment: .leading)
                            GeometryReader { g in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(acc >= 0.9 ? Color.green : acc >= 0.7 ? Color.orange : Color.red)
                                    .frame(width: g.size.width * acc)
                            }
                            .frame(height: 10)
                            Text(percent(acc)).monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                SectionCard(title: "Most confused (swap one of these words)") {
                    if r.confusedPairs.isEmpty { Text("No confusions.").foregroundStyle(.secondary) }
                    ForEach(r.confusedPairs.prefix(6)) { pair in
                        HStack {
                            Text("\(displayLabel(pair.a)) ↔ \(displayLabel(pair.b))")
                            Spacer()
                            Text("×\(pair.count)").foregroundStyle(.secondary)
                        }
                    }
                }
            }

            SectionCard(title: "Confusion matrix (rows = said, columns = decoded)") {
                ConfusionGrid(labels: r.labels, confusion: r.confusion)
            }
        }
    }
}

private struct ConfusionGrid: View {
    var labels: [String]
    var confusion: [[Int]]

    var body: some View {
        let maxValue = max(1, confusion.flatMap { $0 }.max() ?? 1)
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                Text("")
                ForEach(labels, id: \.self) { Text(short($0)).font(.caption2).rotationEffect(.degrees(-35)).frame(width: 40, height: 34) }
            }
            ForEach(labels.indices, id: \.self) { i in
                GridRow {
                    Text(displayLabel(labels[i])).font(.caption).frame(width: 100, alignment: .trailing)
                    ForEach(labels.indices, id: \.self) { j in
                        let v = confusion[i][j]
                        Text(v == 0 ? "" : "\(v)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 40, height: 26)
                            .background((i == j ? Color.green : Color.red).opacity(v == 0 ? 0.04 : 0.15 + 0.6 * Double(v) / Double(maxValue)))
                    }
                }
            }
        }
    }

    private func short(_ s: String) -> String { s == noneLabel ? "none" : String(s.prefix(7)) }
}
