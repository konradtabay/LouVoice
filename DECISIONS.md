# Technical Decision Log

Each entry records what was decided, why, what else was considered, and its status. New entries go at the bottom. When a decision changes, add a new entry that supersedes the old one; don't edit history.

---

### D1: Sensors: AirPods head motion only (2026-11-07)
**Decision:** The only input is `CMHeadphoneMotionManager` data: user acceleration, rotation rate, gravity, attitude quaternion and Euler angles, and sensor location. No microphones, no webcam.
**Why:** This was the product constraint: the proof has to rest on silent, camera-free sensing from AirPods alone. It also keeps the demo claim clean ("motion only").
**Considered:** Using the mic for whisper fusion or auto-labelling, and the webcam for lip landmarks as a training teacher. Both would raise accuracy or cut labelling effort, but both are out of scope by choice.
**Consequence:** Labels come from prompted enrollment, since we know which word was prompted. Accuracy is capped by how much jaw motion shows up at about 25 Hz.

### D2: Web app + native motion bridge (2026-11-07)
**Decision:** The UI and all the logic run in the browser. A minimal Swift menu-bar app streams motion over a localhost WebSocket and serves the web files.
**Why:** It has to be a web app, but no browser API exposes headphone motion (the device-motion web API covers the device's own sensors, not AirPods). A native component is the only path. Keeping it "dumb" means one small file to maintain, while everything else can iterate fast, be tested in Node and be hosted later.
**Considered:**
- A fully native SwiftUI app like subvox: not a web app.
- An iOS app relaying to the web: needs an iPhone, which is extra hardware.
- Electron with a native module: heavy, and still needs native code.

### D3: Build the bridge with Command Line Tools, not Xcode (2026-11-07)
**Decision:** Compile one `main.swift` with `swiftc`, wrap it into a `.app` bundle with a hand-written `Info.plist`, and ad-hoc sign it.
**Why:** Xcode isn't installed on the dev machine. macOS needs a bundle with `NSMotionUsageDescription` before it will show the Motion permission prompt; a bare binary isn't enough.
**Risk:** Motion permission under ad-hoc signing is unverified (open question in PLAN §10).

### D4: Bridge security: loopback only, Origin check (2026-11-07)
**Decision:** Bind both listeners to loopback. Reject WebSocket upgrades whose `Origin` isn't `localhost` or `127.0.0.1`.
**Why:** Head motion is biometric-adjacent data. Without an Origin check, any website open in the browser could connect to `ws://localhost` and read it.

### D5: Plain ES modules, no build step, no dependencies (2026-11-07)
**Decision:** The web app is vanilla JS modules. Tests use the built-in `node --test`.
**Why:** It's a proof of concept: zero install, nothing to break, and the same core files run in the browser, in Workers and in Node. TypeScript or a framework can come later if it grows.

### D6: Resample to a uniform 25 Hz grid (2026-11-07)
**Decision:** Interpolate every segment onto a fixed time grid using the device timestamps before extracting features.
**Why:** subvox treats each sample as one frame. Bluetooth jitter and dropped samples then look like the word was said faster or slower, which corrupts matching. Resampling makes frame index mean time. The largest gap is kept for the quality gate.

### D7: Gravity-based re-seat canonicalisation (2026-11-07)
**Decision:** Rotate each segment so its rest-period gravity points to `[0,0,-1]`. Represent attitude as the rotation since the start of the segment, in that frame.
**Why:** Re-seating an earbud rotates the sensor axes, and subvox lists this as a known failure. Gravity at rest measures that rotation directly and for free. The one thing it can't see, rotation about the gravity axis, is covered by rotation augmentation (D9).
**Considered:** Per-session recalibration takes only: still useful as a top-up, but it costs user time every session.

### D8: Zero-phase high-pass at ~0.8 Hz (2026-11-07)
**Decision:** A 2nd-order Butterworth filter run forward and backward with reflect padding, on all 9 channels.
**Why:** Jaw articulation sits roughly in the 1.5–8 Hz range. Posture drift, slow head movement and attitude wander sit below 1 Hz and dominate the raw signal. Running the filter both ways means it doesn't shift timing, which DTW is sensitive to.
**Considered:** Mean-centring only, as in subvox: it leaves the drift in.

### D9: Augmentation at feature level (2026-11-07)
**Decision:** 4 copies per real take: rotation up to ±12°, time-warp ×0.85–1.15, amplitude ×0.9–1.1, jitter. The RNG is seeded.
**Why:** Few takes per word is the main data bottleneck. Rotation simulates re-seating, time-warp simulates speaking rate, and amplitude simulates effort. Applying it to features is valid because the pipeline is roughly linear under rotation, and it's cheap. Augmented copies are only ever generated from the *training* fold.

### D10: k-NN DTW, mean of the 3 best per class (2026-11-07)
**Decision:** Keep DTW, as in subvox, but score each class by the mean of its k=3 nearest references instead of the single nearest one. Add early abandon.
**Why:**
- DTW works with very little data and needs no training step, so teaching a new word in 3 takes is immediate.
- Using the single nearest match lets one bad take win.
- At this scale speed isn't an issue: about 500 references × 50×10 band cells is a few milliseconds.

**Considered:** MiniRocket + ridge classifier, likely stronger, kept as an M5 fallback; a small CNN, too data-hungry for one person; Create ML Activity Classifier, native-only.

### D11: An explicit `_none` class instead of thresholds alone (2026-11-07)
**Decision:** Enrollment includes prompted non-word movements (chew, swallow, turn, nod, smile, look up). A segment is rejected when `_none` wins.
**Why:** subvox's distance and margin limits are hand-tuned and fragile. A learned "not a word" class rejects real-world motion much more reliably. Nods are included so the confirm gesture never gets decoded as a word.

### D12: Leave-one-block-out as the headline metric (2026-11-07)
**Decision:** A block is one enrollment pass with a re-seat between passes. The main accuracy holds out whole blocks; within-block leave-one-out is shown only as a labelled "optimistic" contrast. Per-channel scaling is computed on the training fold only. A permutation test gives the p-value.
**Why:** Takes recorded back to back are nearly identical, so leave-one-out inflates accuracy. That makes it impossible to tell whether a pipeline change really helped. Holding out blocks also tests re-seat robustness.

### D13: Fixed timed capture window for enrollment *and* decode (2026-11-07)
**Decision:** Beep, then 1.8 s of recording with a 0.3 s pre-roll, in both modes. There's no auto-detect in the proof of concept.
**Why:**
- If training and use segment differently, accuracy drops quietly.
- A fixed rhythm gives consistent onsets.
- The pre-roll provides the rest gravity needed by D7.
- Auto-detect adds false triggers before `_none` is proven.

### D14: Quality gate with re-queue (2026-11-07)
**Decision:** Reject a take if motion dropped out (gap > 150 ms), the head rotated > 15°, or the peak is below 2.5× the rest noise floor. Re-queue it at the end of the block.
**Why:** Bad takes poison k-NN and the evaluation. Catching them at capture time with a clear reason is cheaper than cleaning data later, and it coaches the user.

### D15: Hands-free UX: stem press + nod/shake (2026-11-07)
**Decision:**
- The AirPods stem press triggers capture through the browser's Media Session API, with Space as a fallback.
- Nod accepts and shake rejects, detected from attitude pitch and yaw.
- Accepted decodes are added as training takes.

**Why:** It makes the demo hands-free and AirPods-only, and confirmations become free labelled data, a form of continuous learning.
**Risk:** Stem-press routing to a browser tab on macOS is unverified. Fallback: the bridge forwards media keys.

### D16: Demo scope: fixed, context-constrained vocabulary (2026-11-07)
**Decision:**
- Demo 8–10 words chosen for distinct jaw patterns.
- Show context screens where only 3–5 words are active at a time.
- Show a live "teach a new word in 3 takes" moment.
- Make no open-vocabulary claim.

**Why:**
- At 25 Hz the sensor mostly sees jaw opening over time; lips and tongue are invisible, so many words look the same.
- The best published earable result (MuteIt, 100 words) needed a jaw-mounted dual raw IMU plus phoneme models.
- Context constraint raises usable vocabulary without lowering accuracy.

### D17: In-browser simulator (2026-11-07)
**Decision:** A synthetic AirPods source with word signatures based on syllables and vowel openness, re-seat rotations, noise behaviours and nod/shake.
**Why:** It lets the full UI flow be developed and verified without hardware or a person in the loop. It is labelled so nobody mistakes simulated accuracy for evidence.

### D18: Native macOS app instead of web app + bridge (2026-11-07). *Supersedes D2, D4, D5; D17 still applies.*
**Decision:** Build LouVoice as a single native SwiftUI macOS app. A website is used only as a landing and download page.
**Why:**
- A native component had to be installed anyway, because browsers can't read AirPods motion. So the web app's main advantage, nothing to install, never applied.
- Going native removes a second running process, the localhost WebSocket and Origin checks, and Safari's blocking of localhost from https pages.
- It also removes background-tab throttling, which would quietly break capture timing and audio cues.
- The stem press works through the normal native API (`MPRemoteCommandCenter`) rather than the uncertain browser Media Session route.
- subvox, our reference, is already a native SwiftUI app.

**Considered:** Keeping the web UI with the bridge. Its advantages are fast UI changes and shareable links; the costs are listed above.
**Consequence:** The pipeline, recognizer, evaluation and UX plans are unchanged; they move from JavaScript to Swift (`LouVoiceCore`). The D4 security work isn't needed, since no ports are opened.

### D19: Swift Package Manager now, Xcode project for the polished app (2026-11-07)
**Decision:** For the proof of concept, use a SwiftPM package: a `LouVoiceCore` library, a `LouVoice` app executable and a `LouVoiceCheck` runner. A script wraps the binary into an ad-hoc–signed `.app`. Move to an Xcode project at M7.
**Why:**
- It's the simplest thing that works right now.
- It builds with Command Line Tools while Xcode downloads.
- Files are plain text and easy to review, with no project file to merge.
- Keeping the core free of UI and CoreMotion makes it fully testable.
- Xcode adds value later, for signing, notarization, asset catalogs and profiling, which is polish work.

**Risk:** `swift test` may not run on Command Line Tools alone. `LouVoiceCheck` covers that until Xcode is installed.

### D20: Distribution path (2026-11-07)
**Decision:**
- Demo and proof of concept: ad-hoc–signed local builds.
- Testers: a zip of that build (they click "Open Anyway" once).
- Public beta: a Developer ID–signed, notarized `.dmg`, optionally a Homebrew cask.
- No Mac App Store until there's a reason.

**Why:** Each step only pays for what's needed. The Apple Developer Program ($99/yr) only matters once outside people install the app. The demo runs on our own Mac, so nobody in the audience installs anything.

### D21: No earbud identity on macOS (2026-11-07). *Amends D1 and PLAN §2.*
**Decision:** Takes record `location = unknown` on the Mac. The plan to tag each take with the reporting earbud is dropped for the macOS app.
**Why:** The SDK marks `CMDeviceMotion.sensorLocation` as available on iOS 14+ only (`API_AVAILABLE(ios(14.0))` in `CMDeviceMotion.h`); there is no macOS equivalent. The data model keeps the field, so an iOS build could fill it later.
**Consequence:** An earbud switch mid-session can't be detected directly. Gravity canonicalisation (D7) and rotation augmentation (D9) partly absorb it. If real data shows sudden shifts, add a detector for jumps in rest gravity between takes.

### D22: Smooth the energy before trimming (2026-11-07). *Amends PLAN §2 step 4.*
**Decision:** Apply a 5-frame (~0.2 s) moving average to per-frame energy before thresholding, and raise the threshold from 15% to 25% of the floor-to-peak range.
**Why:** Building it showed raw energy dips to zero mid-syllable (rotation rate crosses zero as the jaw turns around) and spikes on noise. Trimmed lengths ranged from 15 to 52 frames, and many windows weren't trimmed at all, so the word sat at a random offset that DTW's band couldn't absorb. On simulated data the 4-word check went from 12/24 to 24/24 correct, and leave-block-out from 90% to 100%.
**Evidence:** `swift run LouVoiceCheck --sim-eval yes banana hello stop`.

### D23: One set of self-tests, two runners (2026-11-07)
**Decision:** The M1 checks live in `LouVoiceCore/SelfTests.swift`. `swift run LouVoiceCheck` runs them on Command Line Tools; `swift test` wraps the same checks in XCTest once Xcode is installed. `LouVoiceCheck --sim-eval [words…]` runs a leave-block-out evaluation on simulated words.
**Why:** Without Xcode there's no XCTest, but the checks must run now. A single definition avoids two test suites drifting apart. `--sim-eval` turned out to be the fastest way to debug the pipeline (it found D22).

### D24: `--smoke` end-to-end run of the real app (2026-11-07)
**Decision:** `LouVoice --smoke` drives the app's actual Enrollment, Evaluation and Decoder code on the simulator (re-seat breaks, quality gate, nod confirmation), prints a summary and quits. Data goes to `LOUVOICE_DATA_DIR`.
**Why:** It verifies M3 without clicking through the UI, and is repeatable after every change. Unit tests cover the core; this covers the wiring between screens, timing and capture.

### D25: Separate datasets for the simulator and real AirPods (2026-11-07)
**Decision:** `dataset.json` holds real data and `dataset-simulated.json` holds simulator data. Switching the source swaps datasets.
**Why:** Simulated takes mixed into real training data would silently corrupt the evaluation, which is the one number the proof depends on.

### D26: Unconfirmed decodes stay out of training (2026-11-07). *Refines D15.*
**Decision:** Only a nod (or Y) adds a decode to training. If the 3 s confirmation window expires, the word goes into the transcript but not the dataset. Confirmed takes go into a per-day `confirmed-YYYYMMDD` block.
**Why:** A wrong prediction added as training data reinforces itself. Keeping confirmed takes in their own block means evaluation still holds them out as a unit.

### D27: Launch through LaunchServices; never touch CoreMotion in simulator mode (2026-11-07)
**Decision:** Always start the app with `open build/LouVoice.app` (or Finder), never by running the binary directly. Create `CMHeadphoneMotionManager` lazily, only when the AirPods source is selected. `--smoke` and `LOUVOICE_SOURCE=simulator` start on the simulator from `init`.
**Why:** The first smoke run was killed with `__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__` inside CoreMotion. Run directly from a terminal, macOS holds the *parent* process responsible for the Motion permission. That parent has no `NSMotionUsageDescription`, so the system aborts the app. Launched with `open`, LouVoice itself is responsible and its Info.plist applies. Separately, the hub had been creating and stopping the motion manager even in simulator mode, which needlessly triggered the permission check.
**Consequence:** Smoke command: `open -W -n --env LOUVOICE_DATA_DIR=… build/LouVoice.app --args --smoke`.

### D28: Demo vocabulary is "hello can you hear me" (2026-11-07). *Replaces the default word list in PLAN §5.*
**Decision:** The default vocabulary is the five words `hello, can, you, hear, me`. Each is enrolled and decoded on its own; the demo phrase is built by decoding the words one after another into the transcript.
**Why:** Product choice: a natural first sentence for a silent-speech demo. Five classes (plus `_none`) also make enrollment shorter, about 6 minutes for 3 blocks × 3 reps.
**Risk:** Four of the five are single-syllable words with small jaw movement. The simulator already confuses `can↔you` and `me↔you` (80% on words, leave-block-out, simulated); real data may well do the same. Mitigations, in order: exaggerate the jaw ("talking through glass"), add reps for the confused pairs, then use context screens so only the expected next word or two are active.

### D29: Every pipeline variable is tunable, with auto-tune on real takes (2026-11-07)
**Decision:** The feature and recognizer settings are collected into one `PipelineConfig`, persisted in UserDefaults. A new **Tune** screen exposes each one:
- sample rate and high-pass cutoff
- re-seat correction on/off and channel groups
- trim on/off, trim threshold, smoothing and padding
- k, augmented copies, augment rotation and time-warp, DTW band
- capture window and pre-roll

Changing a setting re-extracts features from the stored raw samples and retrains, so it takes effect on existing data immediately. **Auto-tune** is a greedy coordinate search: each variable in turn, scored by leave-one-block-out on your takes, keeping the best, two passes. `LouVoiceCheck --eval <dataset.json> [--tune]` does the same from the command line.
**Why:** The first real session scored 49% on held-out blocks. Fixed defaults chosen from the simulator were never going to be right for real jaw motion. Raw samples are stored, so every setting can be re-tested on recorded data without re-recording.
**Caveat:** Picking the best of about 60 trials on the same 59 takes is optimistic. With about 9 takes per word, one take moves a word's score by about 11 points, so differences under about 5 points are noise. Confirm with quiz takes (D31).

### D30: New defaults from the first real session (2026-11-07). *Amends D6 and D8.*
**Decision:** Resample at 25 Hz with the high-pass at **1.6 Hz** (was 0.8 Hz), and **8** augmented copies (was 4). Everything else unchanged.
**Evidence** (59 real takes, 3 blocks plus 2 confirmed decodes, leave-one-block-out):

| Settings | Accuracy | Words | Non-word rejected |
|---|---|---|---|
| Original (0.8 Hz, ×4) | 49% | 51% | 42% |
| New defaults | 68% | 66% | 75% |

Chance is 20%, and p = 0.005 in both cases, so the motion carries real word information.
**Why these, not the auto-tune winner as-is:** The two top settings found (1.2 Hz with trim 45% and k=2, at 66%, and 1.6 Hz with trim 25% and aug ×8, at 68%) are within noise of each other. The consistent signal was "high-pass well above 0.8 Hz". The chosen default changes the fewest variables from the original, which overfits least.
**Also measured:** The AirPods deliver **50 Hz** on macOS (20 ms between samples), not the 25 Hz subvox reported. Resampling at 50 Hz scored the same or slightly worse and costs 4× more DTW, so 25 Hz stays.
**Reading:** A higher cutoff means the useful information is in fast jaw motion (above about 1.5 Hz). Slower head and posture movement was drowning it.

### D31: Continuous accuracy testing during training (2026-11-07)
**Decision:**
- **Test-then-train:** during enrollment, each take passes the quality gate and is then **predicted before it's saved**, by a model trained only on *other* blocks. The Enroll screen shows live accuracy: overall, per word, last 10 and by block.
- **Quiz rounds:** optional, on by default, after each block: one take per word, predicted by the model trained on everything so far, saved with `isTest = true` and **never trained on**. There is also a standalone quiz.
- Evaluate reports the held-out quiz accuracy next to leave-one-block-out, and can promote quiz takes into training once read.

**Why:** Accuracy was only visible after the fact. Testing every take as it comes in shows immediately which words fail and whether more blocks are helping. Quiz takes are the only number untouched by tuning (D29), because they are never trained on or tuned against.
**Consequence:** Block 1 of a first session has no live score (nothing to test against yet). Quiz rounds add about 25% to session time.

### D32: Self-normalising "too subtle" check; no calibration step (2026-11-07). *Supersedes the noise-floor part of D14.*
**Decision:** A take's **strength** is its smoothed peak activity divided by its own 20th-percentile activity. The capture window is about 2 s and a word fills about 0.5 s, so the 20th percentile is the take's own rest. Word takes need strength ≥ **3×** (tunable). The "Stay still" calibration is removed from enrollment. Thresholds for strength and head movement are now on the Tune screen, and rejection messages show the measured value.
**Why:** The user hit "Too subtle" on most takes. The stored calibration floor was **0.74**, ten times the first session's 0.07: that calibration window must have caught movement. Against it, all 49 recorded word takes scored about 0.3 when 2.5 was required, so the gate would reject every real word. Raising the high-pass to 1.6 Hz (D30) also shrank word energy relative to sensor noise, which tightens a fixed floor further. A one-off calibration is a single point of failure; a per-take ratio can't be poisoned by it.
**Evidence** (`LouVoiceCheck --eval … --quality`, 66 real takes): word strength min 3.4×, p10 4.9×, median 8.3×, so **0 of 49 words** fall below 3×. Simulated still takes stay below 3× and are rejected (self-test).

### D33: Second session: pooled data matters most; new defaults (2026-11-07). *Amends D30.*
**Data:** After a reset, session 2 had 57 training takes in 3 blocks plus 15 quiz takes. Session 1 (66 takes, 6 blocks) was kept as a backup.

**Findings** (leave-one-block-out on words unless noted):
- **Session 2 at the D30 defaults scored 38% on words** (47% overall). The 68% from session 1 was partly luck and partly over-tuning to one session.
- **Models don't transfer across days.** Train on one session and test on the other: 35% and 44%, with words near chance.
- **Pooling both sessions** (123 takes, 9 blocks) gives 61% overall and 51% words at the old defaults, and up to 69% / 66% after auto-tune. Variety across sessions is what the model needs. **Future sessions should add to the data, not replace it.**
- Across pooled data and both single sessions, one setting was consistently at or near the top: **rotation + attitude only** (dropping the accelerometer), **high-pass 1.2 Hz**, **35% trim**, plus the new **magnitude channels**.

**Decision:** These are the new defaults (k=3, aug ×8 unchanged).

| Data | Old words | New words | Quiz |
|---|---|---|---|
| Pooled | 51% | 61% | 11/15 |
| Session 2 | 38% | 42% | 12/15 |
| Session 1 | 55% | 57% | n/a |

Not taken: k=1 and 50 Hz (same within noise), and the single auto-tune winner (69%), which was chosen from 83 trials.

**New options** (D33, on the Tune screen and in auto-tune):
- per-take normalisation (off / per take / per take and channel)
- rate-of-change channels
- rotation-free magnitude channels

Only magnitudes helped. `FeatureSequence.vectorDims` keeps augmentation from rotating scalar channels.

**Tools:** `LouVoiceCheck --eval A.json --merge B.json` pools sessions. `--cross B.json` trains on A and tests on B. `--candidates` compares a fixed shortlist of settings, to avoid trusting one winner.

### D34: Generated tones on a kept-alive audio engine (2026-11-07). *Refines D13 cues.*
**Decision:** Cues are short generated tones (start 880 Hz, end 587 Hz, accept rising two-tone, reject 196 Hz) played through an `AVAudioEngine` that stays running, replacing `NSSound` system sounds. The engine is rebuilt, and the speech synthesizer re-created, on `AVAudioEngineConfigurationChange` (output route change). `NSSound` remains as a fallback if the engine can't start. A **Test sound** button sits on Sensors and Enroll.
**Why:** The user stopped hearing the cues. The Mac's default output was the AirPods and the app's code hadn't changed, so the likely causes were Bluetooth-specific:
- an idle AirPods audio link takes a moment to wake and can swallow a 0.1 s system sound;
- after a Bluetooth route change, a long-lived player or synthesizer can keep pointing at the old route.

A continuously running output stream keeps the link awake, and rebuilding on route change covers the second cause.
**Not verified:** Nothing here can be heard from this side; the Test sound button is how to confirm it.

### D35: Settings have plateaued; improve the data instead (2026-11-07)
**Data:** Sessions 2 and 3 together: 115 training takes in 7 blocks, plus 30 quiz takes. All takes are strong (minimum strength 3.4×).

**Results** (leave-one-block-out):
- **Current defaults are still best:** 63% overall, **56% words**, quiz **20/30 (67%)**. Every word scores 53–61%.
- **The main confusion is me↔you** (×10). Both are short, closed-jaw words that look alike at 25 Hz.
- **Pooling sessions helps:** session 3 alone scores 47% on words, 56% together with session 2.
- **Across sessions:** train on one, test on the other, 46–47%.

**What didn't help:**
- **Low-pass filtering** (4, 6 or 8 Hz) made every setting worse (words 47–52%), so the fast part of the motion carries information. Added as an option, off by default.
- **An ensemble** of 2–5 pipelines with different high-pass cutoffs (`EnsembleClassifier`, `LouVoiceCheck --ensemble`) scored 65–66% held-out and 59–60% words, but the quiz was unchanged at 19–20/30. That's within noise, so it isn't wired into the app; the code is kept for when there's more data.

**Decision:** Improve how the data is collected, not the settings:
- **Articulation hints** per default word, shown on every prompt, so each word gets its own distinct and repeatable movement. Examples: "me" = press the lips together, then a wide smile; "you" = lips pushed forward into a tight "oo".
- **Focus words:** chosen words get +2 reps in each training block. "Pick weakest from last evaluation" selects words under 70% (or the two weakest).

### D36: Adaptive reps and contrast drills, planned per block (2026-11-07). *Extends D35.*
**Decision:** With "Adaptive reps (auto)" on (the default), each training block is planned from current accuracy:
- With 2+ blocks of data, plans use the leave-one-block-out per-word accuracy and confusions, without permutations (about 1 s). Otherwise they use this session's test-then-train results.
- Words get **+3 reps** below 50% accuracy, **+2** below 70%, **+1** below 85%.
- The **two most-confused word pairs** (each confused at least twice) get **contrast drills**: both words prompted **back to back**, ×2 per block, in random order, marked "make it clearly different from …".
- Prompts are shuffled as units so drills stay adjacent. The plan is shown on the Enroll screen and in the log. Manual focus words still add on top.

**Why:** Reps should go where the errors are. Producing two confusable words one after the other pushes you to make them distinct and consistent, and it gives the model paired examples of the boundary between them.
**On the current data** (sessions 2 and 3): every word is between 53% and 61%, so each gets +2, with drills for me↔you (confused ×10) and can↔me (×4). That makes about 37 prompts per block, roughly 2.7 minutes.

### D37: Next-word prediction from expected phrases; high-pass back to 0.8 Hz (2026-11-07)
**Data:** Session 4 (5 blocks with adaptive reps and drills, D36) brings the total to 356 takes: 280 training and 55 quiz in 12 blocks. Words rose to 63% and the quiz to 71% at the D33 settings.

**Motion defaults:** With 3× the data, **high-pass 0.8 Hz** is best. Words score **70%** and the quiz **42/55 (76%)**, against 63% and 71% at 1.2 Hz; 0.5 Hz and 1.0 Hz both score lower. The earlier moves to 1.2–1.6 Hz (D30, D33) came from too little data. Everything else stays as in D33 (rotation + attitude, magnitudes, 35% trim, k=3, ×8).

**Context model (the user's idea):** `ContextModel` is a smoothed bigram, P(word | previous), learned from a list of expected phrases (default "hello can you hear me"):
- After a phrase's last word, the next word is predicted like a phrase start.
- Motion scores become likelihoods, exp(−(score − best) / temperature), multiplied by the prior raised to a weight.
- Results are re-ranked as −log(posterior), so the existing margin rule still works.
- `_none` gets a neutral prior.
- The "too far" check uses the motion score before context.
- Context is the last kept word, and resets after 12 s idle or with "Restart phrase".

**Evaluation** (`LouVoiceCheck --context`): the phrase is simulated by drawing one held-out take per word from the same block. Each step's context is the previous **decoded** word (chained, so errors propagate). The same is repeated with **random word order**, to check that context doesn't override the motion.

| Preset (weight, temperature) | In order: words | In order: phrase | Random order: words |
|---|---|---|---|
| Off | 66% | 11% | 68% |
| **Balanced (0.3, 0.05)**, default | **75%** | 28% | 65% |
| Strong (0.5, 0.1) | 94% | 83% | 41% |
| Phrase lock (1.0, 0.1) | 100% | 99% | 24% |

**Why Balanced is the default:** a high weight looks perfect in order, but at Phrase lock it just recites the phrase, and out-of-order accuracy drops to about chance. Balanced gains 9 points in order for a 3-point cost out of order. Strong is a reasonable demo setting when the phrase is known; Phrase lock must not be presented as recognition.
**UI:** The Decode screen has a strength picker with these explanations, an editor for expected phrases, an "Expected next" line, and a note whenever context changed the motion's answer.

### D38: Context strength defaults to Strong (2026-11-07). *Amends D37.*
**Decision:** The default next-word prediction strength is **Strong** (weight 0.5, temperature 0.1). Balanced is still available.
**Why:** The user's choice for the demo, where the phrase is known: 94% of words and 83% of whole phrases right when said in order (D37).
**Accepted cost:** Words mouthed out of order drop to about 41% (Balanced: 65%). Switch to Balanced or Off for free-order use.

### D39: ElevenLabs voice output with a local cache (2026-11-07). *PRD-CHANGES item 1.*
**Decision:** A new `VoiceService` speaks each accepted decode in the user's ElevenLabs voice clone.
- **Synthesis:** POST `/v1/text-to-speech/{voice_id}?output_format=mp3_44100_128` with the `xi-api-key` header and `model_id = eleven_flash_v2_5` (`TODO(team)`: confirm the model).
- **Cache:** every vocabulary word is synthesized once and cached at `<data dir>/voice/<voiceID>/<hash>.mp3`. Generation runs after an enrollment finishes, when a word is added, and on launch if anything is missing. Playback is a local `AVAudioPlayer`: instant, and no Wi-Fi needed.
- **Live fallback:** words not cached yet are fetched live, then cached.
- **Without a key or voice ID** it falls back to the system voice, so decode always speaks.

**Key handling:** The API key is read from the `ELEVENLABS_API_KEY` environment variable or the macOS Keychain (service `LouVoice.ElevenLabs`). It's entered through a SecureField and never written to disk or the repo; `.gitignore` also covers `.env`, `*.key` and `elevenlabs*.txt`. The voice ID and model live in UserDefaults.

**Delay (PRD success test < 1.5 s):** measured as the quiet part of the capture window after the word, plus processing, plus time to start playback. The new `SegmentFeatures.trailingSeconds` records that quiet tail, and the Decode screen shows the delay per word plus the median and worst of the last 10. On 241 recorded word takes, the tail alone is median 0.68 s, p90 0.80 s, max 1.48 s, so cached playback should land at about 0.7–0.9 s typically, plus about 0.1–0.2 s of Bluetooth output latency the app can't measure.
- The fixed 1.8 s window is the main delay; continuous recognition (item 2) will end segments as the word ends.
- **Not verified** with a real key or voice. The endpoint shape was checked with an invalid key (HTTP 401, not 404).

### D40: Whole-sentence decoding and sentence training (2026-11-07). *PRD-CHANGES item 2, first part.*
**Decision:** A sentence mode where one press captures a 4 s window (`TODO(team)`: tune for longer phrases) and the whole sentence comes out word by word.
- `SentenceDecoder` runs a dynamic program over every way to split the motion into words. Each candidate segment is scored by DTW against that word's most recent 12 real templates (mean of the best 2), plus a per-word penalty and the next-word context (bigram).
- Speed: one open-ended DTW pass per (start frame, template) scores every possible end point at once. That's about 30× cheaper than one DTW per segment: **0.03 s per sentence**.
- The one-word-per-press mode stays as a fallback (Decode › Mode).

**Sentence training:** In Enroll, the user mouths the whole phrase, flowing, at their natural (fast) pace. Each take is:
1. decoded by a model that hasn't seen this block, giving an honest live score (words and whole sentence);
2. **forced-aligned** to the known words with the current model, cut into per-word sample windows (0.3 s lead-in, 0.15 s tail) and stored as ordinary word takes in a `sentence-…` block. This gives the recognizer fast, joined-up versions of each word;
3. stored whole as a sentence take (`Take.isSentence`, excluded from word training), so it can be re-cut later as the model improves.

Confirmed sentence decodes (nod or Y) are cut and learned the same way.

**Correction:** Each decoded word shows its 2 runner-up words as buttons; one tap replaces it. This is the start of PRD item 4.

**Tuning on stitched sentences** (`LouVoiceCheck --sentences [--grid]`): one held-out take per word, concatenated in phrase order, decoded by a model trained on the other blocks, at normal speed and 1.33× time-compressed. At Strong context:

| Per-word penalty / context weight | Normal: words | Normal: whole sentence | 1.33× faster: words | 1.33× faster: whole sentence |
|---|---|---|---|---|
| 0 / 4 (**chosen**) | 95% | 77% | 93% | 79% |
| 1.5 / 4 | 97% | 85% | 89% | 70% |
| 3 / 2 (first guess) | 88% | 71% | 82% | 50% |
| any / no context | 39–46% | 3–8% | 38–46% | 3–8% |

Penalty 0 was chosen because the user will speak faster. The context weight scales with the Decode strength (`SentenceConfig.contextWeight × context.weight`, so Strong = 4). Forced alignment puts word boundaries within about 0.1 s on average.

**Caveat:** Stitched sentences have no co-articulation. Real flowing sentences will score lower until sentence-training takes exist, which is what the next round collects.
**Not done yet (rest of item 2):** continuous listening with no press per sentence. That's planned together with item 3 (hands-free start and stop).

### D41: Full-history phrase model with end-of-sentence for sentence decoding (2026-11-07). *Amends D40.*
**Finding:** With the D40 bigram, every failed stitched sentence was the **wrong length**, never a wrong word. The two errors were:
- running on past the end, "hello can you hear me hello" (×19), caused by the word-mode rule that wraps the last word back to the first;
- stopping early, "hello can you" (×18 at the faster pace), because ending a sentence cost nothing.

**Decision:** Sentence decoding uses a **prefix tree of the expected phrases** (`PhraseTrie`) instead of the bigram:
- P(next word) depends on the whole history said so far.
- Each phrase has an explicit **end-of-sentence** mark, so stopping early or running on is penalised.
- An unexpected word leaves the tree (via smoothing) into a "free" state, where every word and ending are equally likely.
- The decoder's dynamic-program state is the tree node.
- Word mode keeps the bigram with wrap-around, which is right between separate presses.

**Results** (stitched held-out takes; words / whole sentence right; per-word penalty 0):

| Test | Off | Balanced | Strong |
|---|---|---|---|
| "hello can you hear me", normal | 30% / 2% | 98% / 95% | 99% / 96% |
| … 1.33× faster | 31% / 1% | 100% / 100% | 100% / 100% |
| 4 known phrases, say any | 30% / 9% | 87% / 82% | 88% / 83% |
| Off-script random 3–5 words | 37% / 7% | 26% / 2% | 20% / 0% |

Penalties of 1 and 2 changed nothing material.

**What this means (for honest claims):**
- With a single known phrase, near-100% is guaranteed by the prior and proves little.
- The real evidence is **choosing among several known phrases from motion: 83% whole-phrase right**, against 9% without context.
- Context makes LouVoice a **phrasebook**: off-script sentences get worse, because they're pulled towards known phrases.
- For the demo, register several phrases so the choice is real. The PRD already scopes LouVoice to trained words and phrases.
- Stitched sentences lack co-articulation, so real flowing sentences need confirming with the sentence-training round.

### D42: Train with recorded movement mixed in; soft-clip features (2026-11-07)
**Test method** (`LouVoiceCheck --eval … --robust`):
- Take each held-out word, then mix in the movement from a real recorded "not a word" take (turn, nod, look up, chew, swallow, smile) from *another* block, at 0, 0.25, 0.5 and 1.0× its recorded strength. `Interference.mix` adds rotation rate and acceleration, and composes the extra rotation onto the attitude and gravity.
- The model trains on the other blocks, as in leave-one-block-out.

**Finding:** Movement is very damaging. A quarter-strength head movement drops word accuracy from 69% to 38%.

| Variant | 0 | 0.25 | 0.5 | 1.0 |
|---|---|---|---|---|
| Baseline | 69% | 38% | 26% | 11% |
| Soft clip 3σ only | 69% | 37% | 22% | 12% |
| Noisy training ×2 | 68% | 45% | 41% | 20% |
| **Noisy ×2 + soft clip 3σ (chosen)** | **68%** | **45%** | **42%** | **25%** |
| Noisy ×6 (0.2–1.0×) + clip | 68% | 47% | 42% | 31% |
| Head gate 10° (no noise training) | 69% | 49%, answers 55% | 38%, answers 53% | 27%, answers 42% |

Each cell uses one random movement per test take, so it carries about ±3 points of noise.

**Decision:**
- **2 noisy training copies per word take** (`RobustnessConfig.noiseCopies`): random recorded movement at 0.3–0.8× strength, time-shifted ±0.3 s.
- **Soft clipping at 3σ** (`ClassifierConfig.softClip`), so one big spike can't dominate a DTW distance.
- About +7 to +17 points under movement, for about 1 point on clean takes.
- ×6 was only slightly better and makes matching 3× heavier, so it isn't the default.

**Details:**
- Noisy copies are marked synthetic and never used as sentence templates, so sentence decoding still matches against real takes. Clean stitched sentences are unchanged: 95% / 100% whole sentence.
- Building the noisy set runs off the main thread (about 1 s per retrain).
- **"Hold still" gate:** decode can refuse a capture whose head turned more than N° ("Head moved 23°, hold still and try again"). It's off by default, since the gate trades answers for accuracy; it's on Tune › Robustness.

**Limits:**
- This uses mixed recordings, not real "mouthing while moving" takes, and it doesn't cover walking.
- The strongest next step is a training block recorded while moving naturally, which these numbers can then be checked against.
- The app's Evaluate screen still measures clean leave-one-block-out without noisy copies; `--robust` is the movement benchmark.

### D43: Fix dropped words in fast sentences; end the sentence window when mouthing stops (2026-11-07). *Amends D40.*
**Problem reported:** In sentence mode, words were being clipped or dropped.

**Cause (dropped words):** Trained word takes are long after trimming, median 0.72–0.88 s, because isolated words are mouthed slowly and fully. The decoder only allowed a sentence segment down to **0.5×** a template's length (about 0.30–0.34 s), and to at least 0.16 s. Fast, flowing words are shorter, so they couldn't be placed and were merged or dropped.

Stitched-sentence benchmark (`--speed`), time-compressed relative to the isolated takes; words / whole sentence at Strong:

| Squash limit | ×2.0 | ×2.5 | ×3.0 |
|---|---|---|---|
| ≥ 0.50 (old) | 99% / 97% | 73% / 49% | 46% / 8% |
| ≥ 0.35 | 100% / 100% | 100% / 100% | 92% / 88% |
| **≥ 0.25 (chosen)**, shortest word 0.08 s | 100% / 100% | 100% / 100% | 100% / 100% |

The multi-phrase test is unchanged (84% vs 83% whole phrase).

**Cause (clipped endings):** A fixed 4 s window cuts off longer or slower sentences, and the leftover silence also delays the voice.

**Decision:** Sentence captures **end when mouthing stops** (`MotionHub.captureUntilQuiet`):
- Activity is rotation-rate magnitude with slow drift removed, smoothed over about 0.2 s.
- "Active" is above 0.07 rad/s and "quiet" is below 0.05. Real takes: rest ≈ 0.02 (p90 0.05), word peaks 0.10–0.18.
- The window ends after 0.8 s of quiet (`TODO(team)`: tune for users who pause between words), once at least 0.3 s of activity has happened, no earlier than 1 s after the beep, and no later than 6 s.

**Check:** Replayed over 314 recorded word takes, it **never ended mid-word**, and it ended a median 0.88 s after the last movement. All of these settings are on Tune › Sentence.

**Also found:** No ElevenLabs key is set yet, so decodes are spoken by the system voice.

### D44: Varied sentence lengths in training; phrase parts optional in decoding (2026-11-07)
**Request:** Train on parts of "hello can you hear me" ("hello can", "you hear me"…), not only the full sentence.

**Sentence training:** With "Vary the length" on (the default), each take prompts either the full phrase (40%) or a random contiguous part of 2–4 words. The capture limit scales with the number of words. The honest live score allows parts, and forced alignment uses the prompted words, so every part is cut into correct word takes.

**Decoding parts — measured on stitched held-out takes** (words / whole sentence; Strong; `LouVoiceCheck --parts [--grid|--tempo]`):

| Phrase model | Full ×1 | Full ×2 | Parts ×1 | Parts ×2 |
|---|---|---|---|---|
| Full phrase only (**default**) | 99% / 97% | 100% / 100% | 36% / 8% | 37% / 7% |
| + parts, weight 1 | 95% / 78% | 70% / 9% | 57% / 38% | 42% / 15% |
| + parts, weight 0.2 | 99% / 97% | 100% / 99% | 43% / 15% | 45% / 21% |
| + parts 0.5 + tempo model | 98% / 93% | 88% / 73% | 57% / 35% | 48% / 27% |
| + parts + tempo + **known pace** (best) | 95% / 82% | 90% / 65% | 55% / 36% | 54% / 39% |

**Why it's hard:** With isolated-word templates squashed up to 4× (D43), "can you" at normal pace and "can you hear me" at 2× pace fit the motion equally well, so motion can't fix the sentence length. A tempo model (one steady pace per sentence, ln-ratio duration cost), even given the true pace, only reaches about 35–39% whole-sentence for parts.

**Decision:**
- Decoding defaults to **whole phrases only**, which keeps the demo sentence reliable. "Also expect parts" is a switch on Decode, with the trade-off shown; it uses `partWeight` 0.5.
- The tempo model and known-pace prior are implemented but **off** (`durationWeight` 0, `expectedTempo` nil).

**Next:** Varied-length sentence takes provide real fast templates (less squashing), real phrase starts and ends, and the user's real pace. Re-measure parts on **real** sentence takes, and set `expectedTempo` from them, before switching parts on by default.

### D45: Two-sentence demo: "hello can you hear me" and "my name is konrad how are you today" (2026-11-07)
**Request:** The demo will only ever say one of these two sentences, so make demo and training as accurate as possible for exactly that.

**Changes:**
- **Vocabulary +7:** my, name, is, konrad, how, are, today ("you" is shared). Each has a mouthing hint.
- **Train new words only:** an Enroll button trains words with fewer than 9 takes (`TODO(team)`: threshold), with 2 non-word prompts per block.
- **Expected phrases** default to the two sentences.
- **Demo mode** (`SentenceConfig.onlyExpectedPhrases`, on by default; a switch on Decode): sentence decoding aligns the motion to **each expected phrase in full** and outputs the best fit. Total alignment cost covers every frame for every candidate, so costs compare directly. It can't output a partial or garbled sentence, and phrases containing untrained words are skipped.
- **Sentence training:** "All demo phrases (mixed)" is the default. Each take picks one of the two sentences at random, and "Vary the length" now defaults to **off** (full sentences only, as spoken in the demo).

**First real sentence results** (15 recorded "hello can you hear me" takes in 3 blocks, each decoded by a model that never saw its block):
- **Whole-phrase decoding: 14/15 sentences right**, 95% of words.
- With phrase parts allowed: 4/15. Confirms parts off.
- **Two-sentence stand-in** (the second sentence isn't trained yet): against a deliberately hard 7-word decoy built from the *same* trained words, choose-by-alignment picks the right sentence **13/15**, the whole-phrase decoder 12/15. The real second sentence shares only "you", so it should separate more easily.
- **Known weakness:** neither method can tell the full sentence from its own contiguous parts (4/15). That doesn't matter for this demo.

**To do (needs a person):** Record word blocks for the 7 new words, then mixed sentence training for both sentences. Then measure the real two-sentence accuracy with `LouVoiceCheck --eval … --real-sentences`.

### D46: Two votes for the demo sentence choice: word alignment + whole-sentence matching (2026-11-07). *Extends D45.*
**Data:** 754 takes:
- the 7 new words with about 21–25 training takes each (word blocks plus cuts from sentences);
- **45 real sentence takes**: 29 × "hello can you hear me", 16 × "my name is konrad how are you today".

Isolated-word accuracy across 12 words is 50% held-out (quiz 71%). "today", "are" and "konrad" are 19–28%, still thin. That's not what the demo depends on.

**Two-sentence choice on the real sentence takes** (each block held out, together with the word takes cut from it; `LouVoiceCheck --demo`):

| Method | Right | Sentence 1 | Sentence 2 |
|---|---|---|---|
| Choose by word alignment (D45) | 44/45 | 29/29 | 15/16 |
| Whole-phrase decoder (free) | 24/45 | 24/29 | 0/16 |
| Whole-sentence matching only | 44/45 | 28/29 | 16/16 |
| **Combined (chosen)** | **45/45** | **29/29** | **16/16** |

Combined scored 45/45 at sentence weights 0.5, 1 and 2. The two single methods fail on **different** takes, which is why combining them fixes both. Combined margin: smallest 0.05 among correct choices, median 0.54.

**Decision:** Demo mode combines two independent votes:
- (a) the total cost of aligning the motion to each phrase word by word;
- (b) DTW of the **whole sentence** against the user's recorded sentences of each phrase (mean of the 3 nearest).

Each vote is a log-ratio against the candidates' mean, summed with weight 1. If any candidate phrase has no recorded sentences, alignment is used alone.
- The references are rebuilt off the main thread with each retrain (`AppModel.sentenceReferences`).
- In sentence training, the live honest score uses references from **other** blocks only.

**Caveat:** 45 takes is a small sample, and 100% on it isn't a guarantee. The thinnest correct margin was 0.05. Every extra mixed-sentence block makes vote (b) stronger, and it can be re-checked with `--demo`.

### D47: Demo mode says "no sentence" for random movement (2026-11-07)
**Request:** Sentence decoding must recognise when no sentence was said, for example random movement.

**Test** (`LouVoiceCheck --reject`; every block held out):
- **Positives:** the 45 real demo-sentence takes.
- **Negatives:** 54 recorded movement takes (chew, swallow, turn, nod, smile, look up) and 593 single-word takes, since a lone word isn't one of the demo sentences either.

**Scores per capture:**
- (a) word-by-word alignment cost per frame for the chosen phrase;
- (b) distance to the nearest recorded demo sentences ÷ distance to the nearest "nothing" references (movement takes plus 120 single words).

Combined score = ln(a ÷ 0.5) + ln(b); higher means less sentence-like.

**Finding:** Requiring every real sentence to be kept forces thresholds so loose that 8–22 of the 54 movements get through. The combined score gives a clean trade-off:

| Threshold | Sentences kept | Movement accepted | Single words accepted |
|---|---|---|---|
| < 0.2 | 39/45 | 0/54 | 8/593 |
| **< 0.6 (chosen)** | **42/45** | **0/54** | **45/593** |
| < 0.7 | 43/45 | 3/54 | 62/593 |
| < 1.0 | 43/45 | 11/54 | 127/593 |

Adding single words to the "nothing" references cut wrongly accepted single words roughly in half compared with movement-only references.

**Decision:** Demo mode rejects at score ≥ 0.6 (`SentenceConfig.rejectThreshold`; `TODO(team)`). It shows "No sentence detected — looked like other movement" and plays the reject tone instead of speaking. A strictness slider and an on/off switch are on Decode. The references are rebuilt with each retrain. The live sentence-training score never rejects.

**Trade-off accepted:** About 1 in 15 real sentences is refused ("try again"), in exchange for never speaking a sentence in response to random movement. More mixed-sentence blocks should tighten real sentences' scores and lower that refusal rate.

### D49: Word / sentence mode on the AirPods dot; each mode has a fixed output set (2026-11-07)
**Request:** A Word / Sentence toggle on the Speak screen. Word mode detects only the single words of "hello can you hear me" for now. Sentence mode outputs "hello can you hear me", "my name is konrad how are you today", or nothing.

**Changes:**
- **Switching modes:** click the header's AirPods dot (`LiveIndicator`). Green = word mode, purple = sentence mode, with "· Word" / "· Sentence" beside "AirPods on". It's bound to `Decoder.sentenceMode` (same setting as Settings › Speaking) and does nothing while recording or thinking. While the AirPods are off, the dot stays orange and clicking it still opens Signals. (A Word | Sentence switch on Speak was tried first and replaced by this.)
- **Word mode:** decoding is limited to the trained words of the first expected phrase (`Decoder.wordModeWords`; `_none` is still allowed, so movement is still refused). The Context screen's `activeWords` narrows this further. If fewer than two of those words are trained, word mode falls back to every trained word, so the one-word fallback always works (CLAUDE.md rule 3). `TODO(team)`: widen to all words once the newer words are accurate enough.
- **Sentence mode on Speak:** always runs with `onlyExpectedPhrases` and `rejectNothing` on (D45, D47), whatever the developer switches on Decode say. The Decode screen keeps its own switches for experiments.

### D50: Word mode on Speak uses no next-word context (2026-11-07). *Amends D38 for word mode.*
**Request:** Word mode only has the 5 words of "hello can you hear me", so it should be near 95–100%.

**Test** (`LouVoiceCheck --eval … --word-mode`): every isolated take of the 5 words (enrollment and quiz blocks, 330 takes) decoded by a model that never saw its block, restricted to the 5 words plus `_none`, exactly as `Decoder.trigger()` does:

| Setup | Right | Wrong | Refused |
|---|---|---|---|
| Strong context, words in any order (**what Speak › Word did**) | 36% | 62% | 2% |
| Balanced context, any order | 49% | 47% | 4% |
| **No context, any order (chosen)** | **68%** | 30% | 2% |
| Strong context, words in phrase order | 98% | 2% | 1% |
| No context, trained on isolated takes only (no sentence cuts) | 68% | 30% | 2% |

**Findings:**
- The earlier 94–100% figures (D37, D41) come from the context model when the words follow the phrase. Out of order, Strong context overrides the motion and halves accuracy.
- Restricting to 5 words doesn't make single words easy: motion alone is 68% (hello 59–62%, you 78–79%).
- Word takes cut from sentences neither help nor hurt isolated words.
- A "not sure, say it again" margin gate doesn't reach 95% usefully: margin ≥ 0.2 makes spoken words 90% right but refuses 69% of tries.

**Decision:** The user chose **any order** for word mode. Speak › Word decodes with context weight 0; the Decode screen keeps its context slider. Getting closer to 95% in any order needs a better motion model or more data, not settings.
