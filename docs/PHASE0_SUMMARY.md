# PulseDeck AI — Phase 0 Operational Foundation & Architecture Contracts
**Authoritative Phase 0 Status & Phase 1 Handover Specification**

> **USER SCOPE OVERRIDE:** **STOP AFTER PHASE 0.** No Phase 1 or additional implementation work until explicitly requested in a fresh session. Merging PR #1 and advancing to Phase 1 are not automatic steps.  
> **Document Purpose:** Accurate repository state, component inventory, open notes, and Phase 1 contract handover. Enables any fresh orchestrator or engineer to resume development without prior chat context.  
> **Repository:** `https://github.com/Ejv1k/PulseDeckAI.git`  
> **Pull Request:** [PR #1: feat: implement Phase 0 operational foundation and architecture contracts](https://github.com/Ejv1k/PulseDeckAI/pull/1)  
> **Target Hardware Baseline:** Apple Silicon MacBook Pro 14" / 16" (M1 Pro, 16GB Unified Memory)  
> **Target Software Platform:** macOS 14.0+ (Sonoma) / macOS 15.0+ (Sequoia), Swift 6.0 Concurrency Mode  

---

## 1. Project & Review Gate Status

### 1.1 Review State & Commit Lineage
* **PR Status:** PR #1 is **OPEN** and **UNMERGED** against `origin/main`.
* **Remote Baseline:** `origin/main` commit `5aa14b44c8cfa65276342abd9408fbef5fbdf7ea` (empty root commit, 0 tracked files, zero media ancestry).
* **Final Code Lineage:**
  * Last Reviewed SHA: `ff47ce7abbce3776f01fb7c3347762130c9c594c` (native Grok run `9e756a3c-62fc-416a-b559-1dca7d127c1d` verdict: `CHANGES_REQUESTED` on `ff47ce7`).
  * Product Code Head SHA: `f0784c89f3ef5322aff2dd415c2b7ba73fd3e31e` (Grok confirmed all code fixes correct: manual cue clamping, non-finite manual cues, non-finite automated cues substitution to 0.0 before clamping, invalid duration fail-safe, atomic F_FULLFSYNC, schema validation, and LatencyCompensation non-finite offset handling).
  * Test Suite Update: `d34f8a8d4c2d2bbb6a08127d7ae53b3c32dda504` added `test_reanalysis_with_infinity_automated_cues_and_manual_bpm_override` to `scripts/tests/test_pulsedeck_cache.py`.
  * Documentation Hash Alignment: `ff47ce7abbce3776f01fb7c3347762130c9c594c` aligned exact commit hashes in `docs/PHASE0_SUMMARY.md`.
  * Documentation-Only Fix: `130bfc36f31bb037520cd949e603df0de9a84ad1` updated `README.md` lines 238-239 to replace absolute worktree URLs with relative paths `docs/TECHNICAL_ARCHITECTURE.md` and `docs/USER_MANUAL.md` (thread `PRRT_kwDOVJOZu86szlyc` resolved).
* **Audit & Approval Status:**
  * Product sources under `Sources/` are unchanged since `f0784c8`; the Python test file (`scripts/tests/test_pulsedeck_cache.py`) is not unchanged, having received an additional test in ancestor commit `d34f8a8`. Documentation fixes are pending final re-review.
  * There is **NO current approval**.
  * Resolved review threads (all 17 threads on PR #1 resolved) are an internal AO prerequisite, but do **NOT** constitute review approval. Native AO review checks do **NOT** constitute independent GitHub PR approval.
* **Phase Boundary:** **Phase 1 has NOT been started.** STOP AFTER PHASE 0. PR #1 must not be merged to `main` until explicitly authorized in a fresh session.

### 1.2 Automated Verification Status
> *Note: Build and test evidence belongs to the latest code commit with review fixes, not fresh execution on documentation-only edits.*

* **Swift Test Suite:** 24/24 tests passing (0 failures).
* **Python Test Suite:** 35/35 tests passing (0 failures) via `scripts/tests/test_pulsedeck_cache.py`.
* **Companion Cache Validator:** `python3 scripts/pulsedeck_cache.py` validates `PulseDeck_Library/.pulsedeck_ai_cache.json` with exit code 0.
* **Release Executable Build:** `swift build -c release` succeeds; produces `.build/release/PulseDeckAI` (Mach-O 64-bit arm64, 925 KB).
* **Quiet Swift Build Verification:** `swift build -q` executed with exit code 0.
* **Physical Hardware Validation:** Zero physical audio device validation has been conducted in Phase 0. No physical DAC routing, Bluetooth A2DP latency calibration, or hardware audio output has run.

---

## 2. Git Hygiene & Worktree Source-of-Truth

### 2.1 Worktree Directory Structure & Legacy Caution
* **Active Authorized Worktree (Source-of-Truth):**  
  `/Users/tomaselagin/.ao/data/worktrees/pulsedeckai/pulsedeckai-2`  
  Branch: `phase-0-foundation` tracking `origin/phase-0-foundation`.
* **Legacy Checkout Caution:**  
  The original local checkout at `/Users/tomaselagin/Desktop/PulseDeckAI` has old media-tracking ancestry (commit `fe2a499` tracked 25 MB of binary MP3 files). Preserve media and local history, and do **NOT** publish `fe2a499` ancestry to remote. Use the PR review branch `phase-0-foundation` or a clean checkout when resuming.

### 2.2 Local Media Preservation
The 7 development audio files remain physically preserved in `PulseDeck_Library/00_Test_Tracks_Dev/`:
1. `ABBA - Gimme! Gimme! Gimme! (A Man After Midnight).mp3` (3.3 MB)
2. `AC⧸DC - Highway to Hell (Official Video).mp3` (3.4 MB)
3. `Daft Punk - One More Time (Official Video).mp3` (5.2 MB)
4. `Dua Lipa - Don't Start Now (Official Music Video).mp3` (2.9 MB)
5. `Ed Sheeran - Perfect (Official Music Video).mp3` (4.2 MB)
6. `KABÁT - Pohoda.mp3` (3.5 MB)
7. `Queen - Don't Stop Me Now (Official Video Remastered 4K).mp3` (3.2 MB)

**Hygiene Invariant:** All audio media extensions (`*.mp3`, `*.wav`, `*.flac`, etc.), environment variants (`.env*`), and credentials are protected by `.gitignore`. Only `.gitkeep` files and `.pulsedeck_ai_cache.json` are tracked in `PulseDeck_Library/`.

---

## 3. Verified Repository Inventory & Declarations

Every path and declaration kind listed below matches actual repository declarations:

### 3.1 `PulseDeckCore` Target (`Sources/PulseDeckCore/`)
* **`Sources/PulseDeckCore/PulseDeckCore.swift`**:
  * `public enum PulseDeckCoreConfig`: Core constants (`version = "0.1.0-phase0"`, `cacheSchemaVersion = "1.0.0"`, default folder names, standard 10 crates, hardware baseline).
* **`Sources/PulseDeckCore/Models/AudioContracts.swift`**:
  * `public enum DeckIdentifier`: `deckA`, `deckB`.
  * `public enum AudioEngineRole`: `master`, `cue`.
  * `public struct AudioDeviceDescriptor`: Output device descriptor (`id`, `name`, `outputChannelCount`, `sampleRate`, `isDefault`, `isBluetooth`).
  * `public struct EQ3BandParameters`: 3-band EQ parameters (`lowGainDB`, `midGainDB`, `highGainDB`).
  * `public struct ResonantFilterParameters`: Resonant filter sweep parameters (`sweep`, `resonance`).
  * `public struct TimePitchParameters`: Playback rate, pitch shift, key lock (`rate`, `pitchCents`, `keyLockEnabled`).
  * `public struct LatencyCompensation`: Bounded offset model `[-300.0, 300.0]` ms (`offsetMs`, `masterDelayMs`, `cueDelayMs`), non-finite guard defaulting to 0.0.
  * `public enum BluetoothConstraints`: Latency limits and live performance advisory notice.
  * `public protocol AudioEngineContract`: Output-only engine lifecycle. Strictly forbids accessing `engine.inputNode`.
  * `public protocol DeckAudioGraphContract`: Single-deck playback graph protocol.
  * `public protocol AudioEngineCoordinatorContract`: Dual-engine coordinator protocol.
* **`Sources/PulseDeckCore/Models/CacheSchema.swift`**:
  * `public struct CueMarkers`: Four ordered cues (`startTrimCue`, `vocalEntryCue`, `mixOutCue`, `endTrimCue`), validation via `isValid(forDuration:)`, clamping via `clamped(toDuration:)`.
  * `public struct BeatGrid`: BPM, beat grid anchor, confidence, and `isAnalyzed`.
  * `public struct WaveformMetadata`: Multi-band peak and RMS waveform buffers.
  * `public struct ManualOverrides`: User override tracking flags (`isManual`, `overriddenFields`, `lastModifiedAt`).
  * `public struct TrackCacheEntry`: Per-track record with re-analysis merge protection (`mergingPreservingOverrides(with:)`).
  * `public struct PulseDeckLibraryCache`: Root cache container with `validate()` enforcing schema version, library root, and track bounds.
  * `public enum CacheValidationError`: Strongly typed schema validation error.
* **`Sources/PulseDeckCore/Models/LibraryModels.swift`**:
  * `public struct LibraryCrateInfo`: Crate representation (`folderName`, `displayName`, `trackCount`, `isReadable`, `errorMessage`).
  * `public struct LibraryScanSummary`: Overall library scan summary (`totalCrates`, `totalAudioTracks`, `hasCacheFile`, `crates`, `scanError`).
* **`Sources/PulseDeckCore/Models/AIAdvisorContracts.swift`**:
  * `public struct AdvisorRecommendation`: AI DJ transition recommendation payload.
  * `public struct GeminiAdvisorConfig`: Cloud advisor limits (12 RPM limit, 5s interval, 3 retries, exponential backoff).
* **`Sources/PulseDeckCore/Services/CachePersistence.swift`**:
  * `public enum CachePersistence`: Atomic JSON persistence service. Validates cache via `cache.validate()` before temporary file creation, flushes via `F_FULLFSYNC` / `fsync`, replaces destination atomically, and synchronizes parent directory.
* **`Sources/PulseDeckCore/Services/LibraryScanner.swift`**:
  * `public struct LibraryScanner`: Discovers crate directories, counts audio files, propagates crate read errors, and flags corrupt cache files via `scanError`.

### 3.2 `PulseDeckAI` Application Target (`Sources/PulseDeckAI/`)
* **`Sources/PulseDeckAI/PulseDeckApp.swift`**:
  * `@main public struct PulseDeckApp: App`: SwiftUI application entry point, sets window minimum dimensions (`1024x680`), registers Cmd+R library rescan shortcut.
* **`Sources/PulseDeckAI/ViewModels/AppState.swift`**:
  * `@MainActor public final class AppState: ObservableObject`: Manages library scanning, crate selection persistence, background serialization, and debounced generation-stamped scan requests.
* **`Sources/PulseDeckAI/UI/Theme.swift`**:
  * `public enum DJTheme`: Standardized color system (`background`, `cardBackground`, `deckA`, `deckB`, `master`, `cue`).
* **`Sources/PulseDeckAI/UI/ContentView.swift`**:
  * `public struct ContentView: View`: Primary application view assembling status header, library browser, and architecture indicator.
* **`Sources/PulseDeckAI/UI/StatusHeaderView.swift`**:
  * `public struct StatusHeaderView: View`: Status header displaying app version and hardware baseline.
* **`Sources/PulseDeckAI/UI/LibraryBrowserView.swift`**:
  * `public struct LibraryBrowserView: View`: 10-crate sidebar and track list.
* **`Sources/PulseDeckAI/UI/ArchitectureStatusView.swift`**:
  * `public struct ArchitectureStatusView: View`: Output routing indicator for Master, Cue, and Latency compensation.

### 3.3 Test Suites & Companion Scripts
* **`Tests/PulseDeckCoreTests/AudioContractsTests.swift`**: 4 tests verifying latency compensation model math, non-finite guard defaulting to zero, boundary clamping, EQ/filter/pitch defaults, and Gemini rate limiter backoff capping.
* **`Tests/PulseDeckCoreTests/CacheSchemaTests.swift`**: 10 tests verifying cue ordering bounds, re-analysis override preservation, invalid duration fail-safes, and NaN manual cue preservation.
* **`Tests/PulseDeckCoreTests/LibraryScannerTests.swift`**: 10 tests verifying hermetic temporary library scans, unreadable folder handling, corrupted cache reporting, atomic persistence, and rejected save destination preservation.
* **`scripts/pulsedeck_cache.py`**: Python companion script performing handwritten subset validation (not full JSON Schema enforcement) for v1.0.0 cache files, deepcopy immutability, safe re-analysis merge fallback on invalid duration or non-finite cues, automated cue non-finite sanitization, and pre-save validation.
* **`scripts/tests/test_pulsedeck_cache.py`**: 35 Python unit tests validating Python cache engine parity, override preservation with invalid duration/cues, automated cue NaN/infinity clamping with bpm override, and rejected save file preservation.
* **`docs/TECHNICAL_ARCHITECTURE.md`**: Architectural specification and system overview.
* **`docs/USER_MANUAL.md`**: Operational manual and user guide.
* **`docs/cache_schema_v1.json`**: JSON Schema definition for v1.0.0 cache files.

---

## 4. Open Issues & Important Prior Reviewer Notes

The following non-blocking observations from prior review audits are recorded as unresolved / requiring future verification. They are retained as notes; product code changes for these items are deferred unless a new verdict changes severity:

1. **Standard Crates Completeness:** Scanner enumerates directories but does not validate completeness against the standard 10-crate list or warn when standard crates are absent.
2. **README Cue Color Discrepancy:** README specifies purple `#D500F9`, but `Theme.swift` defines cue color as gold/amber (`#FFD600`).
3. **Duplicate Cmd+R Registration:** The Cmd+R shortcut is attached both to the UI button and to the application menu commands, risking duplicate invocation handling.
4. **Generation Guard Early-Return Cleanup Risk:** In `AppState.refreshLibrary()`, a generation mismatch returns early without resetting `isScanning = false`.
5. **AI Advisor Request Interval Bounds:** `minRequestIntervalSeconds = 5.0` is fixed, so setting `requestsPerMinute < 12` does not automatically increase the 5.0s minimum interval.
6. **Zero-Byte Cache Handling:** `CachePersistence.load` accepts a 0-byte file on disk as an empty default cache.
7. **Python `save_atomic` Parent Directory Fsync:** In `scripts/pulsedeck_cache.py`, `save_atomic` calls `os.fsync` on the file descriptor before `os.replace`, but does not open and sync the parent directory descriptor on POSIX platforms.
8. **Schema Bounds Coverage Gaps:** Some structural model fields rely on upstream DSP analyzers for deep semantic validation beyond basic type decoding.
9. **Library Path Working Directory Dependency:** `AppState` resolves `PulseDeck_Library` relative to `FileManager.default.currentDirectoryPath`, requiring the execution working directory to match the project root.

---

## 5. Phase 1 Audio Contracts & Essential Future Decisions

> [!NOTE]
> Phase 0 codifies architectural contracts and protocols. Audio engine implementation, CoreAudio HAL device binding, and DSP pipelines will be implemented in Phase 1 upon review approval.

### 5.1 Strict Output-Only Constraint
* **No Microphone Access:** Accessing `AVAudioEngine.inputNode` is **strictly prohibited**.
  * Calling `inputNode` triggers macOS microphone permission prompts (TCC).
  * In DJ performance environments, input routing risks feedback loops.
  * Accessing input forces Bluetooth devices from stereo A2DP into low-fidelity 16kHz mono hands-free profile (HFP/SCO).
* Both Master and Cue engines must be constructed exclusively from output graph nodes.

### 5.2 Independent Cue Preview vs Master Playback
* **Independent Preview:** The Cue engine must support independent preview, scrubbing, and play/pause for library tracks and cued deck tracks.
* **Isolation Guarantee:** Scrubbing, pausing, or looping a track in headphone preview must have **zero effect** on live Master FOH playback.
* **Pre-Fader Listen (PFL) Monitoring:** Listening to live deck pre-fader audio in headphones routes through an isolated pre-fader tap.

### 5.3 Bounded Latency Alignment
* **Model Range:** `[-300.0, +300.0]` ms, codified in `LatencyCompensation`.
* **Physical Constraint:** Negative physical latency does not exist; sound cannot be rendered into the past.
* **Delay Allocation:**
  * Master lags Cue (`offsetMs > 0`): delay is injected into the **Cue path**.
  * Cue lags Master (`offsetMs < 0`, e.g. Bluetooth monitoring): delay is injected into the **Master path**.
  * Synchronized (`offsetMs == 0`): zero added delay.

### 5.4 Real-Time Audio Thread Ownership & Atomics
* **Render Thread Boundaries:** CoreAudio render callbacks must never perform heap allocations (`malloc`), acquire locks/mutexes, make Objective-C runtime calls, perform ARC retain/release, or execute synchronous file/network I/O.
* **macOS 14 Compatible Atomics:**
  * The Swift standard library `Synchronization.Atomic<T>` requires macOS 15.0+ and is unavailable on the target macOS 14.0+ baseline.
  * `apple/swift-atomics` lacks native `Float` support.
  * **Phase 1 Decision:** Use `ManagedAtomic<UInt32>` storing IEEE 754 `Float.bitPattern`, or a lightweight C11 `<stdatomic.h>` wrapper in `PulseDeckCore`. This will be validated on macOS 14 in Phase 1.

---

## 6. Resumption Instructions (For Fresh Orchestrator)

> **USER DIRECTIVE:** **STOP AFTER PHASE 0.** Do NOT start Phase 1, do NOT merge PR #1, and do NOT treat Phase 1 transition as automatic.

1. **Verify Worktree & Remote State:** Confirm HEAD commit on `phase-0-foundation` matches remote `origin/phase-0-foundation`.
2. **Review Status Check:** Run `ao review ls pulsedeckai-2` (bare `ao review ls` defaults to the wrong session). Check for completed native Grok review verdict on PR #1.
3. **Optional Re-Review Trigger:** If resuming in a fresh session to request a Grok re-review on code commit `f0784c89f3ef5322aff2dd415c2b7ba73fd3e31e`:
   ```bash
   ao review trigger pulsedeckai-2 --agent grok --model grok-4.7
   ```
4. **Approval Requirement:** Merging PR #1 or starting Phase 1 requires explicit native review approval, human authorization, and orchestrator confirmation. Last reviewed SHA was `ff47ce7` with verdict `CHANGES_REQUESTED`; code `f0784c8` was verified correct by Grok, with documentation fix pending re-review.
5. **Validation Commands:**
   ```bash
   swift build -c release
   swift test
   python3 -m unittest discover -s scripts/tests
   python3 scripts/pulsedeck_cache.py
   ```
6. **Phase 1 Scope:** Proceed with Phase 1 only when a fresh, explicit user request instructs Phase 1 implementation to begin.
