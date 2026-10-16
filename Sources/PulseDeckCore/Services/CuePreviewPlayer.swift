import Foundation
import AVFoundation

/// Independent preview and audition player residing exclusively on the Cue (headphones) audio graph.
///
/// Enables DJs to audition, scrub, and loop unassigned tracks directly in headphones with zero
/// impact or audible leakage to live Master Front-Of-House (FOH) playback.
public final class CuePreviewPlayer: @unchecked Sendable {

    public let playerNode: AVAudioPlayerNode
    public let faderNode: AVAudioMixerNode

    private weak var cueEngine: OutputAudioEngine?
    private weak var monitor: OutputDeviceMonitor?
    private let stateLock = NSLock()

    private var _currentAudioFile: AVAudioFile?
    private var _trackDurationSeconds: Double = 0.0
    private var _currentPositionSeconds: Double = 0.0
    private var _scheduleStartSeconds: Double = 0.0
    private var _segmentQueued: Bool = false
    private var _isPlaying: Bool = false
    private var _volume: Float = 1.0

    /// Starting playback time of the currently scheduled segment for testing verification.
    public var scheduleStartSecondsForTesting: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _scheduleStartSeconds
    }

    /// Initializes a dedicated preview player attached exclusively to the Cue audio engine.
    ///
    /// - Parameters:
    ///   - cueEngine: Cue headphones output audio engine.
    ///   - monitor: Optional device monitor used for serialized control synchronization.
    public init(cueEngine: OutputAudioEngine, monitor: OutputDeviceMonitor? = nil) {
        self.cueEngine = cueEngine
        self.monitor = monitor
        self.playerNode = AVAudioPlayerNode()
        self.faderNode = AVAudioMixerNode()

        setupGraph()
    }

    private func setupGraph() {
        guard let cue = cueEngine else { return }
        cue.rawEngine.attach(playerNode)
        cue.rawEngine.attach(faderNode)

        cue.rawEngine.connect(playerNode, to: faderNode, format: nil)
        cue.rawEngine.connect(faderNode, to: cue.subMixer, format: nil)

        faderNode.outputVolume = 1.0
    }

    // MARK: - Public Properties

    public var isPlaying: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isPlaying && playerNode.isPlaying
    }

    public var trackDurationSeconds: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _trackDurationSeconds
    }

    public var currentPositionSeconds: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentPositionSeconds
    }

    public var volume: Float {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _volume
        }
        set {
            let clamped = newValue.isFinite ? min(max(newValue, 0.0), 1.0) : 1.0
            stateLock.lock()
            _volume = clamped
            stateLock.unlock()
            faderNode.outputVolume = clamped
        }
    }

    // MARK: - Playback Controls

    /// Loads an audio file for headphone auditioning.
    public func load(url: URL) throws {
        try executeOnControlQueue {
            let file = try AVAudioFile(forReading: url)
            let sampleRate = file.processingFormat.sampleRate
            let lengthFrames = file.length
            let duration = sampleRate > 0.0 ? Double(lengthFrames) / sampleRate : 0.0

            self.playerNode.stop()

            self.stateLock.lock()
            self._currentAudioFile = file
            self._trackDurationSeconds = duration
            self._currentPositionSeconds = 0.0
            self._scheduleStartSeconds = 0.0
            self._segmentQueued = false
            self._isPlaying = false
            self.stateLock.unlock()

            self.scheduleSegment(file: file, startSeconds: 0.0)
        }
    }

    public func play() {
        executeOnControlQueue {
            self.stateLock.lock()
            self._isPlaying = true
            let queued = self._segmentQueued
            let file = self._currentAudioFile
            let duration = self._trackDurationSeconds
            self.stateLock.unlock()

            // Reschedule from current playhead if previously scheduled segment was consumed
            if !queued, let file {
                var playhead = self.currentPlayheadSeconds()
                if playhead >= duration {
                    playhead = 0.0
                }
                self.scheduleSegment(file: file, startSeconds: playhead)
            }
            self.playerNode.play()
        }
    }

    public func pause() {
        executeOnControlQueue {
            self.stateLock.lock()
            self._isPlaying = false
            self.stateLock.unlock()

            self.playerNode.pause()
        }
    }

    public func stop() {
        executeOnControlQueue {
            self.stateLock.lock()
            self._isPlaying = false
            self._currentPositionSeconds = 0.0
            self._scheduleStartSeconds = 0.0
            self._segmentQueued = false
            self.stateLock.unlock()

            self.playerNode.stop()
        }
    }

    public func seek(to seconds: Double) {
        guard seconds.isFinite else { return }

        executeOnControlQueue {
            self.stateLock.lock()
            guard let file = self._currentAudioFile else {
                self.stateLock.unlock()
                return
            }
            let clampedSeconds = min(max(seconds, 0.0), self._trackDurationSeconds)
            self._currentPositionSeconds = clampedSeconds
            let wasPlaying = self._isPlaying
            self.stateLock.unlock()

            self.playerNode.stop()
            self.scheduleSegment(file: file, startSeconds: clampedSeconds)
            if wasPlaying {
                self.playerNode.play()
            }
        }
    }

    // MARK: - Private Helpers

    private func currentPlayheadSeconds() -> Double {
        stateLock.lock()
        let scheduledStart = _scheduleStartSeconds
        let duration = _trackDurationSeconds
        stateLock.unlock()

        if let nodeTime = playerNode.lastRenderTime,
           let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
            let sampleRate = playerTime.sampleRate
            if sampleRate > 0.0 {
                let elapsed = Double(playerTime.sampleTime) / sampleRate
                let current = scheduledStart + elapsed
                return duration > 0.0 ? min(max(current, 0.0), duration) : max(current, 0.0)
            }
        }
        return scheduledStart
    }

    private func scheduleSegment(file: AVAudioFile, startSeconds: Double) {
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0.0 else { return }

        let startFrame = AVAudioFramePosition(startSeconds * sampleRate)
        guard startFrame < file.length else { return }

        let frameCount = AVAudioFrameCount(file.length - startFrame)

        stateLock.lock()
        _scheduleStartSeconds = startSeconds
        _segmentQueued = true
        stateLock.unlock()

        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil
        ) { [weak self] in
            self?.stateLock.lock()
            self?._segmentQueued = false
            self?.stateLock.unlock()
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
