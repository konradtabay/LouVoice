# Word-mode model lab: overnight results (2026-11-08)

Goal: single-word accuracy 95%+ (hello, can, you, hear, me; `_none` counts as wrong).

## Evaluation (frozen before any experiment, `split.json`)
- **LOCKED** (the real goal): the last 60 isolated word takes recorded (quiz 00:03, quiz 00:04, calibration 00:53 on 2026-11-08, late-night earbud fit). Never trained on, never tuned on; every look is logged in `locked_log.jsonl`.
- **DEV** (selection): 3 other late-night blocks (quiz 23:54, calibration 00:27 and 00:50), 52 takes, each held out in turn.
- **XS** (selection, added later because DEV alone is noisy): for each of the 3 daytime sessions, train without any block of that session, test on its quiz takes (55 takes).
- `confirmed-*` takes are never test data (their labels came from the model's own guess).

## What moved the needle
| Change | DEV | XS | LOCKED |
|---|---|---|---|
| Shipped D53 CNN (baseline) | 59.6 | – | 43.3 |
| Drop `confirmed-*` takes from training | 70.2 | 85.5 | 49.2 |
| + accelerometer channels + 8× weight on late-night takes (`arv_nw8`) | 79.8 | 79.1 | 51.7 |
| Ensemble of `arv_nw8` + base-feature model with 8× night weight | 76.9 | 83.6 | – |

## What did not help (DEV / XS, 2 seeds)
- Rotation augmentation 30°, yaw-about-gravity 45°, physical re-seat variants of the raw frame: worse.
- Gain augmentation 0.4–1.6, per-take amplitude normalisation, causal running normalisation: worse.
- Mixup, time masking, channel gain, 200 epochs, dropout 0.5, wider/narrower CNN, GRU, transformer, residual SE-CNN: no better.
- Label cleaning by out-of-fold confidence: worse (removes hard but valid takes).
- Keeping "confirmed" takes filtered by agreement with a clean model: worse.
- DTW-interpolated synthetic late-night takes: worse.
- Causal recency fine-tuning, causal AdaBN: neutral.
- Time-normalising each take to a fixed length: worse.
- 50 Hz, no trimming, looser trimming, high-pass 0.4/2.0/2.5 Hz: no better.

## Findings
- In-session ceiling: training on half of a late-night block (plus everything else) and testing on the other half only reaches ~76–77%. Late-night takes are mouthed smaller ("you", "hear", "me" ~40–50% less motion than daytime) and vary more take to take. The class-average traces are similar to the daytime ones (no mirrored axes), so this is variability, not a systematic shift.
- DEV and LOCKED disagree strongly (e.g. "can" 100% on DEV, 25–33% on LOCKED): late-night sessions don't transfer well to each other.
