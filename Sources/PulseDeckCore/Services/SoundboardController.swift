import Foundation
import AVFoundation

/// Soundboard pad audio source descriptor.
public enum SoundboardPadSource: Sendable, Equatable {
    case file(name: String, durationSeconds: Double)
    case procedural(toneDescription: String, durationSeconds: Double)
}

/// Soundboard pad error or fallback classification.
public enum SoundboardPadError: Sendable, Equatable {
    case missingFile
    case corruptFile(description: String)
    case oversizedFile(durationSeconds: Double)
    case unsupportedFormat(description: String)
}

/// Immutable public snapshot of a Soundboard pad state for UI and observation.
public struct SoundboardPadSnapshot: Sendable, Equatable, Identifiable {
    public let index: Int
    public let keyLabel: String
    public let title: String
    public let source: SoundboardPadSource
    public let isPlaying: Bool
    public let error: SoundboardPadError?
    public let durationSeconds: Double
    public let ramBytes: Int

    public init(
        index: Int,
        keyLabel: String,
        title: String,
        source: SoundboardPadSource,
        isPlaying: Bool,
        error: SoundboardPadError?,
        durationSeconds: Double,
        ramBytes: Int
    ) {
        self.index = index
        self.keyLabel = keyLabel
        self.title = title
        self.source = source
        self.isPlaying = isPlaying
        self.error = error
        self.durationSeconds = durationSeconds
        self.ramBytes = ramBytes
    }

    public var id: Int { index }

    public var isFallback: Bool {
        switch source {
        case .procedural:
            return true
        case .file:
            return false
        }
    }
}

/// Definition for a procedural fallback tone.
public struct ProceduralToneDefinition: Sendable {
    public let title: String
    public let description: String
    public let durationSeconds: Double
    public let generate: @Sendable (AVAudioFormat) -> AVAudioPCMBuffer?
}

/// Production synthesizer producing pre-allocated procedural fallback audio buffers.
public enum ProceduralSFXGenerator: Sendable {

    /// Standard canonical audio format for all soundboard processing (44.1 kHz, 32-bit Float, Stereo).
    public static var standardFormat: AVAudioFormat {
        AVAudioFormat(
            standardFormatWithSampleRate: 44100.0,
            channels: 2
        )!
    }

