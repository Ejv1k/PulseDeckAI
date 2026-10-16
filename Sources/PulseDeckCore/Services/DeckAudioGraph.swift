import Foundation
import AVFoundation

/// Isolated single-deck playback graph conforming to `DeckAudioGraphContract`.
///
/// ## Graph Architecture & Isolation:
/// - Constructs two completely decoupled audio graphs on `masterEngine` and `cueEngine`.
/// - Never shares `AVAudioNode` instances across engines.
/// - Master Path: `masterPlayerNode -> masterTimePitchNode -> masterEQNode -> masterFilterNode -> masterFaderNode -> masterEngine.subMixer`
/// - Cue (PFL) Path: `cuePlayerNode -> cueTimePitchNode -> cueEQNode -> cueFilterNode -> cueFaderNode -> cueEngine.subMixer`
/// - Pre-Fader Listen (PFL): `masterFaderNode.outputVolume` is governed by channel `volume` and `crossfaderWeight`.
///   `cueFaderNode.outputVolume` is governed solely by `isCueActive`, completely unaffected by master faders.
/// - Independent Scrubbing: Headphone cue scrubbing controls `cuePlayerNode` with zero effect on live FOH playback.
/// - Serialized Control Plane: All player transport operations hop onto `OutputDeviceMonitor.controlQueue`
///   to prevent concurrent mutation during hotplug recovery.
public final class DeckAudioGraph: DeckAudioGraphContract, @unchecked Sendable {

    public let deckId: DeckIdentifier

    // Master Engine Graph Nodes
    public let masterPlayerNode: AVAudioPlayerNode
    public let masterTimePitchNode: AVAudioUnitTimePitch
    public let masterEQNode: AVAudioUnitEQ
    public let masterFilterNode: AVAudioUnitEQ
    public let masterFaderNode: AVAudioMixerNode

    // Cue Engine Graph Nodes (strictly separate instances)
    public let cuePlayerNode: AVAudioPlayerNode
    public let cueTimePitchNode: AVAudioUnitTimePitch
    public let cueEQNode: AVAudioUnitEQ
    public let cueFilterNode: AVAudioUnitEQ
    public let cueFaderNode: AVAudioMixerNode

    private weak var masterEngine: OutputAudioEngine?
    private weak var cueEngine: OutputAudioEngine?
    private weak var monitor: OutputDeviceMonitor?

    private let stateLock = NSLock()

    // State Variables
    private var _volume: Float = 1.0
    private var _crossfaderWeight: Float = 1.0
    private var _isCueActive: Bool = false
    private var _eqParameters = EQ3BandParameters()
    private var _filterParameters = ResonantFilterParameters()
    private var _timePitchParameters = TimePitchParameters()

    private var _masterAudioFile: AVAudioFile?
    private var _cueAudioFile: AVAudioFile?
    private var _trackDurationSeconds: Double = 0.0
    private var _currentSeekPositionSeconds: Double = 0.0
    private var _cueSeekPositionSeconds: Double = 0.0
    private var _masterScheduleStartSeconds: Double = 0.0
    private var _cueScheduleStartSeconds: Double = 0.0
    private var _masterSegmentQueued: Bool = false
    private var _cueSegmentQueued: Bool = false
    private var _masterScheduleGeneration: UInt64 = 0
    private var _cueScheduleGeneration: UInt64 = 0

    private var _isMasterPlaying: Bool = false
    private var _isCuePlaying: Bool = false

    /// Observes the actual scheduled completion closures for deterministic delayed-callback tests.
    /// Install before transport calls; invoked only on the control queue when a monitor is present.
    var segmentCompletionObserverForTesting: (@Sendable (AudioEngineRole, @escaping @Sendable () -> Void) -> Void)?

