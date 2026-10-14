import Foundation

/// Architectural identifier for the primary deck channels.
public enum DeckIdentifier: String, Sendable, CaseIterable {
    case deckA = "Deck A"
    case deckB = "Deck B"
}

/// Identifiers for the two independent output engines.
public enum AudioEngineRole: String, Sendable, CaseIterable {
    case master = "Master Output Engine"
    case cue = "Cue (Headphones) Output Engine"
}

/// Descriptor for a CoreAudio physical output device.
public struct AudioDeviceDescriptor: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let manufacturer: String
    public let outputChannelCount: Int
    public let sampleRate: Double
    public let isDefault: Bool
    public let isBluetooth: Bool

    public init(
        id: String,
        name: String,
        manufacturer: String,
        outputChannelCount: Int,
        sampleRate: Double,
        isDefault: Bool,
        isBluetooth: Bool = false
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.outputChannelCount = outputChannelCount
        self.sampleRate = sampleRate
        self.isDefault = isDefault
        self.isBluetooth = isBluetooth
    }
}

/// Three-band equalizer frequency bands and gain parameters.
public struct EQ3BandParameters: Sendable, Equatable {
    /// Low shelf gain in dB (-24.0 dB to +6.0 dB, 0.0 dB unity, cutoff ~250 Hz).
    public var lowGainDB: Float

    /// Mid parametric peaking gain in dB (-24.0 dB to +6.0 dB, 0.0 dB unity, center ~1.2 kHz, Q ~1.0).
    public var midGainDB: Float

    /// High shelf gain in dB (-24.0 dB to +6.0 dB, 0.0 dB unity, cutoff ~3.5 kHz).
    public var highGainDB: Float

    public init(lowGainDB: Float = 0.0, midGainDB: Float = 0.0, highGainDB: Float = 0.0) {
        self.lowGainDB = lowGainDB
        self.midGainDB = midGainDB
        self.highGainDB = highGainDB
    }
}

/// Resonant filter parameters (bipolar sweep: -1.0 LowPass to +1.0 HighPass, 0.0 Bypass).
public struct ResonantFilterParameters: Sendable, Equatable {
    /// Bipolar sweep value from -1.0 (Low-Pass Filter) to +1.0 (High-Pass Filter). 0.0 is neutral/bypass.
    public var sweep: Float

    /// Resonance Q factor (0.5 to 5.0, default 1.0).
    public var resonance: Float

    public init(sweep: Float = 0.0, resonance: Float = 1.0) {
        self.sweep = sweep
        self.resonance = resonance
    }
}

/// Time-pitch / Key-lock parameters for tempo manipulation without pitch shifting.
public struct TimePitchParameters: Sendable, Equatable {
    /// Playback rate multiplier (e.g. 0.92 to 1.08 for +/- 8% pitch range, 1.0 neutral).
    public var rate: Float

    /// Pitch shift in cents (-2400 to +2400 cents, 0.0 neutral).
    public var pitchCents: Float

    /// When true, pitch is locked to original musical key regardless of tempo changes.
    public var keyLockEnabled: Bool

    public init(rate: Float = 1.0, pitchCents: Float = 0.0, keyLockEnabled: Bool = true) {
        self.rate = rate
        self.pitchCents = pitchCents
        self.keyLockEnabled = keyLockEnabled
    }
}

/// Mathematical model for Master/Cue latency alignment within [-300ms, +300ms].
///
/// ## Physical Latency Constraint
/// Negative physical latency cannot exist in real physical systems: an audio output device
/// cannot render audio into the physical world before the audio buffer has been produced.
///
/// Therefore, latency offset `offsetMs = t_master - t_cue` is strictly implemented by
/// injecting a positive buffer delay into whichever audio path is ahead:
/// - If `offsetMs > 0` (Master is lagging behind Cue, e.g. +150ms due to wireless/HDMI/DSP delays):
///   We inject `150ms` of delay into the **Cue path**, delaying headphones so both sync.
/// - If `offsetMs < 0` (Cue is lagging behind Master, e.g. -120ms due to Bluetooth headphones):
///   We inject `120ms` of delay into the **Master path**, delaying FOH output so headphones sync.
/// - If `offsetMs == 0`, both paths operate at zero added delay.
public struct LatencyCompensation: Sendable, Equatable {
    public static let minOffsetMs: Double = -300.0
    public static let maxOffsetMs: Double = 300.0

    /// Relative offset in milliseconds: positive means Master lags Cue; negative means Cue lags Master.
    public let offsetMs: Double

    public init(offsetMs: Double) {
        self.offsetMs = min(max(offsetMs, Self.minOffsetMs), Self.maxOffsetMs)
    }

    /// Calculated delay in milliseconds to add to the Master audio path.
    public var masterDelayMs: Double {
        return offsetMs < 0 ? -offsetMs : 0.0
    }

    /// Calculated delay in milliseconds to add to the Cue (headphones) audio path.
    public var cueDelayMs: Double {
        return offsetMs > 0 ? offsetMs : 0.0
    }
}