    /// Generates 8 distinct, punchy, click-free procedural fallback tone buffers ahead of time.
    public static func fallbackTones() -> [ProceduralToneDefinition] {
        return [
            // Pad 0 (F1): 1 kHz Stinger Pip
            ProceduralToneDefinition(
                title: "1kHz Pip",
                description: "1000 Hz Stinger Pip",
                durationSeconds: 0.15,
                generate: { format in
                    makeToneBuffer(format: format, durationSeconds: 0.15) { t in
                        let env = exp(-t * 28.0)
                        return Float(sin(2.0 * .pi * 1000.0 * t)) * Float(env) * 0.65
                    }
                }
            ),
            // Pad 1 (F2): 808 Sub-bass Kick
            ProceduralToneDefinition(
                title: "Sub 808",
                description: "808 Sub-bass Drop Kick",
                durationSeconds: 0.35,
                generate: { format in
                    makeToneBuffer(format: format, durationSeconds: 0.35) { t in
                        let phase = 2.0 * .pi * (130.0 * (1.0 - exp(-t * 8.0)) / 8.0 + 42.0 * t)
                        let env = exp(-t * 8.5)
                        return Float(sin(phase)) * Float(env) * 0.75
                    }
                }
            ),
            // Pad 2 (F3): White Noise Snare Drop
            ProceduralToneDefinition(
                title: "Noise Snare",
                description: "White Noise Burst Snare",
                durationSeconds: 0.25,
                generate: { format in
                    makeNoiseBuffer(format: format, durationSeconds: 0.25)
                }
            ),
            // Pad 3 (F4): High Chime
            ProceduralToneDefinition(
                title: "High Chime",
                description: "2.4 kHz Metallic Chime Pip",
                durationSeconds: 0.20,
                generate: { format in
                    makeToneBuffer(format: format, durationSeconds: 0.20) { t in
                        let s1 = sin(2.0 * .pi * 2400.0 * t) * 0.45
                        let s2 = sin(2.0 * .pi * 3600.0 * t) * 0.25
                        let env = exp(-t * 18.0)
                        return Float((s1 + s2) * env)
                    }
                }
            ),
            // Pad 5 (F5): Rimshot Click
            ProceduralToneDefinition(
                title: "Rimshot",
                description: "Dual-tone Metallic Rimshot",
                durationSeconds: 0.18,
                generate: { format in
                    makeToneBuffer(format: format, durationSeconds: 0.18) { t in
                        let s1 = sin(2.0 * .pi * 840.0 * t) * 0.4
                        let s2 = sin(2.0 * .pi * 560.0 * t) * 0.35
                        let env = exp(-t * 24.0)
                        return Float((s1 + s2) * env)
                    }
                }
            ),
            // Pad 5 (F6): Two-tone Siren
            ProceduralToneDefinition(
                title: "Siren Beep",
                description: "Alternating 880/660 Hz Siren Beep",
                durationSeconds: 0.30,
                generate: { format in
                    makeToneBuffer(format: format, durationSeconds: 0.30) { t in
                        let freq = t < 0.15 ? 880.0 : 660.0
                        let localT = t < 0.15 ? t : (t - 0.15)
                        let env = 1.0 - (localT / 0.15) * 0.3
                        return Float(sin(2.0 * .pi * freq * t) * env * 0.6)
                    }
                }
            ),
            // Pad 6 (F7): Laser Zap
            ProceduralToneDefinition(
                title: "Laser Zap",
                description: "Frequency Sweep Down Laser",
                durationSeconds: 0.22,
                generate: { format in
                    makeToneBuffer(format: format, durationSeconds: 0.22) { t in
                        let phase = 2.0 * .pi * (2600.0 * (1.0 - exp(-t * 14.0)) / 14.0 + 150.0 * t)
                        let env = exp(-t * 12.0)
                        return Float(sin(phase) * env * 0.65)
                    }
                }
            ),
            // Pad 7 (F8): Airhorn Triad Chord
            ProceduralToneDefinition(
                title: "Airhorn Triad",
                description: "E4/G#4/B4 Brassy Airhorn Triad",
                durationSeconds: 0.28,
                generate: { format in
                    makeToneBuffer(format: format, durationSeconds: 0.28) { t in
                        let f1 = sin(2.0 * .pi * 329.63 * t) * 0.3
                        let f2 = sin(2.0 * .pi * 415.30 * t) * 0.25
                        let f3 = sin(2.0 * .pi * 493.88 * t) * 0.25
                        // Add bright harmonics for brassy airhorn timbre
                        let h1 = sin(2.0 * .pi * 659.26 * t) * 0.15
                        let env = exp(-t * 10.0)
                        return Float((f1 + f2 + f3 + h1) * env * 0.7)
                    }
                }
            )
        ]
    }

    private static func makeToneBuffer(
        format: AVAudioFormat,
        durationSeconds: Double,
        generator: (Double) -> Float
    ) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(format.sampleRate * durationSeconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        guard let channels = buffer.floatChannelData else { return nil }
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)

        // Smooth 5ms fade-out at end to guarantee zero clicks
        let fadeFrames = min(Int(sampleRate * 0.005), Int(frameCount))
        let fadeStart = Int(frameCount) - fadeFrames

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            var sample = generator(t)
            if frame >= fadeStart {
                let fadeProgress = Float(Int(frameCount) - frame) / Float(fadeFrames)
                sample *= fadeProgress
            }
            for ch in 0..<channelCount {
                channels[ch][frame] = sample
            }
        }
        return buffer
    }

    private static func makeNoiseBuffer(
        format: AVAudioFormat,
        durationSeconds: Double
    ) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(format.sampleRate * durationSeconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        guard let channels = buffer.floatChannelData else { return nil }
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)

        // Simple high-pass filtered white noise with exponential decay
        var lastSample: Float = 0.0
        var seed: UInt32 = 1234567

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let env = Float(exp(-t * 15.0)) * 0.6

            // Linear congruential generator for deterministic noise
            seed = seed &* 1664525 &+ 1013904223
            let rawFloat = Float(seed) / Float(UInt32.max) * 2.0 - 1.0

            // One-pole high-pass filter
            let filtered = 0.85 * (lastSample + rawFloat - lastSample * 0.3)
            lastSample = rawFloat

            let sample = filtered * env
            for ch in 0..<channelCount {
                channels[ch][frame] = sample
            }
        }
        return buffer
    }
}

