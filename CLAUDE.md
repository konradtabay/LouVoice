# LouVoice — instructions for Claude Code

LouVoice is a native macOS SwiftPM app that recognizes silently mouthed words from AirPods Pro 2 head-motion data and speaks them in the user's own ElevenLabs voice clone, for people with ALS.

**Source of truth:** the team's PRD. The original tech plan proved feasibility; where it conflicts with the PRD, the PRD wins. The current work order is `docs/PRD-CHANGES.md`.

## Rules

1. Work ONE checklist item from `docs/PRD-CHANGES.md` at a time, in order, starting with "Must do before the demo." Do not start the next item until the current one builds and `swift run LouVoiceCheck` (or `swift test`) passes.
2. Do not refactor or rewrite working code that an item doesn't require. M1–M4 currently work — keep them working.
3. Keep the one-word-per-trigger decode mode working at all times as a fallback, even while building continuous recognition.
4. Skip items that need a human (recording a session, creating accounts, creating the ElevenLabs voice). List them for the team instead.
5. Never hard-code API keys or commit them. Read the ElevenLabs key from the Keychain or an environment variable, and keep any key file in `.gitignore`.
6. When a choice isn't specified (thresholds, UI layout, schema fields), pick a sensible default, mark it with a `// TODO(team):` comment, and say what you chose.
7. After each item: summarize what changed, which files you touched, and how to test it by hand. Then stop and wait for "next."
8. Only change code and the tech plan document. Pitch and demo-script decisions belong to the team.

## Hard constraints (updated)

- Hardware: AirPods Pro 2 plus the Mac they're paired with.
- Word recognition uses head-motion data only. No webcam, no speech recognition.
- The microphone may be used only to record voice samples for the user's ElevenLabs voice clone, never for word recognition.
- Delivered as a native macOS app; data stays on the Mac by default. Anything sent to Tiger Data or a Vultr backend requires the user's explicit opt-in.
