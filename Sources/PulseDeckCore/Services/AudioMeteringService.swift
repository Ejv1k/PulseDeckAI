import AVFoundation
import PulseDeckAtomics

/// Immutable output measurement. Spectrum contains linear amplitudes for bins `0..<fftSize/2`.
/// Bin `i` represents `Double(i) * sampleRate / Double(fftSize)` hertz. `hostTime` uses
/// `mach_absolute_time` ticks captured by the render callback.
public struct AudioMeterSnapshot: Sendable, Equatable {
    public let rms: Float
    public let peak: Float
    public let spectrum: [Float]
    public let sampleRate: Double
    public let hostTime: UInt64
    public let frameCount: UInt32
    public let fftSize: UInt32

    fileprivate init(sample: PDMeterSample) {
        rms = sample.rms
        peak = sample.peak
        spectrum = withUnsafeBytes(of: sample.spectrum) { bytes in
            Array(bytes.bindMemory(to: Float.self))
        }
        sampleRate = sample.sample_rate
        hostTime = sample.host_time
        frameCount = sample.frame_count
        fftSize = sample.fft_size
    }
}

public enum AudioMeteringError: Error, Sendable {
    case processingResourcesUnavailable
    case lockFreeAtomicsUnavailable
    case invalidOutputFormat(role: AudioEngineRole, sampleRate: Double, channelCount: UInt32)
    case tapAlreadyInstalled(role: AudioEngineRole)
}

/// Queue-confined dual-output meter tap lifecycle. Every public method synchronously enters the
/// coordinator monitor's control queue. Each engine tap is its sole producer; callers of
/// `drainLatest(for:)` share the sole consumer and must not drain concurrently from separate queues.
/// The tap captures only a stable C ring pointer. Its processing performs no allocation, locking,
/// actor hop, I/O, or Swift object lifetime operation. Stop pauses running engines on the control
/// queue before removing taps and freeing their storage, then restores their prior running state.
public final class AudioMeteringService: @unchecked Sendable {
    private let coordinator: AudioEngineCoordinator
    private var masterRing: OpaquePointer?
    private var cueRing: OpaquePointer?
    private var masterTapInstalled = false
    private var cueTapInstalled = false

    public init(coordinator: AudioEngineCoordinator) {
        self.coordinator = coordinator
    }

    deinit {
        stop()
    }

    /// Allocates FFT/ring storage and installs silent output-only taps. Does not start engines or playback.
    public func start() throws {
        try coordinator.monitor.performOnControlQueue {
            guard !self.masterTapInstalled, !self.cueTapInstalled else {
                throw AudioMeteringError.tapAlreadyInstalled(role: self.masterTapInstalled ? .master : .cue)
            }

            let masterFormat = self.coordinator.masterAudioEngine.subMixer.outputFormat(forBus: 0)
            let cueFormat = self.coordinator.cueAudioEngine.subMixer.outputFormat(forBus: 0)
            try Self.validate(masterFormat, role: .master)
            try Self.validate(cueFormat, role: .cue)

            guard let masterRing = pd_meter_ring_create(), let cueRing = pd_meter_ring_create() else {
                if let masterRing { pd_meter_ring_destroy(masterRing) }
                throw AudioMeteringError.processingResourcesUnavailable
            }
            guard pd_meter_ring_is_lock_free(masterRing), pd_meter_ring_is_lock_free(cueRing) else {
                pd_meter_ring_destroy(masterRing)
                pd_meter_ring_destroy(cueRing)
                throw AudioMeteringError.lockFreeAtomicsUnavailable
            }

            self.masterRing = masterRing
            self.cueRing = cueRing
            self.installTap(on: self.coordinator.masterAudioEngine.subMixer, ring: masterRing)
            self.masterTapInstalled = true
            self.installTap(on: self.coordinator.cueAudioEngine.subMixer, ring: cueRing)
            self.cueTapInstalled = true
        }
    }

    /// Removes taps after callbacks quiesce. Previously running engines resume on the same queue.
    public func stop() {
        coordinator.monitor.performOnControlQueue {
            let master = self.coordinator.masterAudioEngine.rawEngine
            let cue = self.coordinator.cueAudioEngine.rawEngine
            let masterWasRunning = master.isRunning
            let cueWasRunning = cue.isRunning
            if masterWasRunning { master.pause() }
            if cueWasRunning { cue.pause() }

            if self.masterTapInstalled {
                self.coordinator.masterAudioEngine.subMixer.removeTap(onBus: 0)
                self.masterTapInstalled = false
            }
            if self.cueTapInstalled {
                self.coordinator.cueAudioEngine.subMixer.removeTap(onBus: 0)
                self.cueTapInstalled = false
            }

            if let ring = self.masterRing { pd_meter_ring_destroy(ring) }
            if let ring = self.cueRing { pd_meter_ring_destroy(ring) }
            self.masterRing = nil
            self.cueRing = nil

            self.resume(master, ifPreviouslyRunning: masterWasRunning, role: .master)
            self.resume(cue, ifPreviouslyRunning: cueWasRunning, role: .cue)
        }
    }

    /// Drains all queued records and returns newest snapshot. Spectrum array allocation stays off render thread.
    public func drainLatest(for role: AudioEngineRole) -> AudioMeterSnapshot? {
        coordinator.monitor.performOnControlQueue {
            let ring = role == .master ? self.masterRing : self.cueRing
            guard let ring else { return nil }
            var sample = PDMeterSample()
            var hasSample = false
            while pd_meter_ring_pop(ring, &sample) {
                hasSample = true
            }
            return hasSample ? AudioMeterSnapshot(sample: sample) : nil
        }
    }

    private func installTap(on mixer: AVAudioMixerNode, ring: OpaquePointer) {
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            let channelCount = buffer.format.channelCount
            guard let channels = buffer.floatChannelData else {
                _ = pd_meter_ring_push_audio(ring, nil, nil, channelCount, buffer.frameLength,
                                             buffer.format.sampleRate, mach_absolute_time())
                return
            }
            guard channelCount == 1 || channelCount == 2 else {
                _ = pd_meter_ring_push_audio(ring, nil, nil, channelCount, buffer.frameLength,
                                             buffer.format.sampleRate, mach_absolute_time())
                return
            }
            _ = pd_meter_ring_push_audio(ring, channels[0], channelCount == 2 ? channels[1] : nil,
                                         channelCount, buffer.frameLength, buffer.format.sampleRate,
                                         mach_absolute_time())
        }
    }

    private func resume(_ engine: AVAudioEngine, ifPreviouslyRunning wasRunning: Bool, role: AudioEngineRole) {
        guard wasRunning else { return }
        do {
            try engine.start()
        } catch {
            coordinator.monitor.setIntendedRunningState(for: engine, running: false)
            coordinator.monitor.reportError(.osStatus(OSStatus(-1), operation: "meteringStopResume_\(role.rawValue)"))
        }
    }

    private static func validate(_ format: AVAudioFormat, role: AudioEngineRole) throws {
        let rate = format.sampleRate
        let channels = format.channelCount
        guard format.commonFormat == .pcmFormatFloat32,
              rate.isFinite, (8000.0...192000.0).contains(rate),
              channels == 1 || channels == 2 else {
            throw AudioMeteringError.invalidOutputFormat(role: role, sampleRate: rate, channelCount: channels)
        }
    }
}
