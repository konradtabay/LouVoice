<p align="center">
  <a href="https://louvoice.health"><img src="docs/media/banner.png" alt="LouVoice: Mouth a word. Your voice speaks." width="100%"></a>
</p>

<p align="center">
  <a href="https://louvoice.health"><b>louvoice.health</b></a> &nbsp;·&nbsp;
  <a href="#demo">Demo</a> &nbsp;·&nbsp;
  <a href="#results">Results</a> &nbsp;·&nbsp;
  <a href="#built-with-this-weekends-sponsors">Sponsors</a> &nbsp;·&nbsp;
  <a href="#run-it">Run it</a>
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-010101?style=flat-square">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-SwiftPM-682bd7?style=flat-square">
  <img alt="Hardware" src="https://img.shields.io/badge/hardware-AirPods%20Pro%202-3d1689?style=flat-square">
  <img alt="BioHacks 2026" src="https://img.shields.io/badge/BioHacks-2026-bd2e95?style=flat-square">
</p>

---

**LouVoice gives people with ALS their own voice back, using AirPods they can already buy.** You mouth a word. The AirPods' motion sensors pick up the tiny movement of your jaw, a model trained on *your* movements recognises the word, and it's spoken aloud in an ElevenLabs clone of *your* voice.

No camera. No microphone for recognition. No implant. No specialist hardware.

<p align="center">
  <img src="docs/media/signals.gif" alt="LouVoice Signals screen: live AirPods motion while a word is mouthed" width="100%">
  <br><sub>Live AirPods Pro 2 motion in the Signals screen while a word is mouthed.</sub>
</p>

## The problem

