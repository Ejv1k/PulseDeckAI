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
* **Last Functional Code Commits:**
  * `5dd90ad`: Strict schema version `"1.0.0"` validation and track bounds checking on cache load.
  * `34b9454`: Fail re-analysis merge on invalid duration, clamp cues, throw POSIXError on flush failure, and cleanup temporary cache files on failure.
  * Latest review fix: Enforce `cache.validate()` in `CachePersistence.saveAtomic` and `PulseDeckLibraryCache.save_atomic` before temp file creation; verify destination bytes unchanged and temp files cleaned up on rejected saves.
* **Last Completed Native Review Verdict:** `changes_requested` on commit `18c05f2`.
* **Current Audit Status:**
  * Native Grok review run `20b1b216-7f9f-4f6c-b21b-fa2fee351ac6` is auditing the PR.
  * Current audit outcome is **PENDING** until the orchestrator confirms reviewer findings.
  * **Critical Distinction:** Resolving inline review threads in AO is a prerequisite, but does **NOT** constitute review approval. Native AO review checks do **NOT** constitute independent GitHub PR approval.
* **Phase Boundary:** **Phase 1 has NOT been started.** PR #1 must not be merged to `main` until the orchestrator confirms approval of the updated head.

### 1.2 Automated Verification Status
> *Note: Build and test evidence belongs to the latest code commit with review fixes, not fresh execution on documentation-only edits.*

* **Swift Test Suite:** 22/22 tests passing (0 failures).
* **Python Test Suite:** 31/31 tests passing (0 failures) via `scripts/tests/test_pulsedeck_cache.py`.
* **Companion Cache Validator:** `python3 scripts/pulsedeck_cache.py` validates `PulseDeck_Library/.pulsedeck_ai_cache.json` with exit code 0.
* **Release Executable Build:** `swift build -c release` succeeds; produces `.build/release/PulseDeckAI` (Mach-O 64-bit arm64, 925 KB).
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
  * `public struct LatencyCompensation`: Bounded offset model `[-300.0, 300.0]` ms (`offsetMs`, `masterDelayMs`, `cueDelayMs`).
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
* **`Tests/PulseDeckCoreTests/AudioContractsTests.swift`**: 3 tests verifying latency compensation model math and boundary clamping.
* **`Tests/PulseDeckCoreTests/CacheSchemaTests.swift`**: 9 tests verifying cue ordering bounds, re-analysis override preservation, and invalid duration fail-safes.
* **`Tests/PulseDeckCoreTests/LibraryScannerTests.swift`**: 10 tests verifying hermetic temporary library scans, unreadable folder handling, corrupted cache reporting, atomic persistence, and rejected save destination preservation.
* **`scripts/pulsedeck_cache.py`**: Python companion script performing handwritten subset validation (not full JSON Schema enforcement) for v1.0.0 cache files, deepcopy immutability, and pre-save validation.
* **`scripts/tests/test_pulsedeck_cache.py`**: 31 Python unit tests validating Python cache engine parity and rejected save file preservation.
* **`docs/TECHNICAL_ARCHITECTURE.md`**: Architectural specification and system overview.
* **`docs/USER_MANUAL.md`**: Operational manual and user guide.
* **`docs/cache_schema_v1.json`**: JSON Schema definition for v1.0.0 cache files.

---

## 4. Open Issues & Important Prior Reviewer Notes

The following non-blocking observations from prior review audits are recorded as unresolved / requiring future verification. They are retained as notes; product code changes for these items are deferred unless a new verdict changes severity:

1. **Zero-Byte Cache Handling:** `CachePersistence.load` returns a default empty cache when encountering a 0-byte file on disk.
2. **Schema Bounds Coverage Gaps:** Some structural model fields have basic type validation in Swift models but rely on upstream DSP analyzers for extended semantic validation.
3. **Library Path Working Directory Dependency:** `AppState` resolves `PulseDeck_Library` relative to `FileManager.default.currentDirectoryPath`, requiring the execution working directory to match the package root.
4. **Duplicate Cmd+R Registration Risk:** The Cmd+R shortcut is registered in the application menu commands; views attaching additional shortcut handlers could produce duplicate triggers.
5. **Python `save_atomic` Parent Directory Fsync:** In `scripts/pulsedeck_cache.py`, `save_atomic` executes `os.fsync` on the file descriptor before `os.replace`, but does not open and sync the parent directory descriptor on POSIX platforms.
6. **Absent Standard Crate Warning:** The scanner detects missing standard crate directories without crashing, but does not currently surface a visible UI warning when expected crates are absent.
7. **README Cue Color Naming Discrepancy:** Textual color naming in documentation/README has minor naming variations (e.g. Amber vs Gold).

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
2. **Review Status Check:** Run `ao review ls`. Check for completed native Grok review verdict on PR #1.
3. **Approval Requirement:** Merging PR #1 or starting Phase 1 requires explicit orchestrator confirmation and human authorization.
4. **Validation Commands:**
   ```bash
   swift build -c release
   swift test
   python3 -m unittest discover -s scripts/tests
   python3 scripts/pulsedeck_cache.py
   ```
5. **Phase 1 Scope:** Proceed with Phase 1 only when a fresh, explicit user request instructs Phase 1 implementation to begin.
