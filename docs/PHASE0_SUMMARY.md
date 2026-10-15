# PulseDeck AI — Phase 0 Operational Foundation & Architecture Contracts
**Authoritative Phase 0 Status & Phase 1 Handover Specification**

> **Document Purpose:** Accurate repository state, component inventory, and Phase 1 contract handover. Enables any fresh orchestrator or engineer to resume development without prior chat context.  
> **Repository:** `https://github.com/Ejv1k/PulseDeckAI.git`  
> **Pull Request:** [PR #1: feat: implement Phase 0 operational foundation and architecture contracts](https://github.com/Ejv1k/PulseDeckAI/pull/1)  
> **Target Hardware Baseline:** Apple Silicon MacBook Pro 14" / 16" (M1 Pro, 16GB Unified Memory)  
> **Target Software Platform:** macOS 14.0+ (Sonoma) / macOS 15.0+ (Sequoia), Swift 6.0 Concurrency Mode  

---

## 1. Project & Review Gate Status

### 1.1 Review State & Commit Lineage
* **PR Status:** PR #1 is **OPEN** and **UNMERGED** against `origin/main`.
* **Remote Baseline:** `origin/main` commit `5aa14b44c8cfa65276342abd9408fbef5fbdf7ea` (empty root commit, 0 tracked files, zero media ancestry).
* **Last Functional Code HEAD:** `34b9454f22ae94a91fb63a41ea8fde93c0399213` (all review fixes and tests committed).
* **Last Completed Native Review Verdict:** `changes_requested` on commit `18c05f2`.
* **Fixes Implemented in Response:**
  * Commit `5dd90ad`: Strict schema version `"1.0.0"` validation and track bounds checking on cache load.
  * Commit `34b9454`: Fail re-analysis merge on invalid duration, clamp cues, throw POSIXError on flush failure, and cleanup temporary cache files on failure.
* **Current Audit Status:**
  * Native Grok review run `20b1b216-7f9f-4f6c-b21b-fa2fee351ac6` on head `34b9454` is **PENDING**.
  * No confirmed approval has been issued by the reviewer or orchestrator.
  * **Critical Distinction:** Resolving 10 inline review threads in AO is a prerequisite, but does **NOT** constitute review approval. Native AO review checks do **NOT** constitute independent GitHub PR approval.
* **Phase Boundary:** **Phase 1 has NOT been started.** PR #1 must not be merged to `main` until the orchestrator confirms approval of the updated head.

### 1.2 Automated Verification Status
* **Swift Test Suite:** 21/21 tests passing (0 failures).
* **Python Test Suite:** 30/30 tests passing (0 failures) via `scripts/tests/test_pulsedeck_cache.py`.
* **Companion Cache Validator:** `python3 scripts/pulsedeck_cache.py` validates `PulseDeck_Library/.pulsedeck_ai_cache.json` with exit code 0.
* **Release Executable Build:** `swift build -c release` succeeds; produces `.build/release/PulseDeckAI` (Mach-O 64-bit arm64, 925 KB).
* **Physical Hardware Validation:** Zero physical audio device validation has been conducted in Phase 0. No physical DAC routing, Bluetooth A2DP latency calibration, or hardware audio output has run.

---

## 2. Git Hygiene & Worktree Source-of-Truth

### 2.1 Worktree Directory Structure
* **Active Authorized Worktree (Source-of-Truth):**  
  `/Users/tomaselagin/.ao/data/worktrees/pulsedeckai/pulsedeckai-2`  
  Branch: `phase-0-foundation` tracking `origin/phase-0-foundation`.
* **Legacy Directory Prohibition:**  
  Do **NOT** use or commit to the desktop checkout at `/Users/tomaselagin/Desktop/PulseDeckAI`. Its initial commit `fe2a499` tracked 25 MB of binary MP3 files. Never push `fe2a499` ancestry to remote.

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

Every path and symbol listed below exists in the repository and matches its declaration:

### 3.1 `PulseDeckCore` Target (`Sources/PulseDeckCore/`)
* **`Sources/PulseDeckCore/PulseDeckCore.swift`**:
  * `enum PulseDeckCoreConfig`: Defines version (`"0.1.0-phase0"`), `cacheSchemaVersion` (`"1.0.0"`), `defaultLibraryFolderName`, `cacheFileName`, `standardCrates` (10 crates), and `hardwareBaseline`.
* **`Sources/PulseDeckCore/Models/AudioContracts.swift`**:
  * `enum DeckIdentifier`: `deckA`, `deckB`.
  * `enum AudioEngineRole`: `master`, `cue`.
  * `struct AudioDeviceDescriptor`: Physical device attributes (`id`, `name`, `outputChannelCount`, `sampleRate`, `isDefault`, `isBluetooth`).
  * `struct EQ3BandParameters`: 3-band EQ (`lowGainDB`, `midGainDB`, `highGainDB`).
  * `struct ResonantFilterParameters`: Resonant filter sweep (`sweep`, `resonance`).
  * `struct TimePitchParameters`: Playback rate, pitch shift, key lock (`rate`, `pitchCents`, `keyLockEnabled`).
  * `struct LatencyCompensation`: Offset model bounded to `[-300.0, 300.0]` ms (`offsetMs`, `masterDelayMs`, `cueDelayMs`).
  * `enum BluetoothConstraints`: Maximum compensation limit and live performance advisory notice.
  * `protocol AudioEngineContract`: Output-only engine lifecycle (`role`, `currentDevice`, `hardwareLatencyMs`, `start()`, `pause()`, `stop()`, `setOutputDevice(id:)`). Strictly forbids accessing `engine.inputNode`.
  * `protocol DeckAudioGraphContract`: Single-deck playback graph (`deckId`, `volume`, `crossfaderWeight`, `isCueActive`, `eqParameters`, `filterParameters`, `timePitchParameters`, `loadTrack(url:)`, `play()`, `pause()`, `seek(to:)`).
  * `protocol AudioEngineCoordinatorContract`: Coordinator managing dual output engines, two deck graphs, latency compensation, and CoreAudio device enumeration (`masterEngine`, `cueEngine`, `deckA`, `deckB`, `latencyCompensation`, `enumerateOutputDevices()`, `handleDeviceConfigurationChange()`).
* **`Sources/PulseDeckCore/Models/CacheSchema.swift`**:
  * `struct CueMarkers`: Four strictly ordered cue points (`startTrimCue`, `vocalEntryCue`, `mixOutCue`, `endTrimCue`), validation via `isValid(forDuration:)`, defensive clamping via `clamped(toDuration:)`.
  * `struct BeatGrid`: BPM, beat grid anchor, confidence, and `isAnalyzed`.
  * `struct WaveformMetadata`: Multi-band peak and RMS waveform buffers.
  * `struct ManualOverrides`: Flags indicating user manual edits (`isManual`, `overriddenFields`, `lastModifiedAt`).
  * `struct TrackCacheEntry`: Per-track cache record with re-analysis merge protection via `mergingPreservingOverrides(with:)`.
  * `struct PulseDeckLibraryCache`: Root cache container (`schemaVersion`, `generatedAt`, `libraryRoot`, `tracks`).
* **`Sources/PulseDeckCore/Models/LibraryModels.swift`**:
  * `struct LibraryCrateInfo`: Crate representation (`folderName`, `displayName`, `trackCount`, `audioFiles`, `isReadable`, `errorMessage`).
  * `struct LibraryScanSummary`: Overall scan results (`totalCrates`, `totalAudioTracks`, `hasCacheFile`, `crates`, `scanError`).
* **`Sources/PulseDeckCore/Models/AIAdvisorContracts.swift`**:
  * `struct AdvisorRecommendation`: AI transition payload (`suggestedTrackPath`, `rationale`, `harmonicCompatibility`, `transitionBars`, `suggestedMixInSeconds`, `energyProgression`).
  * `struct GeminiAdvisorConfig`: Cloud advisor constraints (12 RPM limit, 5s interval, 3 retries, exponential backoff).
* **`Sources/PulseDeckCore/Services/CachePersistence.swift`**:
  * `class CachePersistence`: Loads cache with strict version `"1.0.0"` validation and track bounds checking; saves atomically via temporary file (`.cache_tmp_<UUID>.json`), `fcntl(fd, F_FULLFSYNC)`, atomic rename, and `defer` cleanup.
* **`Sources/PulseDeckCore/Services/LibraryScanner.swift`**:
  * `class LibraryScanner`: Discovers crate folders, scans audio files, propagates crate read errors, flags corrupt cache files via `scanError`.

### 3.2 `PulseDeckAI` Application Target (`Sources/PulseDeckAI/`)
* **`Sources/PulseDeckAI/PulseDeckApp.swift`**:
  * `@main struct PulseDeckApp: App`: SwiftUI lifecycle, sets window sizing (`1024x680` min), injects `AppState`, registers Cmd+R rescan shortcut.
* **`Sources/PulseDeckAI/ViewModels/AppState.swift`**:
  * `@MainActor class AppState: ObservableObject`: Manages library scanning, crate selection persistence across rescans, debounced background dispatch, and generation-stamped results.
* **`Sources/PulseDeckAI/UI/Theme.swift`**:
  * `enum DJTheme`: Color system (background `#0A0B0F`, card `#14171F`, deckA `#00E5FF`, deckB `#FF6D00`, master `#00E676`, cue `#FFD600`).
* **`Sources/PulseDeckAI/UI/ContentView.swift`**:
  * `struct ContentView: View`: Top-level container assembling header, library browser, and status view.
* **`Sources/PulseDeckAI/UI/StatusHeaderView.swift`**:
  * `struct StatusHeaderView: View`: System status header displaying app version and hardware baseline.
* **`Sources/PulseDeckAI/UI/LibraryBrowserView.swift`**:
  * `struct LibraryBrowserView: View`: 10-crate sidebar and track listing.
* **`Sources/PulseDeckAI/UI/ArchitectureStatusView.swift`**:
  * `struct ArchitectureStatusView: View`: Architectural routing indicator for Master, Cue, and Latency compensation.

### 3.3 Test Suites & Companion Scripts
* **`Tests/PulseDeckCoreTests/AudioContractsTests.swift`**: 3 tests verifying latency compensation model math, boundary clamping, and default parameters.
* **`Tests/PulseDeckCoreTests/CacheSchemaTests.swift`**: 9 tests verifying cue ordering bounds, re-analysis override preservation, invalid duration fail-safes, and clamping.
* **`Tests/PulseDeckCoreTests/LibraryScannerTests.swift`**: 9 tests verifying hermetic temporary library scans, unreadable folder handling, corrupted cache reporting, and atomic persistence.
* **`scripts/pulsedeck_cache.py`**: Python companion validator enforcing identical v1.0.0 schema constraints, deepcopy immutability, and override preservation.
* **`scripts/tests/test_pulsedeck_cache.py`**: 30 Python unit tests validating Python cache engine parity.
* **`docs/TECHNICAL_ARCHITECTURE.md`**: Architectural specification and system overview.
* **`docs/USER_MANUAL.md`**: Operational manual and user guide.
* **`docs/cache_schema_v1.json`**: JSON Schema definition for v1.0.0 cache files.

---

## 4. Phase 1 Audio Contracts & Essential Future Decisions

> [!NOTE]
> Phase 0 codifies architectural contracts and protocols. Audio engine implementation, CoreAudio HAL device binding, and DSP pipelines will be implemented in Phase 1 upon review approval.

### 4.1 Strict Output-Only Constraint
* **No Microphone Access:** Accessing `AVAudioEngine.inputNode` is **strictly prohibited**.
  * Calling `inputNode` triggers macOS microphone permission prompts (TCC).
  * In DJ performance environments, input routing risks feedback loops.
  * Accessing input forces Bluetooth devices from stereo A2DP into low-fidelity 16kHz mono hands-free profile (HFP/SCO).
* Both Master and Cue engines must be constructed exclusively from output graph nodes.

### 4.2 Independent Cue Preview vs Master Playback
* **Independent Preview:** The Cue engine must support independent preview, scrubbing, and play/pause for library tracks and cued deck tracks.
* **Isolation Guarantee:** Scrubbing, pausing, or looping a track in headphone preview must have **zero effect** on live Master FOH playback.
* **Pre-Fader Listen (PFL) Monitoring:** Listening to live deck pre-fader audio in headphones routes through an isolated pre-fader tap.

### 4.3 Bounded Latency Alignment
* **Model Range:** `[-300.0, +300.0]` ms, codified in `LatencyCompensation`.
* **Physical Constraint:** Negative physical latency does not exist; sound cannot be rendered into the past.
* **Delay Allocation:**
  * Master lags Cue (`offsetMs > 0`): delay is injected into the **Cue path**.
  * Cue lags Master (`offsetMs < 0`, e.g. Bluetooth monitoring): delay is injected into the **Master path**.
  * Synchronized (`offsetMs == 0`): zero added delay.

### 4.4 Real-Time Audio Thread Ownership & Atomics
* **Render Thread Boundaries:** CoreAudio render callbacks must never perform heap allocations (`malloc`), acquire locks/mutexes, make Objective-C runtime calls, perform ARC retain/release, or execute synchronous file/network I/O.
* **macOS 14 Compatible Atomics:**
  * The Swift standard library `Synchronization.Atomic<T>` requires macOS 15.0+ and is unavailable on the target macOS 14.0+ baseline.
  * `apple/swift-atomics` lacks native `Float` support.
  * **Phase 1 Decision:** Use `ManagedAtomic<UInt32>` storing IEEE 754 `Float.bitPattern`, or a lightweight C11 `<stdatomic.h>` wrapper in `PulseDeckCore`. This will be validated on macOS 14 in Phase 1.

---

## 5. Resumption Instructions (For Fresh Orchestrator)

1. **Verify Current Head:** Confirm HEAD commit on `phase-0-foundation` matches remote `origin/phase-0-foundation`.
2. **Review Status Check:** Run `ao review ls`. Wait for native Grok review verdict on PR #1.
3. **Approval Requirement:** Do **NOT** merge PR #1 or advance to Phase 1 until the orchestrator confirms native review approval on the updated head.
4. **Validation Commands:**
   ```bash
   swift build -c release
   swift test
   python3 -m unittest discover -s scripts/tests
   python3 scripts/pulsedeck_cache.py
   ```
5. **Phase 1 Implementation:** Once approved and merged, proceed with Phase 1 audio engine implementation adhering strictly to `AudioContracts.swift`.
