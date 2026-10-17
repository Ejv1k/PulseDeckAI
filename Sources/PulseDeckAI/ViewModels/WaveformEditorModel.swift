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

/// Asynchronous persistence boundary shared by the editor and its production background actor.
public protocol WaveformTrackPersisting: Sendable {
    func persistTrack(_ track: TrackCacheEntry, libraryRootURL: URL) async throws -> PulseDeckLibraryCache
}

/// Serial background executor actor for atomic cache persistence, ensuring all decoding,
/// validation, encoding, and disk flush operations run completely off MainActor while preserving
/// save request ordering.
public actor WaveformPersistenceActor: WaveformTrackPersisting {
    public init() {}

    public func persistTrack(
        _ track: TrackCacheEntry,
        libraryRootURL: URL
    ) throws -> PulseDeckLibraryCache {
        let cacheURL = libraryRootURL.appendingPathComponent(PulseDeckCoreConfig.cacheFileName)
        var cache: PulseDeckLibraryCache
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            guard let loaded = CachePersistence.load(from: cacheURL) else {
                throw WaveformEditorError.invalidExistingCache(cacheURL.lastPathComponent)
            }
            cache = loaded
        } else {
            cache = PulseDeckLibraryCache(libraryRoot: libraryRootURL.lastPathComponent)
        }

        let entryToSave: TrackCacheEntry
        if let diskEntry = cache.tracks[track.relativePath], track.manualOverrides.isManual {
            entryToSave = mergeManualIntent(track: track, intoDiskEntry: diskEntry)
        } else {
            entryToSave = track
        }

        cache.tracks[track.relativePath] = entryToSave
        cache.generatedAt = ISO8601DateFormatter().string(from: Date())

        try CachePersistence.saveAtomic(cache: cache, to: cacheURL)
        return cache
    }

    private func mergeManualIntent(track: TrackCacheEntry, intoDiskEntry disk: TrackCacheEntry) -> TrackCacheEntry {
        var merged = disk

        var mergedFields = disk.manualOverrides.overriddenFields
        for field in track.manualOverrides.overriddenFields where !mergedFields.contains(field) {
            mergedFields.append(field)
        }

        if track.manualOverrides.overriddenFields.contains("cueMarkers") {
            merged.cueMarkers = track.cueMarkers.clamped(toDuration: disk.duration)
        }
        if track.manualOverrides.overriddenFields.contains("aiTrimBypass") {
            merged.aiTrimBypass = track.aiTrimBypass
        }
        if track.manualOverrides.overriddenFields.contains("bpm") {
            merged.bpm = track.bpm
        }
        if track.manualOverrides.overriddenFields.contains("musicalKey") {
            merged.musicalKey = track.musicalKey
        }

        merged.manualOverrides = ManualOverrides(
            isManual: true,
            overriddenFields: mergedFields,
            updatedAt: track.manualOverrides.updatedAt ?? disk.manualOverrides.updatedAt,
            author: track.manualOverrides.author ?? disk.manualOverrides.author,
            notes: track.manualOverrides.notes ?? disk.manualOverrides.notes
        )

        return merged
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
    public private(set) var interactionRevision: UInt64 = 0

    public var onTrackPersisted: (@MainActor (TrackCacheEntry, PulseDeckLibraryCache, URL) -> Void)?
    public private(set) var libraryRootURL: URL
    private let persistenceActor: any WaveformTrackPersisting
    private var inFlightSaveTask: Task<Void, Never>?
    private struct TrackIdentity: Hashable {
        let root: URL
        let relativePath: String

        init(root: URL, relativePath: String) {
            self.root = root.standardizedFileURL
            self.relativePath = relativePath
        }
    }
    private struct LocalEdit {
        let track: TrackCacheEntry
        let revision: UInt64
        var isPending = true
        var failureMessage: String?
    }
    private var localEdits: [TrackIdentity: LocalEdit] = [:]
    private var nextRevision: UInt64 = 0
    private var pendingSaveCount = 0

    public var hasActiveDrag: Bool {
        activeDraggingCue != nil
    }

    public func hasDirtyEdits(for relativePath: String, libraryRootURL: URL) -> Bool {
        let identity = TrackIdentity(root: libraryRootURL, relativePath: relativePath)
        guard let local = localEdits[identity] else { return false }
        return local.isPending || local.failureMessage != nil
    }

    public func hasActiveInteraction(since revision: UInt64, relativePath: String, libraryRootURL: URL) -> Bool {
        if hasActiveDrag { return true }
        if interactionRevision != revision { return true }
        if hasDirtyEdits(for: relativePath, libraryRootURL: libraryRootURL) { return true }
        return false
    }

    public init(libraryRootURL: URL, persistence: any WaveformTrackPersisting = WaveformPersistenceActor()) {
        self.libraryRootURL = libraryRootURL
        self.persistenceActor = persistence
        self.cues = CueMarkers(startTrimCue: 0.0, vocalEntryCue: 0.0, mixOutCue: 0.0, endTrimCue: 0.0)
    }

    public func updateLibraryRoot(_ url: URL) {
        if libraryRootURL.standardizedFileURL != url.standardizedFileURL {
            finishActiveDrag()
            clearTrack()
        }
        self.libraryRootURL = url
    }

    /// Local manual revisions remain authoritative for this editing session, including failed or pending saves.
    /// Fresh analysis metadata can still be adopted without replacing the DJ's latest manual fields.
    func entryForSelection(relativePath: String, cache: PulseDeckLibraryCache?, libraryRootURL: URL) -> TrackCacheEntry? {
        let persisted = cache?.tracks[relativePath]
        guard let local = localEdits[TrackIdentity(root: libraryRootURL, relativePath: relativePath)] else {
            return persisted
        }
        guard local.isPending || local.failureMessage != nil else {
            return persisted
        }
        return persisted.map { local.track.mergingPreservingOverrides(with: $0) } ?? local.track
    }

    func applyingLocalEdits(to cache: PulseDeckLibraryCache, libraryRootURL: URL) -> PulseDeckLibraryCache {
        var updated = cache
        for (identity, local) in localEdits where identity.root == libraryRootURL.standardizedFileURL {
            guard local.isPending || local.failureMessage != nil else { continue }
            updated.tracks[identity.relativePath] = updated.tracks[identity.relativePath].map {
                local.track.mergingPreservingOverrides(with: $0)
            } ?? local.track
        }
        return updated
    }

    func finishActiveDrag() {
        if let cue = activeDraggingCue { endDrag(cue: cue) }
    }

    func clearTrack() {
        currentTrack = nil
        cues = CueMarkers(startTrimCue: 0, vocalEntryCue: 0, mixOutCue: 0, endTrimCue: 0)
        aiTrimBypass = false
        manualOverrides = ManualOverrides()
        selectedCue = nil
        activeDraggingCue = nil
        errorMessage = nil
        statusMessage = "Waveform Editor Ready"
        playheadPosition = 0
        zoomLevel = 1
        scrollOffsetSeconds = 0
    }

    /// Waits for saves enqueued before this call; the UI remains responsive while persistence suspends.
    func waitForPendingSaves() async {
        await inFlightSaveTask?.value
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
        let local = localEdits[TrackIdentity(root: libraryRootURL, relativePath: entry.relativePath)]
        self.errorMessage = local?.failureMessage
        if local?.failureMessage != nil {
            self.statusMessage = "Unsaved cue changes"
        } else if local?.isPending == true {
            self.statusMessage = "Loaded \(entry.relativePath) (Persisting...)"
        } else {
            self.statusMessage = "Loaded \(entry.relativePath) (BPM: \(String(format: "%.1f", entry.bpm)), Key: \(entry.musicalKey))"
        }
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
        self.interactionRevision &+= 1
        self.activeDraggingCue = cue
        self.selectedCue = cue
    }

    public func updateDrag(cue: CueType, toTime: Double) {
        self.interactionRevision &+= 1
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
        self.interactionRevision &+= 1
        guard activeDraggingCue == cue else { return }
        self.activeDraggingCue = nil
        commitCueChanges(reason: "Dragged \(cue.displayName)")
    }

    /// Sets a cue to a specific timestamp (e.g. from hotkeys I/O or scrubber).
    public func setCue(_ cue: CueType, toTime: Double) {
        self.interactionRevision &+= 1
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
        self.interactionRevision &+= 1
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
        let actor = self.persistenceActor
        let identity = TrackIdentity(root: rootURL, relativePath: track.relativePath)
        nextRevision &+= 1
        let revision = nextRevision
        localEdits[identity] = LocalEdit(track: track, revision: revision)
        pendingSaveCount += 1
        self.isSaving = true
        let previousSave = inFlightSaveTask

        // Chain every snapshot in submission order. Cancellation must never discard another track's commit.
        inFlightSaveTask = Task { [weak self, track, rootURL, actor] in
            await previousSave?.value
            do {
                let updatedCache = try await actor.persistTrack(track, libraryRootURL: rootURL)
                self?.completeSave(track: track, rootURL: rootURL, identity: identity,
                                   revision: revision, result: .success(updatedCache))
            } catch {
                self?.completeSave(track: track, rootURL: rootURL, identity: identity,
                                   revision: revision, result: .failure(error))
            }
        }
    }

    private func completeSave(track: TrackCacheEntry, rootURL: URL, identity: TrackIdentity,
                              revision: UInt64, result: Result<PulseDeckLibraryCache, any Error>) {
        pendingSaveCount -= 1
        isSaving = pendingSaveCount > 0
        let isLatestRevisionForTrack = localEdits[identity]?.revision == revision
        if isLatestRevisionForTrack {
            switch result {
            case .success:
                localEdits.removeValue(forKey: identity)
            case .failure(let error):
                localEdits[identity]?.isPending = false
                localEdits[identity]?.failureMessage = error.localizedDescription
            }
        }
        if case .success(let cache) = result {
            let savedTrack = cache.tracks[identity.relativePath] ?? track
            onTrackPersisted?(savedTrack, cache, rootURL)
        }
        // Earlier completions may update the shared cache, but cannot overwrite a newer edit's UI status.
        guard currentTrack?.relativePath == identity.relativePath,
              libraryRootURL.standardizedFileURL == identity.root,
              isLatestRevisionForTrack else { return }
        switch result {
        case .success(let cache):
            errorMessage = nil
            statusMessage = "Saved cues to .pulsedeck_ai_cache.json"
            if let savedTrack = cache.tracks[identity.relativePath] {
                self.currentTrack = savedTrack
                self.manualOverrides = savedTrack.manualOverrides
                self.cues = savedTrack.cueMarkers
                self.aiTrimBypass = savedTrack.aiTrimBypass
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
            statusMessage = "Save Error"
        }
    }
}
