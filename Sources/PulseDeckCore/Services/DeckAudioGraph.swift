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

    private var _currentAudioFile: AVAudioFile?
    private var _trackDurationSeconds: Double = 0.0
    private var _currentSeekPositionSeconds: Double = 0.0
    private var _cueSeekPositionSeconds: Double = 0.0

    private var _isMasterPlaying: Bool = false
    private var _isCuePlaying: Bool = false

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
            stateLock.lock()
            _isCueActive = newValue
            let shouldPlayCue = newValue && _isMasterPlaying
            stateLock.unlock()

            // Pre-fader listen toggle on cue engine
            cueFaderNode.outputVolume = newValue ? 1.0 : 0.0

            if shouldPlayCue && !cuePlayerNode.isPlaying {
                cuePlayerNode.play()
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
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        let lengthFrames = file.length
        let duration = sampleRate > 0.0 ? Double(lengthFrames) / sampleRate : 0.0

        stateLock.lock()
        _currentAudioFile = file
        _trackDurationSeconds = duration
        _currentSeekPositionSeconds = 0.0
        _cueSeekPositionSeconds = 0.0
        stateLock.unlock()

        scheduleSegment(for: masterPlayerNode, file: file, startSeconds: 0.0)
        scheduleSegment(for: cuePlayerNode, file: file, startSeconds: 0.0)
    }

    public func play() {
        stateLock.lock()
        _isMasterPlaying = true
        let cueActive = _isCueActive
        stateLock.unlock()

        masterPlayerNode.play()
        if cueActive {
            cuePlayerNode.play()
        }
    }

    public func pause() {
        stateLock.lock()
        _isMasterPlaying = false
        stateLock.unlock()

        masterPlayerNode.pause()
        cuePlayerNode.pause()
    }

    public func seek(to seconds: Double) {
        guard seconds.isFinite else { return }

        stateLock.lock()
        guard let file = _currentAudioFile else {
            stateLock.unlock()
            return
        }
        let clampedSeconds = min(max(seconds, 0.0), _trackDurationSeconds)
        _currentSeekPositionSeconds = clampedSeconds
        _cueSeekPositionSeconds = clampedSeconds
        let wasMasterPlaying = _isMasterPlaying
        let cueActive = _isCueActive
        stateLock.unlock()

        masterPlayerNode.stop()
        scheduleSegment(for: masterPlayerNode, file: file, startSeconds: clampedSeconds)
        if wasMasterPlaying {
            masterPlayerNode.play()
        }

        cuePlayerNode.stop()
        scheduleSegment(for: cuePlayerNode, file: file, startSeconds: clampedSeconds)
        if wasMasterPlaying && cueActive {
            cuePlayerNode.play()
        }
    }

    // MARK: - Independent Cue Scrubbing (Zero Master FOH Effect)

    /// Scrubs the cue headphone preview independently without affecting master playback.
    public func seekCue(to seconds: Double) {
        guard seconds.isFinite else { return }

        stateLock.lock()
        guard let file = _currentAudioFile else {
            stateLock.unlock()
            return
        }
        let clampedSeconds = min(max(seconds, 0.0), _trackDurationSeconds)
        _cueSeekPositionSeconds = clampedSeconds
        let wasCuePlaying = _isCuePlaying || (_isMasterPlaying && _isCueActive)
        stateLock.unlock()

        cuePlayerNode.stop()
        scheduleSegment(for: cuePlayerNode, file: file, startSeconds: clampedSeconds)
        if wasCuePlaying {
            cuePlayerNode.play()
        }
    }

    /// Plays cue preview independently in headphones.
    public func playCue() {
        stateLock.lock()
        _isCuePlaying = true
        stateLock.unlock()
        cuePlayerNode.play()
    }

    /// Pauses cue preview independently in headphones.
    public func pauseCue() {
        stateLock.lock()
        _isCuePlaying = false
        stateLock.unlock()
        cuePlayerNode.pause()
    }

    // MARK: - Private DSP & Routing Helpers

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

    private func scheduleSegment(for player: AVAudioPlayerNode, file: AVAudioFile, startSeconds: Double) {
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0.0 else { return }

        let startFrame = AVAudioFramePosition(startSeconds * sampleRate)
        guard startFrame < file.length else { return }

        let frameCount = AVAudioFrameCount(file.length - startFrame)
        player.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil,
            completionHandler: nil
        )
    }
}
