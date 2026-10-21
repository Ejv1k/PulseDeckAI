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
    case conflictingEdit(relativePath: String, field: String)
    case incompatibleCueBounds(relativePath: String, field: String)

    public var errorDescription: String? {
        switch self {
        case .invalidExistingCache(let fileName):
            return "Existing cache file '\(fileName)' failed schema validation or is unreadable. Aborting save to preserve file."
        case .conflictingEdit(let relativePath, let field):
            return "Track '\(relativePath)' has a newer \(field) edit on disk. Aborting save to preserve it."
        case .incompatibleCueBounds(let relativePath, let field):
            return "Track '\(relativePath)' cannot save \(field) at the requested timestamp within current disk cue bounds and duration. Resolve the bounds and retry."
        }
    }
}

/// Identifies the exact editor field changed from its selected value.
public enum WaveformEditIntent: Sendable {
    case cue(CueType, acceptedPreviousValues: Set<Double>)
    case aiTrimBypass(acceptedPreviousValues: Set<Bool>)
}

/// Asynchronous persistence boundary shared by the editor and its production background actor.
public protocol WaveformTrackPersisting: Sendable {
    func persistTrack(_ track: TrackCacheEntry, libraryRootURL: URL, intent: WaveformEditIntent) async throws -> PulseDeckLibraryCache
}

