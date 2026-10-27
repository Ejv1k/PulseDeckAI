# PulseDeck AI continuation

Updated: 2026-10-27

## PR #24 review follow-up: loaded source identity (candidate)

Published head `f156fa4622a134b715bddca1a8a07801c38dc319` passed automatic PR CI40397072073 with 346 Swift and 40 Python tests. Native audit `491d8da5-f9a6-4a4b-9bba-62290093cc32` subsequently requested two AppState fixes (provider5658706269, not approval): duration-only cache reuse accepted replaced audio, and comparing analyzer-specific fingerprint strings prevented unchanged Python-cache tracks from adopting local analysis. This historical CI does not prove the follow-up candidate.

The repair validates real source identity before adopting analysis. Local size/millisecond-mtime fingerprints are checked immediately. Existing Python fingerprints are raw-file SHA-256 values; validation streams bounded 1 MiB chunks off MainActor and the audio control/render queues. Header-only loading and playback remain available while hashing, with automation blocked until measured metadata is verified. Adoption requires the current request, root, loaded URL and stable filesystem identity, and resolves the current cache/editor publication rather than adopting a captured old entry. No DSP analysis runs automatically on LOAD.

Loaded source identity is retained independently of the analyzer's fingerprint encoding. An unchanged file can therefore move from Python SHA-256 cache metadata to local size/mtime metadata on both decks without reloading transport, changing schedule generations or losing transition readiness. New-root, changed-source and cancelled/replaced validation results remain rejected. Manual cue/bypass edits and newer local analysis retain priority over a held hash task.

Controlled failure proofs: same-path/equal-duration replacement produced eight failures across stat/SHA cache cases before validation; reinstating the original encoding guard in isolation produced three A/B metadata/readiness failures, then restoring the repair passed. The raw SHA implementation matches a 1,048,835-byte golden vector produced by the actual `scripts/analyze_library.py::_fingerprint` function. Focused proof passes **63 tests** (22 workflow, 16 Safety Lock, 6 transition and 19 Cue), including held current-publication/manual/local-analysis and cancellation cases. The current build and **40 Python tests** also pass.

Only three legacy fixture files migrate invented fingerprints to genuine values after WAV finalization: MasterSafetyLockIntegrationTests.swift, TransitionStudioIntegrationTests.swift and the reference-deck fixture in LibraryCuePreviewTests.swift. All behavioral assertions/scenarios are retained. DeckStudioView, LibraryBrowserView, Core, schema and persistence code remain unchanged in this follow-up; worker82 retains presentation ownership.

The user's offline-only override applies to local testing. The final local offline selection passed **352 Swift tests**, zero failures; only OutputRoutingStudioTests.testDefaultAppStateStartsCoordinatorAndMonitorsTopology was excluded because AppState() starts real SystemAudioHardware engines. This is explicitly not a full local-suite claim. The final build and 40 Python tests pass. All test source/assertions remain present; unchanged automatic hosted CI supplies its own full-suite result after the repair push. Only private MockHAL/manual-offline PCM was exercised locally. Exact-head hosted CI and a fresh independent native audit remain required. The follow-up is not independently approved, merged, or a native fixed-candidate UI verification.

## Initial PR #24 library workflow proof (historical candidate at f156fa4)

This branch starts from `84dbb199e551a2c6851bb2545f4873f093cb4921`, the merged root-layout PR #23. Its automatic main push CI [40378538421](https://github.com/Ejv1k/PulseDeckAI/actions/runs/40378538421) passed 331 Swift and 40 Python tests. The delivered local app from that source is the user's reported reference; that historical proof does not prove this new repair.

The production LOAD action silently returned whenever a selected file lacked an analysis-cache entry. The library already selected fresh files, but no decoder or graph load ran. Library drag/deck drop handlers and an app action for the existing local analyzer were also absent.

