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

## Selective accuracy (answer only when confident; DEV + XS, 107 takes, ensemble of the two best models)
| Confidence ≥ | Answers | Right when answering |
|---|---|---|
| (always answer) | 100% | 82.2% |
| 0.5 | 65% | 90.0% |
| 0.6 | 49% | 94.2% |
| 0.7 | 40% | 97.7% |
| 0.8 | 23% | 100% |
In the app this is `Decoder.cnnMinConfidence` (currently 0, always answers): "Not sure: try again" below it.

## Also tried later (DEV / XS)
- Representation: 50 Hz, untrimmed window, gravity channels, derivatives, high-pass 0.4 Hz, accel + rotation only: all 75–80 / 73–79, no better than `arv_nw8`.
- Time-normalised input: DEV 82.7 but XS 71.8 (overfits the late-night blocks).
- Causal session axis alignment (rotate each session's main motion axes onto a reference): much worse (62–64).
- ROCKET (random convolution kernels + ridge): 46–56 / 65.
- Ensembles: accel + base features 80.4 combined; + time-normalised accel 80.8 combined (best overall, but needs two feature pipelines in the app; within noise of the single shipped model at 79.4).
- Prototypical network trained across sessions (prototypes from the latest takes): 68.2 combined.
- MixStyle (mixing per-take feature statistics while training): 67.8–73.8 combined.
- Fit-matched fine-tuning (weight training takes by resting-gravity similarity to the test take): 77–78 combined; gravity tilt as an input: 69.6.
- Other trained words as extra classes: 73–76 combined.
- DTW template matching against late-night takes: 42 dev.
- Training without sentence-cut takes, without flagged sentence cuts, or with sentence cuts at half weight: 76–79 combined.
- Stochastic weight averaging: 76–78.5 combined.
- Weak-mouthing synthesis (scale a take down and add noise at the measured sensor noise floor): 74.8–79.0 combined.
- Oversampling late-night takes instead of loss-weighting them: 77.1–78.0 combined.
- Short-time spectral magnitudes as input: 59.8 combined.
- Random search over 16 training hyperparameters (learning rate, weight decay, smoothing, dropout, width, window, augmentation ranges, night weight; running continuously): best so far 78.0 combined, i.e. the defaults are near a local optimum.

## How much the numbers can be trusted
- DEV + XS is 107 takes: at ~80% accuracy the standard error is about ±4 points, so only changes of 5+ points are real.
- Seed-to-seed spread is ~3 points: the shipped recipe scored 79.4 combined on seeds 0–1 and 76.2 on seeds 2–3.
- The random search's best configs (80.4 on seeds 0–1) re-tested on seeds 2–3 at 76.6 and 77.1, the same as the shipped recipe (76.2): winner's curse. The shipped model was kept.
- So the only changes that clearly cleared the noise were dropping `confirmed-*` takes (+10), and the accelerometer channels with late-session weighting (+10 on DEV, +4 on LOCKED).

## Learning curve (how much data 95% would need)
Same recipe trained on a random 25 / 50 / 75 / 100% of the training takes (DEV + XS combined): 54.7 / 70.6 / 72.9 / ~77.8% (100% = mean of 4 seeds). A power-law fit, error ≈ 22% × (data)^-0.49, extrapolates to roughly **85% at 2×, 90% at 5× and 95% at ~20× today's data** (today ~670 usable takes). Four noisy points, so treat this as an order of magnitude: more recorded practice, in varied fits and late/tired sessions, is the lever, not more modelling.

## Shipped (D63)
`ship.py`: accelerometer + rotation + attitude, latest session ×8, 5 networks, every take except `confirmed-*` (locked blocks included, as for any real model). Locked score of the recipe (trained without the locked blocks): **53.3%** (D53 recipe: 43.3%).

## Findings
- In-session ceiling: training on half of a late-night block (plus everything else) and testing on the other half only reaches ~76–77%. Late-night takes are mouthed smaller ("you", "hear", "me" ~40–50% less motion than daytime) and vary more take to take. The class-average traces are similar to the daytime ones (no mirrored axes), so this is variability, not a systematic shift.
- DEV and LOCKED disagree strongly (e.g. "can" 100% on DEV, 25–33% on LOCKED): late-night sessions don't transfer well to each other.
