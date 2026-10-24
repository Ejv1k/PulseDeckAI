# PulseDeck AI continuation

Updated: 2026-10-24

## Project state

Current merged `main` is `5a639de99b6ffc00ebeddd6fcf2eef77cf896526`. PR #16 merged at `2026-10-24T21:38:46Z` via normal AO squash (parent `2d428d22c1f0ef3f54c271391589d35b605b859a`). Its merge tree `cf4e6e096349ad33f8b61098f7c453087c2325e1` exactly matches approved PR head `93a0ae78c91df4d805edb36dc4efadbb15080e2c`. PR CI `40128488045` and post-merge main push CI `40135135430` both completed **SUCCESS** with 270 Swift and 40 Python tests. Native independent Sol audit `657f3d2e-cdae-4e70-b713-b575be1076d7` completed **APPROVED / up_to_date**; provider review `5639788733` commented internal approval, and both review threads were resolved.

Phase 4B is now fully implemented with the addition of the RAM-preloaded Soundboard slice on isolated branch `ao/unattended-caveman-mode-17/root` (worker `pulsedeckai-82`, coordinator `pulsedeckai-77`). See [phase status](docs/PHASE_STATUS.md) and [user manual](docs/USER_MANUAL.md).

Relevant merged work:

- [PR #9](https://github.com/Ejv1k/PulseDeckAI/pull/9): Phase 3A waveform UI and cue persistence, merged at `54dbb9712a3f24d97ea6f63b844d21490530a386`.
- [PR #11](https://github.com/Ejv1k/PulseDeckAI/pull/11): Phase 4A transition backend, merged at `bda0b256f814d4f1625cef29a41471d6cc0b6593`.
- [PR #12](https://github.com/Ejv1k/PulseDeckAI/pull/12): real macOS Swift build/tests and Python CI, merged at `b1c2e0c94c0de1c25b58f00628c4cfb261313872`.
- [PR #13](https://github.com/Ejv1k/PulseDeckAI/pull/13): Phase 3B Block 1 studio shell, independent output routing, and startup/recovery safety, merged at `9bb69ca3534cea1e5b298bbbcab6e743e80179a5`.
- [PR #14](https://github.com/Ejv1k/PulseDeckAI/pull/14): Phase 3B Block 2 library cue preview and audition engine, merged at `ec582558c6a0ffd9a3ddfb3b4b943ca28ec43b43`.
- [PR #15](https://github.com/Ejv1k/PulseDeckAI/pull/15): Phase 4A transition studio controls and AutoPilot integration, merged at `2d428d22c1f0ef3f54c271391589d35b605b859a`.
- [PR #16](https://github.com/Ejv1k/PulseDeckAI/pull/16): Phase 4B Master-only talkover ducking and vocal pocket EQ, merged at `5a639de99b6ffc00ebeddd6fcf2eef77cf896526`.

## Implemented Phase 4B slice: RAM Soundboard (`F1`–`F8`)

The bounded Phase 4B Soundboard slice implements instant, zero-I/O SFX playback in `PulseDeckCore` and `PulseDeckAI`:

1. **Audio Graph Architecture**:
   - `SoundboardController` manages eight high-priority `AVAudioPlayerNode` instances feeding a dedicated intermediate `soundboardMixerNode: AVAudioMixerNode`.
   - `soundboardMixerNode` attaches exclusively to `masterAudioEngine.rawEngine` and connects directly to `masterAudioEngine.subMixer`.
   - The Cue (headphone PFL) audio engine receives zero soundboard audio, guaranteeing complete audition isolation.
   - Strictly output-only: zero calls or connections to `inputNode`, zero live microphone access.
   - Preserves Deck A and Deck B channel volume, crossfader weight, and talkover attenuation parameters. Soundboard audio mixes cleanly at full punch without resetting or ducking deck music.

2. **Deterministic Asset Mapping & Bounded RAM Caching**:
   - Discovers up to 8 supported audio files from `PulseDeck_Library/08_Soundboard_SFX`, sorted alphabetically and mapped deterministically to Pads F1–F8. Non-audio files, `.gitkeep`, and hidden files are ignored.
   - All files are pre-decoded and pre-converted into canonical 44.1 kHz, 32-bit Float, stereo buffers off the trigger and render paths during preload. Buffers are retained in unified RAM for the lifetime of playback.
   - Per-asset duration cap $\le 15.0\,\text{s}$, per-asset RAM ceiling $\le 12\,\text{MB}$, and total soundboard RAM cap $\le 64\,\text{MB}$.
   - Files exceeding duration/RAM bounds, corrupted files, or unsupported formats safely fall back to pre-synthesized procedural tones while surfacing honest UI diagnostic state.

3. **Pre-Synthesized Procedural Fallbacks**:
   - Eight distinct procedural fallback tone buffers are synthesized ahead of time during initialization (1 kHz stinger pip, 808 sub kick, white noise snare, high chime, metallic rimshot, alternating siren beep, laser zap, airhorn triad chord).
   - If an audio file is missing (e.g. empty crate with `.gitkeep`), corrupt, or oversized, the pad immediately utilizes its ready fallback buffer with zero synthesis overhead or allocation in render callbacks.

4. **Retrigger, Overlap & Lifecycle Semantics**:
   - Independent pads overlap polyphonically without cutting off other pads or deck playback.
   - Retriggering the same active pad executes a monophonic cut-and-restart (choke self), preventing runaway voice growth while enabling stutter performance drops.
   - Lifecycle generation counters reject stale background preloads across library root changes and stop/restart transitions.
   - All player mutation and scheduling is serialized through `OutputDeviceMonitor.controlQueue` (with a reentrant serial fallback in monitor-free test mode).

5. **Keyboard Routing & Studio UI**:
   - Dispatched via `SoundboardKeyboardRouter` in `DeckStudioView` and `ContentView`.
   - Drops OS key-repeat events (`press.phase == .repeat` / `event.isARepeat == true`) and suppresses duplicate multi-route dispatches within the same runloop tick.
   - Zero global event monitoring outside the active PulseDeck AI window.
   - Studio view features an 8-pad interactive grid displaying key labels `[F1]`–`[F8]`, pad titles, duration, RAM footprint, readiness dots (green file, orange fallback, flashing yellow when active), and full button click triggering.
   - Application menu bar includes accessible `Soundboard` menu commands for all 8 pads.
   - Documents macOS `Fn` / Globe key requirements for standard function keys.

6. **Verification Proof**:
   - 9 comprehensive soundboard tests in `SoundboardTests.swift`:
     1. `testAssetMappingAllEightPads`: Sorted 8-file mapping, labels F1–F8, buffer capacities.
     2. `testEmptyCrateFallbackAudibleActualPCM`: Empty crate with `.gitkeep` renders audible non-zero PCM (>0.05).
     3. `testPartialCorruptAndOversizedFilesSafeBehavior`: 2 valid, 1 corrupt, 1 oversized (>15s), 4 missing pads safely render audio without crashing.
     4. `testPreloadedBuffersTriggerWithoutFileAccess`: Deleting fixture files from disk after preload proves trigger path plays directly from RAM with zero file access.
     5. `testSimultaneousPadsAndRetriggerPolicy`: Concurrent playback of Pad 0 + Pad 1, monophonic retrigger, and stop isolation.
     6. `testMasterPCMWithCueUnchanged`: Master renders audible SFX PCM (>0.05), while Cue remains strictly silent (peak 0.00000).
     7. `testDeckCrossfaderAndTalkoverIsolation`: Deck crossfader at full Deck B and talkover at -16.5 dB ducking are completely untouched by SFX trigger.
     8. `testCancellationRootChangeStaleCompletionStopRestartTeardown`: Rejects stale root 1 completion after root 2 switch; stopping coordinator stops all pads.
     9. `testKeyboardRepeatAndRoutingBehavior`: Real NSEvent F1–F8 keycode dispatch, repeat suppression, and duplicate routing debounce.
   - Local gates: `swift build -q`, `swift test -q` (**279 Swift tests, zero failures**), and Python companion discovery (**40 tests, zero failures**).

## Next concrete slice: Phase 5A Projector Secondary Window

After PR for Phase 4B Soundboard merges:
- Secondary presentation window for external HDMI projectors / AirPlay screens.
- Modes 1–4 (FFT spectrum visualizer, Ken Burns slideshow, Now Playing card, Blackout screen) mapped to Keys 1–4.
- Master deck safety lock to prevent accidental dancefloor interruptions.

## Boundaries and invariants

Offline AV rendering and mocked output HAL establish automated control and PCM behavior. Physical speakers/headphones, Bluetooth latency, live Gemini/Ollama providers, and pointer automation remain unverified. Strictly output-only: zero microphone permissions, zero input node access. All AO/Grok repair/backup/export/deployment tasks remain cancelled.