`AppState.loadTrack(relativePath:deck:)` now validates a readable supported library file and obtains header metadata independently of analysis. Both production LOAD buttons and typed native library drops use that boundary. Empty/corrupt files, invalid or redirected paths, stale-library and multiple-track drops receive visible deck feedback. Safety Lock and pending/armed/running automation retain the existing atomic graph mutation guard; a successful drop focuses its target without changing library selection. Programmatic loads retain their prior keyboard-focus semantics. No Core/audio/keyboard/Projector implementation changes are included.

Each library row exposes an explicit local ANALYZE action, an indeterminate running state, completion or actionable failure. Analysis is optional for playback. LocalTrackAnalyzer computes waveform, trim estimates and heuristic tempo; key remains Unknown and vocal timing is not voice recognition. There is no batch action, automatic analysis on LOAD, cloud requirement or new output route. Analysis and manual edits share the existing WaveformTrackPersisting actor and editor submission/publication chain. File fingerprint checks, root/task cancellation and selection/interaction guards prevent stale results from replacing current editor state; manual cue and bypass overrides survive persistence and reanalysis.

The production row/LOAD Button regression failed four assertions before the behavior fix: loaded URL, metadata, duration and actual offline Master PCM. The same actions pass for fresh WAV and MP3 with default Safety Lock on. Public SwiftUI primitive button activation is used in own-view tests; this is not physical pointer or global event delivery. Typed transfer serialization/dispatch and production drop wiring are tested/inspected without claiming an OS drag gesture. Controlled persistence gates cover newer manual cue/bypass edits, stale selection, source changes and root cancellation. Invalid cache bytes remain untouched and do not block basic loading.

The first candidate full Swift run executed 344 tests and failed only one old test with six assertions: OutputRoutingStudioTests.testDualDeckLoadSelectedTrackIntoDeck retained its WAV writer while opening a separate reader. A bounded private probe proved zero frames before writer finalization and 4,410 afterward. The authorized migration only scopes that test's writer in autoreleasepool, preserving all original assertions and production validation. The dedicated finalized-empty/valid WAV regression and repaired legacy test pass. The workflow group initially passed 14 tests and the migrated legacy test also passed; the repaired intermediate build/full 345 Swift tests passed. A further controlled equal-relative-path/equal-fingerprint case across two roots reproduced one metadata-adoption failure. Requiring the actual loaded graph URL before adopting analysis fixed it without changing transport. The final workflow group passes 15 tests; final `swift build -q` and the full **346 Swift tests** pass, zero failures. The unchanged independent Python suite passes **40/40**. No old baseline suite or workflow was rerun for a checklist.

Private functional checkpoint `191b87893e4f683aa574ee2a6b6ed518b930e46d` is build/focused proof only. DeckStudioView and LibraryBrowserView presentation ownership was explicitly handed to worker82 at that frozen checkpoint; this branch does not consume its later private design work. AppState, editor persistence, transfer helper, functional tests and these handoff documents remain worker80's scope. New exact-head CI and a fresh independent native audit are required before merge; no approval or merge is claimed here. Ordinary app/audio/device testing remains independently coordinated, with no user-library, provider, input or permission operations in these offline checks.

## Root viewport reachability repair (merged PR #23)

