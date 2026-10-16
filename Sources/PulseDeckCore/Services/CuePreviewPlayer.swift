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
    private let stateLock = NSLock()

    private var _currentAudioFile: AVAudioFile?
    private var _trackDurationSeconds: Double = 0.0
    private var _currentPositionSeconds: Double = 0.0
    private var _isPlaying: Bool = false
    private var _volume: Float = 1.0

    /// Initializes a dedicated preview player attached exclusively to the Cue audio engine.
    ///
    /// - Parameter cueEngine: Cue headphones output audio engine.
    public init(cueEngine: OutputAudioEngine) {
        self.cueEngine = cueEngine
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
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        let lengthFrames = file.length
        let duration = sampleRate > 0.0 ? Double(lengthFrames) / sampleRate : 0.0

        stateLock.lock()
        _currentAudioFile = file
        _trackDurationSeconds = duration
        _currentPositionSeconds = 0.0
        _isPlaying = false
        stateLock.unlock()

        playerNode.stop()
        scheduleSegment(file: file, startSeconds: 0.0)
    }

    public func play() {
        stateLock.lock()
        _isPlaying = true
        stateLock.unlock()
        playerNode.play()
    }

    public func pause() {
        stateLock.lock()
        _isPlaying = false
        stateLock.unlock()
        playerNode.pause()
    }

    public func stop() {
        stateLock.lock()
        _isPlaying = false
        _currentPositionSeconds = 0.0
        stateLock.unlock()
        playerNode.stop()
    }

    public func seek(to seconds: Double) {
        guard seconds.isFinite else { return }

        stateLock.lock()
        guard let file = _currentAudioFile else {
            stateLock.unlock()
            return
        }
        let clampedSeconds = min(max(seconds, 0.0), _trackDurationSeconds)
        _currentPositionSeconds = clampedSeconds
        let wasPlaying = _isPlaying
        stateLock.unlock()

        playerNode.stop()
        scheduleSegment(file: file, startSeconds: clampedSeconds)
        if wasPlaying {
            playerNode.play()
        }
    }

    private func scheduleSegment(file: AVAudioFile, startSeconds: Double) {
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0.0 else { return }

        let startFrame = AVAudioFramePosition(startSeconds * sampleRate)
        guard startFrame < file.length else { return }

        let frameCount = AVAudioFrameCount(file.length - startFrame)
        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil,
            completionHandler: nil
        )
    }
}
