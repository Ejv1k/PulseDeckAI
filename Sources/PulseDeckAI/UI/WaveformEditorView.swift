import SwiftUI
import PulseDeckCore

/// Production SwiftUI Waveform Editor for Phase 3A.
/// Features 60 FPS Canvas rendering, bounded visible-bin rendering, scroll & zoom navigation,
/// 4 draggable color-coded cue handles with strict order/bounds constraints, Bypass AI Trim toggle,
/// hotkeys I/O without overriding text inputs, and atomic cache persistence.
public struct WaveformEditorView: View {
    @ObservedObject public var model: WaveformEditorModel
    var selectedTrackPath: String?
    var analysisStatus: LibraryTrackAnalysisStatus?
    @FocusState private var isWaveformFocused: Bool
    @State private var hoveredCue: CueType? = nil
    @State private var dragInitialHandle: (cue: CueType, x: CGFloat)? = nil
    @State private var isDetailedEditorExpanded: Bool = false
    private static let waveformCoordinateSpaceName = "WaveformContainerCoordinateSpace"

    public init(model: WaveformEditorModel) {
        self.model = model
        self.selectedTrackPath = nil
        self.analysisStatus = nil
    }

    init(
        model: WaveformEditorModel,
        selectedTrackPath: String? = nil,
        analysisStatus: LibraryTrackAnalysisStatus? = nil
    ) {
        self.model = model
        self.selectedTrackPath = selectedTrackPath
        self.analysisStatus = analysisStatus
    }

    private func pendingStatusText(for path: String) -> String {
        if let status = analysisStatus {
            switch status {
            case .running:
                return "Analysis in progress…"
            case .complete:
                return "Analysis ready · Loading waveform…"
            case .failed(let reason):
                return "Analysis failed: \(reason) · Click ANALYZE to retry"
            }
        }
        return "Waveform pending · Click ANALYZE in crate row"
    }

    private func pendingCanvasPrompt(for path: String) -> String {
        if let status = analysisStatus {
            switch status {
            case .running:
                return "Local audio analysis in progress. Waveform will appear upon completion."
            case .complete:
                return "Analysis complete. Waveform is preparing to render."
            case .failed(let reason):
                return "Analysis error: \(reason). Click ANALYZE in the crate row to retry."
            }
        }
        return "Selected track has pending waveform data. Click ANALYZE in the crate row to generate waveform, beat grid, and cues."
    }

