import Foundation
import SwiftUI
import Combine
import PulseDeckCore

/// Distinct cue types conforming to the Phase 2/3 4-cue system.
public enum CueType: String, CaseIterable, Identifiable, Sendable {
    case startTrim
    case vocalEntry
    case mixOut
    case endTrim

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .startTrim: return "START TRIM"
        case .vocalEntry: return "VOCAL ENTRY"
        case .mixOut: return "MIX OUT"
        case .endTrim: return "END TRIM"
        }
    }

    public var shortLabel: String {
        switch self {
        case .startTrim: return "IN"
        case .vocalEntry: return "VOC"
        case .mixOut: return "OUT"
        case .endTrim: return "END"
        }
    }

    public var color: Color {
        switch self {
        case .startTrim: return Color(red: 0.00, green: 0.90, blue: 0.46) // Emerald Green (DJTheme.master)
        case .vocalEntry: return Color(red: 0.00, green: 0.90, blue: 1.00) // Electric Cyan (DJTheme.deckA)
        case .mixOut: return Color(red: 1.00, green: 0.43, blue: 0.00) // Neon Orange (DJTheme.deckB)
        case .endTrim: return Color(red: 1.00, green: 0.25, blue: 0.35) // Coral Crimson
        }
    }
}

/// Pure math coordinate mapper for converting between track timestamps and screen coordinates,
/// computing visible bin ranges, and enforcing cue ordering and bounds.
public struct WaveformCoordinateMapper: Sendable, Equatable {
    public let duration: Double
    public let zoomLevel: Double
    public let scrollOffsetSeconds: Double
    public let totalBins: Int

    public init(duration: Double, zoomLevel: Double, scrollOffsetSeconds: Double, totalBins: Int) {
        self.duration = max(0.0, duration.isFinite ? duration : 0.0)
        self.zoomLevel = max(1.0, min(32.0, zoomLevel.isFinite ? zoomLevel : 1.0))
        let visibleDuration = self.duration / self.zoomLevel
        let maxScroll = max(0.0, self.duration - visibleDuration)
        self.scrollOffsetSeconds = max(0.0, min(maxScroll, scrollOffsetSeconds.isFinite ? scrollOffsetSeconds : 0.0))
        self.totalBins = max(0, totalBins)
    }

    public var visibleDuration: Double {
        duration / zoomLevel
    }

    public var visibleStartTime: Double {
        scrollOffsetSeconds
    }

    public var visibleEndTime: Double {
        min(duration, scrollOffsetSeconds + visibleDuration)
    }

    public func timeToX(time: Double, viewWidth: CGFloat) -> CGFloat {
        guard duration > 0, visibleDuration > 0, viewWidth > 0 else { return 0 }
        let clampedTime = max(0.0, min(duration, time))
        let relative = (clampedTime - visibleStartTime) / visibleDuration
        return CGFloat(relative) * viewWidth
    }

    public func xToTime(x: CGFloat, viewWidth: CGFloat) -> Double {
        guard duration > 0, visibleDuration > 0, viewWidth > 0 else { return 0 }
        let fraction = Double(x / viewWidth)
        let time = visibleStartTime + fraction * visibleDuration
        return max(0.0, min(duration, time))
    }

    public func visibleBinRange() -> ClosedRange<Int>? {
        guard totalBins > 0, duration > 0 else { return nil }
        let startFraction = max(0.0, min(1.0, visibleStartTime / duration))
        let endFraction = max(0.0, min(1.0, visibleEndTime / duration))
        let startBin = min(totalBins - 1, max(0, Int(floor(startFraction * Double(totalBins)))))
        let endBin = min(totalBins - 1, max(startBin, Int(ceil(endFraction * Double(totalBins)))))
        return startBin...endBin
    }

    /// Clamps an edited cue timestamp against duration and its neighboring cues to prevent inversion.
    public func validateAndClamp(
        cue: CueType,
        newTime: Double,
        currentCues: CueMarkers
    ) -> CueMarkers {
        guard duration > 0 else { return currentCues }
        let clampedTime = max(0.0, min(duration, newTime))

        var updated = currentCues
        switch cue {
        case .startTrim:
            // 0.0 <= startTrim <= vocalEntry
            updated.startTrimCue = min(clampedTime, currentCues.vocalEntryCue)
        case .vocalEntry:
            // startTrim <= vocalEntry <= mixOut
            updated.vocalEntryCue = max(currentCues.startTrimCue, min(clampedTime, currentCues.mixOutCue))
        case .mixOut:
            // vocalEntry <= mixOut <= endTrim
            updated.mixOutCue = max(currentCues.vocalEntryCue, min(clampedTime, currentCues.endTrimCue))
        case .endTrim:
            // mixOut <= endTrim <= duration
            updated.endTrimCue = max(currentCues.mixOutCue, min(clampedTime, duration))
        }

        // Defensively ensure final ordering and bounds
        return updated.clamped(toDuration: duration)
    }
}

/// Errors thrown during WaveformEditorModel operations.
public enum WaveformEditorError: LocalizedError, Equatable {
    case invalidExistingCache(String)

