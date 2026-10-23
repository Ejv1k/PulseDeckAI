# PulseDeck AI continuation

Updated: 2026-10-23

## Project state

Current merged `main` is `ec582558c6a0ffd9a3ddfb3b4b943ca28ec43b43`. PR #14 merged at `2026-10-23T05:11:19Z`; Phase 3B Blocks 1 and 2 are merged. Phase 4A backend remains merged, and its UI/AutoPilot integration and required review repairs are implemented on `ao/pulsedeckai/pr14-phase4a/phase4a-ui`. See [phase status](docs/PHASE_STATUS.md) and [user manual](docs/USER_MANUAL.md).

Relevant merged work:

- [PR #9](https://github.com/Ejv1k/PulseDeckAI/pull/9): Phase 3A waveform UI and cue persistence, merged at `54dbb9712a3f24d97ea6f63b844d21490530a386`.
- [PR #11](https://github.com/Ejv1k/PulseDeckAI/pull/11): Phase 4A transition backend, merged at `bda0b256f814d4f1625cef29a41471d6cc0b6593`; full transition UI/integration is not complete.
- [PR #12](https://github.com/Ejv1k/PulseDeckAI/pull/12): real macOS Swift build/tests and Python CI, merged at `b1c2e0c94c0de1c25b58f00628c4cfb261313872`.
- [PR #13](https://github.com/Ejv1k/PulseDeckAI/pull/13): Phase 3B Block 1 studio shell, independent output routing, and startup/recovery safety, merged at `9bb69ca3534cea1e5b298bbbcab6e743e80179a5`.

## PR14 merged status and evidence

Original source branch: `feat/phase-3b-library-cue-preview`. Implementation owner: `pulsedeckai-78` (`gemini-3.8-flash-high`); coordinating orchestrator: `pulsedeckai-77`. Prior owner work remains held, with existing branches and worktrees preserved.

PR #14's approved head was `1352dbf680baa502372f12858b0deb66b7fc0e67`. Merge commit `ec582558c6a0ffd9a3ddfb3b4b943ca28ec43b43` has parents `9bb69ca3534cea1e5b298bbbcab6e743e80179a5` and the approved head. Its tree `496213f1d12e09a98050c314f51869307ab00957` exactly matches the approved head tree.

[Exact-head PR CI 39850064996](https://github.com/Ejv1k/PulseDeckAI/actions/runs/39850064996) succeeded on `1352dbf`: build, **249 Swift tests**, and **40 Python tests**. This is the final PR-head CI result; historical code-head run `39757702690` at `6446b82` (247 Swift / 40 Python) and documentation-head CI `39793773350` at `111e994` are separate earlier runs, not evidence for `1352dbf`.

Automatic post-merge main CI [39904377040](https://github.com/Ejv1k/PulseDeckAI/actions/runs/39904377040) completed **SUCCESS** on merge commit `ec582558c6a0ffd9a3ddfb3b4b943ca28ec43b43`: **249 Swift tests** and **40 Python tests**. This main push run is distinct from PR CI `39850064996`.

Coordinator-verified native Grok review `caf8ed06-a7ca-4fa8-b618-942d640214d1` completed **APPROVED / up_to_date** on exact head `1352dbf`. Provider review `5621152438` is **COMMENTED** with native approval text; it is not a GitHub `APPROVED` review. All four PR review threads are resolved. The two review channels and their states must remain distinct in future summaries.

Review findings fixed and their provider threads resolved:

- [4346578316](https://github.com/Ejv1k/PulseDeckAI/pull/14#discussion_r4346578316), `PRRT_kwDOVJOZu86vHy1f`: immediate CUE playback now waits for successful current-request installation. Pending intent can be cancelled; failures cannot play the previous file or publish false playing state.
- [4346578333](https://github.com/Ejv1k/PulseDeckAI/pull/14#discussion_r4346578333), `PRRT_kwDOVJOZu86vHy1s`: file preparation performs no player mutation. MainActor identity checks and serialized player request tokens reject stale selection/root/stop completions before installation. Production regressions verify actual Cue PCM and Master transport/fader isolation.
- [4349752755](https://github.com/Ejv1k/PulseDeckAI/pull/14#discussion_r4349752755), `PRRT_kwDOVJOZu86vPYjb`: play requests for an unready or failed track path trigger file reloading and arm playback upon completion. Paused preview whose file is already installed toggles play without reloading. Player stays silent until the requested file installs. Tested in `testPlayRequestForFailedTrackReloadsAndArmsPlayback`.
- [4349752771](https://github.com/Ejv1k/PulseDeckAI/pull/14#discussion_r4349752771), `PRRT_kwDOVJOZu86vPYjk`: `HarmonicCompatibility.isAuthenticMeasuredGrid` removes sample-accurate per-beat equality so authentic librosa analysis with natural transient jitter of tens of ms is accepted. Retains strict rejection of nonpositive BPM/confidence, empty/single beat timestamps, interval inconsistent with 60/BPM, nonfinite/out-of-file/non-strictly-increasing timestamps, and unknown-tempo sentinels. Tested in `testAuthenticMeasuredGridAcceptsRealisticJitterAndEnablesBeatSteppingAndCompatibility`.

Negative proof preceded behavioral repair: all three primary production regressions failed with 11 assertions at the old code behavior. The PR body retains that evidence, prior feature history, and the necessary older-Swift ownership fixes. Historical code and documentation evidence remains scoped to its recorded head.

## Next concrete slice: Phase 4A UI & AutoPilot integration

Phase 4A UI and AutoPilot integration is implemented in open [PR #15](https://github.com/Ejv1k/PulseDeckAI/pull/15), based on merged `main` `ec582558c6a0ffd9a3ddfb3b4b943ca28ec43b43`. It adds three macro controls, 8/16/32-bar phrase selection, one-click dispatch, readiness/error/progress state, cancellation, and AutoPilot arm/disarm atop the existing actor. PR #15 remains open, not independently approved on the repaired head, and not merged.

### Historical CI and independent review

- Original implementation/documentation head `d80f4ea261943d0c414459ee54f4845d3b33a52c` passed [CI 39905357927](https://github.com/Ejv1k/PulseDeckAI/actions/runs/39905357927): build, **252 Swift tests**, **40 Python tests**. This historical result does not prove the later repairs.
- One native Grok launch, `036d4bf5-a78e-432a-aef4-0db10ff3a7a6`, failed before model execution: `launch reviewer: reviewer replace stale pane: tmux runtime: set detach-on-destroy review-pulsedeckai-79: exit status 1: no such session: =review-pulsedeckai-79:`. This is a launcher failure, not a review, verdict, or approval.
- The user authorized conditional independent Sol fallback. Native Sol review `5c21a560` completed **changes_requested** on `d80f4ea`; [provider review 5624445263](https://github.com/Ejv1k/PulseDeckAI/pull/15#pullrequestreview-5624445263) is **COMMENTED** and records three required findings. A failed Grok launch must never be substituted for that completed review.
- Accepted cue-metadata fix `a5994349161dcb5bf9b69fe71d520df0e5d54989` passed [CI 39908548272](https://github.com/Ejv1k/PulseDeckAI/actions/runs/39908548272): build, **253 Swift tests**, **40 Python tests**. This result precedes the gain and DISARM repairs below.

### Required findings and repair proof

- `PRRT_kwDOVJOZu86vfWn-` / [4356561679](https://github.com/Ejv1k/PulseDeckAI/pull/15#discussion_r4356561679): fixed and resolved in `a599434`. Readiness and dispatch resolve the latest loaded-cache entry by track path and fingerprint. Its saved-cue regression failed four assertions before repair and remains covered unchanged.
- `PRRT_kwDOVJOZu86vfWoD` / [4356561685](https://github.com/Ejv1k/PulseDeckAI/pull/15#discussion_r4356561685): repaired in the commit containing this section. Successful manual loads and stopped-deck playback restore unity channel gain on the audio control queue. Armed or active automation rejects manual load/play. Crossfader weights and Cue gain remain independent. The preserved predecessor regression failed four assertions; extended production-path tests verify Hard Cut completion followed by reload/play, direct incoming restart after cancellation, actual Master PCM, and Cue PCM/control preservation.
- `PRRT_kwDOVJOZu86vfWoH` / [4356561689](https://github.com/Ejv1k/PulseDeckAI/pull/15#discussion_r4356561689): repaired in the commit containing this section. DISARM retains observation when the refreshed service snapshot remains armed or in progress; only a terminal snapshot stops observation. A deterministic regression holds MainActor publication while the production service fires before DISARM. Before repair it failed eight assertions despite service completion. After repair, AppState reaches completion/progress 1, publishes deck handoff, and unlocks transport/crossfader controls.

Local final gates passed: `swift build -q`, `swift test -q` (**254 Swift tests**, zero failures), and `python3 -m unittest discover -s scripts/tests -q` (**40 Python tests**, zero failures). Focused verification passes **5 integration tests** with mocked hardware and offline AV rendering. The repair changes AppState and regression coverage only; the production transition backend is unchanged. The new repair head still requires its own automatic provider CI and one coordinator-dispatched final independent audit. Historical 252/253-test runs above are not latest-head evidence. Provider thread resolution and green exact-head CI are handoff gates before that audit.

### Bounded Phase 4B talkover path map

- Current deck Master signal path uses `DeckAudioGraph.masterEQNode` then `masterFaderNode`; Cue uses distinct nodes and a separate engine. `DeckAudioGraph.eqParameters` applies values to both Master and Cue EQ nodes, so Phase 4B must not use that setter for talkover attenuation.
- `masterFaderNode.outputVolume` is currently recomputed as channel volume × crossfader weight. A talkover multiplier must compose independently with that value and restore the prior state without overwriting channel volume or crossfader intent. Prefer a dedicated Master-only multiplier/state in `DeckAudioGraph`; do not write the fader directly from UI code.
- Current Master EQ has low shelf near 250 Hz, mid peak near 1.2 kHz/Q 1, and high shelf near 3.5 kHz. Those three bands do not exactly represent a 300 Hz–3 kHz, −4 dB span. Use a Master-only dedicated EQ shape/path or document and verify an accepted approximation; preserve Cue EQ unchanged. Coordinate talkover EQ save/restore with transition EQ commands to prevent stale restoration.
- Likely narrow touch points: `DeckAudioGraph.swift` for isolated Master attenuation/EQ state and ramp application; `AudioEngineCoordinator.swift` only if a single shared talkover controller is required; `DeckStudioView.swift` and `AppState.swift` for T-key/button state and lifecycle; focused `PulseDeckCoreTests` and app integration tests. Reuse existing graph and audio-control contracts; no backend redesign.
- Acceptance proof: T press and release are idempotent; 800 ms linear attenuation reaches 0.15 and restores captured Master gain over 800 ms; EQ reaches −4 dB across the specified band and returns exact prior Master values; Cue nodes/engine and preview level remain unchanged; cancellation, duplicate input, track changes, transition overlap, and app teardown leave no stale task or altered user gain/EQ. Use mocked output and offline rendering only; do not access `inputNode` or live output.

## Stop boundary and remaining limits

PR14 is merged. All three required PR15 findings have code fixes; final exact-head CI and independent audit remain pending for this repair commit. The coordinator dispatches one native audit only after all three provider threads are resolved and the exact repaired head passes CI. Grok remains primary; Sol is the user-authorized conditional fallback. Do not self-trigger review, merge PR15, or begin Phase 4B implementation. The talkover map above is a draft only.

AO hotfix deployment was cancelled. No hotfix was installed. No AO installation, restart, project removal, backup, or deployment work belongs to this handoff.

Offline AV rendering and mocked output HAL establish automated control/publication and PCM behavior. Physical speakers/headphones, Bluetooth behavior/latency, pointer-driven GUI delivery, live Gemini/Ollama providers, and the full Phase 4A UI flow remain unverified. No new microphone access or audio permission was introduced.
