# Explainer videos from skein output (idea, not planned)

**Status**: Idea. No dev plan yet.
**Source**: Karpathy's thread, https://x.com/karpathy/status/2105819303471976479 ("Explainer videos" is the format he is most bullish on).
**Split from**: `docs/dev_plans/20261008-feature-review-output-formats.md` (items 1-3). This doc covers item 4 only.

## Goal

Turn a review result, plan, or diff into a short narrated video the user can watch instead of reading. Narration uses the user's cloned voice.

## Pipeline sketch

1. **Script.** Write short beats in plain prose, each with an intended visual.
2. **Narration.** Send each beat to the local tts-server. Cloned voice comes from the local Qwen model on disk.
3. **Visuals.** Option A: HTML slides captured with headless Chrome (reuses `show-me` and `artifact-design` work). Option B: Manim for 3b1b-style animation.
4. **Assembly.** `ffmpeg` joins frames and audio. Narration length per beat sets that beat's duration.

## Open questions (not verified yet)

- tts-server: endpoint, request shape, and whether it already serves the cloned voice.
- Qwen model: exact model name and how it is run (MLX, script, server).
- Tooling present: `ffmpeg`, Manim, Playwright or headless Chrome.
- Which first input: review findings, a dev plan, or a PR diff.
- Where it lives: a new `skein:explain-video` skill, or a standalone script outside the plugin.

## Constraints

- skein ships as a public plugin. The tts-server URL and voice reference audio are personal: config via env vars or a local file, nothing hardcoded, voice audio never committed.
- Opt-in only. Video rendering is slow and must not sit on the default review path.
- Codex mirror applies if this becomes a skill (Codex half first via `codex:rescue`).

## Suggested first step

Spike outside the repo: one hand-written 3-beat script, narrated through the tts-server, slides from HTML, joined with `ffmpeg`. If that works in under an hour of effort, write a dev plan.