    /// Independent audio file instance scheduled on the Master player.
    public var masterAudioFileForTesting: AVAudioFile? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _masterAudioFile
    }

    /// Independent audio file instance scheduled on the Cue player.
    public var cueAudioFileForTesting: AVAudioFile? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _cueAudioFile
    }

    /// Starting playback time of the currently scheduled Master segment for testing verification.
    public var masterScheduleStartSecondsForTesting: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _masterScheduleStartSeconds
    }

    /// Starting playback time of the currently scheduled Cue segment for testing verification.
    public var cueScheduleStartSecondsForTesting: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _cueScheduleStartSeconds
    }

    /// Initializes a new dual-engine deck audio graph.
    ///
    /// - Parameters:
    ///   - deckId: Deck identifier (`.deckA` or `.deckB`).
    ///   - masterEngine: Master output audio engine.
    ///   - cueEngine: Cue headphones output audio engine.
    ///   - monitor: Output device monitor for serialized control mutations.
    public init(
        deckId: DeckIdentifier,
        masterEngine: OutputAudioEngine,
        cueEngine: OutputAudioEngine,
        monitor: OutputDeviceMonitor? = nil
    ) {
        self.deckId = deckId
        self.masterEngine = masterEngine
        self.cueEngine = cueEngine
        self.monitor = monitor

        // Instantiate Master Nodes
        self.masterPlayerNode = AVAudioPlayerNode()
        self.masterTimePitchNode = AVAudioUnitTimePitch()
        self.masterEQNode = AVAudioUnitEQ(numberOfBands: 3)
        self.masterFilterNode = AVAudioUnitEQ(numberOfBands: 1)
        self.masterFaderNode = AVAudioMixerNode()

        // Instantiate Cue Nodes
        self.cuePlayerNode = AVAudioPlayerNode()
        self.cueTimePitchNode = AVAudioUnitTimePitch()
        self.cueEQNode = AVAudioUnitEQ(numberOfBands: 3)
        self.cueFilterNode = AVAudioUnitEQ(numberOfBands: 1)
        self.cueFaderNode = AVAudioMixerNode()

        setupGraphs()
    }

    private func setupGraphs() {
        guard let master = masterEngine, let cue = cueEngine else { return }

        // Setup Master Graph
        master.rawEngine.attach(masterPlayerNode)
        master.rawEngine.attach(masterTimePitchNode)
        master.rawEngine.attach(masterEQNode)
        master.rawEngine.attach(masterFilterNode)
        master.rawEngine.attach(masterFaderNode)

        master.rawEngine.connect(masterPlayerNode, to: masterTimePitchNode, format: nil)
        master.rawEngine.connect(masterTimePitchNode, to: masterEQNode, format: nil)
        master.rawEngine.connect(masterEQNode, to: masterFilterNode, format: nil)
        master.rawEngine.connect(masterFilterNode, to: masterFaderNode, format: nil)
        master.rawEngine.connect(masterFaderNode, to: master.subMixer, format: nil)

        // Setup Cue Graph
        cue.rawEngine.attach(cuePlayerNode)
        cue.rawEngine.attach(cueTimePitchNode)
        cue.rawEngine.attach(cueEQNode)
        cue.rawEngine.attach(cueFilterNode)
        cue.rawEngine.attach(cueFaderNode)

        cue.rawEngine.connect(cuePlayerNode, to: cueTimePitchNode, format: nil)
        cue.rawEngine.connect(cueTimePitchNode, to: cueEQNode, format: nil)
        cue.rawEngine.connect(cueEQNode, to: cueFilterNode, format: nil)
        cue.rawEngine.connect(cueFilterNode, to: cueFaderNode, format: nil)
        cue.rawEngine.connect(cueFaderNode, to: cue.subMixer, format: nil)

        // Initialize EQ bands
        configureEQ(masterEQNode)
        configureEQ(cueEQNode)

        // Initial volume states
        updateMasterFaderVolume()
        cueFaderNode.outputVolume = 0.0
    }

    private func configureEQ(_ eq: AVAudioUnitEQ) {
        guard eq.bands.count >= 3 else { return }
        // Band 0: Low Shelf @ 250 Hz
        eq.bands[0].filterType = .lowShelf
        eq.bands[0].frequency = 250.0
        eq.bands[0].gain = 0.0
        eq.bands[0].bypass = false

        // Band 1: Mid Parametric @ 1200 Hz, Q = 1.0
        eq.bands[1].filterType = .parametric
        eq.bands[1].frequency = 1200.0
        eq.bands[1].bandwidth = 1.0
        eq.bands[1].gain = 0.0
        eq.bands[1].bypass = false

        // Band 2: High Shelf @ 3500 Hz
        eq.bands[2].filterType = .highShelf
        eq.bands[2].frequency = 3500.0
        eq.bands[2].gain = 0.0
        eq.bands[2].bypass = false
    }

    // MARK: - DeckAudioGraphContract Properties

    public var volume: Float {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _volume
        }
        set {
            let clamped = newValue.isFinite ? min(max(newValue, 0.0), 1.0) : 0.0
            stateLock.lock()
            _volume = clamped
            stateLock.unlock()
            updateMasterFaderVolume()
        }
    }

    public var crossfaderWeight: Float {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _crossfaderWeight
        }
        set {
            let clamped = newValue.isFinite ? min(max(newValue, 0.0), 1.0) : 1.0
            stateLock.lock()
            _crossfaderWeight = clamped
            stateLock.unlock()
            updateMasterFaderVolume()
        }
    }

    public var isCueActive: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isCueActive
        }
        set {
            executeOnControlQueue {
                self.stateLock.lock()
                self._isCueActive = newValue
                let isMasterPlaying = self._isMasterPlaying
                let cueFile = self._cueAudioFile
                self.stateLock.unlock()

                // Pre-fader listen toggle on cue engine
                self.cueFaderNode.outputVolume = newValue ? 1.0 : 0.0

                if newValue {
                    // Tap master playhead when engaging cue
                    let tapSeconds = self.currentMasterPlayheadSeconds()
                    if let cueFile {
                        self.invalidateSchedule(for: .cue)
                        self.cuePlayerNode.stop()
                        self.scheduleCueSegment(file: cueFile, startSeconds: tapSeconds)
                    }
                    if isMasterPlaying {
                        self.cuePlayerNode.play()
                    }
                } else {
                    self.cuePlayerNode.pause()
                }
            }
        }
    }

    public var eqParameters: EQ3BandParameters {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _eqParameters
        }
        set {
            let safeLow = newValue.lowGainDB.isFinite ? min(max(newValue.lowGainDB, -24.0), 6.0) : 0.0
            let safeMid = newValue.midGainDB.isFinite ? min(max(newValue.midGainDB, -24.0), 6.0) : 0.0
            let safeHigh = newValue.highGainDB.isFinite ? min(max(newValue.highGainDB, -24.0), 6.0) : 0.0
            let clamped = EQ3BandParameters(lowGainDB: safeLow, midGainDB: safeMid, highGainDB: safeHigh)

            stateLock.lock()
            _eqParameters = clamped
            stateLock.unlock()

            applyEQ(clamped, to: masterEQNode)
            applyEQ(clamped, to: cueEQNode)
        }
    }

    public var filterParameters: ResonantFilterParameters {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _filterParameters
        }
        set {
            let safeSweep = newValue.sweep.isFinite ? min(max(newValue.sweep, -1.0), 1.0) : 0.0
            let safeResonance = newValue.resonance.isFinite ? min(max(newValue.resonance, 0.5), 5.0) : 1.0
            let clamped = ResonantFilterParameters(sweep: safeSweep, resonance: safeResonance)

            stateLock.lock()
            _filterParameters = clamped
            stateLock.unlock()

            applyFilter(clamped, to: masterFilterNode)
            applyFilter(clamped, to: cueFilterNode)
        }
    }

    public var timePitchParameters: TimePitchParameters {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _timePitchParameters
        }
        set {
            let safeRate = newValue.rate.isFinite ? min(max(newValue.rate, 0.05), 32.0) : 1.0
            let safePitch = newValue.pitchCents.isFinite ? min(max(newValue.pitchCents, -2400.0), 2400.0) : 0.0
            let clamped = TimePitchParameters(rate: safeRate, pitchCents: safePitch, keyLockEnabled: newValue.keyLockEnabled)

            stateLock.lock()
            _timePitchParameters = clamped
            stateLock.unlock()

            applyTimePitch(clamped, to: masterTimePitchNode)
            applyTimePitch(clamped, to: cueTimePitchNode)
        }
    }

    // MARK: - Playback Operations

    public func loadTrack(url: URL) throws {
        try executeOnControlQueue {
            // Open two distinct AVAudioFile handles from the URL to prevent cross-engine thread races.
            let masterFile = try AVAudioFile(forReading: url)
            let cueFile = try AVAudioFile(forReading: url)
            let sampleRate = masterFile.processingFormat.sampleRate
            let lengthFrames = masterFile.length
            let duration = sampleRate > 0.0 ? Double(lengthFrames) / sampleRate : 0.0

            // Stop players to clear queued segments from prior loads
            self.invalidateSchedule(for: .master)
            self.invalidateSchedule(for: .cue)
            self.masterPlayerNode.stop()
            self.cuePlayerNode.stop()

            self.stateLock.lock()
            self._masterAudioFile = masterFile
            self._cueAudioFile = cueFile
            self._trackDurationSeconds = duration
            self._currentSeekPositionSeconds = 0.0
            self._cueSeekPositionSeconds = 0.0
            self._masterScheduleStartSeconds = 0.0
            self._cueScheduleStartSeconds = 0.0
            self._masterSegmentQueued = false
            self._cueSegmentQueued = false
            self._isMasterPlaying = false
            self._isCuePlaying = false
            self.stateLock.unlock()

            self.scheduleMasterSegment(file: masterFile, startSeconds: 0.0)
            self.scheduleCueSegment(file: cueFile, startSeconds: 0.0)
        }
    }

    public func play() {
        executeOnControlQueue {
            self.stateLock.lock()
            self._isMasterPlaying = true
            let cueActive = self._isCueActive
            let masterQueued = self._masterSegmentQueued
            let cueQueued = self._cueSegmentQueued
            let masterFile = self._masterAudioFile
            let cueFile = self._cueAudioFile
            let duration = self._trackDurationSeconds
            self.stateLock.unlock()

            // If segment completed/nothing queued, reschedule from playhead (or 0.0 if at end)
            if !masterQueued, let masterFile {
                var playhead = self.currentMasterPlayheadSeconds()
                if playhead >= duration {
                    playhead = 0.0
                }
                self.scheduleMasterSegment(file: masterFile, startSeconds: playhead)
            }
            self.masterPlayerNode.play()

            if cueActive {
                if !cueQueued, let cueFile {
                    var playhead = self.currentCuePlayheadSeconds()
                    if playhead >= duration {
                        playhead = 0.0
                    }
                    self.scheduleCueSegment(file: cueFile, startSeconds: playhead)
                }
                self.cuePlayerNode.play()
            }
        }
    }

    public func pause() {
        executeOnControlQueue {
            self.stateLock.lock()
            self._isMasterPlaying = false
            self.stateLock.unlock()

            self.masterPlayerNode.pause()
            self.cuePlayerNode.pause()
        }
    }

    public func seek(to seconds: Double) {
        guard seconds.isFinite else { return }

        executeOnControlQueue {
            self.stateLock.lock()
            guard let masterFile = self._masterAudioFile, let cueFile = self._cueAudioFile else {
                self.stateLock.unlock()
                return
            }
            let clampedSeconds = min(max(seconds, 0.0), self._trackDurationSeconds)
            self._currentSeekPositionSeconds = clampedSeconds
            self._cueSeekPositionSeconds = clampedSeconds
            let wasMasterPlaying = self._isMasterPlaying
            let cueActive = self._isCueActive
            self.stateLock.unlock()

            self.invalidateSchedule(for: .master)
            self.masterPlayerNode.stop()
            self.scheduleMasterSegment(file: masterFile, startSeconds: clampedSeconds)
            if wasMasterPlaying {
                self.masterPlayerNode.play()
            }

            self.invalidateSchedule(for: .cue)
            self.cuePlayerNode.stop()
            self.scheduleCueSegment(file: cueFile, startSeconds: clampedSeconds)
            if wasMasterPlaying && cueActive {
                self.cuePlayerNode.play()
            }
        }
    }

    // MARK: - Independent Cue Scrubbing (Zero Master FOH Effect)

    /// Scrubs the cue headphone preview independently without affecting master playback.
    public func seekCue(to seconds: Double) {
        guard seconds.isFinite else { return }

        executeOnControlQueue {
            self.stateLock.lock()
            guard let cueFile = self._cueAudioFile else {
                self.stateLock.unlock()
                return
            }
            let clampedSeconds = min(max(seconds, 0.0), self._trackDurationSeconds)
            self._cueSeekPositionSeconds = clampedSeconds
            let wasCuePlaying = self._isCuePlaying || (self._isMasterPlaying && self._isCueActive)
            self.stateLock.unlock()

            self.invalidateSchedule(for: .cue)
            self.cuePlayerNode.stop()
            self.scheduleCueSegment(file: cueFile, startSeconds: clampedSeconds)
            if wasCuePlaying {
                self.cuePlayerNode.play()
            }
        }
    }

    /// Plays cue preview independently in headphones.
    public func playCue() {
        executeOnControlQueue {
            self.stateLock.lock()
            self._isCuePlaying = true
            let cueQueued = self._cueSegmentQueued
            let cueFile = self._cueAudioFile
            let duration = self._trackDurationSeconds
            self.stateLock.unlock()

            if !cueQueued, let cueFile {
                var playhead = self.currentCuePlayheadSeconds()
                if playhead >= duration {
                    playhead = 0.0
                }
                self.scheduleCueSegment(file: cueFile, startSeconds: playhead)
            }
            self.cuePlayerNode.play()
        }
    }

    /// Pauses cue preview independently in headphones.
    public func pauseCue() {
        executeOnControlQueue {
            self.stateLock.lock()
            self._isCuePlaying = false
            self.stateLock.unlock()

            self.cuePlayerNode.pause()
        }
    }

    // MARK: - Private DSP & Routing Helpers

    private func currentMasterPlayheadSeconds() -> Double {
        stateLock.lock()
        let scheduledStart = _masterScheduleStartSeconds
        let duration = _trackDurationSeconds
        stateLock.unlock()

        if let nodeTime = masterPlayerNode.lastRenderTime,
           let playerTime = masterPlayerNode.playerTime(forNodeTime: nodeTime) {
            let sampleRate = playerTime.sampleRate
            if sampleRate > 0.0 {
                let elapsed = Double(playerTime.sampleTime) / sampleRate
                let current = scheduledStart + elapsed
                return duration > 0.0 ? min(max(current, 0.0), duration) : max(current, 0.0)
            }
        }
        return scheduledStart
    }

    private func currentCuePlayheadSeconds() -> Double {
        stateLock.lock()
        let scheduledStart = _cueScheduleStartSeconds
        let duration = _trackDurationSeconds
        stateLock.unlock()

        if let nodeTime = cuePlayerNode.lastRenderTime,
           let playerTime = cuePlayerNode.playerTime(forNodeTime: nodeTime) {
            let sampleRate = playerTime.sampleRate
            if sampleRate > 0.0 {
                let elapsed = Double(playerTime.sampleTime) / sampleRate
                let current = scheduledStart + elapsed
                return duration > 0.0 ? min(max(current, 0.0), duration) : max(current, 0.0)
            }
        }
        return scheduledStart
    }

    private func updateMasterFaderVolume() {
        stateLock.lock()
        let eff = _volume * _crossfaderWeight
        stateLock.unlock()
        masterFaderNode.outputVolume = eff
    }

    private func applyEQ(_ params: EQ3BandParameters, to eq: AVAudioUnitEQ) {
        guard eq.bands.count >= 3 else { return }
        eq.bands[0].gain = params.lowGainDB
        eq.bands[1].gain = params.midGainDB
        eq.bands[2].gain = params.highGainDB
    }

    private func applyFilter(_ params: ResonantFilterParameters, to filter: AVAudioUnitEQ) {
        guard !filter.bands.isEmpty else { return }
        let band = filter.bands[0]

        if params.sweep == 0.0 {
            band.bypass = true
            filter.bypass = true
        } else if params.sweep < 0.0 {
            // Resonant Low-Pass Filter: sweeps downward from 20 kHz to 100 Hz
            band.bypass = false
            filter.bypass = false
            band.filterType = .resonantLowPass
            let ratio = 1.0 + Double(params.sweep) // 1.0 at sweep=0, 0.0 at sweep=-1.0
            let freq = pow(10.0, log10(100.0) + ratio * (log10(20000.0) - log10(100.0)))
            band.frequency = Float(freq)
            band.bandwidth = params.resonance
        } else {
            // Resonant High-Pass Filter: sweeps upward from 20 Hz to 10 kHz
            band.bypass = false
            filter.bypass = false
            band.filterType = .resonantHighPass
            let ratio = Double(params.sweep) // 0.0 at sweep=0, 1.0 at sweep=+1.0
            let freq = pow(10.0, log10(20.0) + ratio * (log10(10000.0) - log10(20.0)))
            band.frequency = Float(freq)
            band.bandwidth = params.resonance
        }
    }

    private func applyTimePitch(_ params: TimePitchParameters, to timePitch: AVAudioUnitTimePitch) {
        timePitch.rate = params.rate
        // Key-lock: pitch locked to original musical key (0.0 cents) when enabled
        timePitch.pitch = params.keyLockEnabled ? 0.0 : params.pitchCents
    }

    private func scheduleMasterSegment(file: AVAudioFile, startSeconds: Double) {
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0.0 else { return }

        let startFrame = AVAudioFramePosition(startSeconds * sampleRate)
        guard startFrame < file.length else { return }

        let frameCount = AVAudioFrameCount(file.length - startFrame)

        stateLock.lock()
        _masterScheduleGeneration &+= 1
        let generation = _masterScheduleGeneration
        _masterScheduleStartSeconds = startSeconds
        _masterSegmentQueued = true
        stateLock.unlock()

        let completion: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            defer { self.stateLock.unlock() }
            guard self._masterScheduleGeneration == generation else { return }
            self._masterSegmentQueued = false
        }
        masterPlayerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil,
            completionHandler: completion
        )
        segmentCompletionObserverForTesting?(.master, completion)
    }

    private func scheduleCueSegment(file: AVAudioFile, startSeconds: Double) {
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0.0 else { return }

        let startFrame = AVAudioFramePosition(startSeconds * sampleRate)
        guard startFrame < file.length else { return }

        let frameCount = AVAudioFrameCount(file.length - startFrame)

        stateLock.lock()
        _cueScheduleGeneration &+= 1
        let generation = _cueScheduleGeneration
        _cueScheduleStartSeconds = startSeconds
        _cueSegmentQueued = true
        stateLock.unlock()

        let completion: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            defer { self.stateLock.unlock() }
            guard self._cueScheduleGeneration == generation else { return }
            self._cueSegmentQueued = false
        }
        cuePlayerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil,
            completionHandler: completion
        )
        segmentCompletionObserverForTesting?(.cue, completion)
    }

    /// Invalidate before stopping: AVAudioPlayerNode may deliver a stopped segment's completion later.
    private func invalidateSchedule(for role: AudioEngineRole) {
        stateLock.lock()
        defer { stateLock.unlock() }
        switch role {
        case .master:
            _masterScheduleGeneration &+= 1
            _masterSegmentQueued = false
        case .cue:
            _cueScheduleGeneration &+= 1
            _cueSegmentQueued = false
        }
    }

    private func executeOnControlQueue<T: Sendable>(_ block: @Sendable () throws -> T) rethrows -> T {
        if let monitor {
            return try monitor.performOnControlQueue(block)
        } else {
            return try block()
        }
    }
}
