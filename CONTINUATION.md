# PulseDeck AI continuation

Updated: 2026-10-24

## Project state

Current merged `main` is `2d428d22c1f0ef3f54c271391589d35b605b859a`. PR #15 merged at `2026-10-23T07:17:26Z`; Phase 4A UI and AutoPilot integration are fully merged. Phase 4B Master-only talkover is open in PR #16 on branch `ao/unattended-caveman-mode-16/root`; its concurrency repair has passed local gates and still requires exact-head CI and a fresh independent native review. See [phase status](docs/PHASE_STATUS.md) and [user manual](docs/USER_MANUAL.md).

Relevant merged work:

- [PR #9](https://github.com/Ejv1k/PulseDeckAI/pull/9): Phase 3A waveform UI and cue persistence, merged at `54dbb9712a3f24d97ea6f63b844d21490530a386`.
- [PR #11](https://github.com/Ejv1k/PulseDeckAI/pull/11): Phase 4A transition backend, merged at `bda0b256f814d4f1625cef29a41471d6cc0b6593`.
- [PR #12](https://github.com/Ejv1k/PulseDeckAI/pull/12): real macOS Swift build/tests and Python CI, merged at `b1c2e0c94c0de1c25b58f00628c4cfb261313872`.
- [PR #13](https://github.com/Ejv1k/PulseDeckAI/pull/13): Phase 3B Block 1 studio shell, independent output routing, and startup/recovery safety, merged at `9bb69ca3534cea1e5b298bbbcab6e743e80179a5`.
- [PR #14](https://github.com/Ejv1k/PulseDeckAI/pull/14): Phase 3B Block 2 library cue preview and audition engine, merged at `ec582558c6a0ffd9a3ddfb3b4b943ca28ec43b43`.
- [PR #15](https://github.com/Ejv1k/PulseDeckAI/pull/15): Phase 4A transition studio controls and AutoPilot integration, merged at `2d428d22c1f0ef3f54c271391589d35b605b859a`.

## PR15 merged status and evidence

Original source branch: `ao/pr14-phase4a/phase4a-ui`. Implementation owner: `pulsedeckai-79`; coordinating orchestrator: `pulsedeckai-77`.

PR #15's approved head was `9bf36fb2601a9adcc3fd78dcc7a273e8d4f63e73`. Merge commit `2d428d22c1f0ef3f54c271391589d35b605b859a` has parent `ec582558c6a0ffd9a3ddfb3b4b943ca28ec43b43` (PR #14 merge). Its tree `e61e87b582f9bf8f719efe0ed1a4967b67af411d` exactly matches the approved PR head tree.

[Exact-head PR CI 39911504863](https://github.com/Ejv1k/PulseDeckAI/actions/runs/39911504863) succeeded on `9bf36fb`: build, **255 Swift tests**, and **40 Python tests**. Automatic post-merge main CI [39916786279](https://github.com/Ejv1k/PulseDeckAI/actions/runs/39916786279) completed **SUCCESS** on merge commit `2d428d2`: **255 Swift tests** and **40 Python tests**.

Native independent Sol review `8fbecec5-b67e-46dd-a674-23ef60f7f314` completed **APPROVED / up_to_date** on exact head `9bf36fb`. Provider review `5624740274` is **COMMENTED** with internal approval text. All four PR review threads are resolved.

## PR16 concurrency repair and pending gates

PR #16 remains open. Coordinator: `pulsedeckai-77`; senior repair owner: `pulsedeckai-80`, running verified `gpt-6.1-sol/high`. Worker81 exited through the supported AO operation before takeover; its worktree and uncommitted graph draft are preserved. The repair uses an isolated worktree/branch and updates the existing PR source with a normal fast-forward push.

The original PR head `edd58b04db0f276b9824ffcef9d6f7e9353ee275` passed [CI 40126733260](https://github.com/Ejv1k/PulseDeckAI/actions/runs/40126733260): 267 Swift and 40 Python tests. Native independent Sol/high review `6b02565e-783b-4079-b37e-45e6c26c25b6` required two concurrency fixes. Provider review `5639708863` is COMMENTED with the internal changes-requested verdict. That historical CI does not validate the new repair head.

Both findings are addressed in the repair containing this checkpoint:

- `TalkoverController` validates each tick's generation inside the same synchronous, reentrant audio-control operation that advances progress and applies both Master graphs. Cancellation invalidates the generation and restores both graphs in that operation. Task replacement, explicit stepping, and toggles use the same serialization; callbacks execute after the controller's operation. Monitor-free controllers use a private reentrant serial queue.
- `DeckAudioGraph` serializes channel volume, crossfader weight, and talkover gain mutations together with fader recomputation and node assignment. Monitor-free graphs use their own reentrant serial queue. Public setters remain synchronous; Cue and user/transition EQ retain their existing paths.

Two semaphore-controlled regressions failed 14 assertions before the source fix. A paused stale tick left both Master graphs ducked after completed cancellation and restart. A final restore tick reopened a closed crossfader to gain 1, producing actual offline PCM peak 0.7999953. After the fix, both regressions pass: cancellation remains neutral, closed-crossfader Master PCM stays below 0.0001, and Cue remains audible. A third regression checks synchronous monitor-free setters and nested control-queue calls.

Final local gates passed: `swift build -q`, `swift test -q` (**270 Swift tests, zero failures**), and Python unittest discovery (**40 tests, zero failures**). Existing twelve talkover tests and transition/cue/gain/DISARM/readiness coverage remain included. The repair head still needs its own automatic CI and one fresh independent native Sol/high audit, dispatched by the coordinator after green CI. No review or merge is self-authorized. Soundboard and Phase 5 work remain on hold.

## Implemented Phase 4B slice: Master-only Talkover

Phase 4B Master-only talkover ducking is implemented in open PR #16 (original author `pulsedeckai-81`, repair owner `pulsedeckai-80`, coordinator `pulsedeckai-77`):

1. **Dedicated Master Talkover Path**:
   - `DeckAudioGraph` inserts a dedicated `masterTalkoverEQNode` (`AVAudioUnitEQ(numberOfBands: 1)`) into the Master path:
     `masterPlayerNode -> masterTimePitchNode -> masterEQNode -> masterTalkoverEQNode -> masterFilterNode -> masterEchoNode -> masterFaderNode -> masterEngine.subMixer`.
   - The Cue (PFL) path has no talkover node and remains strictly isolated.
   - User and transition 3-band EQ in `masterEQNode` and `cueEQNode` remain completely untouched by talkover.

2. **Vocal-Pocket EQ & Linear Attenuation**:
   - Master volume multiplier ramps linearly over 800 ms between 1.0 (unity) and 0.15 (-16.5 dB attenuation).
   - Dedicated vocal-pocket parametric EQ ramps linearly over 800 ms between 0.0 dB (bypassed) and -4.0 dB dip centered at 948.7 Hz with bandwidth 3.32 octaves (symmetrically spanning 300 Hz–3 kHz).
   - `masterFaderNode.outputVolume` is computed as `_volume * _crossfaderWeight * _talkoverVolumeMultiplier`. User volume knob changes, crossfader moves, and automated transitions compose multiplicatively; zero stale fader or EQ intent is ever restored.

3. **Controller & State Machine**:
   - `TalkoverController` provides deterministic progress stepping, linear 800 ms rate calculation, and continuous mid-ramp toggle reversal (no clicks, pops, or discontinuities).
   - Hotkey `T` / `t` and UI button toggle talkover on and off. Duplicate keyDown events from OS key-repeat are dropped.
   - Idempotent commands, cancel/reset to neutral, and teardown lifecycle cleanup halt background tasks with zero leaks.

4. **Verification Proof**:
   - Original head `edd58b04` passed **267 Swift tests** and **40 Python tests**; the concurrency repair passes **270 Swift tests** and **40 Python tests** locally. New-head CI and independent audit remain pending.
   - 12 comprehensive talkover tests verify deterministic 800 ms midpoint (multiplier 0.575, EQ -2.0 dB) and endpoints (0.15, -4.0 dB), toggle reversals, cancel, gain/crossfader composition, underlying EQ preservation, Cue PFL/preview isolation, track load preservation, and offline PCM rendering attenuation.
   - CoreAudio safety guarantees intact: zero touches to `inputNode`, zero live microphone access.

## Next concrete slice: Phase 4B Soundboard

After PR #16 passes its remaining gates and merges, a separately authorized next slice can address the 8-pad Soundboard. No Soundboard implementation is part of this repair:
- Pre-loaded RAM audio triggers mapped to Hotkeys `F1`–`F8`.
- Media sourced from `08_Soundboard_SFX/` directory with synthesized tone fallbacks when empty.
- Zero-latency trigger playback routed through the engine graph.
- Projector secondary display (Hotkeys 1–4) remains bounded to Phase 5A; no projector work in Phase 4B.

## Boundaries and invariants

Offline AV rendering and mocked output HAL establish automated control/publication and PCM behavior. Physical speakers/headphones, Bluetooth latency, live Gemini/Ollama providers, and pointer automation remain unverified. No new microphone access or audio permission was introduced. All AO/Grok repair/backup/export/deployment tasks remain cancelled.