/// Serial background executor actor for atomic cache persistence, ensuring all decoding,
/// validation, encoding, and disk flush operations run completely off MainActor while preserving
/// save request ordering.
public actor WaveformPersistenceActor: WaveformTrackPersisting {
    public init() {}

    public func persistTrack(
        _ track: TrackCacheEntry,
        libraryRootURL: URL,
        intent: WaveformEditIntent
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
        if let diskEntry = cache.tracks[track.relativePath] {
            entryToSave = try mergeManualIntent(track: track, intoDiskEntry: diskEntry, intent: intent)
        } else {
            entryToSave = track
        }

        cache.tracks[track.relativePath] = entryToSave
        cache.generatedAt = ISO8601DateFormatter().string(from: Date())

        try CachePersistence.saveAtomic(cache: cache, to: cacheURL)
        return cache
    }

    private func mergeManualIntent(
        track: TrackCacheEntry,
        intoDiskEntry disk: TrackCacheEntry,
        intent: WaveformEditIntent
    ) throws -> TrackCacheEntry {
        var merged = disk

        var mergedFields = disk.manualOverrides.overriddenFields
        switch intent {
        case .cue(let cue, let acceptedPreviousValues):
            guard acceptedPreviousValues.contains(cueValue(cue, in: disk.cueMarkers)) else {
                throw WaveformEditorError.conflictingEdit(relativePath: track.relativePath, field: "\(cue.displayName)")
            }
            let submittedTime = cueValue(cue, in: track.cueMarkers)
            let cues = WaveformCoordinateMapper(
                duration: disk.duration,
                zoomLevel: 1,
                scrollOffsetSeconds: 0,
                totalBins: 0
            ).validateAndClamp(cue: cue, newTime: submittedTime, currentCues: disk.cueMarkers)
            // A failed prerequisite or fresh disk bounds must never turn a different timestamp into an acknowledged save.
            guard cueValue(cue, in: cues) == submittedTime else {
                throw WaveformEditorError.incompatibleCueBounds(relativePath: track.relativePath, field: cue.displayName)
            }
            merged.cueMarkers = cues
            if !mergedFields.contains("cueMarkers") { mergedFields.append("cueMarkers") }
        case .aiTrimBypass(let acceptedPreviousValues):
            guard acceptedPreviousValues.contains(disk.aiTrimBypass) else {
                throw WaveformEditorError.conflictingEdit(relativePath: track.relativePath, field: "AI trim bypass")
            }
            merged.aiTrimBypass = track.aiTrimBypass
            if !mergedFields.contains("aiTrimBypass") { mergedFields.append("aiTrimBypass") }
        }

        merged.manualOverrides = ManualOverrides(
            isManual: true,
            overriddenFields: mergedFields,
            updatedAt: track.manualOverrides.updatedAt ?? disk.manualOverrides.updatedAt,
            author: track.manualOverrides.author ?? disk.manualOverrides.author,
            notes: disk.manualOverrides.notes
        )

        return merged
    }

    private func cueValue(_ cue: CueType, in cues: CueMarkers) -> Double {
        switch cue {
        case .startTrim: cues.startTrimCue
        case .vocalEntry: cues.vocalEntryCue
        case .mixOut: cues.mixOutCue
        case .endTrim: cues.endTrimCue
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
    private enum EditedField: Hashable {
        case cue(CueType)
        case aiTrimBypass
    }
    private struct FieldEdit {
        let revision: UInt64
        var isPending: Bool
        var failureMessage: String?
    }
    private struct LocalEdit {
        let track: TrackCacheEntry
        let revision: UInt64
        var acceptedPreviousCueValues: [CueType: Set<Double>]
        var acceptedPreviousBypassValues: Set<Bool>
        var fieldEdits: [EditedField: FieldEdit]

        var hasPendingEdits: Bool { fieldEdits.values.contains(where: \.isPending) }
        var failureMessage: String? { fieldEdits.values.compactMap(\.failureMessage).first }
    }
    private var localEdits: [TrackIdentity: LocalEdit] = [:]
    private var cachePublicationGenerations: [URL: UInt64] = [:]
    private var nextRevision: UInt64 = 0
    private var pendingSaveCount = 0

    public func cachePublicationGeneration(for libraryRootURL: URL) -> UInt64 {
        cachePublicationGenerations[libraryRootURL.standardizedFileURL] ?? 0
    }

    public var hasActiveDrag: Bool {
        activeDraggingCue != nil
    }

    public func hasDirtyEdits(for relativePath: String, libraryRootURL: URL) -> Bool {
        let identity = TrackIdentity(root: libraryRootURL, relativePath: relativePath)
        return localEdits[identity] != nil
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
        return persisted.map { applying(local, to: $0) } ?? local.track
    }

    func applyingLocalEdits(to cache: PulseDeckLibraryCache, libraryRootURL: URL) -> PulseDeckLibraryCache {
        var updated = cache
        for (identity, local) in localEdits where identity.root == libraryRootURL.standardizedFileURL {
            updated.tracks[identity.relativePath] = updated.tracks[identity.relativePath].map {
                applying(local, to: $0)
            } ?? local.track
        }
        return updated
    }

    private func applying(_ local: LocalEdit, to persisted: TrackCacheEntry) -> TrackCacheEntry {
        var merged = persisted
        merged.cueMarkers = reconcileCues(local: local, persisted: persisted)
        if local.fieldEdits[.aiTrimBypass] != nil {
            merged.aiTrimBypass = local.track.aiTrimBypass
        }

        var overrides = persisted.manualOverrides
        if !local.fieldEdits.isEmpty {
            overrides.isManual = true
            if local.fieldEdits.keys.contains(where: { if case .cue = $0 { true } else { false } }),
               !overrides.overriddenFields.contains("cueMarkers") {
                overrides.overriddenFields.append("cueMarkers")
            }
            if local.fieldEdits[.aiTrimBypass] != nil,
               !overrides.overriddenFields.contains("aiTrimBypass") {
                overrides.overriddenFields.append("aiTrimBypass")
            }
            overrides.updatedAt = local.track.manualOverrides.updatedAt ?? overrides.updatedAt
            overrides.author = local.track.manualOverrides.author ?? overrides.author
        }
        merged.manualOverrides = overrides
        return merged
    }

    /// Reconciles all dirty local cue targets jointly before enforcing bounds and ordering
    /// against unrelated fresh disk cues and track duration.
    private func reconcileCues(local: LocalEdit, persisted: TrackCacheEntry) -> CueMarkers {
        let duration = persisted.duration
        guard duration > 0 else { return persisted.cueMarkers }

        let allCues = CueType.allCases
        var cueValues = allCues.map { cueValue($0, in: persisted.cueMarkers) }
        let isDirty = allCues.map { local.fieldEdits[.cue($0)] != nil }

        var index = 0
        while index < allCues.count {
            if !isDirty[index] {
                index += 1
                continue
            }

            let startIndex = index
            while index < allCues.count && isDirty[index] {
                index += 1
            }
            let endIndex = index - 1

            let rawLowerBound = startIndex > 0 ? cueValues[startIndex - 1] : 0.0
            let rawUpperBound = endIndex < allCues.count - 1 ? cueValues[endIndex + 1] : duration
            let effectiveUpperBound = max(0.0, min(duration, rawUpperBound))
            let effectiveLowerBound = max(0.0, min(effectiveUpperBound, rawLowerBound))

            var dirtyTargets = (startIndex...endIndex).map { cueValue(allCues[$0], in: local.track.cueMarkers) }

            // 1. Jointly order dirty cues among themselves
            for i in 0..<dirtyTargets.count {
                dirtyTargets[i] = max(effectiveLowerBound, min(effectiveUpperBound, dirtyTargets[i]))
                if i > 0 {
                    dirtyTargets[i] = max(dirtyTargets[i - 1], dirtyTargets[i])
                }
            }

            // 2. Clamp against upper bound from right to left
            dirtyTargets[dirtyTargets.count - 1] = min(effectiveUpperBound, dirtyTargets[dirtyTargets.count - 1])
            if dirtyTargets.count > 1 {
                for i in stride(from: dirtyTargets.count - 2, through: 0, by: -1) {
                    dirtyTargets[i] = min(dirtyTargets[i + 1], dirtyTargets[i])
                }
            }

            // 3. Clamp against lower bound from left to right
            dirtyTargets[0] = max(effectiveLowerBound, dirtyTargets[0])
            if dirtyTargets.count > 1 {
                for i in 1..<dirtyTargets.count {
                    dirtyTargets[i] = max(dirtyTargets[i - 1], dirtyTargets[i])
                }
            }

            for (offset, target) in dirtyTargets.enumerated() {
                cueValues[startIndex + offset] = target
            }
        }

        return CueMarkers(
            startTrimCue: cueValues[0],
            vocalEntryCue: cueValues[1],
            mixOutCue: cueValues[2],
            endTrimCue: cueValues[3]
        ).clamped(toDuration: duration)
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

    /// Updates an already-loaded track with fresh cached metadata/analysis from disk while
    /// strictly preserving interactive view state (zoomLevel, scrollOffsetSeconds, playheadPosition, selectedCue).
    /// Clamps scroll offset and playhead to valid duration bounds.
    public func updateLoadedTrack(_ entry: TrackCacheEntry) {
        guard let current = currentTrack,
              current.relativePath == entry.relativePath else {
            loadTrack(entry)
            return
        }

        self.currentTrack = entry
        self.cues = entry.cueMarkers.clamped(toDuration: entry.duration)
        self.aiTrimBypass = entry.aiTrimBypass
        self.manualOverrides = entry.manualOverrides

        // Preserve interactive view state, clamping to valid duration bounds
        if entry.duration > 0 {
            let visibleDuration = entry.duration / zoomLevel
            let maxOffset = max(0.0, entry.duration - visibleDuration)
            self.scrollOffsetSeconds = max(0.0, min(maxOffset, scrollOffsetSeconds))
            self.playheadPosition = max(0.0, min(entry.duration, playheadPosition))
        } else {
            self.zoomLevel = 1.0
            self.scrollOffsetSeconds = 0.0
            self.playheadPosition = 0.0
        }

        let local = localEdits[TrackIdentity(root: libraryRootURL, relativePath: entry.relativePath)]
        self.errorMessage = local?.failureMessage
        if local?.failureMessage != nil {
            self.statusMessage = "Unsaved cue changes"
        } else if local?.hasPendingEdits == true {
            self.statusMessage = "Loaded \(entry.relativePath) (Persisting...)"
        } else {
            self.statusMessage = "Loaded \(entry.relativePath) (BPM: \(String(format: "%.1f", entry.bpm)), Key: \(entry.musicalKey))"
        }
    }

    /// Loads a real cached track analysis entry into the editor.
    /// Resets interactive view state (zoom, scroll, playhead, selectedCue) to defaults unless
    /// preservingViewStateIfSameTrack is true and this same relativePath is already loaded.
    public func loadTrack(_ entry: TrackCacheEntry, preservingViewStateIfSameTrack: Bool = false) {
        if preservingViewStateIfSameTrack,
           let current = currentTrack,
           current.relativePath == entry.relativePath {
            updateLoadedTrack(entry)
            return
        }
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
        } else if local?.hasPendingEdits == true {
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
        commitCueChanges(reason: "Dragged \(cue.displayName)", cue: cue)
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
        commitCueChanges(reason: "Set \(cue.displayName) to \(String(format: "%.3f", toTime))s", cue: cue)
    }

    /// Nudges the currently selected or specified cue by a small delta in seconds.
    public func nudgeCue(_ cue: CueType, deltaSeconds: Double) {
        let currentTime = cueTime(for: cue)
        setCue(cue, toTime: currentTime + deltaSeconds)
    }

    /// Toggles the AI trim bypass state and atomically persists to cache.
    public func toggleAITrimBypass() {
        guard let selectedTrack = currentTrack else { return }
        let previousValue = aiTrimBypass
        let identity = TrackIdentity(root: libraryRootURL, relativePath: selectedTrack.relativePath)
        var acceptedPreviousValues = localEdits[identity]?.acceptedPreviousBypassValues ?? []
        acceptedPreviousValues.insert(previousValue)
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
        persistCurrentTrackToCache(intent: .aiTrimBypass(acceptedPreviousValues: acceptedPreviousValues))
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

    private func cueValue(_ cue: CueType, in cues: CueMarkers) -> Double {
        switch cue {
        case .startTrim: cues.startTrimCue
        case .vocalEntry: cues.vocalEntryCue
        case .mixOut: cues.mixOutCue
        case .endTrim: cues.endTrimCue
        }
    }

    private func editedField(for intent: WaveformEditIntent) -> EditedField {
        switch intent {
        case .cue(let cue, _): .cue(cue)
        case .aiTrimBypass: .aiTrimBypass
        }
    }

    private func commitCueChanges(reason: String, cue: CueType) {
        guard var track = currentTrack else { return }
        let previousValue = cueValue(cue, in: track.cueMarkers)
        let identity = TrackIdentity(root: libraryRootURL, relativePath: track.relativePath)
        var acceptedPreviousValues = localEdits[identity]?.acceptedPreviousCueValues[cue] ?? []
        acceptedPreviousValues.insert(previousValue)

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

        persistCurrentTrackToCache(intent: .cue(cue, acceptedPreviousValues: acceptedPreviousValues))
    }

    private func persistCurrentTrackToCache(intent: WaveformEditIntent) {
        guard let track = currentTrack else { return }
        let rootURL = self.libraryRootURL
        let actor = self.persistenceActor
        let identity = TrackIdentity(root: rootURL, relativePath: track.relativePath)
        var acceptedPreviousCueValues = localEdits[identity]?.acceptedPreviousCueValues ?? [:]
        var acceptedPreviousBypassValues = localEdits[identity]?.acceptedPreviousBypassValues ?? []
        switch intent {
        case .cue(let cue, let values):
            acceptedPreviousCueValues[cue] = values
        case .aiTrimBypass(let values):
            acceptedPreviousBypassValues = values
        }
        nextRevision &+= 1
        let revision = nextRevision
        let submittedInteractionRevision = interactionRevision
        var fieldEdits = localEdits[identity]?.fieldEdits ?? [:]
        fieldEdits[editedField(for: intent)] = FieldEdit(revision: revision, isPending: true)
        localEdits[identity] = LocalEdit(track: track, revision: revision,
                                         acceptedPreviousCueValues: acceptedPreviousCueValues,
                                         acceptedPreviousBypassValues: acceptedPreviousBypassValues,
                                         fieldEdits: fieldEdits)
        pendingSaveCount += 1
        self.isSaving = true
        let previousSave = inFlightSaveTask

        // Chain every snapshot in submission order. Cancellation must never discard another track's commit.
        inFlightSaveTask = Task { [weak self, track, rootURL, actor] in
            await previousSave?.value
            do {
                let updatedCache = try await actor.persistTrack(track, libraryRootURL: rootURL, intent: intent)
                self?.completeSave(track: track, rootURL: rootURL, identity: identity,
                                   revision: revision, intent: intent,
                                   interactionRevision: submittedInteractionRevision,
                                   result: .success(updatedCache))
            } catch {
                self?.completeSave(track: track, rootURL: rootURL, identity: identity,
                                   revision: revision, intent: intent,
                                   interactionRevision: submittedInteractionRevision,
                                   result: .failure(error))
            }
        }
    }

    private func completeSave(track: TrackCacheEntry, rootURL: URL, identity: TrackIdentity,
                              revision: UInt64, intent: WaveformEditIntent,
                              interactionRevision submittedInteractionRevision: UInt64,
                              result: Result<PulseDeckLibraryCache, any Error>) {
        pendingSaveCount -= 1
        isSaving = pendingSaveCount > 0
        let isLatestRevisionForTrack = localEdits[identity]?.revision == revision
        let field = editedField(for: intent)
        var acknowledgedCurrentField = false
        if var local = localEdits[identity],
           var fieldEdit = local.fieldEdits[field],
           fieldEdit.revision == revision {
            acknowledgedCurrentField = true
            switch result {
            case .success:
                local.fieldEdits.removeValue(forKey: field)
            case .failure(let error):
                fieldEdit.isPending = false
                fieldEdit.failureMessage = error.localizedDescription
                local.fieldEdits[field] = fieldEdit
            }
            if local.fieldEdits.isEmpty {
                localEdits.removeValue(forKey: identity)
            } else {
                localEdits[identity] = local
            }
        }
        if case .success(let cache) = result {
            cachePublicationGenerations[identity.root, default: 0] &+= 1
            let savedTrack = cache.tracks[identity.relativePath] ?? track
            onTrackPersisted?(savedTrack, cache, rootURL)
        }
        if acknowledgedCurrentField, case .failure(let error) = result,
           currentTrack?.relativePath == identity.relativePath,
           libraryRootURL.standardizedFileURL == identity.root {
            errorMessage = error.localizedDescription
            statusMessage = "Unsaved cue changes"
        }
        // Earlier completions may update the shared cache, but cannot overwrite a newer edit's UI status.
        guard currentTrack?.relativePath == identity.relativePath,
              libraryRootURL.standardizedFileURL == identity.root,
              isLatestRevisionForTrack else { return }
        switch result {
        case .success(let cache):
            let local = localEdits[identity]
            errorMessage = local?.failureMessage
            statusMessage = local?.failureMessage == nil
                ? "Saved cues to .pulsedeck_ai_cache.json"
                : "Unsaved cue changes"
            guard interactionRevision == submittedInteractionRevision || hasActiveDrag else { return }
            if let savedTrack = cache.tracks[identity.relativePath] {
                let displayedTrack = local.map { applying($0, to: savedTrack) } ?? savedTrack
                var displayedCues = displayedTrack.cueMarkers
                // The active target is not a committed field yet. Keep it in the UI while adopting
                // the saved baseline used by endDrag's conflict check, even if the pointer moved.
                switch activeDraggingCue {
                case .startTrim: displayedCues.startTrimCue = cues.startTrimCue
                case .vocalEntry: displayedCues.vocalEntryCue = cues.vocalEntryCue
                case .mixOut: displayedCues.mixOutCue = cues.mixOutCue
                case .endTrim: displayedCues.endTrimCue = cues.endTrimCue
                case nil: break
                }
                self.currentTrack = displayedTrack
                self.manualOverrides = displayedTrack.manualOverrides
                self.cues = displayedCues
                self.aiTrimBypass = displayedTrack.aiTrimBypass
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
            statusMessage = "Save Error"
        }
    }
}