/// Bluetooth audio constraints and advisory specification.
public enum BluetoothConstraints: Sendable {
    /// Maximum supported buffer delay compensation limit (ms) within the [-300ms, +300ms] range.
    public static let maxCompensationMs: Double = 300.0

    /// Contract: Bluetooth audio is supported with an explicit advisory notification.
    /// Wireless A2DP connections exhibit variable codec buffer latencies and asynchronous
    /// clock drift between the host system and the Bluetooth peripheral DAC.
    /// For sample-accurate DJ cueing and scratch/beatmatching, wired CoreAudio outputs
    /// (USB DAC or 3.5mm headphone jack) are strongly recommended for live performance.
    public static let warningMessage =
        "Bluetooth audio detected. Variable wireless buffer latency and asynchronous clock drift prevent sample-accurate cueing. Wired CoreAudio output recommended for live performance."
}

// MARK: - Core Audio Architectural Protocols (Phases 1-5 Contract)

/// Architectural contract governing an output-only audio engine.
///
/// ## STRICT SAFETY CONTRACT:
/// 1. Output-Only: Absolutely NEVER call or access `engine.inputNode`. Touching `inputNode`
///    triggers macOS microphone privacy prompts, allocates input buffers, and risks
///    destructive feedback loops in live DJ environments.
/// 2. Audio-Thread Safety:
///    - In the CoreAudio real-time render thread, dynamic memory allocations (`malloc`, `free`, `realloc`),
///      class instantiations, Swift runtime actor hops, and ARC retain/release operations are FORBIDDEN.
///    - Locks, mutexes, condition variables, and semaphores are FORBIDDEN to prevent priority inversion.
///    - File I/O and network operations are FORBIDDEN.
///    - Inter-thread communication must use bounded lock-free ring buffers (SPSC) and atomic variables.
/// 3. Threading Boundaries:
///    - UI code runs on `@MainActor`.
///    - Background DSP and file analysis runs on detached background utility tasks.
///    - Audio graph topology changes are serialized on a dedicated private serial audio queue.
public protocol AudioEngineContract: AnyObject, Sendable {
    /// The specific role of this output engine (Master or Cue).
    var role: AudioEngineRole { get }

    /// Currently assigned CoreAudio output device.
    var currentDevice: AudioDeviceDescriptor? { get }

    /// Total hardware output latency in milliseconds reported by CoreAudio HAL.
    var hardwareLatencyMs: Double { get }

    /// Starts audio engine output rendering.
    func start() throws

    /// Pauses audio engine rendering.
    func pause()

    /// Stops audio engine rendering and resets node states.
    func stop()

    /// Assigns engine output to a specific CoreAudio device ID via HAL.
    func setOutputDevice(id: String) throws
}

/// Architectural contract for a single Deck audio graph (Deck A or Deck B).
///
/// Graph topology:
/// `AVAudioPlayerNode` -> `AVAudioUnitTimePitch` -> `AVAudioUnitEQ` (3-Band) -> Resonant Filter -> Deck Bus Router
public protocol DeckAudioGraphContract: AnyObject, Sendable {
    /// The deck identifier (A or B).
    var deckId: DeckIdentifier { get }

    /// Volume level (0.0 to 1.0, linear or logarithmic taper).
    var volume: Float { get set }

    /// Crossfader assignment (Left/Deck A, Right/Deck B, Thru/Both).
    var crossfaderWeight: Float { get set }

    /// Cue send switch: routes pre-fader audio to the Cue (Headphones) engine.
    var isCueActive: Bool { get set }

    /// 3-Band EQ parameters.
    var eqParameters: EQ3BandParameters { get set }

    /// Dual-pole resonant filter sweep parameters.
    var filterParameters: ResonantFilterParameters { get set }

    /// Time-pitch rate and key lock parameters.
    var timePitchParameters: TimePitchParameters { get set }

    /// Loads an audio file from a validated URL into the deck's playback buffer.
    func loadTrack(url: URL) throws

    /// Initiates playback from current playhead position.
    func play()

    /// Pauses playback.
    func pause()

    /// Seeks playback to a specific timestamp in seconds.
    func seek(to seconds: Double)
}

/// Master coordinator managing both Master and Cue output engines and CoreAudio device enumeration.
public protocol AudioEngineCoordinatorContract: AnyObject, Sendable {
    /// Master FOH output engine.
    var masterEngine: AudioEngineContract { get }

    /// Cue headphones output engine.
    var cueEngine: AudioEngineContract { get }

    /// Deck A audio graph.
    var deckA: DeckAudioGraphContract { get }

    /// Deck B audio graph.
    var deckB: DeckAudioGraphContract { get }

    /// Current latency compensation configuration between Master and Cue.
    var latencyCompensation: LatencyCompensation { get set }

    /// Discovers and enumerates all available physical CoreAudio output devices.
    func enumerateOutputDevices() -> [AudioDeviceDescriptor]

    /// Handles CoreAudio device hotplug or disconnect events safely without audio thread crash.
    func handleDeviceConfigurationChange()
}
