import AppKit
import Foundation
import LouVoiceCore

/// `LouVoice --smoke`: drives the real app flow on the simulator (M3) — enrollment with re-seat
/// breaks, evaluation, then decoding with nod confirmation — prints a summary and quits.
/// Run with LOUVOICE_DATA_DIR pointing at a throwaway folder.
@MainActor
struct SmokeTest {
    let model: AppModel

    func run() {
        model.cues.muted = true
        Task { @MainActor in
            let words = ["yes", "banana", "hello", "stop"]
            log("smoke: source=\(model.hub.source.rawValue) data=\(DatasetStore.directory.path)")
            model.deleteTakes { _ in true }

            // 1. Enrollment: 2 blocks × 2 reps × 4 words + 2 non-word prompts per block.
            let e = model.enrollment
            e.start(words: words, reps: 2, blocks: 2, noisePerBlock: 2)
            while e.isRunning {
                if case .blockBreak = e.phase { log("smoke: block break → re-seat + continue"); e.continueAfterBreak() }
                try? await Task.sleep(for: .milliseconds(200))
            }
            let counts = Dictionary(grouping: model.dataset.takes, by: \.label).mapValues(\.count)
            log("smoke: enrollment phase=\(e.phase) takes=\(model.dataset.takes.count) \(counts.sorted { $0.key < $1.key }) re-takes=\(e.rejected)")
            let tt = e.score(quiz: false), qz = e.score(quiz: true)
            log("smoke: live test-then-train \(tt.correct)/\(tt.total), quiz \(qz.correct)/\(qz.total), training=\(model.dataset.trainingTakes.count) quiz-takes=\(model.dataset.testTakes.count)")

            // 2. Evaluation.
            model.runEvaluation()
            while model.isEvaluating { try? await Task.sleep(for: .milliseconds(100)) }
            if let q = model.quizScore { log("smoke: held-out quiz score \(q.correct)/\(q.total)") }
            if let r = model.evaluation {
                log(String(format: "smoke: evaluation %@ accuracy=%.2f words=%.2f none=%@ p=%.3f blocks=%d",
                           r.mode.rawValue, r.accuracy, r.wordAccuracy, percent(r.noneRecall), r.pValue, r.blockCount))
            } else {
                log("smoke: evaluation produced no report")
            }

            // 3. Auto-tune on the recorded takes.
            model.runAutoTune()
            while model.isTuning { try? await Task.sleep(for: .milliseconds(100)) }
            if let best = model.tuneTrials.first {
                log(String(format: "smoke: auto-tune %d trials, best %.2f: %@", model.tuneTrials.count, best.accuracy, best.config.summary))
            }

            // 4. Decode with nod confirmation.
            while model.classifier == nil || model.isTraining { try? await Task.sleep(for: .milliseconds(100)) }
            let d = model.decoder
            var correct = 0
            let trials = words + words.prefix(2)
            for word in trials {
                d.simulatedWord = word
                d.trigger()
                while d.phase == .recording || d.phase == .thinking { try? await Task.sleep(for: .milliseconds(50)) }
                if d.isConfirming {
                    d.simulateGesture(.nod)
                    while d.isConfirming { try? await Task.sleep(for: .milliseconds(50)) }
                }
                if let r = d.results.first {
                    let got = r.prediction.best?.label ?? "?"
                    if got == word && r.outcome != .discarded { correct += 1 }
                    log("smoke: decode said=\(word) got=\(got) outcome=\(r.outcome.rawValue) gesture=\(d.lastGesture?.rawValue ?? "-")")
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            let confirmed = model.dataset.takes.filter { $0.block.hasPrefix("confirmed-") }.count
            log("smoke: decode \(correct)/\(trials.count) correct, \(confirmed) confirmed takes added to training")
            log("smoke: transcript=\"\(d.transcript)\"")
            log("smoke: done")
            try? await Task.sleep(for: .milliseconds(500))   // let the dataset save finish
            NSApp.terminate(nil)
        }
    }

    private func log(_ s: String) {
        print(s)
        fflush(stdout)
    }
}
