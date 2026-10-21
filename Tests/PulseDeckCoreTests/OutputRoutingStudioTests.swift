import XCTest
import CoreAudio
import AVFoundation
@testable import PulseDeckCore
@testable import PulseDeckAI

final class OutputRoutingStudioTests: XCTestCase {

    private var mockHAL: MockAudioHardware!
    private var coordinator: AudioEngineCoordinator!

    override func setUp() {
        super.setUp()
        mockHAL = MockAudioHardware()

        // Set up 3 physical output devices:
        // 1. Built-in Speakers (Default)
        mockHAL.addDevice(
            id: 101,
            uid: "builtin_speakers_uid",
            name: "MacBook Pro Speakers",
            manufacturer: "Apple Inc.",
            outputChannels: 2,
            sampleRate: 48000.0,
            transportType: 0
        )
        // 2. Wired Headphones (3.5mm)
        mockHAL.addDevice(
            id: 102,
            uid: "wired_headphones_uid",
            name: "External Headphones",
            manufacturer: "Sony",
            outputChannels: 2,
            sampleRate: 44100.0,
            transportType: 0
        )
        // 3. Bluetooth DJ Cans (A2DP)
        mockHAL.addDevice(
            id: 103,
            uid: "bluetooth_headphones_uid",
            name: "HD 250BT Headphones",
            manufacturer: "Sennheiser",
            outputChannels: 2,
            sampleRate: 48000.0,
            transportType: kAudioDeviceTransportTypeBluetooth
        )

        mockHAL.setDefaultOutputID(101)
        coordinator = AudioEngineCoordinator(hal: mockHAL)
    }

    override func tearDown() {
        coordinator.stop()
        coordinator = nil
        mockHAL = nil
        super.tearDown()
    }

    // MARK: - Tests

    @MainActor
    func testDeviceEnumerationAndPublishedState() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let editor = WaveformEditorModel(libraryRootURL: tempDir)
        let appState = AppState(
            libraryRootURL: tempDir,
            waveformEditorModel: editor,
            audioCoordinator: coordinator
        )

        XCTAssertEqual(appState.availableOutputDevices.count, 3)
        let uids = appState.availableOutputDevices.map(\.id)
        XCTAssertTrue(uids.contains("builtin_speakers_uid"))
        XCTAssertTrue(uids.contains("wired_headphones_uid"))
        XCTAssertTrue(uids.contains("bluetooth_headphones_uid"))