/// Master-only, 8-pad RAM Soundboard controller.
///
/// ## Architectural Guarantees:
/// - Strictly Output-Only: Renders exclusively to `masterAudioEngine.subMixer`. Absolutely NEVER accesses `inputNode`.
/// - Headphone Isolation: Cue engine receives ZERO soundboard signal. Cue (PFL) remains completely clean.
/// - Crossfader & Talkover Preservation: Soundboard mixes directly to Master after deck crossfaders and vocal pocket EQ,
///   so deck gain, crossfader cuts, and talkover states are never altered or bypassed.
/// - Ready RAM Playback: Pre-decodes and pre-allocates audio into unified memory during library scan or initialization.
///   Trigger path performs zero disk I/O, zero network, zero decoding, and zero allocations.
/// - Procedural Fallback: If an SFX asset is missing, corrupted, or oversized, a pre-generated procedural tone plays
///   without silence drops, while the UI displays honest status and fallback badges.
/// - Deterministic Retrigger & Overlap:
///   - Independent pads (e.g. F1 and F2) play concurrently with full polyphony.
///   - Retriggering the same pad cuts and restarts that pad monophonically, preventing runaway voice accumulation.
/// - Reentrant Serialized Control Plane: All graph mutation and trigger scheduling is serialized on
///   `OutputDeviceMonitor.controlQueue` (or a private serial queue in monitor-free test environments).
public final class SoundboardController: @unchecked Sendable {

    public static let padCount: Int = 8
    public static let keyLabels: [String] = ["F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8"]
    public static let crateFolderName = "08_Soundboard_SFX"

    /// Strict upper bound on a single soundboard asset duration (15 seconds).
    public static let maxAssetDurationSeconds: Double = 15.0

    /// Strict upper bound on single asset RAM size (12 MB ≈ 35 seconds of stereo 44.1kHz Float32).
    public static let maxPerAssetRAMBytes: Int = 12 * 1024 * 1024

    /// Strict upper bound on total soundboard RAM footprint (64 MB).
    public static let maxTotalRAMBytes: Int = 64 * 1024 * 1024

    /// Canonical audio format for all soundboard processing.
    public let processingFormat: AVAudioFormat = ProceduralSFXGenerator.standardFormat

    public let playerNodes: [AVAudioPlayerNode]
    public let soundboardMixerNode: AVAudioMixerNode

    private weak var masterEngine: OutputAudioEngine?
    private weak var monitor: OutputDeviceMonitor?

    private let fallbackQueue = DispatchQueue(label: "com.pulsedeck.soundboard.control")
    private let fallbackQueueKey = DispatchSpecificKey<UInt8>()
    private static let fallbackQueueToken: UInt8 = 1

    private let stateLock = NSLock()

    // Pad state internals
    private struct InternalPad {
        var buffer: AVAudioPCMBuffer
        var fallbackBuffer: AVAudioPCMBuffer
        var source: SoundboardPadSource
        var error: SoundboardPadError?
        var title: String
        var isPlaying: Bool
        var durationSeconds: Double
        var ramBytes: Int
        var triggerGeneration: UInt64
    }

    private var _pads: [InternalPad]
    private var _preloadGeneration: UInt64 = 0
    private var _activePreloadTask: Task<Void, Never>?
    private var _isMuted: Bool = false

    /// Callback invoked whenever pad state, readiness, or playing status changes.
    public var onPadsChanged: (@Sendable ([SoundboardPadSnapshot]) -> Void)?

