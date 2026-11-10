import Accelerate
import AVFoundation
import Foundation

public enum MelSpectrogramError: Error, LocalizedError, Equatable {
    case unreadableAudio(String)
    case invalidAudioFormat(String)
    case unsupportedDuration
    case missingFilterbankResource
    case fftSetupFailed
    case bufferAllocationFailed

    public var errorDescription: String? {
        switch self {
        case .unreadableAudio(let reason): return "Unable to read audio: \(reason)"
        case .invalidAudioFormat(let reason): return "Invalid audio format: \(reason)"
        case .unsupportedDuration: return "Audio duration is empty or unsupported"
        case .missingFilterbankResource: return "Mel filterbank binary resource missing or invalid"
        case .fftSetupFailed: return "vDSP FFT setup initialization failed"
        case .bufferAllocationFailed: return "Audio buffer memory allocation failed"
        }
    }
}

/// Computes log-mel spectrograms matching upstream Beat This! (ISMIR 2024 / CPJKU) specification.
/// Parameters: 22050 Hz mono, 1024-point STFT, Hann periodic window, hop size 441 (50 fps),
/// reflection padding of 512 samples on each boundary, normalized="frame_length" (divided by 32),
/// Slaney 128-bin Mel filterbank, log1p(1000 * mel) compression.
public struct SlaneyMelSpectrogram: Sendable {
    public static let sampleRate: Double = 22050.0
    public static let nFft: Int = 1024
    public static let hopLength: Int = 441
    public static let padLength: Int = 512
    public static let numMels: Int = 128
    public static let numFftBins: Int = 513
    public static let logMultiplier: Float = 1000.0

    private let melFilterbank: [Float]

    public init(melFilterbank: [Float]? = nil) throws {
        if let provided = melFilterbank {
            guard provided.count == Self.numFftBins * Self.numMels else {
                throw MelSpectrogramError.missingFilterbankResource
            }
            self.melFilterbank = provided
        } else {
            guard let resourceURL = Bundle.module.url(forResource: "mel_filterbank_513x128_fp32", withExtension: "bin") else {
                throw MelSpectrogramError.missingFilterbankResource
            }
            let data: Data
            do {
                data = try Data(contentsOf: resourceURL)
            } catch {
                throw MelSpectrogramError.missingFilterbankResource
            }
            guard data.count == Self.numFftBins * Self.numMels * MemoryLayout<Float>.size else {
                throw MelSpectrogramError.missingFilterbankResource
            }
            self.melFilterbank = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
    }

    /// Loads and resamples any audio file at `url` to 22,050 Hz mono Float32 PCM.
    public static func loadAudioSamples(from url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw MelSpectrogramError.unreadableAudio(error.localizedDescription)
        }

        let srcFormat = file.processingFormat
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

        guard srcFormat.sampleRate > 0, srcFormat.channelCount > 0 else {
            throw MelSpectrogramError.invalidAudioFormat("Unsupported sample rate or channel count")
        }

        let srcLength = file.length
        guard srcLength > 0 else {
            throw MelSpectrogramError.unsupportedDuration
        }

        if srcFormat.sampleRate == sampleRate && srcFormat.channelCount == 1 && srcFormat.commonFormat == .pcmFormatFloat32 {
            var samples: [Float] = []
            samples.reserveCapacity(Int(srcLength))
            let chunkCapacity: AVAudioFrameCount = 16384
            guard let buffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: chunkCapacity) else {
                throw MelSpectrogramError.bufferAllocationFailed
            }
            while file.framePosition < srcLength {
                let framesRemaining = AVAudioFrameCount(srcLength - file.framePosition)
                let toRead = min(chunkCapacity, framesRemaining)
                try file.read(into: buffer, frameCount: toRead)
                guard buffer.frameLength > 0, let channelData = buffer.floatChannelData else {
                    break
                }
                samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
            }
            return samples
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else {
            throw MelSpectrogramError.invalidAudioFormat("Cannot create converter for audio format \(srcFormat)")
        }

        let ratio = sampleRate / srcFormat.sampleRate
        let estimatedTargetFrames = AVAudioFrameCount(ceil(Double(srcLength) * ratio)) + 2048
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedTargetFrames) else {
            throw MelSpectrogramError.bufferAllocationFailed
        }

