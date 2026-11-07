# LouVoice — Proof-of-Technology Plan

**Goal:** show that AirPods Pro 2 head-motion data alone can recognise a small set of silently mouthed words, accurately enough for a live demo.

**Hard constraints**
- Only hardware: AirPods Pro 2 plus the Mac they're paired with.
- Motion only: **no microphones, no webcam**, no speech recognition.
- Delivered as a **native macOS app**. A website is used only as a landing and download page. This changed from web app to native; see D18.

**Build approach:** do the simplest thing now, using Swift Package Manager with no Xcode project. Move to an Xcode project for the polished app (D19).

Reasoning for each choice is in [DECISIONS.md](DECISIONS.md).

---

## 1. Architecture

```
AirPods Pro 2 ──BT──▶ LouVoice.app (SwiftUI, macOS 14+)
                        ├─ MotionService      CMHeadphoneMotionManager @ ~25 Hz, own serial queue
                        ├─ LouVoiceCore       pure Swift: pipeline, recognizer, evaluation, gestures
                        ├─ Enrollment / Evaluate / Decode / Sensors screens
                        ├─ CueService         beeps + optional spoken prompt (output only)
                        ├─ StemPress          MPRemoteCommandCenter (AirPods stem → capture)
                        ├─ Simulator          fake AirPods source for testing without hardware
                        └─ DatasetStore       JSON in ~/Library/Application Support/LouVoice
```

One process with no sockets or browser. Motion goes straight into the recognizer.

### Package layout (SwiftPM, builds with Command Line Tools)
```
Package.swift
Sources/
  LouVoiceCore/          no UI, no CoreMotion — fully testable
    Math.swift           vectors, quaternions, seeded RNG
    Signal.swift         resample to 25 Hz grid, zero-phase Butterworth high-pass
    Features.swift       re-seat canonicalisation → 9 features → trim
    DTW.swift            banded multivariate DTW with early abandon
    Augment.swift        rotation / time-warp / scale / jitter
    Classifier.swift     k-NN DTW (mean of k best per class), `_none`, active-word filter
    Evaluation.swift     leave-one-block-out + permutation test + optimistic contrast
    Gestures.swift       nod / shake detector
    Quality.swift        per-take checks (dropout, head moved, too weak)
    Simulator.swift      synthetic motion (shared by the app and the tests)
  LouVoice/              SwiftUI app
    App.swift, AppModel.swift
    MotionService.swift, StemPress.swift, CueService.swift, DatasetStore.swift
    Views/ SensorsView, EnrollView, EvaluateView, DecodeView
  LouVoiceCheck/         command-line self-test runner (fallback if `swift test` can't run on CLT)
Tests/LouVoiceCoreTests/
Resources/Info.plist     NSMotionUsageDescription, LSMinimumSystemVersion
scripts/build-app.sh     swift build → wrap into LouVoice.app → ad-hoc codesign
```

`scripts/build-app.sh` exists because macOS only shows the Motion permission prompt for a real `.app` bundle with `NSMotionUsageDescription`. A bare `swift run` binary won't get motion data.

---

## 2. Signal pipeline (per captured segment)

1. **Resample** to a uniform 25 Hz grid using the timestamps. Linear interpolation for vectors, nlerp for quaternions. Record the largest gap between samples.
2. **Re-seat / posture canonicalisation:**
   - Take the mean gravity over the ~0.3 s rest pre-roll.
   - Find the rotation `R` that takes it onto `[0,0,-1]`.
   - Rotate acceleration and rotation rate by `R`.
   - Attitude becomes the rotation vector of `q0⁻¹·q(t)`, also rotated by `R`.
3. **High-pass** each of the 9 channels with a zero-phase 2nd-order Butterworth filter at about 0.8 Hz (reflect-padded).
4. **Trim** to the active part using a segment-relative energy threshold (`|ω| + 5|a|`), keeping 2 frames of padding.
5. **Scale** each channel by its standard deviation over the *training* fold only.

`sensorLocation` (which earbud) is iOS-only, so on macOS takes record `unknown` (D21). Energy is smoothed over ~0.2 s before trimming, with a 25% threshold (D22).