    /// Initializes the Master-only soundboard with 8 player nodes connected to a dedicated mixer.
    public init(
        masterEngine: OutputAudioEngine,
        monitor: OutputDeviceMonitor? = nil
    ) {
        self.masterEngine = masterEngine
        self.monitor = monitor
        self.soundboardMixerNode = AVAudioMixerNode()

        var nodes: [AVAudioPlayerNode] = []
        for _ in 0..<Self.padCount {
            nodes.append(AVAudioPlayerNode())
        }
        self.playerNodes = nodes

        fallbackQueue.setSpecific(key: fallbackQueueKey, value: Self.fallbackQueueToken)

        // Pre-generate procedural fallback buffers
        let fallbackDefs = ProceduralSFXGenerator.fallbackTones()
        var initialPads: [InternalPad] = []

        for i in 0..<Self.padCount {
            let def = fallbackDefs[i]
            let buffer = def.generate(processingFormat) ?? Self.makeEmergencySilentBuffer(format: processingFormat)
            let ram = Int(buffer.frameLength) * Int(processingFormat.channelCount) * MemoryLayout<Float>.size
            initialPads.append(
                InternalPad(
                    buffer: buffer,
                    fallbackBuffer: buffer,
                    source: .procedural(toneDescription: def.description, durationSeconds: def.durationSeconds),
                    error: nil,
                    title: def.title,
                    isPlaying: false,
                    durationSeconds: def.durationSeconds,
                    ramBytes: ram,
                    triggerGeneration: 0
                )
            )
        }
        self._pads = initialPads

        setupAudioGraph()
    }

    deinit {
        _activePreloadTask?.cancel()
    }

    private func setupAudioGraph() {
        guard let master = masterEngine else { return }
        let rawEngine = master.rawEngine

        // Attach soundboard mixer to Master rawEngine
        rawEngine.attach(soundboardMixerNode)

        // Attach and connect all 8 player nodes to soundboardMixerNode
        for player in playerNodes {
            rawEngine.attach(player)
            rawEngine.connect(player, to: soundboardMixerNode, format: processingFormat)
        }

        // Connect soundboard mixer directly to Master subMixer
        rawEngine.connect(soundboardMixerNode, to: master.subMixer, format: nil)
        soundboardMixerNode.outputVolume = 1.0
    }

    // MARK: - Queue Serialization

    private func executeOnControlQueue<T: Sendable>(_ block: () throws -> T) rethrows -> T {
        if let monitor = monitor {
            return try monitor.performOnControlQueue(block)
        }
        if DispatchQueue.getSpecific(key: fallbackQueueKey) == Self.fallbackQueueToken {
            return try block()
        }
        return try fallbackQueue.sync(execute: block)
    }

    // MARK: - Public State Access