        var conversionError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            let remaining = file.length - file.framePosition
            let readCapacity = min(inNumPackets, AVAudioFrameCount(max(0, remaining)))
            if readCapacity == 0 {
                outStatus.pointee = .endOfStream
                return nil
            }
            guard let inBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: readCapacity) else {
                outStatus.pointee = .noDataNow
                return nil
            }
            do {
                try file.read(into: inBuffer, frameCount: readCapacity)
                outStatus.pointee = .haveData
                return inBuffer
            } catch {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)
        if let conversionError = conversionError {
            throw MelSpectrogramError.unreadableAudio(conversionError.localizedDescription)
        }
        guard status != .error, let channelData = outputBuffer.floatChannelData else {
            throw MelSpectrogramError.unreadableAudio("Conversion failed with status \(status.rawValue)")
        }

        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }

    /// Computes the [T, 128] log-mel spectrogram from 22,050 Hz mono PCM samples.
    public func computeLogMelSpectrogram(samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty else {
            throw MelSpectrogramError.unsupportedDuration
        }

        let pad = Self.padLength
        let L = samples.count

        // Reflection padding: 512 samples on left and right
        var padded = [Float](repeating: 0, count: L + 2 * pad)
        if L > pad {
            for i in 0..<pad {
                padded[i] = samples[pad - i]
            }
            for i in 0..<L {
                padded[pad + i] = samples[i]
            }
            for i in 0..<pad {
                padded[pad + L + i] = samples[L - 2 - i]
            }
        } else {
            for i in 0..<pad {
                let idx = min(max(0, pad - i), L - 1)
                padded[i] = samples[idx]
            }
            for i in 0..<L {
                padded[pad + i] = samples[i]
            }
            for i in 0..<pad {
                let idx = min(max(0, L - 2 - i), L - 1)
                padded[pad + L + i] = samples[idx]
            }
        }

        let nFft = Self.nFft
        let hop = Self.hopLength
        let numFrames = (padded.count - nFft) / hop + 1
        guard numFrames > 0 else {
            throw MelSpectrogramError.unsupportedDuration
        }

        // Periodic Hann window: 0.5 * (1 - cos(2*pi*n / N))
        var window = [Float](repeating: 0, count: nFft)
        for i in 0..<nFft {
            window[i] = Float(0.5 * (1.0 - cos(2.0 * Double.pi * Double(i) / Double(nFft))))
        }

        let log2n = vDSP_Length(10)
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw MelSpectrogramError.fftSetupFailed
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var windowed = [Float](repeating: 0, count: nFft)
        var realp = [Float](repeating: 0, count: nFft / 2)
        var imagp = [Float](repeating: 0, count: nFft / 2)
        var magnitudes = [Float](repeating: 0, count: numFrames * Self.numFftBins)

        let numFftBins = Self.numFftBins
        let halfN = nFft / 2

        realp.withUnsafeMutableBufferPointer { realBuffer in
            imagp.withUnsafeMutableBufferPointer { imagBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)

                for f in 0..<numFrames {
                    let startIdx = f * hop
                    for i in 0..<nFft {
                        windowed[i] = padded[startIdx + i] * window[i]
                    }

                    windowed.withUnsafeBytes { ptr in
                        let floatPtr = ptr.bindMemory(to: DSPComplex.self)
                        vDSP_ctoz(floatPtr.baseAddress!, 2, &split, 1, vDSP_Length(halfN))
                    }

                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                    // vDSP scales by 2, normalized='frame_length' divides by sqrt(1024) = 32. Total scale: 1/64.
                    let scale: Float = 1.0 / 64.0
                    let frameOffset = f * numFftBins

                    // Bin 0 (DC)
                    magnitudes[frameOffset + 0] = abs(realBuffer[0] * scale)

                    // Bins 1..<512
                    for k in 1..<512 {
                        let r = realBuffer[k] * scale
                        let im = imagBuffer[k] * scale
                        magnitudes[frameOffset + k] = sqrt(r * r + im * im)
                    }

                    // Bin 512 (Nyquist)
                    magnitudes[frameOffset + 512] = abs(imagBuffer[0] * scale)
                }
            }
        }

        // Mel projection: [numFrames, 513] * [513, 128] -> [numFrames, 128]
        var melSpec = [Float](repeating: 0, count: numFrames * Self.numMels)
        vDSP_mmul(
            magnitudes, 1,
            melFilterbank, 1,
            &melSpec, 1,
            vDSP_Length(numFrames),
            vDSP_Length(Self.numMels),
            vDSP_Length(Self.numFftBins)
        )

        // Log compression: ln(1.0 + 1000.0 * mel)
        let multiplier = Self.logMultiplier
        for i in 0..<melSpec.count {
            melSpec[i] = log1pf(multiplier * melSpec[i])
        }

        return melSpec
    }
}