## 3. Recognizer

- **References:** every real take plus 4 augmented copies of it:
  - random rotation up to ±12°
  - time-warp ×0.85–1.15
  - amplitude ×0.9–1.1
  - jitter
  - The RNG is seeded, and copies are made only from the training fold.
- **Distance:** dependent multivariate DTW with a Sakoe–Chiba band of 20% (at least `|n−m|`), normalised by `n+m`, with early abandon.
- **Class score:** the mean of the k=3 smallest distances.
- **`_none` class:** chew, swallow, head turn, nod, smile, look up. A segment is **accepted** only if:
  - the best class isn't `_none`, and
  - the score is at most `maxScore`, and
  - the margin `1 − s1/s2` is at least `minMargin`.
- **Active words** (context constraint) limit decoding to a subset, plus `_none`.
- Prediction runs off the main thread.

## 4. Evaluation (the honesty layer)

- **Main number: leave-one-block-out.** A block is one enrollment pass, with a re-seat between blocks.
- **Contrast number:** leave-one-out within a block, labelled "optimistic".
- **Permutation test:** 200 label shuffles reusing the precomputed distances, giving a p-value. The baseline is the majority-class rate.
- **Output:**
  - overall and word-only accuracy
  - `_none` recall and false-accept rate
  - per-word accuracy and confusion matrix
  - **most-confused pairs**
- Runs as a background `Task`.

## 5. Enrollment UX

1. **Rest calibration:** 2 s still, which sets the noise floor.
2. **Blocks:** 3 by default. Each has every word ×3 reps plus 4 `_none` prompts, in random order.
3. **Per prompt:** show the word (optionally spoken through the AirPods), pause 0.7 s, beep, record a fixed 1.8 s window (with 0.3 s pre-roll), then an end tone. Decode uses the same window.
4. **Quality gate:** a failed take is re-queued with a reason. A take fails if:
   - motion dropped out (gap > 150 ms), or
   - the head moved (> 15° rotation), or
   - the movement was too weak (peak below 2.5× the noise floor).
5. **Between blocks:** "Take out both AirPods, put them back in, press Continue."
6. **Coaching:** "Exaggerated jaw, like talking through glass. Keep your head still."
7. **Default vocabulary (editable):** `hello, can, you, hear, me`, so the demo phrase is "hello can you hear me" (D28).

## 6. Decode UX

- **Trigger:** press Space or the **AirPods stem**. Either one starts the same timed beep → 1.8 s window.
  - The stem press uses `MPRemoteCommandCenter`, with the app set as "now playing" through `MPNowPlayingInfoCenter`. A silent audio loop is added only if macOS needs it.
- **Result display:** the top word, the top-3 scores and the margin, optionally spoken back.
- **Confirm window (3 s):** **nod** = accept (added to the training set as a "confirmed" block), **shake** = reject. Y/N keys do the same.
- **Active-words checklist** for context screens. The transcript shows accepted words.

## 7. Simulator

A synthetic AirPods source inside `LouVoiceCore` that can be switched on in the app.
- Each word gets a signature from its syllable count and how open its vowels are.
- Each take varies in timing, amplitude and onset.
- It can simulate a re-seat rotation, `_none` behaviours and nod/shake.
- The tests use it too, and it is labelled: **simulator accuracy means nothing.**

---

## 8. Milestones & acceptance

**Status (2026-11-07):** M1 ✅, M2 ✅ (streams at 50 Hz), M3 ✅ (`--smoke`). **M4 first real session: 59 takes, leave-block-out 49% at the original defaults, 68% after tuning** (D30); chance is 20%, p = 0.005. Session 2 (after a reset): 42% words alone, **61% words with both sessions pooled**, and models don't transfer across days (D33). Now in progress: M5, accumulating sessions rather than resetting.