The repair branch `ao/pr15-fixes/root-layout` starts from green main `7ca8763e33a89bdd384ca69bc6a28a6aadfc2a82` (documentation-only PR #22, merged 2026-10-26T10:51:33Z, parent `6322edb944d82c0888aae1e757a277dba8809468`, tree `47de667d434d72da29147590b35e6ceaa6cb4db3`). Its automatic main CI [40310664952](https://github.com/Ejv1k/PulseDeckAI/actions/runs/40310664952) passed 329 Swift and 40 Python tests. This is historical base proof, separate from the repair's new results.

The isolated native geometry check (PID93302) reproduced clipping in the real ContentView at legal 1024×680, 1200×760 and current visible-area 1512×884 proposals. Both output selectors had zero visible area at y=-171.5/-131.5/-69.5 respectively; the only scroll container belonged to the crate list. The ordinary WindowGroup was not launched, so no ordinary-app default/minimum-size behavior is claimed.

Only ContentView changes in production: a root vertical ScrollView keeps all sections reachable, and a finite 300-point library viewport preserves independent nested scrolling. The declared app minimum/ideal sizes, child actions, meter ownership, Safety Lock, Projector, keyboard routing and Core audio implementations are unchanged.

The new dedicated RootLayoutReachabilityTests failed 15 assertions across two tests before the fix, then passed. They check real native control visibility or actual root clip movement at legal viewports, return to the top controls, and independent movement of a 32-crate inner list without moving the root. Final local gates passed `swift build -q`, **331 Swift tests** and **40 Python tests**, zero failures.

Matching-source native positive geometry (PID2291, exit0/reaped) verified the same three sizes with nil audio injection and the unchanged restrictive private host policy. Output selectors are fully visible at y=123; root scrolling by 667/587/463 points reveals the lower audition control and scrolling back restores the output controls. All six native controls were visible or reachable per size. ContentView SHA-256 is `2c974cba3cf4f65dee638115f0103c1699606af52b71ce94ba9afaec698df944`. The host stayed inactive, frontmost app and private fixtures were unchanged, and no ordinary app, audio, provider, AX or permission path was used.

PR #23 subsequently merged at `84dbb199e551a2c6851bb2545f4873f093cb4921` on 2026-10-26T18:31:46Z, parent `7ca8763e33a89bdd384ca69bc6a28a6aadfc2a82`. Approved source `391850557ba490f49d836da8b1dad75031cd9980` and merge share tree `3b708e560700eae978a9e85b52f33c0ce31d9e7f`. PR CI40348246514 and automatic main CI40378538421 each passed 331 Swift/40 Python. Native audit d9d99dbb-df19-446a-9ead-b712b3952873 approved internally; provider5654552382 was COMMENTED, not GitHub APPROVED. This is historical root-layout proof, distinct from the new workflow repair. Physical pointer/frontmost key/menu delivery, ordinary startup, real output devices/Bluetooth and external projector behavior remain unverified.

## Historical implementation/documentation baseline at 6322edb (after PR21)

The verified PR21 implementation/documentation baseline was `6322edb944d82c0888aae1e757a277dba8809468`. PR #21 merged at `2026-10-25T20:44:05Z` via normal AO squash (sole parent `cfd7d206da1bb455fbbcf5de6ce13be42fd081d9`, merge tree `47e2927bc65064edf55bdab4058abcff448ccea9` exactly matching approved feature head `29bfd01afacdd3e1f7d8968d4f028914fc494195`). Automatic post-merge main push CI run [40232158237](https://github.com/Ejv1k/PulseDeckAI/actions/runs/40232158237) completed **SUCCESS** with **329 Swift tests** and **40 Python tests**, zero failures. Native Sol audit `8e85bb1a-c9bf-423a-acee-9e176eb19cba` completed APPROVED (internal); provider review `5645079322` commented internal approval. PR CI [40230402157](https://github.com/Ejv1k/PulseDeckAI/actions/runs/40230402157) (329 Swift / 40 Python) remains distinct historical feature proof. Check remote `main` for subsequent documentation maintenance commits.

Phase 5A and Phase 5B are now completely merged to `main`.

### Historical Merge & Recovery Context
1. **PR #18 (Projector Window & Visuals)**: Merged at `bfd1fc214d9b421321119253705768d3243ee3ce` (parent `a8095ca64e09c5ba78dc17fff26e76c320e2b430`, merge tree `0b0db9fb32e1d5abaf0bd36f295fbb99c173c774`). PR CI [40191168012](https://github.com/Ejv1k/PulseDeckAI/actions/runs/40191168012) passed 313 Swift and 40 Python tests; native Sol audit `136e0ef8-a401-43d5-9ce6-836ab375473a` completed APPROVED; provider review `5643131826` commented internal approval; all 9 review threads were resolved.
2. **Main Push CI 40192024850**: Automatic main push CI [40192024850](https://github.com/Ejv1k/PulseDeckAI/actions/runs/40192024850) on `bfd1fc2` failed 1 of 313 Swift tests in `testSingleMeterPollingOwnerFansOutDestructiveSnapshotsAndCancels` at line 547 (`XCTAssertNotNil failed - Projector subscription keeps polling alive`). Python tests (40) and build passed.
3. **PR #20 (Deterministic Meter Liveness Recovery)**: Worker84 controlled diagnosis proved that a legitimate 30 Hz empty polling tick could drain an empty real transfer ring and clear the cached snapshot while the other subscriber remained active, causing the non-nil assertion to fail intermittently. Production code was unchanged; the test was corrected to prove liveness via delivery of a fresh producer frame rather than cached persistence. Approved candidate `bc2bc87c984795f84cda0e173f3920f314a06d05` passed PR CI [40221545843](https://github.com/Ejv1k/PulseDeckAI/actions/runs/40221545843) (313 Swift / 40 Python); native Sol audit `58341716-ee62-46f7-94e6-5e2667e595ae` completed APPROVED; provider review `5644677401` commented internal approval. Squash-merged to `main` at `2b2a7b40524d91fd7e51fcb7e06a62ff96b92330`, restoring main CI to green ([40225347504](https://github.com/Ejv1k/PulseDeckAI/actions/runs/40225347504)).
4. **PR #19 (Master Safety Lock)**: Concurrently developed by worker80 on branch `ao/pr15-fixes/master-safety-lock`. Combined head `b1f6a10140f0825b42f813b33915cf63866e3d71` integrated green `main` `2b2a7b40524d91fd7e51fcb7e06a62ff96b92330`. Feature CI [40225891954](https://github.com/Ejv1k/PulseDeckAI/actions/runs/40225891954) passed 329 Swift / 40 Python tests; native Sol audit `600cf197-b24e-43d1-bc88-d6a3f86cfbfa` completed APPROVED; provider review `5644884694` commented approval. Merged to `main` at `cfd7d206da1bb455fbbcf5de6ce13be42fd081d9` at 2026-10-25T19:45:49Z with main push CI [40227566733](https://github.com/Ejv1k/PulseDeckAI/actions/runs/40227566733) SUCCESS (329 Swift, 40 Python).
5. **Phase 5B (Final Documentation & Polish)**: Merged in [PR #21](https://github.com/Ejv1k/PulseDeckAI/pull/21) at `6322edb944d82c0888aae1e757a277dba8809468` at 2026-10-25T20:44:05Z (sole parent `cfd7d206da1bb455fbbcf5de6ce13be42fd081d9`, approved head `29bfd01afacdd3e1f7d8968d4f028914fc494195`, merge tree `47e2927bc65064edf55bdab4058abcff448ccea9`). Addressed 6 review comments across docs (`USER_MANUAL.md`, `README.md`, `TECHNICAL_ARCHITECTURE.md`, `PHASE_STATUS.md`, `CONTINUATION.md`) on cue keys (`I`/`O`/`V`/`M`), unbound shortcuts, button workflows, DSP vs UI controls, one-shot Auto-Pilot, and key analysis limits. PR CI [40230402157](https://github.com/Ejv1k/PulseDeckAI/actions/runs/40230402157) and main push CI [40232158237](https://github.com/Ejv1k/PulseDeckAI/actions/runs/40232158237) passed 329 Swift and 40 Python tests. Native Sol audit `8e85bb1a-c9bf-423a-acee-9e176eb19cba` approved; provider review `5645079322` commented approval; all 6 review threads resolved.

Relevant merged work on `main`:
- [PR #9](https://github.com/Ejv1k/PulseDeckAI/pull/9): Phase 3A waveform UI and cue persistence (`54dbb9712a3f24d97ea6f63b844d21490530a386`).
- [PR #11](https://github.com/Ejv1k/PulseDeckAI/pull/11): Phase 4A transition backend (`bda0b256f814d4f1625cef29a41471d6cc0b6593`).
- [PR #12](https://github.com/Ejv1k/PulseDeckAI/pull/12): Real macOS Swift build/tests and Python CI (`b1c2e0c94c0de1c25b58f00628c4cfb261313872`).
- [PR #13](https://github.com/Ejv1k/PulseDeckAI/pull/13): Phase 3B Block 1 studio shell, independent output routing (`9bb69ca3534cea1e5b298bbbcab6e743e80179a5`).
- [PR #14](https://github.com/Ejv1k/PulseDeckAI/pull/14): Phase 3B Block 2 library cue preview and audition engine (`ec582558c6a0ffd9a3ddfb3b4b943ca28ec43b43`).
- [PR #15](https://github.com/Ejv1k/PulseDeckAI/pull/15): Phase 4A transition studio controls and AutoPilot (`2d428d22c1f0ef3f54c271391589d35b605b859a`).
- [PR #16](https://github.com/Ejv1k/PulseDeckAI/pull/16): Phase 4B Master-only talkover ducking and vocal pocket EQ (`5a639de99b6ffc00ebeddd6fcf2eef77cf896526`).
- [PR #17](https://github.com/Ejv1k/PulseDeckAI/pull/17): Phase 4B RAM-preloaded 8-pad soundboard and F1–F8 hotkeys (`a8095ca64e09c5ba78dc17fff26e76c320e2b430`).
- [PR #18](https://github.com/Ejv1k/PulseDeckAI/pull/18): Phase 5A secondary Projector window and visuals (`bfd1fc214d9b421321119253705768d3243ee3ce`).
- [PR #20](https://github.com/Ejv1k/PulseDeckAI/pull/20): Test-only recovery for shared meter polling liveness (`2b2a7b40524d91fd7e51fcb7e06a62ff96b92330`).
- [PR #19](https://github.com/Ejv1k/PulseDeckAI/pull/19): Phase 5A Master Deck Safety Lock (`cfd7d206da1bb455fbbcf5de6ce13be42fd081d9`).
- [PR #21](https://github.com/Ejv1k/PulseDeckAI/pull/21): Phase 5B product documentation and alignment with shipped runtime (`6322edb944d82c0888aae1e757a277dba8809468`).

---

## Phase 5A Slice 1: Secondary Projector Window & Visuals (Keys `1`–`4`)

The bounded Phase 5A Projector slice is fully merged to `main`:
1. **Four Presentation Modes (`Keys 1–4`)**:
   - **Mode 1 (`Key 1`) — Master FFT Visualizer**: Maps 512 linear FFT bins from `AudioMeterSnapshot` into 24 perceptually-spaced visualizer bands with smooth attack/decay ballistics. Consumes published snapshots from `AudioMeteringService` with zero audio RT allocations, zero locks, and honest silence decay to 0.0.
   - **Mode 2 (`Key 2`) — Media Slideshow & Video Loops**: Discovers photos (JPG, PNG, HEIC, WEBP, TIFF) and video loops (MP4, MOV, M4V) from `09_Visual_Backgrounds_Media`. Downsamples photos with a 48 MB / 20 photo RAM cache. Videos are strictly muted (`isMuted = true`, `volume = 0.0`), guaranteeing zero audio leakage into Master PA or Headphone Cue. Corrupt media or empty crates display an ambient honest idle fallback.
   - **Mode 3 (`Key 3`) — Now Playing & Event Title**: Displays active on-air track title, artist, BPM, and musical key derived from Master deck state, plus customizable event banner text (e.g. *"Sarah & Michael's Wedding — October 14, 2026"*).
   - **Mode 4 (`Key 4`) — True Blackout**: Solid pitch-black canvas (`Color.black`) with zero light or controls leaking onto the audience screen.
2. **Window Lifecycle & Display Detection**: Managed by `ProjectorWindowController` (`NSWindowController`), prioritizing external secondary displays and falling back to the main display. Listens for `NSApplication.didChangeScreenParametersNotification` to safely reposition windows on disconnect without audio disruption. Supports standard macOS fullscreen (`Cmd + Ctrl + F`).
3. **Context-Sensitive Keyboard Routing (`ProjectorKeyboardRouter`)**: Routes keys 1–4, drops OS repeat events, debounces multi-route dispatches within 120 ms, and checks first-responder text editing (`NSTextField`, `NSTextView`, `NSText`) so digits 1–4 are never stolen while editing the event banner.
4. **DJ Control Sheet (`ProjectorBannerEditorView`)**: Accessible via `Projector > Configure Event Banner...` for editing event titles without audience display leakage.

---

## Phase 5A Slice 2: Master Deck Safety Lock (Merged in PR #19)

Developed by worker80 in PR #19 and merged to `main` at `cfd7d206da1bb455fbbcf5de6ce13be42fd081d9`:
1. **Default-On Protection**: Enabled upon startup. Protects any loaded deck actively broadcasting to Master with nonzero channel or crossfader gain.
2. **Control-Queue Graph Authority**: On-air status is evaluated synchronously on the audio control queue against real graph state, protecting both decks during crossfades.
3. **Guarded Actions**: Manual pause, stop, track replacement/load, and live playhead seek commands are intercepted and rejected with nonmodal warning feedback.
4. **One-Shot Override (`Shift + Space`)**: Pressing `Shift + Space` allows a one-shot pause of the focused on-air deck without clearing persistent lock protection.
5. **Automation & Cue Isolation**: Automated transitions, headphone Cue audition, and non-destructive waveform cue editing are completely exempt from manual transport locking.

---

## Next Operational Steps: Native UI Readiness & Hardware Verification

1. **Operational Native UI Readiness & Smoke Testing**:
   - Isolated native host PID85908 passed real root controls, Projector lifecycle/modes/blackout and native text binding without audio or activation. This does not prove ordinary startup, physical input or App menus.
   - Legal-viewport geometry exposed root overflow, repaired and merged in PR #23 as recorded above. The current library-workflow candidate still requires its own exact-head CI and independent review.
   - Preserve all existing branches, worktrees, media assets and native evidence; no feature expansion is part of this repair.
2. **Hardware & Physical IO Verification (Deferred/Unverified)**:
   - Physical output audio interfaces and dual stereo routing remain unverified on hardware.
   - External HDMI/DisplayPort display scaling and projector disconnect recovery remain unverified on physical hardware.
   - Bluetooth audio output latency and clock drift remain unverified.
   - Live cloud LLM provider API credentials and rate limits remain external.

---

## Boundaries and invariants

- **Strictly Output-Only**: Zero `engine.inputNode` calls, zero microphone permissions, zero audio input latency overhead.
- **Real-Time Safety**: Render callbacks execute without allocations, locks, or ARC retain/release.
- **Non-Destructive Cue Editing**: Waveform cue editing playhead is strictly isolated; moving cue markers does not alter live Master audio playback.
- **Accurate Review Reporting**: Native AO audit approvals (`APPROVED / up_to_date`) remain distinct from provider `COMMENTED` reviews. Grok review history accurately recorded (pre-model failure + 900s timeout; no approval exists).
- **Tooling Invariants**: Normal AO workflow APIs operated as expected for sessions and automations. All launcher repairs, backups, snapshots, and manual deployments remain cancelled. Zero AO database, harness configuration, or installer modifications were performed.
- **Hardware Verification Scope**: Offline CI verifies audio graphs, PCM math, vDSP analysis, transition curves, RAM soundboard preloading, and secondary window event routing. Physical output audio devices, HDMI display scaling, Bluetooth latency/clock drift, live cloud provider endpoints, and physical pointer automation remain unverified.
