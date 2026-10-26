import XCTest
import Combine
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

    @MainActor
    private func makeOfflineApp(startCoordinator: Bool = false) throws -> AppState {
        let audio = try XCTUnwrap(coordinator)
        try audio.monitor.performOnControlQueue {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
            try audio.masterAudioEngine.rawEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            try audio.cueAudioEngine.rawEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return AppState(libraryRootURL: root, waveformEditorModel: WaveformEditorModel(libraryRootURL: root),
                        audioCoordinator: audio, startCoordinator: startCoordinator)
    }

    @MainActor
    func testPlayRetryClearsInitializerStartupFailureAfterMasterRuns() async throws {
        coordinator.masterAudioEngine.startErrorForTesting = CoreAudioError.osStatus(-1, operation: "initialStart")
        let app = try makeOfflineApp(startCoordinator: true)
        XCTAssertNotNil(app.coordinatorErrorMessage)
        XCTAssertTrue(app.statusMessage.hasPrefix("Audio Startup Error:"))
        XCTAssertFalse(coordinator.masterAudioEngine.isRunning)
        XCTAssertFalse(app.isDeckAPlaying)

        coordinator.masterAudioEngine.startErrorForTesting = nil
        app.toggleDeckPlay(deck: .deckA)
        XCTAssertTrue(coordinator.masterAudioEngine.isRunning)
        XCTAssertTrue(coordinator.cueAudioEngine.isRunning)
        XCTAssertTrue(app.isDeckAPlaying)
        XCTAssertFalse(app.isDeckBPlaying)
        XCTAssertNil(app.coordinatorErrorMessage)
        XCTAssertFalse(app.statusMessage.hasPrefix("Audio Startup Error:"))
        await assertRetryRestoresDeviceLifecycle(app)
    }

    @MainActor
    func testPlayRetryClearsOnDemandStartupFailureForDeckB() throws {
        let app = try makeOfflineApp()
        coordinator.masterAudioEngine.startErrorForTesting = CoreAudioError.osStatus(-1, operation: "retryStart")
        app.toggleDeckPlay(deck: .deckB)
        XCTAssertNotNil(app.coordinatorErrorMessage)
        XCTAssertTrue(app.statusMessage.hasPrefix("Audio Start Error:"))
        XCTAssertFalse(app.isDeckBPlaying)
        XCTAssertFalse(coordinator.masterAudioEngine.isRunning)

        coordinator.masterAudioEngine.startErrorForTesting = nil
        app.toggleDeckPlay(deck: .deckB)
        XCTAssertTrue(coordinator.masterAudioEngine.isRunning)
        XCTAssertTrue(app.isDeckBPlaying)
        XCTAssertFalse(app.isDeckAPlaying)
        XCTAssertNil(app.coordinatorErrorMessage)
        XCTAssertFalse(app.statusMessage.hasPrefix("Audio Start Error:"))
    }

    @MainActor
    func testPlayRetryAcknowledgesStartupErrorWithoutReplacingUnrelatedStatus() throws {
        coordinator.masterAudioEngine.startErrorForTesting = CoreAudioError.osStatus(-1, operation: "initialStart")
        let app = try makeOfflineApp(startCoordinator: true)
        XCTAssertNotNil(app.coordinatorErrorMessage)
        let unrelated = "Library Verified: 2 Crates, 4 Tracks"
        app.statusMessage = unrelated
        coordinator.masterAudioEngine.startErrorForTesting = nil
        app.toggleDeckPlay(deck: .deckA)
        XCTAssertTrue(coordinator.masterAudioEngine.isRunning)
        XCTAssertTrue(app.isDeckAPlaying)
        XCTAssertNil(app.coordinatorErrorMessage)
        XCTAssertEqual(app.statusMessage, unrelated)
    }

    @MainActor
    func testCueActivationFailureRejectsBothDecksAndSuccessfulRetryRecovers() async throws {
        let app = try makeOfflineApp()
        coordinator.cueAudioEngine.startErrorForTesting = CoreAudioError.osStatus(-10868, operation: "cueStart")
        for deck in [DeckIdentifier.deckA, .deckB] {
            app.setDeckCueActive(deck: deck, active: true)
            XCTAssertFalse(coordinator.cueAudioEngine.isRunning)
            XCTAssertFalse(coordinator.masterAudioEngine.isRunning)
            XCTAssertFalse(coordinator.deckA.isCueActive)
            XCTAssertFalse(coordinator.deckB.isCueActive)
            XCTAssertFalse(app.isDeckACueActive)
            XCTAssertFalse(app.isDeckBCueActive)
            XCTAssertNotNil(app.coordinatorErrorMessage)
        }
        coordinator.cueAudioEngine.startErrorForTesting = nil
        app.setDeckCueActive(deck: .deckB, active: true)
        XCTAssertTrue(coordinator.cueAudioEngine.isRunning)
        XCTAssertTrue(coordinator.masterAudioEngine.isRunning)
        XCTAssertTrue(coordinator.deckB.isCueActive)
        XCTAssertTrue(app.isDeckBCueActive)
        XCTAssertFalse(coordinator.deckA.isCueActive)
        XCTAssertFalse(app.isDeckACueActive)
        XCTAssertNil(app.coordinatorErrorMessage)
        await assertRetryRestoresDeviceLifecycle(app)
    }

    @MainActor
    func testCueActivationStartsStoppedCoordinatorAndKeepsDecksIndependent() throws {
        let app = try makeOfflineApp()
        XCTAssertFalse(coordinator.masterAudioEngine.isRunning)
        XCTAssertFalse(coordinator.cueAudioEngine.isRunning)
        app.setDeckCueActive(deck: .deckA, active: true)
        XCTAssertTrue(coordinator.masterAudioEngine.isRunning)
        XCTAssertTrue(coordinator.cueAudioEngine.isRunning)
        XCTAssertTrue(coordinator.monitor.isMonitoringActive)
        XCTAssertTrue(app.isDeckACueActive)
        XCTAssertTrue(coordinator.deckA.isCueActive)
        XCTAssertFalse(app.isDeckBCueActive)
        XCTAssertFalse(coordinator.deckB.isCueActive)
        app.setDeckCueActive(deck: .deckB, active: true)
        app.setDeckCueActive(deck: .deckA, active: false)
        XCTAssertFalse(app.isDeckACueActive)
        XCTAssertFalse(coordinator.deckA.isCueActive)
        XCTAssertTrue(app.isDeckBCueActive)
        XCTAssertTrue(coordinator.deckB.isCueActive)
    }

    @MainActor
    func testCueOnlyRecoveryStartsCueWithoutRestartingLiveMaster() throws {
        let app = try makeOfflineApp(startCoordinator: true)
        XCTAssertTrue(coordinator.masterAudioEngine.isRunning)
        coordinator.cueAudioEngine.stop()
        // A broad coordinator start would touch this healthy master and throw before starting cue.
        coordinator.masterAudioEngine.startErrorForTesting = CoreAudioError.osStatus(-1, operation: "mustNotRestartMaster")
        app.setDeckCueActive(deck: .deckB, active: true)
        XCTAssertTrue(coordinator.masterAudioEngine.isRunning)
        XCTAssertTrue(coordinator.cueAudioEngine.isRunning)
        XCTAssertTrue(coordinator.monitor.isMonitoringActive)
        XCTAssertTrue(coordinator.deckB.isCueActive)
        XCTAssertTrue(app.isDeckBCueActive)
        XCTAssertFalse(app.isDeckACueActive)
        XCTAssertNil(app.coordinatorErrorMessage)
    }

    @MainActor
    func testCueOnlyFailurePreservesMasterPlaybackAndIntendedRunningState() throws {
        let app = try makeOfflineApp(startCoordinator: true)
        let audio = try XCTUnwrap(coordinator)
        let master = audio.masterAudioEngine.rawEngine
        let format = master.manualRenderingFormat
        let url = app.libraryRootURL.appendingPathComponent("master.wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100))
            pcm.frameLength = 44100
            let channels = try XCTUnwrap(pcm.floatChannelData)
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(pcm.frameLength) { channels[channel][frame] = 0.25 }
            }
            try file.write(from: pcm)
        }
        try audio.deckAGraph.loadTrack(url: url)
        app.toggleDeckPlay(deck: .deckA)
        let rendered = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        XCTAssertEqual(try master.renderOffline(4096, to: rendered), .success)
        let sampleTime = master.manualRenderingSampleTime
        audio.cueAudioEngine.stop()
        audio.cueAudioEngine.startErrorForTesting = CoreAudioError.osStatus(-10868, operation: "cueOnlyStart")

        app.setDeckCueActive(deck: .deckA, active: true)
        XCTAssertTrue(audio.masterAudioEngine.isRunning)
        XCTAssertTrue(audio.monitor.isMonitoringActive)
        XCTAssertTrue(app.isDeckAPlaying)
        XCTAssertTrue(audio.deckAGraph.isMasterPlaying)
        XCTAssertTrue(audio.deckAGraph.masterPlayerNode.isPlaying)
        XCTAssertEqual(master.manualRenderingSampleTime, sampleTime)
        XCTAssertFalse(audio.cueAudioEngine.isRunning)
        XCTAssertFalse(app.isDeckACueActive)
        XCTAssertFalse(audio.deckA.isCueActive)
        XCTAssertNotNil(app.coordinatorErrorMessage)
        XCTAssertEqual(try master.renderOffline(4096, to: rendered), .success)
        let samples = try XCTUnwrap(rendered.floatChannelData)[0]
        XCTAssertGreaterThan((0..<Int(rendered.frameLength)).map { abs(samples[$0]) }.max() ?? 0, 0.01)
        XCTAssertGreaterThan(master.manualRenderingSampleTime, sampleTime)

        // Simulate a configuration pause without cancelling the monitor's real running intent.
        audio.monitor.performOnControlQueue { master.pause() }
        XCTAssertFalse(master.isRunning)
        audio.handleDeviceConfigurationChange()
        XCTAssertTrue(master.isRunning, "Cue failure must preserve master recovery intent")
        XCTAssertFalse(audio.cueAudioEngine.isRunning)
    }

    @MainActor
    func testCueDeactivationClearsBothDecksAfterCueEngineStops() throws {
        let app = try makeOfflineApp(startCoordinator: true)
        app.setDeckCueActive(deck: .deckA, active: true)
        app.setDeckCueActive(deck: .deckB, active: true)
        coordinator.cueAudioEngine.stop()
        coordinator.cueAudioEngine.startErrorForTesting = CoreAudioError.osStatus(-10868, operation: "mustNotStartWhenDeactivating")
        app.setDeckCueActive(deck: .deckA, active: false)
        XCTAssertFalse(app.isDeckACueActive)
        XCTAssertFalse(coordinator.deckA.isCueActive)
        XCTAssertTrue(app.isDeckBCueActive)
        app.setDeckCueActive(deck: .deckB, active: false)
        XCTAssertFalse(app.isDeckBCueActive)
        XCTAssertFalse(coordinator.deckB.isCueActive)
        XCTAssertFalse(coordinator.cueAudioEngine.isRunning)
        XCTAssertTrue(coordinator.masterAudioEngine.isRunning)
        XCTAssertNil(app.coordinatorErrorMessage)
    }

    @MainActor
    func testCueToggleWithoutCoordinatorKeepsIndependentPublishedState() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = AppState(libraryRootURL: root, waveformEditorModel: WaveformEditorModel(libraryRootURL: root))
        XCTAssertNil(app.audioCoordinator)
        app.setDeckCueActive(deck: .deckA, active: true)
        XCTAssertTrue(app.isDeckACueActive)
        XCTAssertFalse(app.isDeckBCueActive)
        app.setDeckCueActive(deck: .deckB, active: true)
        app.setDeckCueActive(deck: .deckA, active: false)
        XCTAssertFalse(app.isDeckACueActive)
        XCTAssertTrue(app.isDeckBCueActive)
        app.setDeckCueActive(deck: .deckB, active: false)
        XCTAssertFalse(app.isDeckBCueActive)
    }

    @MainActor
    private func expectRoutePublication(
        _ app: AppState, master: String?, cue: String?, trigger: () -> Void
    ) async {
        let published = XCTestExpectation(description: "Actual monitor event publishes master and cue routing")
        let observation = Publishers.CombineLatest(app.$masterOutputUID, app.$cueOutputUID)
            .dropFirst()
            .filter { $0.0 == master && $0.1 == cue }
            .prefix(1)
            .sink { _ in published.fulfill() }
        trigger()
        let result = await XCTWaiter.fulfillment(of: [published], timeout: 2)
        XCTAssertEqual(result, .completed)
        withExtendedLifetime(observation) {}
        XCTAssertEqual(app.masterOutputUID, master)
        XCTAssertEqual(app.cueOutputUID, cue)
    }

    @MainActor
    private func assertRetryRestoresDeviceLifecycle(_ app: AppState) async {
        let audio = coordinator!
        app.refreshOutputDevices()
        XCTAssertEqual(app.masterOutputUID, "builtin_speakers_uid")
        XCTAssertEqual(app.cueOutputUID, "builtin_speakers_uid")
        app.selectOutputDevice(role: .master, uid: "wired_headphones_uid")
        app.selectOutputDevice(role: .cue, uid: "bluetooth_headphones_uid")
        XCTAssertNil(app.masterRoutingError)
        XCTAssertNil(app.cueRoutingError)
        XCTAssertEqual(app.masterOutputUID, "wired_headphones_uid")
        XCTAssertEqual(app.cueOutputUID, "bluetooth_headphones_uid")
        XCTAssertEqual(audio.monitor.desiredDeviceUID(for: .master), "wired_headphones_uid")
        XCTAssertEqual(audio.monitor.desiredDeviceUID(for: .cue), "bluetooth_headphones_uid")

        // Stop only cue through its real API so recovery must keep its intended state false.
        app.setDeckCueActive(deck: .deckA, active: false)
        app.setDeckCueActive(deck: .deckB, active: false)
        audio.cueAudioEngine.stop()
        await expectRoutePublication(app, master: "builtin_speakers_uid", cue: "builtin_speakers_uid") {
            mockHAL.removeDevice(id: 102)
            mockHAL.removeDevice(id: 103)
            mockHAL.triggerDevicesChange()
        }
        XCTAssertTrue(app.isMasterFallback)
        XCTAssertTrue(app.isCueFallback)
        XCTAssertTrue(audio.masterAudioEngine.isRunning)
        XCTAssertFalse(audio.cueAudioEngine.isRunning)

        // Remove the fallback too, then replug preferred UIDs under new numeric IDs.
        await expectRoutePublication(app, master: nil, cue: nil) {
            mockHAL.removeDevice(id: 101)
            mockHAL.setDefaultOutputID(nil)
            mockHAL.triggerDevicesChange()
        }
        XCTAssertFalse(audio.masterAudioEngine.isRunning)
        XCTAssertFalse(audio.cueAudioEngine.isRunning)
        await expectRoutePublication(app, master: "wired_headphones_uid", cue: "bluetooth_headphones_uid") {
            mockHAL.addDevice(id: 112, uid: "wired_headphones_uid", name: "External Headphones", outputChannels: 2)
            mockHAL.addDevice(id: 113, uid: "bluetooth_headphones_uid", name: "HD 250BT Headphones", outputChannels: 2)
            mockHAL.setDefaultOutputID(112)
            mockHAL.triggerDevicesChange()
        }
        XCTAssertFalse(app.isMasterFallback)
        XCTAssertFalse(app.isCueFallback)
        XCTAssertEqual(audio.monitor.boundDeviceIDForTesting(of: audio.masterAudioEngine.rawEngine), 112)
        XCTAssertEqual(audio.monitor.boundDeviceIDForTesting(of: audio.cueAudioEngine.rawEngine), 113)
        XCTAssertTrue(audio.masterAudioEngine.isRunning, "Missing-output recovery must retain master's running intent")
        XCTAssertFalse(audio.cueAudioEngine.isRunning, "Replug must not restart deliberately stopped cue")

        audio.monitor.performOnControlQueue { audio.masterAudioEngine.rawEngine.pause() }
        XCTAssertFalse(audio.masterAudioEngine.isRunning)
        let observersBefore = audio.monitor.configurationObserverFireCountForTesting()
        await expectRoutePublication(app, master: "wired_headphones_uid", cue: "bluetooth_headphones_uid") {
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: audio.masterAudioEngine.rawEngine)
            XCTAssertEqual(audio.monitor.configurationObserverFireCountForTesting(), observersBefore + 2,
                           "Both engine observers must exist exactly once")
        }
        XCTAssertTrue(audio.masterAudioEngine.isRunning, "Real configuration notification must recover master")
        XCTAssertFalse(audio.cueAudioEngine.isRunning)
        XCTAssertEqual(mockHAL.devicesListeners.count, 1)
        XCTAssertEqual(mockHAL.defaultListeners.count, 1)
    }

    @MainActor
    func testRepeatedStartupRollbackAndShutdownRestartRestoreDesiredRoutesWithoutDuplicateObservers() async throws {
        let app = try makeOfflineApp()
        let audio = coordinator!
        app.selectOutputDevice(role: .master, uid: "wired_headphones_uid")
        app.selectOutputDevice(role: .cue, uid: "bluetooth_headphones_uid")
        for attempt in 0..<3 {
            audio.masterAudioEngine.startErrorForTesting = attempt == 1
                ? CoreAudioError.osStatus(-1, operation: "masterRetry") : nil
            audio.cueAudioEngine.startErrorForTesting = attempt == 1
                ? nil : CoreAudioError.osStatus(-10868, operation: "cueRetry")
            app.toggleDeckPlay(deck: .deckB)
            XCTAssertNotNil(app.coordinatorErrorMessage)
            XCTAssertFalse(app.isDeckBPlaying)
            XCTAssertFalse(audio.masterAudioEngine.isRunning)
            XCTAssertFalse(audio.cueAudioEngine.isRunning)
            XCTAssertFalse(audio.monitor.isMonitoringActive)
            XCTAssertTrue(mockHAL.devicesListeners.isEmpty)
            XCTAssertTrue(mockHAL.defaultListeners.isEmpty)
        }
        audio.masterAudioEngine.startErrorForTesting = nil
        audio.cueAudioEngine.startErrorForTesting = nil
        await expectRoutePublication(app, master: "wired_headphones_uid", cue: "bluetooth_headphones_uid") {
            app.toggleDeckPlay(deck: .deckB)
        }
        XCTAssertNil(app.coordinatorErrorMessage)
        XCTAssertTrue(app.isDeckBPlaying)
        XCTAssertEqual(audio.monitor.desiredDeviceUID(for: .master), "wired_headphones_uid")
        XCTAssertEqual(audio.monitor.desiredDeviceUID(for: .cue), "bluetooth_headphones_uid")
        try audio.start()
        try audio.start()
        XCTAssertEqual(mockHAL.devicesListeners.count, 1)
        XCTAssertEqual(mockHAL.defaultListeners.count, 1)

        audio.stop()
        XCTAssertFalse(audio.monitor.isMonitoringActive)
        XCTAssertNil(audio.monitor.boundDeviceUID(for: .master))
        XCTAssertNil(audio.monitor.boundDeviceUID(for: .cue))
        XCTAssertTrue(mockHAL.devicesListeners.isEmpty)
        XCTAssertTrue(mockHAL.defaultListeners.isEmpty)
        let stoppedObserverCount = audio.monitor.configurationObserverFireCountForTesting()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: audio.masterAudioEngine.rawEngine)
        XCTAssertEqual(audio.monitor.configurationObserverFireCountForTesting(), stoppedObserverCount,
                       "Normal shutdown must remove configuration observers")
        app.refreshOutputDevices()
        await expectRoutePublication(app, master: "wired_headphones_uid", cue: "bluetooth_headphones_uid") {
            app.toggleDeckPlay(deck: .deckA)
        }
        XCTAssertTrue(audio.masterAudioEngine.isRunning)
        XCTAssertTrue(audio.cueAudioEngine.isRunning)
        let restartedObserverCount = audio.monitor.configurationObserverFireCountForTesting()
        await expectRoutePublication(app, master: "wired_headphones_uid", cue: "bluetooth_headphones_uid") {
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: audio.cueAudioEngine.rawEngine)
            XCTAssertEqual(audio.monitor.configurationObserverFireCountForTesting(), restartedObserverCount + 2)
        }
        XCTAssertEqual(mockHAL.devicesListeners.count, 1)
        XCTAssertEqual(mockHAL.defaultListeners.count, 1)
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
        // Finalize the WAV header before a separate production reader opens it.
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: trackURL, settings: format.settings)
            let frameCount = AVAudioFrameCount(44100.0 * 2.0)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
            buffer.frameLength = frameCount
            try file.write(from: buffer)
        }

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