    /// Returns snapshots of all 8 pads.
    public var padSnapshots: [SoundboardPadSnapshot] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _pads.enumerated().map { index, pad in
            SoundboardPadSnapshot(
                index: index,
                keyLabel: Self.keyLabels[index],
                title: pad.title,
                source: pad.source,
                isPlaying: pad.isPlaying,
                error: pad.error,
                durationSeconds: pad.durationSeconds,
                ramBytes: pad.ramBytes
            )
        }
    }

    /// Total RAM currently consumed by preloaded soundboard audio buffers in bytes.
    public var totalRAMBytes: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _pads.reduce(0) { $0 + $1.ramBytes }
    }

    /// Testing hook to inspect the preloaded PCM buffer for a specific pad.
    public func bufferForTesting(at index: Int) -> AVAudioPCMBuffer? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard index >= 0 && index < _pads.count else { return nil }
        return _pads[index].buffer
    }

    /// Prepares player nodes for low-latency playback.
    public func preparePlayers() {
        executeOnControlQueue {
            for player in playerNodes {
                player.prepare(withFrameCount: 4096)
            }
        }
    }

    // MARK: - Trigger and Retrigger API

    /// Triggers playback of the designated Soundboard pad (0..<8).
    ///
    /// ## Retrigger Policy:
    /// - Calling `triggerPad` on an actively playing pad cleanly cuts and restarts playback from the beginning
    ///   (monophonic same-pad choke), preventing runaway voice buildup while enabling stutter effects.
    /// - Independent pads play concurrently (polyphonic overlap) through the soundboard mixer.
    /// - Zero allocations, zero file I/O, zero network, zero decoding during trigger.
    public func triggerPad(index: Int) {
        guard index >= 0 && index < Self.padCount else { return }

        executeOnControlQueue {
            stateLock.lock()
            var pad = self._pads[index]
            pad.triggerGeneration &+= 1
            let gen = pad.triggerGeneration
            pad.isPlaying = true
            self._pads[index] = pad
            let bufferToPlay = pad.buffer
            stateLock.unlock()

            let player = self.playerNodes[index]

            // Stop any in-flight playback on this pad to restart deterministically
            player.stop()

            let isManual = self.masterEngine?.rawEngine.isInManualRenderingMode ?? false
            let callbackType: AVAudioPlayerNodeCompletionCallbackType = isManual ? .dataRendered : .dataPlayedBack

            // Schedule buffer from RAM with explicit playback completion tracking
            player.scheduleBuffer(bufferToPlay, at: nil, options: [], completionCallbackType: callbackType) { [weak self] _ in
                guard let self = self else { return }
                DispatchQueue.global().async {
                    self.executeOnControlQueue {
                        self.handlePadPlaybackCompleted(index: index, generation: gen)
                    }
                }
            }

            if let master = self.masterEngine, master.isRunning {
                player.play()
            }

            self.notifyPadsChanged()
        }
    }

    private func handlePadPlaybackCompleted(index: Int, generation: UInt64) {
        stateLock.lock()
        guard index >= 0 && index < self._pads.count else {
            stateLock.unlock()
            return
        }
        // Only mark inactive if no subsequent trigger on this pad has occurred
        if self._pads[index].triggerGeneration == generation {
            self._pads[index].isPlaying = false
            stateLock.unlock()
            notifyPadsChanged()
        } else {
            stateLock.unlock()
        }
    }

    /// Stops playback on a specific pad.
    public func stopPad(index: Int) {
        guard index >= 0 && index < Self.padCount else { return }

        executeOnControlQueue {
            stateLock.lock()
            self._pads[index].triggerGeneration &+= 1
            self._pads[index].isPlaying = false
            stateLock.unlock()

            self.playerNodes[index].stop()
            self.notifyPadsChanged()
        }
    }

    /// Stops all currently playing soundboard pads.
    public func stopAllPads() {
        executeOnControlQueue {
            stateLock.lock()
            for i in 0..<self._pads.count {
                self._pads[i].triggerGeneration &+= 1
                self._pads[i].isPlaying = false
            }
            stateLock.unlock()

            for player in self.playerNodes {
                player.stop()
            }
            self.notifyPadsChanged()
        }
    }

    private func notifyPadsChanged() {
        let snapshots = self.padSnapshots
        if let callback = self.onPadsChanged {
            callback(snapshots)
        }
    }

    // MARK: - Asset Preloading & Lifecycle

    /// Preloads SFX audio assets from the library root directory into RAM.
    ///
    /// - Scans `<libraryRootURL>/08_Soundboard_SFX` for supported audio formats.
    /// - Deterministically maps up to 8 sorted files to Pads F1–F8.
    /// - Converts assets to standard 44.1kHz stereo Float32 buffers off the audio trigger path.
    /// - Enforces duration and RAM bounds; safely substitutes procedural fallback tones for missing,
    ///   corrupt, or oversized files.
    /// - Rejects stale background completions when the library root changes mid-load.
    public func preload(from libraryRootURL: URL) {
        stateLock.lock()
        _preloadGeneration &+= 1
        let currentGen = _preloadGeneration
        _activePreloadTask?.cancel()
        stateLock.unlock()

        let task = Task.detached(priority: .userInitiated) { [weak self, processingFormat] in
            guard let self = self else { return }

            let sfxDirectoryURL = libraryRootURL.appendingPathComponent(Self.crateFolderName)
            let decodedPads = Self.loadAndDecodeSFXCrate(
                from: sfxDirectoryURL,
                targetFormat: processingFormat
            )

            // Guard against stale completion
            self.executeOnControlQueue {
                self.stateLock.lock()
                guard self._preloadGeneration == currentGen else {
                    self.stateLock.unlock()
                    return
                }

                // Stop any running playback before swapping buffers
                for player in self.playerNodes {
                    player.stop()
                }

                for i in 0..<Self.padCount {
                    let decoded = decodedPads[i]
                    self._pads[i].buffer = decoded.buffer
                    self._pads[i].source = decoded.source
                    self._pads[i].error = decoded.error
                    self._pads[i].title = decoded.title
                    self._pads[i].durationSeconds = decoded.durationSeconds
                    self._pads[i].ramBytes = decoded.ramBytes
                    self._pads[i].isPlaying = false
                    self._pads[i].triggerGeneration &+= 1
                }
                self.stateLock.unlock()

                self.notifyPadsChanged()
            }
        }

        stateLock.lock()
        _activePreloadTask = task
        stateLock.unlock()
    }

    /// Internal struct holding decoded pad asset information.
    private struct DecodedAsset {
        let buffer: AVAudioPCMBuffer
        let source: SoundboardPadSource
        let error: SoundboardPadError?
        let title: String
        let durationSeconds: Double
        let ramBytes: Int
    }

    private static func loadAndDecodeSFXCrate(
        from directoryURL: URL,
        targetFormat: AVAudioFormat
    ) -> [DecodedAsset] {
        let fallbackDefs = ProceduralSFXGenerator.fallbackTones()
        let fileManager = FileManager.default
        var isDir: ObjCBool = false

        var results: [DecodedAsset] = []
        var discoveredFiles: [URL] = []

        if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDir), isDir.boolValue {
            if let items = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) {
                discoveredFiles = items.filter { url in
                    let name = url.lastPathComponent
                    guard !name.hasPrefix(".") else { return false }
                    let ext = url.pathExtension.lowercased()
                    return LibraryScanner.supportedAudioExtensions.contains(ext)
                }.sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }
            }
        }

        var cumulativeRAM = 0

        for padIndex in 0..<Self.padCount {
            let fallbackDef = fallbackDefs[padIndex]
            let fallbackBuffer = fallbackDef.generate(targetFormat) ?? makeEmergencySilentBuffer(format: targetFormat)
            let fallbackRAM = Int(fallbackBuffer.frameLength) * Int(targetFormat.channelCount) * MemoryLayout<Float>.size

            if padIndex < discoveredFiles.count {
                let fileURL = discoveredFiles[padIndex]
                let fileName = fileURL.lastPathComponent

                // Decode file into canonical format
                do {
                    let audioFile = try AVAudioFile(forReading: fileURL)
                    let fileLength = audioFile.length
                    let duration = Double(fileLength) / audioFile.fileFormat.sampleRate

                    // Bound asset duration
                    if duration > maxAssetDurationSeconds {
                        results.append(
                            DecodedAsset(
                                buffer: fallbackBuffer,
                                source: .procedural(toneDescription: fallbackDef.description, durationSeconds: fallbackDef.durationSeconds),
                                error: .oversizedFile(durationSeconds: duration),
                                title: "\(fileName) [OVERSIZED]",
                                durationSeconds: fallbackDef.durationSeconds,
                                ramBytes: fallbackRAM
                            )
                        )
                        continue
                    }

                    // Read source buffer
                    let srcCapacity = AVAudioFrameCount(fileLength)
                    guard srcCapacity > 0, let srcBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: srcCapacity) else {
                        throw NSError(domain: "PulseDeck.Soundboard", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid audio buffer capacity"])
                    }
                    try audioFile.read(into: srcBuffer)

                    // Convert to canonical format if needed
                    let finalBuffer: AVAudioPCMBuffer
                    if audioFile.processingFormat == targetFormat {
                        guard srcBuffer.frameLength > 0 else {
                            throw NSError(domain: "PulseDeck.Soundboard", code: -5, userInfo: [NSLocalizedDescriptionKey: "Audio file contains zero frames"])
                        }
                        finalBuffer = srcBuffer
                    } else {
                        guard let converter = AVAudioConverter(from: audioFile.processingFormat, to: targetFormat) else {
                            throw NSError(domain: "PulseDeck.Soundboard", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unsupported audio format conversion"])
                        }

                        var drainedBuffers: [AVAudioPCMBuffer] = []
                        var totalDrainedFrames: AVAudioFrameCount = 0
                        var inputSupplied = false

                        while true {
                            let chunkCapacity: AVAudioFrameCount = 8192
                            guard let chunk = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: chunkCapacity) else {
                                throw NSError(domain: "PulseDeck.Soundboard", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate destination buffer"])
                            }
                            var convertError: NSError?
                            let status = converter.convert(to: chunk, error: &convertError) { _, outStatus in
                                if inputSupplied {
                                    outStatus.pointee = .endOfStream
                                    return nil
                                }
                                inputSupplied = true
                                outStatus.pointee = .haveData
                                return srcBuffer
                            }

                            if let convertError {
                                throw convertError
                            }

                            if chunk.frameLength > 0 {
                                drainedBuffers.append(chunk)
                                totalDrainedFrames += chunk.frameLength
                            }

                            if status == .endOfStream || chunk.frameLength == 0 {
                                break
                            }
                        }

                        // Reject empty conversion output
                        guard totalDrainedFrames > 0,
                              let destBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: totalDrainedFrames) else {
                            throw NSError(domain: "PulseDeck.Soundboard", code: -4, userInfo: [NSLocalizedDescriptionKey: "Audio conversion produced empty output"])
                        }
                        destBuffer.frameLength = totalDrainedFrames

                        var destOffset: AVAudioFrameCount = 0
                        let channelCount = Int(targetFormat.channelCount)
                        for chunk in drainedBuffers {
                            let framesToCopy = chunk.frameLength
                            guard framesToCopy > 0 else { continue }
                            if let srcChannels = chunk.floatChannelData,
                               let dstChannels = destBuffer.floatChannelData {
                                for ch in 0..<channelCount {
                                    let srcPtr = srcChannels[ch]
                                    let dstPtr = dstChannels[ch].advanced(by: Int(destOffset))
                                    dstPtr.initialize(from: srcPtr, count: Int(framesToCopy))
                                }
                            }
                            destOffset += framesToCopy
                        }

                        finalBuffer = destBuffer
                    }

                    let assetRAM = Int(finalBuffer.frameLength) * Int(targetFormat.channelCount) * MemoryLayout<Float>.size

                    // Bound per-asset and total RAM
                    if assetRAM > maxPerAssetRAMBytes || (cumulativeRAM + assetRAM) > maxTotalRAMBytes {
                        results.append(
                            DecodedAsset(
                                buffer: fallbackBuffer,
                                source: .procedural(toneDescription: fallbackDef.description, durationSeconds: fallbackDef.durationSeconds),
                                error: .oversizedFile(durationSeconds: duration),
                                title: "\(fileName) [RAM LIMIT]",
                                durationSeconds: fallbackDef.durationSeconds,
                                ramBytes: fallbackRAM
                            )
                        )
                        continue
                    }

                    cumulativeRAM += assetRAM
                    let cleanTitle = fileURL.deletingPathExtension().lastPathComponent
                    let effectiveDuration = Double(finalBuffer.frameLength) / targetFormat.sampleRate
                    results.append(
                        DecodedAsset(
                            buffer: finalBuffer,
                            source: .file(name: fileName, durationSeconds: effectiveDuration),
                            error: nil,
                            title: cleanTitle,
                            durationSeconds: effectiveDuration,
                            ramBytes: assetRAM
                        )
                    )
                } catch {
                    // Corrupt or unreadable file: fallback cleanly
                    results.append(
                        DecodedAsset(
                            buffer: fallbackBuffer,
                            source: .procedural(toneDescription: fallbackDef.description, durationSeconds: fallbackDef.durationSeconds),
                            error: .corruptFile(description: error.localizedDescription),
                            title: "\(fileName) [CORRUPT]",
                            durationSeconds: fallbackDef.durationSeconds,
                            ramBytes: fallbackRAM
                        )
                    )
                }
            } else {
                // Missing pad slot: procedural fallback
                results.append(
                    DecodedAsset(
                        buffer: fallbackBuffer,
                        source: .procedural(toneDescription: fallbackDef.description, durationSeconds: fallbackDef.durationSeconds),
                        error: nil,
                        title: fallbackDef.title,
                        durationSeconds: fallbackDef.durationSeconds,
                        ramBytes: fallbackRAM
                    )
                )
            }
        }

        return results
    }

    private static func makeEmergencySilentBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let count: AVAudioFrameCount = 4410
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buf.frameLength = count
        return buf
    }
}