- **80–95% of people with ALS** eventually can't meet their daily communication needs with natural speech ([Beukelman et al., 2011](https://pmc.ncbi.nlm.nih.gov/articles/PMC3096454/)).
- **About 95%** of people in the Nebraska ALS Database became unable to speak at some point before death (same source).
- ALS costs **$157,000 a year** per person in Canada; families pay about 78% of the total ([ALS Canada, Burden of ALS Study, 2026](https://www.ctvnews.ca/health/article/the-cost-of-als-in-canada-new-study-reveals-financial-burden-pushing-families-to-the-brink/)).

Today's options are eye-gaze boards, typing, and generic synthetic voices. They're slow, and they don't sound like the person. LouVoice reads the movement that's still there.

## Demo

<!-- TODO: replace with the demo video. On GitHub: edit this file in the browser, drag the .mp4 here, and GitHub inserts a user-attachments link that plays inline. -->
> 🎬 **Demo video coming.** Until then, the GIF above shows live sensor data, and [louvoice.health](https://louvoice.health) shows the product.

## How it works

```
 AirPods Pro 2 ──► head-motion stream ──► jaw-band filter ──► DTW match ──► word ──► ElevenLabs voice clone ──► speaker
  (CoreMotion)     re-seat corrected       trim to motion     vs. your takes          (your voice, cached on the Mac)
```

1. **Enroll (about 10 minutes).** Mouth each word in a few blocks, re-seating the AirPods between blocks so the model learns to handle how they sit.
2. **Recognise.** Banded DTW against every enrolled take (plus augmented copies) picks the nearest word. An explicit *not-a-word* class rejects chewing, swallowing, nods and head turns.
3. **Speak.** The word is spoken in the user's ElevenLabs voice clone. Audio is cached locally, and the API key lives in the macOS Keychain.
4. **Confirm hands-free.** Nod to accept, shake to reject.

Everything runs on the Mac. Nothing leaves it unless the user opts in.

## Results

These are measured on real AirPods data from 754 recorded takes, with held-out evaluation. See [DECISIONS.md](DECISIONS.md) (D46) for the full numbers.

| Test | Result | Chance |
|---|---|---|
| Demo mode: pick the right sentence (2 trained sentences, 45 real takes, each block held out) | **45 / 45** | 50% |
| Isolated words, quiz takes (12 words) | **71%** | 8% |
| Isolated words, whole recording blocks held out (12 words) | **50%** | 8% |

**What this is and isn't.** It's a proof of technology from one user. It isn't open-vocabulary speech yet. The recognizer is personal by design: it learns one person's movements. The next steps are a larger vocabulary, more sessions per user, and testing with people living with ALS.

## Built with this weekend's sponsors

| Sponsor | What we used it for |
|---|---|
| **ElevenLabs** | Voice clone made from the user's own recordings, so every recognised word is spoken in their voice. Audio is cached on the Mac so repeated words play instantly and work offline. |
| **Tiger Data** | TimescaleDB hypertable `word_attempts` plus a continuous aggregate `word_weekly` (7-day buckets, hourly refresh) that powers the caregiver progress chart on the website. It also stores the waitlist, written through a least-privilege `louvoice_web` role. |
| **Vultr** | Cloud compute in New York running the website and its API (Node 22, pm2, Caddy with automatic HTTPS). |
| **GoDaddy Registry** | The `.health` domain: [louvoice.health](https://louvoice.health). |
| **Entire** | Session checkpoints on every Claude Code session, stored as git refs (`refs/entire/checkpoints/*`), so every AI-assisted change is traceable. |

## Run it

Requires macOS 14+ and AirPods Pro connected to the Mac. Command Line Tools are enough; Xcode isn't needed.

```bash
scripts/build-app.sh          # builds and ad-hoc signs build/LouVoice.app
open build/LouVoice.app       # allow Motion when asked
```

Then:
1. **Sensors**: check it's streaming at about 25 Hz.
2. **Enroll**: about 3 minutes (2 blocks), with a re-seat between blocks. Add blocks for more accuracy.
3. **Evaluate**: read the leave-one-block-out and quiz accuracy.
4. **Tune**: change any pipeline variable or run auto-tune on your takes.
5. **Decode**: press Space (or the stem) and mouth a word; nod to accept, shake to reject.

Use the **Simulator** switch at the bottom of the sidebar to try every screen without AirPods. Simulated accuracy means nothing about the real thing.

<details>
<summary><b>Checks, pipeline details and repo layout</b></summary>

### Checks

```bash
swift run LouVoiceCheck                                   # core self-tests
swift run LouVoiceCheck --sim-eval yes banana hello stop  # simulated leave-block-out benchmark
swift run -c release LouVoiceCheck --eval ~/Library/Application\ Support/LouVoice/dataset.json --tune   # evaluate + auto-tune real takes
open -W -n --env LOUVOICE_DATA_DIR=/tmp/lv --stdout /tmp/lv.log build/LouVoice.app --args --smoke   # end-to-end app run on the simulator (D27: always launch via open)
```

### Pipeline

1. **Motion data:** CoreMotion headphone motion at about 25 Hz, resampled onto an even time grid.
2. **Re-seat correction:** each capture is rotated so its rest gravity points down, which cancels how the earbud is seated.
3. **Filter:** removes posture drift and slow head movement, keeping jaw-band motion.
4. **Trim:** keeps just the active part of the window.
5. **Match:** banded DTW against every enrolled take plus 4 augmented copies each; the score is the mean of the 3 nearest per word.
6. **Not-a-word class:** an explicit `_none` class (chewing, swallowing, head turns, nods) rejects stray motion.
7. **Evaluation:** whole enrollment blocks are held out, with a re-seat between them, plus a permutation test, so the accuracy number is honest.

The plan and its acceptance targets are in [PLAN.md](PLAN.md), and every technical choice with its reasoning is in [DECISIONS.md](DECISIONS.md).

### Layout

```
Sources/LouVoiceCore/   pipeline, DTW, augmentation, classifier, evaluation, gestures, quality, simulator, self-tests
Sources/LouVoice/       SwiftUI app: motion hub, enrollment, decoder, cues, stem press, dataset store, views
Sources/LouVoiceCheck/  command-line runner for the self-tests and the simulated benchmark
scripts/build-app.sh    wraps the binary into a signed .app (needed for the Motion permission)
website/                louvoice.health: Vite + React site and Node API (see website/DEPLOY.md)
```

Data lives in `~/Library/Application Support/LouVoice/` (`dataset.json` for real takes, `dataset-simulated.json` for simulator takes).

</details>

## Team

Built at BioHacks 2026 by **Konrad Tabay** and **Neel Laroiya**.

## License and credits

Copyright © 2026 Konrad Tabay and Neel Laroiya. All rights reserved. No license is granted to use, copy, modify or distribute this code without written permission.