| # | Milestone | Done when |
|---|---|---|
| M1 | `LouVoiceCore` + tests | Tests pass (via `swift test`, or `swift run LouVoiceCheck` on CLT), covering: resampling handles gaps; a seat rotation is undone; the high-pass filter removes DC and drift; DTW identical = 0 and tolerates time-warp; the classifier separates simulated words; evaluation gives p < 0.01 with signal and p > 0.05 on noise; nod and shake are detected. |
| M2 | App shell + motion | `scripts/build-app.sh` produces `LouVoice.app`; the Motion prompt appears; the Sensors screen shows about 25 Hz live data and which earbud is reporting. |
| M3 | Full flow on the simulator | Enroll → Evaluate → Decode works end to end with the simulator source. |
| M4 | Real AirPods data | One person, 8 words × 3 blocks × 3 reps, plus noise takes. Report leave-block-out accuracy and the optimistic number. |
| M5 | Vocabulary tuning | Swap confused words until **leave-block-out ≥ 90% on 8 words** with `_none` false accepts ≤ 10%. This is a goal; M4 tells us if it's realistic. |
| M6 | Demo polish | Stem-press trigger, nod/shake confirm, context screens, a "teach a new word in 3 takes" flow. |
| M7 | Polished app (Xcode) | Move to an Xcode project; app icon, onboarding, a Developer ID–signed and notarized `.dmg` (see §10). |

## 9. Demo plan

- **The main demo: 8–10 fixed words picked for distinct jaw patterns.** Do a live re-seat in front of the audience to prove the re-seat fix works.
- **Context screens:** only 3–5 words valid at a time.
- **"Teach it a new word":** 3 takes, live.
- **Explicitly not claimed:** open vocabulary, or words it has never been trained on.
- Runs on your own Mac, so nobody in the audience installs anything, and the ad-hoc–signed build is enough.

## 10. Distribution (how users get the app)

| Stage | How | User experience |
|---|---|---|
| Proof of concept / demo | `scripts/build-app.sh`, ad-hoc signed, run locally | Only on our machines; no install friction because we built it. |
| Teammates / testers | Zip or `.dmg` of the ad-hoc build | macOS blocks the first open: System Settings › Privacy & Security › **Open Anyway**. Acceptable for a few people. |
| Public beta (M7) | Xcode build signed with **Developer ID** + **notarized**, shipped as a `.dmg`; optional Homebrew cask | Download, drag to Applications, open, allow Motion. No warnings. Needs the Apple Developer Program ($99/yr). |
| Later, maybe | Mac App Store | Requires sandboxing and review; not needed until then. |

The website becomes a landing page: what LouVoice is, a demo video and a **Download for Mac** button.

**First-run flow in the app:**
1. A welcome screen, then "Connect your AirPods Pro" (it detects the connection).
2. The Motion permission prompt.
3. A short guided enrollment (about 10 minutes).
4. A ready screen showing the accuracy from the evaluation.

## 11. Risks & open questions

- **Tests on Command Line Tools:** `swift test` may not run without Xcode. The fallback is the `LouVoiceCheck` runner. Xcode is being installed, which removes this risk.
- **Motion permission with an ad-hoc-signed bundle:** must be launched via `open`/Finder (D27); the real prompt with AirPods is still unverified. If it doesn't, sign with a free Apple ID development certificate in Xcode.
- **Stem press on macOS:** routing through `MPRemoteCommandCenter` needs the app to be "now playing"; verify in M6. Space is the fallback.
- **Real sample rate and jitter:** measure in M2 (subvox reports about 25 Hz).
- **Signal ceiling:** jaw motion at 25 Hz may cap accuracy below target. M4 decides early.
- **Later, if needed:** MiniRocket + ridge classifier in place of k-NN DTW, plus derivative features.

## 12. Running (once built)

```bash
swift run LouVoiceCheck        # core checks (swift test once Xcode is installed)
swift run LouVoiceCheck --sim-eval            # simulated leave-block-out benchmark
scripts/build-app.sh           # builds build/LouVoice.app
open build/LouVoice.app
```

## Credits

The approach builds on [joeblau/subvox](https://github.com/joeblau/subvox) (MIT): a native SwiftUI app doing template DTW plus a permutation test on `CMHeadphoneMotionManager` data. If any of its code is reused, its MIT notice must come with it.
