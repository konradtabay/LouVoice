# LouVoice

Silent speech from **AirPods Pro 2 head motion only**: no microphone, no camera. You mouth a word, and the tiny jaw-driven motion picked up by the earbuds is recognised on your Mac.

This is a **proof of technology**. The plan and its acceptance targets are in [PLAN.md](PLAN.md), and every technical choice with its reasoning is in [DECISIONS.md](DECISIONS.md).

## Status

| | |
|---|---|
| Core pipeline + recognizer + honest evaluation | ✅ 9/9 self-checks pass |
| Full app flow (enroll → evaluate → decode, nod to confirm) | ✅ verified on the simulator with `--smoke` |
| Real AirPods data (M4) | ✅ first session: 68% leave-block-out after tuning (chance 20%); confirming with quiz takes |

## Run it

Requires macOS 14+ and AirPods Pro connected to the Mac. Command Line Tools are enough; Xcode isn't needed.

```bash
scripts/build-app.sh          # builds and ad-hoc signs build/LouVoice.app
open build/LouVoice.app       # allow Motion when asked
```

Then:
1. **Sensors**: check it's streaming at about 25 Hz.
2. **Enroll**: about 10 minutes, with a re-seat between blocks.
3. **Evaluate**: read the leave-one-block-out and quiz accuracy.
4. **Tune**: change any pipeline variable or run auto-tune on your takes.
5. **Decode**: press Space (or the stem) and mouth a word; nod to accept, shake to reject.

Use the **Simulator** switch at the bottom of the sidebar to try every screen without AirPods. Simulated accuracy means nothing about the real thing.

## Checks

```bash
swift run LouVoiceCheck                                   # core self-tests
swift run LouVoiceCheck --sim-eval yes banana hello stop  # simulated leave-block-out benchmark
swift run -c release LouVoiceCheck --eval ~/Library/Application\ Support/LouVoice/dataset.json --tune   # evaluate + auto-tune real takes
open -W -n --env LOUVOICE_DATA_DIR=/tmp/lv --stdout /tmp/lv.log build/LouVoice.app --args --smoke   # end-to-end app run on the simulator (D27: always launch via open)
```

## How it works (short)

1. **Motion data:** CoreMotion headphone motion at about 25 Hz, resampled onto an even time grid.
2. **Re-seat correction:** each capture is rotated so its rest gravity points down, which cancels how the earbud is seated.
3. **Filter:** removes posture drift and slow head movement, keeping jaw-band motion.
4. **Trim:** keeps just the active part of the window.
5. **Match:** banded DTW against every enrolled take plus 4 augmented copies each; the score is the mean of the 3 nearest per word.
6. **Not-a-word class:** an explicit `_none` class (chewing, swallowing, head turns, nods) rejects stray motion.
7. **Evaluation:** whole enrollment blocks are held out, with a re-seat between them, plus a permutation test, so the accuracy number is honest.

## Layout

```
Sources/LouVoiceCore/   pipeline, DTW, augmentation, classifier, evaluation, gestures, quality, simulator, self-tests
Sources/LouVoice/       SwiftUI app: motion hub, enrollment, decoder, cues, stem press, dataset store, views
Sources/LouVoiceCheck/  command-line runner for the self-tests and the simulated benchmark
scripts/build-app.sh    wraps the binary into a signed .app (needed for the Motion permission)
```

Data lives in `~/Library/Application Support/LouVoice/` (`dataset.json` for real takes, `dataset-simulated.json` for simulator takes).

## Credits

The approach builds on [joeblau/subvox](https://github.com/joeblau/subvox) (MIT). No subvox code is copied; the pipeline, recognizer and evaluation were re-implemented with the changes logged in DECISIONS.md.
