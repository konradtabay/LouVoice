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