    public var errorDescription: String? {
        switch self {
        case .invalidExistingCache(let fileName):
            return "Existing cache file '\(fileName)' failed schema validation or is unreadable. Aborting save to preserve file."
        }
    }
}

/// Observable state model for the Phase 3A interactive Waveform Editor.
/// Owns track waveform data, coordinate mappings, zoom/scroll states, cue marker manipulations,
/// AI trim bypass state, and atomic cache persistence.
@MainActor
public final class WaveformEditorModel: ObservableObject {
    @Published public private(set) var currentTrack: TrackCacheEntry?
    @Published public private(set) var cues: CueMarkers
    @Published public private(set) var aiTrimBypass: Bool = false
    @Published public private(set) var manualOverrides: ManualOverrides = ManualOverrides()
    @Published public var zoomLevel: Double = 1.0
    @Published public var scrollOffsetSeconds: Double = 0.0
    @Published public var playheadPosition: Double = 0.0
    @Published public var selectedCue: CueType? = nil
    @Published public private(set) var activeDraggingCue: CueType? = nil
    @Published public private(set) var isSaving: Bool = false
    @Published public var statusMessage: String = "Waveform Editor Ready"
    @Published public var errorMessage: String? = nil

    public private(set) var libraryRootURL: URL
    private var inFlightSaveTask: Task<Void, Never>?

    public init(libraryRootURL: URL) {
        self.libraryRootURL = libraryRootURL
        self.cues = CueMarkers(startTrimCue: 0.0, vocalEntryCue: 0.0, mixOutCue: 0.0, endTrimCue: 0.0)
    }

    public func updateLibraryRoot(_ url: URL) {
        self.libraryRootURL = url
    }

    /// Loads a real cached track analysis entry into the editor.
    public func loadTrack(_ entry: TrackCacheEntry) {
        self.currentTrack = entry
        self.cues = entry.cueMarkers.clamped(toDuration: entry.duration)
        self.aiTrimBypass = entry.aiTrimBypass
        self.manualOverrides = entry.manualOverrides
        self.zoomLevel = 1.0
        self.scrollOffsetSeconds = 0.0
        self.playheadPosition = self.cues.startTrimCue
        self.selectedCue = nil
        self.activeDraggingCue = nil
        self.errorMessage = nil
        self.statusMessage = "Loaded \(entry.relativePath) (BPM: \(String(format: "%.1f", entry.bpm)), Key: \(entry.musicalKey))"
    }

    /// Returns the coordinate mapper for the current view state.
    public var coordinateMapper: WaveformCoordinateMapper {
        let duration = currentTrack?.duration ?? 0.0
        let totalBins = currentTrack?.waveformMetadata.peakValues.count ?? 0
        return WaveformCoordinateMapper(
            duration: duration,
            zoomLevel: zoomLevel,
            scrollOffsetSeconds: scrollOffsetSeconds,
            totalBins: totalBins
        )
    }

    public func timeToX(time: Double, viewWidth: CGFloat) -> CGFloat {
        coordinateMapper.timeToX(time: time, viewWidth: viewWidth)
    }

    public func xToTime(x: CGFloat, viewWidth: CGFloat) -> Double {
        coordinateMapper.xToTime(x: x, viewWidth: viewWidth)
    }

    public func visibleBinRange() -> ClosedRange<Int>? {
        coordinateMapper.visibleBinRange()
    }

    public func cueTime(for cue: CueType) -> Double {
        switch cue {
        case .startTrim: return cues.startTrimCue
        case .vocalEntry: return cues.vocalEntryCue
        case .mixOut: return cues.mixOutCue
        case .endTrim: return cues.endTrimCue
        }
    }

    // MARK: - Dragging and Cue Manipulation

    public func beginDrag(cue: CueType) {
        self.activeDraggingCue = cue
        self.selectedCue = cue
    }

    public func updateDrag(cue: CueType, toTime: Double) {
        guard let track = currentTrack else { return }
        let mapper = WaveformCoordinateMapper(
            duration: track.duration,
            zoomLevel: zoomLevel,
            scrollOffsetSeconds: scrollOffsetSeconds,
            totalBins: track.waveformMetadata.peakValues.count
        )
        self.cues = mapper.validateAndClamp(cue: cue, newTime: toTime, currentCues: self.cues)
    }

    public func endDrag(cue: CueType) {
        guard activeDraggingCue == cue else { return }
        self.activeDraggingCue = nil
        commitCueChanges(reason: "Dragged \(cue.displayName)")
    }

    /// Sets a cue to a specific timestamp (e.g. from hotkeys I/O or scrubber).
    public func setCue(_ cue: CueType, toTime: Double) {
        guard let track = currentTrack else { return }
        let mapper = WaveformCoordinateMapper(
            duration: track.duration,
            zoomLevel: zoomLevel,
            scrollOffsetSeconds: scrollOffsetSeconds,
            totalBins: track.waveformMetadata.peakValues.count
        )
        self.cues = mapper.validateAndClamp(cue: cue, newTime: toTime, currentCues: self.cues)
        self.selectedCue = cue
        commitCueChanges(reason: "Set \(cue.displayName) to \(String(format: "%.3f", toTime))s")
    }