        // Built-in speaker was default, so master resolves initially
        XCTAssertNotNil(appState.masterDeviceDescriptor)
        XCTAssertEqual(appState.masterDeviceDescriptor?.id, "builtin_speakers_uid")
        XCTAssertFalse(appState.isMasterFallback)
        XCTAssertFalse(appState.isCueFallback)
    }

    @MainActor
    func testIndependentMasterAndCueSelection() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let editor = WaveformEditorModel(libraryRootURL: tempDir)
        let appState = AppState(
            libraryRootURL: tempDir,
            waveformEditorModel: editor,
            audioCoordinator: coordinator
        )

        // Select Speakers for Master
        appState.selectOutputDevice(role: .master, uid: "builtin_speakers_uid")
        XCTAssertNil(appState.masterRoutingError)
        XCTAssertEqual(appState.masterOutputUID, "builtin_speakers_uid")
        XCTAssertEqual(appState.masterDeviceDescriptor?.name, "MacBook Pro Speakers")

        // Select Wired Headphones for Cue independently
        appState.selectOutputDevice(role: .cue, uid: "wired_headphones_uid")
        XCTAssertNil(appState.cueRoutingError)
        XCTAssertEqual(appState.cueOutputUID, "wired_headphones_uid")
        XCTAssertEqual(appState.cueDeviceDescriptor?.name, "External Headphones")

        // Master should still be Speakers
        XCTAssertEqual(appState.masterOutputUID, "builtin_speakers_uid")

        // Coordinator engines reflect the assignment
        XCTAssertEqual(coordinator.masterAudioEngine.currentDevice?.id, "builtin_speakers_uid")
        XCTAssertEqual(coordinator.cueAudioEngine.currentDevice?.id, "wired_headphones_uid")
    }

    @MainActor
    func testRoutingFailureVisibleErrorWithoutFakeSuccess() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let editor = WaveformEditorModel(libraryRootURL: tempDir)
        let appState = AppState(
            libraryRootURL: tempDir,
            waveformEditorModel: editor,
            audioCoordinator: coordinator
        )

        // Select a non-existent device
        appState.selectOutputDevice(role: .master, uid: "ghost_device_uid")

        // Must expose visible error and not pretend it succeeded
        XCTAssertNotNil(appState.masterRoutingError)
        XCTAssertTrue(appState.masterRoutingError!.contains("Routing failed"))
        XCTAssertNotEqual(appState.masterOutputUID, "ghost_device_uid")
    }

    @MainActor
    func testFallbackStateDetection() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let editor = WaveformEditorModel(libraryRootURL: tempDir)
        let appState = AppState(
            libraryRootURL: tempDir,
            waveformEditorModel: editor,
            audioCoordinator: coordinator
        )

        // Start monitoring so hotplug reconciliation runs
        try? coordinator.start()

        // Bind Cue to wired headphones
        appState.selectOutputDevice(role: .cue, uid: "wired_headphones_uid")
        XCTAssertFalse(appState.isCueFallback)

        // Disconnect wired headphones from hardware
        mockHAL.removeDevice(id: 102)
        coordinator.handleDeviceConfigurationChange()
        appState.refreshOutputDevices()

        // Cue engine should now indicate fallback because desired device is missing
        XCTAssertTrue(coordinator.isFallbackActive(for: .cue))
        XCTAssertTrue(appState.isCueFallback)
        // Must publish the actual fallback device UID, not the stale removed device
        XCTAssertEqual(appState.cueOutputUID, "builtin_speakers_uid")
        XCTAssertEqual(appState.cueDeviceDescriptor?.id, "builtin_speakers_uid")
    }

    @MainActor
    func testUnboundRoleDoesNotFabricateDefaultDescriptor() {
        // Coordinator freshly created without registration binding
        // When monitor has no bound UID, boundDevice must return nil, not fake the default
        let unmanagedCoordinator = AudioEngineCoordinator(hal: mockHAL)
        XCTAssertNil(unmanagedCoordinator.boundDevice(for: .cue))
    }

    @MainActor
    func testToggleDeckPlayRequiresRunningEngine() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Simulate engine start failure
        coordinator.masterAudioEngine.startErrorForTesting = CoreAudioError.osStatus(-1, operation: "simulatedStartFailure")

        let editor = WaveformEditorModel(libraryRootURL: tempDir)
        let appState = AppState(
            libraryRootURL: tempDir,
            waveformEditorModel: editor,
            audioCoordinator: coordinator,
            startCoordinator: false
        )

        // toggleDeckPlay should not report playing if engine cannot run
        appState.toggleDeckPlay(deck: .deckA)
        XCTAssertFalse(appState.isDeckAPlaying, "toggleDeckPlay must not publish true against stopped engine")
        XCTAssertFalse(coordinator.deckAGraph.isMasterPlaying)
    }

    @MainActor
    func testDefaultAppStateStartsCoordinatorAndMonitorsTopology() {
        let appState = AppState()
        guard let coord = appState.audioCoordinator else {
            XCTFail("AppState must instantiate audio coordinator")
            return
        }
        defer { coord.stop() }
        XCTAssertTrue(coord.monitor.isMonitoringActive, "Production AppState must activate monitor listeners on startup")
        XCTAssertTrue(coord.masterAudioEngine.isRunning, "Production AppState must start master engine on startup")
        XCTAssertTrue(coord.cueAudioEngine.isRunning, "Production AppState must start cue engine on startup")
    }

    @MainActor
    func testBluetoothAdvisoryWarning() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let editor = WaveformEditorModel(libraryRootURL: tempDir)
        let appState = AppState(
            libraryRootURL: tempDir,
            waveformEditorModel: editor,
            audioCoordinator: coordinator
        )

        XCTAssertNil(appState.cueWarning)

        // Select Bluetooth device for Cue
        appState.selectOutputDevice(role: .cue, uid: "bluetooth_headphones_uid")

        XCTAssertNotNil(appState.cueWarning)
        XCTAssertEqual(appState.cueWarning, BluetoothConstraints.warningMessage)
        XCTAssertEqual(appState.cueDeviceDescriptor?.isBluetooth, true)
    }

    @MainActor
    func testDualDeckTransportAndCueToggle() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let editor = WaveformEditorModel(libraryRootURL: tempDir)
        let appState = AppState(
            libraryRootURL: tempDir,
            waveformEditorModel: editor,
            audioCoordinator: coordinator
        )

        XCTAssertFalse(appState.isDeckAPlaying)
        XCTAssertFalse(appState.isDeckACueActive)
        XCTAssertFalse(appState.isDeckBPlaying)
        XCTAssertFalse(appState.isDeckBCueActive)

        // Toggle Cue active for Deck A
        appState.setDeckCueActive(deck: .deckA, active: true)
        XCTAssertTrue(appState.isDeckACueActive)
        XCTAssertTrue(coordinator.deckA.isCueActive)
        XCTAssertFalse(appState.isDeckBCueActive)

        // Toggle Cue active off
        appState.setDeckCueActive(deck: .deckA, active: false)
        XCTAssertFalse(appState.isDeckACueActive)
        XCTAssertFalse(coordinator.deckA.isCueActive)

        // Toggle Play on Deck A
        appState.toggleDeckPlay(deck: .deckA)
        XCTAssertTrue(appState.isDeckAPlaying)

        appState.toggleDeckPlay(deck: .deckA)
        XCTAssertFalse(appState.isDeckAPlaying)
    }

    @MainActor
    func testCrossfaderAdjustment() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let editor = WaveformEditorModel(libraryRootURL: tempDir)
        let appState = AppState(
            libraryRootURL: tempDir,
            waveformEditorModel: editor,
            audioCoordinator: coordinator
        )

        XCTAssertEqual(appState.crossfaderPosition, 0.5, accuracy: 0.001)

        // Move full to Deck A (0.0)
        appState.updateCrossfader(position: 0.0)
        XCTAssertEqual(appState.crossfaderPosition, 0.0, accuracy: 0.001)
        XCTAssertEqual(coordinator.crossfaderPosition, 0.0, accuracy: 0.001)
        XCTAssertEqual(coordinator.deckA.crossfaderWeight, 1.0, accuracy: 0.001)
        XCTAssertEqual(coordinator.deckB.crossfaderWeight, 0.0, accuracy: 0.001)

        // Move full to Deck B (1.0)
        appState.updateCrossfader(position: 1.0)
        XCTAssertEqual(appState.crossfaderPosition, 1.0, accuracy: 0.001)
        XCTAssertEqual(coordinator.crossfaderPosition, 1.0, accuracy: 0.001)
        XCTAssertEqual(coordinator.deckA.crossfaderWeight, 0.0, accuracy: 0.001)
        XCTAssertEqual(coordinator.deckB.crossfaderWeight, 1.0, accuracy: 0.001)
    }

    @MainActor
    func testDualDeckLoadSelectedTrackIntoDeck() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create test WAV file
        let trackURL = tempDir.appendingPathComponent("test_track.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 2)!
        let file = try AVAudioFile(forWriting: trackURL, settings: format.settings)
        let frameCount = AVAudioFrameCount(44100.0 * 2.0)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        try file.write(from: buffer)

        let peaks = [Float](repeating: 0.5, count: 200)
        let entry = TrackCacheEntry(
            relativePath: "test_track.wav",
            fileFingerprint: "fp123",
            fileSizeBytes: 1024,
            fileModificationTime: "2026-10-21T00:00:00Z",
            duration: 2.0,
            sampleRate: 44100.0,
            channels: 2,
            bitDepth: 16,
            bpm: 124.0,
            musicalKey: "8A",
            confidence: 0.95,
            waveformMetadata: WaveformMetadata(
                sampleCount: Int(2.0 * 44100.0),
                downsampleFactor: 512,
                peakValues: peaks,
                lowBandPeaks: peaks,
                midBandPeaks: peaks,
                highBandPeaks: peaks
            ),
            beatGrid: BeatGrid(
                firstBeatOffsetSeconds: 0.0,
                beatIntervalSeconds: 0.4838,
                beatTimestamps: stride(from: 0.0, to: 2.0, by: 0.4838).map { $0 }
            ),
            structure: TrackStructure(sections: [], vocalSegments: []),
            cueMarkers: CueMarkers(startTrimCue: 0.0, vocalEntryCue: 0.5, mixOutCue: 1.5, endTrimCue: 2.0),
            aiTrimBypass: false,
            analyzerVersion: "fixture",
            analysisTimestamp: "2026-10-21T00:00:00Z"
        )

        let cache = PulseDeckLibraryCache(
            schemaVersion: "1.0.0",
            generatedAt: "2026-10-21T00:00:00Z",
            libraryRoot: tempDir.path,
            tracks: ["test_track.wav": entry]
        )

        let editor = WaveformEditorModel(libraryRootURL: tempDir)
        let appState = AppState(
            libraryRootURL: tempDir,
            waveformEditorModel: editor,
            loadedCache: cache,
            audioCoordinator: coordinator
        )

        appState.selectedTrackPath = "test_track.wav"

        // Load into Deck A
        appState.loadSelectedTrackIntoDeck(deck: .deckA)
        XCTAssertNotNil(appState.deckATrack)
        XCTAssertEqual(appState.deckATrack?.relativePath, "test_track.wav")
        XCTAssertEqual(coordinator.deckAGraph.loadedTrackURL?.lastPathComponent, "test_track.wav")

        // Load into Deck B
        appState.loadSelectedTrackIntoDeck(deck: .deckB)
        XCTAssertNotNil(appState.deckBTrack)
        XCTAssertEqual(appState.deckBTrack?.relativePath, "test_track.wav")
        XCTAssertEqual(coordinator.deckBGraph.loadedTrackURL?.lastPathComponent, "test_track.wav")
    }
}