    @ViewBuilder
    private func headerToolbarAnalysisAction(for path: String) -> some View {
        if let status = analysisStatus {
            switch status {
            case .running:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Analyzing…")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(DJTheme.deckA)
                }
            case .complete:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                    Text("Loading…")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .foregroundColor(DJTheme.master)
            case .failed:
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text("Retry in Crate")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .foregroundColor(.orange)
            }
        } else {
            Text("Click Analyze in crate to inspect cues")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(DJTheme.deckA)
        }
    }

    private func cueSummaryPrompt(for path: String) -> String {
        if let status = analysisStatus {
            switch status {
            case .running:
                return "Selected '\(path)' · Analysis in progress… waveform and cues will appear automatically"
            case .complete:
                return "Selected '\(path)' · Analysis complete · Loading waveform and cue points…"
            case .failed(let reason):
                return "Selected '\(path)' · Analysis error: \(reason) · Click ANALYZE in crate to retry"
            }
        }
        return "Selected '\(path)' · Click ANALYZE in crate row to inspect cue points"
    }

    public var body: some View {
        VStack(spacing: 6) {
            // Header Bar
            headerToolbar

            // Main Waveform Canvas & Cue Handles
            waveformContainer
                .frame(height: isDetailedEditorExpanded ? 160 : 64)

            if isDetailedEditorExpanded {
                // Minimap Overview Scroller (visible when zoomed in)
                if model.zoomLevel > 1.05 {
                    waveformMinimap
                        .frame(height: 20)
                }

                // Cue Summary & Nudge Controls
                cueSummaryBar

                // Keyboard hints & status bar
                footerStatusBar
            } else {
                // Compact Cue Strip with expand button
                compactCueBar
            }
        }
        .padding(8)
        .background(DJTheme.cardBackground)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isWaveformFocused ? DJTheme.deckA.opacity(0.8) : DJTheme.border, lineWidth: 1)
        )
        .focusable()
        .focused($isWaveformFocused)
        .onKeyPress(phases: .down) { press in
            handleKeyPress(press)
        }
    }

    // MARK: - Header Toolbar

    private var headerToolbar: some View {
        HStack(spacing: 12) {
            // Track Title & Crate Info
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 14))
                    .foregroundColor(DJTheme.deckA)

                if let track = model.currentTrack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.relativePath)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(DJTheme.textPrimary)
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            Text(formatTime(track.duration))
                                .font(.system(size: 10, weight: .medium))
                                .monospacedDigit()
                                .foregroundColor(DJTheme.textSecondary)

                            Text(String(format: "%.1f BPM", track.bpm))
                                .font(.system(size: 10, weight: .bold))
                                .monospacedDigit()
                                .foregroundColor(DJTheme.deckA)

                            Text("Key: \(track.musicalKey)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(DJTheme.cue)

                            if track.manualOverrides.isManual {
                                Text("Manual Override")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(DJTheme.cue.opacity(0.2))
                                    .foregroundColor(DJTheme.cue)
                                    .cornerRadius(2)
                            }
                        }
                    }
                } else if let selected = selectedTrackPath {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundColor(DJTheme.deckA)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(selected)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(DJTheme.textPrimary)
                                .lineLimit(1)

                            Text(pendingStatusText(for: selected))
                                .font(.system(size: 9.5))
                                .foregroundColor(DJTheme.textSecondary)
                        }
                    }
                } else {
                    Text("No Track Loaded — Select a track in crate")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DJTheme.textMuted)
                }
            }

            Spacer()

            if model.currentTrack != nil {
                // Bypass AI Trim Toggle
                Button(action: {
                    model.toggleAITrimBypass()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: model.aiTrimBypass ? "slash.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(model.aiTrimBypass ? .orange : DJTheme.master)

                        Text(model.aiTrimBypass ? "AI Trim: Bypassed" : "AI Trim: Active")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(model.aiTrimBypass ? .orange : DJTheme.master)
                    }
                    .padding(.horizontal, 8)
                    .frame(minHeight: DJTheme.minTouchTarget)
                    .background(model.aiTrimBypass ? Color.orange.opacity(0.15) : DJTheme.master.opacity(0.15))
                    .cornerRadius(DJTheme.controlRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                            .stroke(model.aiTrimBypass ? Color.orange : DJTheme.master.opacity(0.6), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(StudioPressableStyle())
                .help("Toggle AI trim cue boundaries for waveform display and cue audition")

                Divider()
                    .frame(height: 16)
                    .background(DJTheme.border)

                // Zoom Controls
                HStack(spacing: 4) {
                    Button(action: { model.zoomOut() }) {
                        Image(systemName: "minus.magnifyingglass")
                            .font(.system(size: 11))
                            .padding(4)
                            .frame(minWidth: DJTheme.minTouchTarget, minHeight: DJTheme.minTouchTarget)
                            .background(DJTheme.cardHeader)
                            .cornerRadius(DJTheme.chipRadius)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(StudioPressableStyle())
                    .disabled(model.zoomLevel <= 1.0)
                    .help("Zoom out (-)")

                    Text(String(format: "%.1fx", model.zoomLevel))
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(DJTheme.textSecondary)
                        .frame(width: 36)

                    Button(action: { model.zoomIn() }) {
                        Image(systemName: "plus.magnifyingglass")
                            .font(.system(size: 11))
                            .padding(4)
                            .frame(minWidth: DJTheme.minTouchTarget, minHeight: DJTheme.minTouchTarget)
                            .background(DJTheme.cardHeader)
                            .cornerRadius(DJTheme.chipRadius)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(StudioPressableStyle())
                    .disabled(model.zoomLevel >= 32.0)
                    .help("Zoom in (+)")

                    if model.zoomLevel > 1.05 {
                        Button(action: {
                            model.resetZoom()
                        }) {
                            Text("Fit")
                                .font(.system(size: 9.5, weight: .semibold))
                                .padding(.horizontal, 6)
                                .frame(minHeight: DJTheme.minTouchTarget)
                                .background(DJTheme.cardHeader)
                                .foregroundColor(DJTheme.deckA)
                                .cornerRadius(DJTheme.chipRadius)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(StudioPressableStyle())
                        .help("Reset to full track view")
                    }
                }
            } else if let selected = selectedTrackPath {
                headerToolbarAnalysisAction(for: selected)
            } else {
                Text("Select a track in crate to inspect cues")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(DJTheme.textMuted)
            }
        }
        .padding(.horizontal, 6)
    }

    // MARK: - Main Waveform Container

    private var waveformContainer: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            ZStack(alignment: .leading) {
                // Background & Grid Lines
                Rectangle()
                    .fill(Color(red: 0.05, green: 0.06, blue: 0.08))

                if let track = model.currentTrack {
                    // 60 FPS capped Multiband Waveform Canvas
                    TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { _ in
                        Canvas { context, size in
                            drawWaveform(in: &context, size: size, track: track)
                        }
                    }

                    // Trimmed Silence Shaded Overlays
                    trimOverlays(track: track, width: width, height: height)

                    // 4 Draggable Cue Handles
                    cueHandlesOverlay(width: width, height: height)

                    // Playhead Scrub Marker
                    playheadMarker(width: width, height: height)
                } else if let selected = selectedTrackPath {
                    VStack(spacing: 4) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .font(.system(size: 20))
                            .foregroundColor(DJTheme.deckA)
                        Text("Selected: \(selected)")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(DJTheme.textPrimary)
                            .lineLimit(1)
                        Text(pendingCanvasPrompt(for: selected))
                            .font(.system(size: 9.5))
                            .foregroundColor(DJTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Compact helpful select/analyze empty state (no selection)
                    VStack(spacing: 4) {
                        Image(systemName: "waveform")
                            .font(.system(size: 20))
                            .foregroundColor(DJTheme.textMuted)
                        Text("No track active in waveform editor")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(DJTheme.textSecondary)
                        Text("Select a track from library to inspect waveform, beat grid, and cues.")
                            .font(.system(size: 9.5))
                            .foregroundColor(DJTheme.textMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .coordinateSpace(name: Self.waveformCoordinateSpaceName)
            .cornerRadius(DJTheme.controlRadius)
            .overlay(
                RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                    .stroke(DJTheme.border.opacity(0.7), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { location in
                isWaveformFocused = true
                let clickedTime = model.xToTime(x: location.x, viewWidth: width)
                model.seekPlayhead(to: clickedTime)
            }
        }
    }

    // MARK: - Waveform Canvas Drawing

    private func drawWaveform(in context: inout GraphicsContext, size: CGSize, track: TrackCacheEntry) {
        let width = size.width
        let height = size.height
        guard width > 0, height > 0 else { return }

        let midY = height / 2.0
        let maxHalfHeight = (height - 30) / 2.0

        // Center Reference Line
        var centerPath = Path()
        centerPath.move(to: CGPoint(x: 0, y: midY))
        centerPath.addLine(to: CGPoint(x: width, y: midY))
        context.stroke(centerPath, with: .color(DJTheme.border.opacity(0.7)), lineWidth: 1)

        // Beat Grid Ticks
        let mapper = model.coordinateMapper
        let startTime = mapper.visibleStartTime
        let endTime = mapper.visibleEndTime
        for beatTime in track.beatGrid.beatTimestamps where beatTime >= startTime && beatTime <= endTime {
            let beatX = mapper.timeToX(time: beatTime, viewWidth: width)
            var beatPath = Path()
            beatPath.move(to: CGPoint(x: beatX, y: 0))
            beatPath.addLine(to: CGPoint(x: beatX, y: height))
            context.stroke(beatPath, with: .color(Color.white.opacity(0.08)), lineWidth: 1)
        }

        // Visible Waveform Bins (Strictly Bounded Work via WaveformSampler)
        let metadata = track.waveformMetadata
        guard let binRange = mapper.visibleBinRange() else { return }

        let columns = max(1, Int(width))
        let samples = WaveformSampler.sampleColumns(
            metadata: metadata,
            binRange: binRange,
            columnCount: columns
        )

        let columnWidth = max(1.0, width / CGFloat(columns))
        for sample in samples {
            let barHeight = max(2.0, CGFloat(sample.peak) * maxHalfHeight)
            let colX = CGFloat(sample.column)

            // Multiband Color Blending (Electric Cyan Lows + Amber Mids + Ice White Highs)
            let r = Double(min(1.0, sample.mid * 0.95 + sample.high * 0.8))
            let g = Double(min(1.0, sample.low * 0.85 + sample.mid * 0.65 + sample.high * 0.9))
            let b = Double(min(1.0, sample.low * 1.0 + sample.high * 0.95))
            let blendedColor = Color(red: r, green: g, blue: b)

            var barPath = Path()
            barPath.move(to: CGPoint(x: colX, y: midY - barHeight))
            barPath.addLine(to: CGPoint(x: colX, y: midY + barHeight))
            context.stroke(barPath, with: .color(blendedColor), lineWidth: columnWidth)
        }
    }

    // MARK: - Trim Overlays

    private func trimOverlays(track: TrackCacheEntry, width: CGFloat, height: CGFloat) -> some View {
        let startX = model.timeToX(time: model.cues.startTrimCue, viewWidth: width)
        let endX = model.timeToX(time: model.cues.endTrimCue, viewWidth: width)

        return ZStack(alignment: .leading) {
            // Intro Trimmed Silence (0.0 to startTrimCue)
            if startX > 0 {
                Rectangle()
                    .fill(model.aiTrimBypass ? Color.orange.opacity(0.12) : Color.black.opacity(0.55))
                    .frame(width: max(0, startX), height: height)
                    .overlay(
                        HStack {
                            Spacer()
                            if model.aiTrimBypass && startX > 50 {
                                Text("BYPASS")
                                    .font(.system(size: 7.5, weight: .black, design: .monospaced))
                                    .foregroundColor(.orange.opacity(0.85))
                                    .padding(.trailing, 4)
                            }
                        }
                    )
            }

            // Outro Trimmed Silence (endTrimCue to duration)
            if endX < width {
                Rectangle()
                    .fill(model.aiTrimBypass ? Color.orange.opacity(0.12) : Color.black.opacity(0.55))
                    .offset(x: endX)
                    .frame(width: max(0, width - endX), height: height)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Cue Handles Overlay

    private func cueHandlesOverlay(width: CGFloat, height: CGFloat) -> some View {
        let sortedCues = CueType.allCases.sorted { a, b in
            let aRank = cueZRank(cue: a)
            let bRank = cueZRank(cue: b)
            if aRank != bRank {
                return aRank < bRank
            }
            return a.rawValue < b.rawValue
        }

        return ZStack(alignment: .leading) {
            ForEach(sortedCues) { cue in
                let cueTime = model.cueTime(for: cue)
                let x = model.timeToX(time: cueTime, viewWidth: width)
                let isDragging = model.activeDraggingCue == cue
                let isHovered = hoveredCue == cue
                let isSelected = model.selectedCue == cue

                cueHandleView(
                    cue: cue,
                    cueTime: cueTime,
                    x: x,
                    height: height,
                    width: width,
                    isDragging: isDragging,
                    isHovered: isHovered,
                    isSelected: isSelected
                )
                .zIndex(cueZRank(cue: cue))
            }
        }
    }

    private func cueZRank(cue: CueType) -> Double {
        if model.activeDraggingCue == cue { return 100 }
        if model.selectedCue == cue { return 50 }
        if hoveredCue == cue { return 25 }
        switch cue {
        case .startTrim: return 1
        case .vocalEntry: return 2
        case .mixOut: return 3
        case .endTrim: return 4
        }
    }

    private func cueHandleView(
        cue: CueType,
        cueTime: Double,
        x: CGFloat,
        height: CGFloat,
        width: CGFloat,
        isDragging: Bool,
        isHovered: Bool,
        isSelected: Bool
    ) -> some View {
        let badgeHalfWidth: CGFloat = 28
        let clampedBadgeX = min(max(x, badgeHalfWidth + 2), max(badgeHalfWidth + 2, width - badgeHalfWidth - 2))
        let badgeOffsetX = clampedBadgeX - x

        return VStack(spacing: 0) {
            // Top Badge Handle (anchored within canvas bounds to prevent edge clipping)
            HStack(spacing: 2) {
                Text(cue.shortLabel)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(.black)

                Text(formatTime(cueTime))
                    .font(.system(size: 8, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(.black)
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(cue.color)
            .cornerRadius(3)
            .shadow(color: isDragging || isSelected ? cue.color.opacity(0.9) : .clear, radius: 4)
            .scaleEffect(isDragging ? 1.08 : (isHovered ? 1.04 : 1.0))
            .offset(x: badgeOffsetX)

            // Vertical Guide Line (stays strictly at the true cue timestamp position)
            Rectangle()
                .fill(cue.color)
                .frame(width: isDragging || isSelected ? 2.5 : 1.5)
                .shadow(color: cue.color.opacity(0.6), radius: 2)

            // Bottom Grip Pill
            Circle()
                .fill(cue.color)
                .frame(width: 7, height: 7)
                .shadow(color: cue.color.opacity(0.8), radius: 3)
        }
        .frame(height: height)
        .contentShape(
            CueHandleHitShape(
                badgeOffsetX: badgeOffsetX,
                badgeHalfWidth: badgeHalfWidth + 2,
                guideHalfWidth: 16,
                badgeHeight: 26
            )
        )
        .onHover { inside in
            hoveredCue = inside ? cue : (hoveredCue == cue ? nil : hoveredCue)
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.waveformCoordinateSpaceName))
                .onChanged { value in
                    isWaveformFocused = true
                    if model.activeDraggingCue == nil {
                        model.beginDrag(cue: cue)
                        dragInitialHandle = (cue: cue, x: x)
                    }
                    let startX = (dragInitialHandle?.cue == cue) ? dragInitialHandle!.x : x
                    let targetX = startX + value.translation.width
                    let targetTime = model.xToTime(x: targetX, viewWidth: width)
                    model.updateDrag(cue: cue, toTime: targetTime)
                }
                .onEnded { _ in
                    dragInitialHandle = nil
                    model.endDrag(cue: cue)
                }
        )
        .simultaneousGesture(
            TapGesture()
                .onEnded {
                    isWaveformFocused = true
                    model.selectedCue = cue
                }
        )
        .position(x: x, y: height / 2.0)
    }

    // MARK: - Playhead Scrubber Marker

    private func playheadMarker(width: CGFloat, height: CGFloat) -> some View {
        let playheadX = model.timeToX(time: model.playheadPosition, viewWidth: width)

        return ZStack {
            Rectangle()
                .fill(Color.white)
                .frame(width: 1.5, height: height)
                .shadow(color: .white.opacity(0.8), radius: 3)

            VStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: 6, height: 6)
                Spacer()
            }
        }
        .frame(width: 12)
        .position(x: playheadX, y: height / 2.0)
        .allowsHitTesting(false)
    }

    // MARK: - Waveform Minimap

    private var waveformMinimap: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            if let track = model.currentTrack, track.duration > 0 {
                let visibleFraction = (track.duration / model.zoomLevel) / track.duration
                let startFraction = model.scrollOffsetSeconds / track.duration
                let viewportWidth = max(16.0, width * CGFloat(visibleFraction))
                let viewportX = width * CGFloat(startFraction)

                ZStack(alignment: .leading) {
                    // Minimap background track
                    Rectangle()
                        .fill(DJTheme.cardHeader)
                        .cornerRadius(2)

                    // Simplified full track peak line
                    Canvas { context, size in
                        let cols = max(1, Int(size.width))
                        let samples = WaveformSampler.sampleMinimap(
                            metadata: track.waveformMetadata,
                            columnCount: cols
                        )
                        for sample in samples {
                            let p = CGFloat(sample.peak)
                            var path = Path()
                            path.move(to: CGPoint(x: CGFloat(sample.column), y: size.height / 2.0 - p * (size.height / 2.0)))
                            path.addLine(to: CGPoint(x: CGFloat(sample.column), y: size.height / 2.0 + p * (size.height / 2.0)))
                            context.stroke(path, with: .color(DJTheme.textMuted.opacity(0.6)), lineWidth: 1)
                        }
                    }

                    // Visible Viewport Box
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(DJTheme.deckA, lineWidth: 1.5)
                        .background(DJTheme.deckA.opacity(0.18))
                        .frame(width: min(width, viewportWidth), height: height)
                        .offset(x: min(width - viewportWidth, max(0, viewportX)))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let centerFrac = Double(value.location.x / width)
                            let centerSec = centerFrac * track.duration
                            let visibleDur = track.duration / model.zoomLevel
                            let newOffset = centerSec - (visibleDur / 2.0)
                            model.scrollTo(offsetSeconds: newOffset)
                        }
                )
            }
        }
    }

    // MARK: - Cue Summary Bar

    private var cueSummaryBar: some View {
        HStack(spacing: 8) {
            if model.currentTrack != nil {
                ForEach(CueType.allCases, id: \.self) { (cue: CueType) in
                    let cueTime = model.cueTime(for: cue)
                    let isSelected = model.selectedCue == cue

                    Button(action: {
                        model.selectedCue = cue
                        model.seekPlayhead(to: cueTime)
                    }) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(cue.color)
                                .frame(width: 8, height: 8)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(cue.displayName)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(isSelected ? cue.color : DJTheme.textSecondary)

                                Text(formatTime(cueTime))
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundColor(DJTheme.textPrimary)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isSelected ? cue.color.opacity(0.15) : DJTheme.cardHeader)
                        .cornerRadius(DJTheme.controlRadius)
                        .overlay(
                            RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                                .stroke(isSelected ? cue.color : DJTheme.border.opacity(0.6), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Audition cue position for \(cue.displayName)")
                }

                Spacer()

                // Nudge Controls for Selected Cue
                if let selected = model.selectedCue {
                    HStack(spacing: 4) {
                        Text("Nudge \(selected.shortLabel):")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundColor(DJTheme.textMuted)

                        Button("-50ms") {
                            model.nudgeCue(selected, deltaSeconds: -0.050)
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(DJTheme.cardHeader)
                        .cornerRadius(DJTheme.chipRadius)
                        .buttonStyle(.plain)

                        Button("+50ms") {
                            model.nudgeCue(selected, deltaSeconds: 0.050)
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(DJTheme.cardHeader)
                        .cornerRadius(DJTheme.chipRadius)
                        .buttonStyle(.plain)
                    }
                }
            } else if let selected = selectedTrackPath {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundColor(DJTheme.deckA)
                    Text(cueSummaryPrompt(for: selected))
                        .font(.system(size: 10))
                        .foregroundColor(DJTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundColor(DJTheme.textMuted)
                    Text("Select a track in the library to inspect and edit cue markers")
                        .font(.system(size: 10))
                        .foregroundColor(DJTheme.textMuted)
                }
                Spacer()
            }

            Button(action: { isDetailedEditorExpanded = false }) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8))
                    Text("Compact")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(DJTheme.textSecondary)
                .padding(.horizontal, 6)
                .frame(minHeight: DJTheme.minTouchTarget)
                .background(DJTheme.cardHeader)
                .cornerRadius(DJTheme.chipRadius)
                .contentShape(Rectangle())
            }
            .buttonStyle(StudioPressableStyle())
        }
        .padding(.horizontal, 4)
    }

    private var compactCueBar: some View {
        HStack(spacing: 6) {
            if model.currentTrack != nil {
                ForEach(CueType.allCases, id: \.self) { (cue: CueType) in
                    let cueTime = model.cueTime(for: cue)
                    let isSelected = model.selectedCue == cue

                    Button(action: {
                        model.selectedCue = cue
                        model.seekPlayhead(to: cueTime)
                    }) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(cue.color)
                                .frame(width: 6, height: 6)

                            Text(cue.shortLabel)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(isSelected ? cue.color : DJTheme.textSecondary)

                            Text(formatTime(cueTime))
                                .font(.system(size: 9.5, weight: .semibold))
                                .monospacedDigit()
                                .foregroundColor(DJTheme.textPrimary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(isSelected ? cue.color.opacity(0.18) : DJTheme.cardHeader)
                        .cornerRadius(DJTheme.chipRadius)
                        .overlay(
                            RoundedRectangle(cornerRadius: DJTheme.chipRadius)
                                .stroke(isSelected ? cue.color : Color.clear, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(StudioPressableStyle())
                    .help("Audition cue position for \(cue.displayName)")
                }

                Spacer()

                // Save state & feedback in compact mode
                compactPersistenceStatus

                Button(action: {
                    isDetailedEditorExpanded = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 8))
                        Text("Nudge & Minimap")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(DJTheme.textSecondary)
                    .padding(.horizontal, 6)
                    .frame(minHeight: DJTheme.minTouchTarget)
                    .background(DJTheme.cardHeader)
                    .cornerRadius(DJTheme.chipRadius)
                    .contentShape(Rectangle())
                }
                .buttonStyle(StudioPressableStyle())
                .help("Expand detailed cue nudge controls and minimap")
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9))
                        .foregroundColor(DJTheme.textMuted)
                    if let selected = selectedTrackPath {
                        Text(cueSummaryPrompt(for: selected))
                            .font(.system(size: 9.5))
                            .foregroundColor(DJTheme.textSecondary)
                            .lineLimit(1)
                    } else {
                        Text("Select a track in the library to inspect cue points")
                            .font(.system(size: 9.5))
                            .foregroundColor(DJTheme.textMuted)
                    }
                }
                Spacer()

                if let error = model.errorMessage {
                    compactErrorView(error: error)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var compactPersistenceStatus: some View {
        if model.isSaving {
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 10, height: 10)
                Text("Persisting to cache...")
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundColor(DJTheme.deckA)
            }
            .accessibilityIdentifier("waveformCompactSavingStatus")
        } else if let error = model.errorMessage {
            compactErrorView(error: error)
        }
    }

    private func compactErrorView(error: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8.5))
                .foregroundColor(.red)
            Text(error)
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundColor(.red)
                .lineLimit(1)
        }
        .accessibilityIdentifier("waveformCompactErrorMessage")
    }

    // MARK: - Footer Status Bar

    private var footerStatusBar: some View {
        HStack(spacing: 12) {
            // Hotkey cheat sheet
            HStack(spacing: 6) {
                Text("HOTKEYS:")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(DJTheme.textMuted)

                Text("[I] In/Start  [O] Out/End  [V] Vocal  [M] MixOut  [←/→] Nudge  [+/-] Zoom")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(DJTheme.textSecondary)
            }

            Spacer()

            // Save state / feedback
            if model.isSaving {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 10, height: 10)
                    Text("Persisting to cache...")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(DJTheme.deckA)
                }
            } else if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.red)
            } else {
                Text(model.statusMessage)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(DJTheme.textMuted)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Keyboard Handling (Without Overriding Text Inputs)

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // Since focusable() is on WaveformEditorView and this handler is attached to the view,
        // it only executes when the waveform view has active keyboard focus, preserving text fields.
        guard model.currentTrack != nil else { return .ignored }

        switch press.characters {
        case "i", "I":
            model.setCue(.startTrim, toTime: model.playheadPosition)
            return .handled
        case "o", "O":
            model.setCue(.endTrim, toTime: model.playheadPosition)
            return .handled
        case "v", "V":
            model.setCue(.vocalEntry, toTime: model.playheadPosition)
            return .handled
        case "m", "M":
            model.setCue(.mixOut, toTime: model.playheadPosition)
            return .handled
        case "+", "=":
            model.zoomIn()
            return .handled
        case "-", "_":
            model.zoomOut()
            return .handled
        case "[":
            model.scrollTo(offsetSeconds: model.scrollOffsetSeconds - 5.0)
            return .handled
        case "]":
            model.scrollTo(offsetSeconds: model.scrollOffsetSeconds + 5.0)
            return .handled
        default:
            if press.key == .leftArrow {
                if let selected = model.selectedCue {
                    model.nudgeCue(selected, deltaSeconds: -0.050)
                    return .handled
                }
            } else if press.key == .rightArrow {
                if let selected = model.selectedCue {
                    model.nudgeCue(selected, deltaSeconds: 0.050)
                    return .handled
                }
            }
            return .ignored
        }
    }

    /// Current error text displayed in the compact status bar.
    public var displayedCompactError: String? {
        model.errorMessage
    }

    /// Whether the detailed editor (nudge and minimap) is expanded.
    public var isDetailedEditorExpandedForTesting: Bool {
        isDetailedEditorExpanded
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00.00" }
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        let millis = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%d:%02d.%02d", minutes, secs, millis)
    }
}

/// Hit-testing shape for a cue handle that encompasses both the centered vertical guide line
/// and the translated top badge pill (anchored within canvas bounds via badgeOffsetX).
public struct CueHandleHitShape: Shape, Equatable, Sendable {
    public let badgeOffsetX: CGFloat
    public let badgeHalfWidth: CGFloat
    public let guideHalfWidth: CGFloat
    public let badgeHeight: CGFloat

    public init(
        badgeOffsetX: CGFloat = 0,
        badgeHalfWidth: CGFloat = 30,
        guideHalfWidth: CGFloat = 16,
        badgeHeight: CGFloat = 26
    ) {
        self.badgeOffsetX = badgeOffsetX
        self.badgeHalfWidth = badgeHalfWidth
        self.guideHalfWidth = guideHalfWidth
        self.badgeHeight = badgeHeight
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let centerX = rect.midX

        // 1. Vertical guide line hit box (centered at cue timestamp position centerX)
        let guideRect = CGRect(
            x: centerX - guideHalfWidth,
            y: rect.minY,
            width: guideHalfWidth * 2,
            height: rect.height
        )
        path.addRect(guideRect)

        // 2. Translated top badge hit box (centered at centerX + badgeOffsetX)
        let badgeRect = CGRect(
            x: centerX + badgeOffsetX - badgeHalfWidth,
            y: rect.minY,
            width: badgeHalfWidth * 2,
            height: min(rect.height, badgeHeight)
        )
        path.addRoundedRect(in: badgeRect, cornerSize: CGSize(width: 3, height: 3))

        return path
    }

    public func contains(point: CGPoint, in rect: CGRect) -> Bool {
        path(in: rect).contains(point)
    }
}