    /// Nudges the currently selected or specified cue by a small delta in seconds.
    public func nudgeCue(_ cue: CueType, deltaSeconds: Double) {
        let currentTime = cueTime(for: cue)
        setCue(cue, toTime: currentTime + deltaSeconds)
    }

    /// Toggles the AI trim bypass state and atomically persists to cache.
    public func toggleAITrimBypass() {
        guard currentTrack != nil else { return }
        self.aiTrimBypass.toggle()

        var overrides = self.manualOverrides
        overrides.isManual = true
        if !overrides.overriddenFields.contains("aiTrimBypass") {
            overrides.overriddenFields.append("aiTrimBypass")
        }
        overrides.updatedAt = ISO8601DateFormatter().string(from: Date())
        overrides.author = "DJ (PulseDeck Manual Editor)"
        self.manualOverrides = overrides

        if var track = currentTrack {
            track.aiTrimBypass = self.aiTrimBypass
            track.manualOverrides = overrides
            self.currentTrack = track
        }

        self.statusMessage = "AI Trim \(self.aiTrimBypass ? "Bypassed" : "Active")"
        persistCurrentTrackToCache()
    }

    // MARK: - Zoom and Scroll

    public func setZoom(_ newZoom: Double, focusTime: Double? = nil) {
        guard let track = currentTrack, track.duration > 0 else {
            self.zoomLevel = 1.0
            self.scrollOffsetSeconds = 0.0
            return
        }

        let clampedZoom = max(1.0, min(32.0, newZoom))
        let centerTime = focusTime ?? (scrollOffsetSeconds + (track.duration / zoomLevel) / 2.0)
        let newVisibleDuration = track.duration / clampedZoom

        self.zoomLevel = clampedZoom
        let newOffset = centerTime - (newVisibleDuration / 2.0)
        let maxOffset = max(0.0, track.duration - newVisibleDuration)
        self.scrollOffsetSeconds = max(0.0, min(maxOffset, newOffset))
    }

    public func zoomIn() {
        setZoom(zoomLevel * 1.5, focusTime: playheadPosition)
    }

    public func zoomOut() {
        setZoom(zoomLevel / 1.5, focusTime: playheadPosition)
    }

    public func resetZoom() {
        self.zoomLevel = 1.0
        self.scrollOffsetSeconds = 0.0
    }

    public func scrollTo(offsetSeconds: Double) {
        guard let track = currentTrack else { return }
        let visibleDuration = track.duration / zoomLevel
        let maxOffset = max(0.0, track.duration - visibleDuration)
        self.scrollOffsetSeconds = max(0.0, min(maxOffset, offsetSeconds))
    }

    public func seekPlayhead(to time: Double) {
        guard let track = currentTrack else { return }
        self.playheadPosition = max(0.0, min(track.duration, time))
    }

    // MARK: - Atomic Persistence

    private func commitCueChanges(reason: String) {
        guard var track = currentTrack else { return }

        // Update track's cues
        track.cueMarkers = self.cues

        // Update provenance metadata
        var overrides = self.manualOverrides
        overrides.isManual = true
        if !overrides.overriddenFields.contains("cueMarkers") {
            overrides.overriddenFields.append("cueMarkers")
        }
        overrides.updatedAt = ISO8601DateFormatter().string(from: Date())
        overrides.author = "DJ (PulseDeck Manual Editor)"
        self.manualOverrides = overrides
        track.manualOverrides = overrides

        self.currentTrack = track
        self.statusMessage = "\(reason) (Persisting...)"

        persistCurrentTrackToCache()
    }

    private func persistCurrentTrackToCache() {
        guard let track = currentTrack else { return }
        let rootURL = self.libraryRootURL

        self.isSaving = true

        // Cancel previous pending save task if any
        inFlightSaveTask?.cancel()

        inFlightSaveTask = Task { [track, rootURL] in
            let cacheURL = rootURL.appendingPathComponent(PulseDeckCoreConfig.cacheFileName)
            do {
                var cache: PulseDeckLibraryCache
                if FileManager.default.fileExists(atPath: cacheURL.path) {
                    guard let loaded = CachePersistence.load(from: cacheURL) else {
                        throw WaveformEditorError.invalidExistingCache(cacheURL.lastPathComponent)
                    }
                    cache = loaded
                } else {
                    cache = PulseDeckLibraryCache(libraryRoot: rootURL.lastPathComponent)
                }

                // Update track in cache
                cache.tracks[track.relativePath] = track
                cache.generatedAt = ISO8601DateFormatter().string(from: Date())

                // Atomic save with POSIX flush and schema validation
                try CachePersistence.saveAtomic(cache: cache, to: cacheURL)

                await MainActor.run {
                    self.isSaving = false
                    self.errorMessage = nil
                    self.statusMessage = "Saved cues to .pulsedeck_ai_cache.json"
                }
            } catch {
                await MainActor.run {
                    self.isSaving = false
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = "Save Error"
                }
            }
        }
    }
}
