# LouVoice: Tech Plan Changes to Match the PRD

The PRD is the source of truth now. The tech plan proved AirPods motion can tell words apart; these changes turn it into the product the PRD describes. Work top to bottom: the first section is what the Sunday demo needs.

## Must do before the demo

- [ ] **Add ElevenLabs voice output (new `VoiceService`).** The plan never speaks in the user's voice, and that's the core of the PRD. Use the user's ElevenLabs voice clone. Because the vocabulary is fixed, generate the audio for every word or phrase once at enrollment and cache it locally. Playback is then instant and doesn't depend on venue Wi-Fi. Fall back to live API calls only for words added since the last cache.
    - Keep the API key out of the app bundle: Keychain or an environment variable.
    - Done when: delay from the end of a mouthed word to the start of audio is under 1.5 s (PRD success test).
- [ ] **Recognize full sentences, not one word per button press.** The plan captures one fixed 1.8 s window per trigger. The PRD says the user mouths a full sentence. Stream motion continuously, detect where each word starts and stops (the energy trim in `Features.swift` is a starting point), and classify each segment as it ends. Keep the one-word-per-trigger mode as a demo fallback if continuous mode isn't reliable by Sunday.
    - Done when: "hello can you hear me" mouthed at a normal pace comes out as 5 words, in order, without pressing anything between them.
- [ ] **Hands-free start and stop.** The stem press, Space bar and nods all need finger or neck control, which people with ALS can lose. With continuous recognition, the app just listens. Add a simple on/off "listening" switch that a caregiver can control too.
- [ ] **Fast correction.** At today's 68% word accuracy, a 5-word sentence comes out fully right only about 15% of the time. Show the top 3 guesses under each word so one tap (by the user or caregiver) fixes it, and feed every confirmed or corrected word back into training. Nod/shake can stay as an option, not the only way.
- [ ] **Support phrases, not just single words.** Let a vocabulary entry be a phrase like "I love you" or "I'm tired." Enrollment and decoding need a longer capture limit for phrase entries.
- [ ] **Use the PRD's persona and vocabulary everywhere.** Alex Chen; demo phrase "hello can you hear me." The plan's demo section still says 8–10 words.
- [ ] **Voice banking during enrollment.** The tech plan bans the microphone, but the PRD doesn't, and Alex can still speak. While he can, have him say each word out loud during enrollment and record mic audio alongside the motion. That one session trains the motion model *and* collects clean samples for his ElevenLabs voice clone. The mic is used only to build the voice, never to recognize words. Test whether a model trained on spoken words still recognizes silently mouthed ones; if not, enroll both ways.
- [ ] **Voice clone setup in the app.** Add an onboarding step that creates the user's ElevenLabs voice: from enrollment audio if they can still speak, or from old recordings (videos, voicemails) if they can't. Link to the ElevenLabs Impact Program for free access.

## Should do before the demo

- [ ] **Re-check the 68% on a fresh session.** The settings were tuned on the same 59 takes they were scored on, so 68% may be optimistic. Record a new session, score it with the tuned settings, and put that number in the PRD and the pitch.
- [ ] **Try 50 Hz instead of 25 Hz.** The AirPods stream at 50 Hz, but the pipeline downsamples to 25 Hz. Change the resample rate, rerun the evaluation, and keep whichever scores higher.
- [ ] **Report the PRD's metrics.** Add sentence success rate and end-to-end delay (end of word to start of audio) to the Evaluate output, next to word accuracy.
- [ ] **Build a quick judge enrollment.** The PRD has a judge train the model. Add a short mode (3–5 words, 3 takes each, about 2 minutes) and show the judge their own accuracy honestly. Run the main demo on a teammate's fully trained model.
- [ ] **Make a user-facing dashboard.** Sensors and Evaluate are developer screens; hide them behind a developer toggle. The user sees the live transcript, the correction tap, and their voice playing back. Per the PRD: clean, cool, not like a medical device.

## Deterioration tracking and adaptation

The PRD's "Building for patient's needs" section commits to three things the plan doesn't have yet: enroll early, retrain word by word, and warn when the signal fades. For the demo, one working chart of a user's data over time is enough; the full loop can come after.

- [ ] **Tiger Data time-series.** After every session, log per word: movement strength (peak motion vs. the noise floor), accuracy on confirmed words, and speaking pace. Tiger Data stores it as a time series per user.
- [ ] **Vultr backend.** A small API on Vultr receives session metrics from the Mac app and writes them to Tiger Data; Vultr also hosts the landing page. Raw motion stays on the Mac unless the user opts in to uploading it.
- [ ] **Per-word retraining prompt.** When a word's accuracy over its last ~20 uses drops below a set threshold, prompt the user to retrain just that word (3 takes), not the whole vocabulary.
- [ ] **Recent takes count more.** Weight recent takes higher and retire old templates, so the model follows the user's current movements instead of how they moved months ago.
- [ ] **Allow for slower speech.** ALS slows speaking rate before it hurts clarity. Widen the time-warp augmentation (now ×0.85–1.15) and the DTW band so slower versions of a word still match.
- [ ] **Signal-fading alert.** When movement strength trends toward the noise floor, tell the user and caregiver that LouVoice is becoming unreliable, so they can plan another communication method in time.
- [ ] **Consent screen.** Explain what is uploaded, get explicit opt-in, and let the user delete their data. This is health data; it supports the PRD's dignity principle.

## Cut or change

- [ ] **Drop M7 from hackathon scope.** Xcode migration, Developer ID signing, notarized `.dmg`: none of it matters for judging. The ad-hoc build is enough.
- [ ] **Drop the live re-seat stunt.** Leave-one-block-out already re-seats the AirPods between every session, so that number proves re-seat robustness. Show the number instead of risking a live failure.
- [ ] **Don't claim GPU training for the current model.** The k-NN DTW recognizer trains on a laptop in seconds. Vultr GPUs only make sense if we move to a neural model later; say that, or describe Vultr as hosting the backend.
- [ ] **Rewrite M5–M6 around the PRD.** Replace them with: voice output, continuous sentence recognition, correction, deterioration tracking, then accuracy toward 90%.
- [ ] **Remove Solana** if it's referenced anywhere.

## Keep as is

- **The honest evaluation:** leave-one-block-out, the permutation test, the chance baseline, and labelling the optimistic number.
- **Re-seat correction, the `_none` rejection class and the quality checks on each take.**
- **Native macOS app with data stored locally by default.**
- **The simulator,** for development only; its accuracy never goes in the reference numbers.
- **Not claiming open vocabulary.** LouVoice only knows words and phrases the user has trained.
