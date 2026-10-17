import SwiftUI
import PulseDeckCore

/// Production SwiftUI Waveform Editor for Phase 3A.
/// Features 60 FPS Canvas rendering, bounded visible-bin rendering, scroll & zoom navigation,
/// 4 draggable color-coded cue handles with strict order/bounds constraints, Bypass AI Trim toggle,
/// hotkeys I/O without overriding text inputs, and atomic cache persistence.
public struct WaveformEditorView: View {
    @ObservedObject public var model: WaveformEditorModel
    @FocusState private var isWaveformFocused: Bool
    @State private var hoveredCue: CueType? = nil

    public init(model: WaveformEditorModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 8) {
            // Header Bar
            headerToolbar

            // Main Waveform Canvas & Cue Handles
            waveformContainer
                .frame(height: 190)

            // Minimap Overview Scroller (visible when zoomed in)
            if model.zoomLevel > 1.05 {
                waveformMinimap
                    .frame(height: 20)
            }

            // Cue Summary & Nudge Controls
            cueSummaryBar

            // Keyboard hints & status bar
            footerStatusBar
        }
        .padding(10)
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
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(DJTheme.textPrimary)
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            Text(formatTime(track.duration))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(DJTheme.textSecondary)

                            Text(String(format: "BPM: %.1f", track.bpm))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(DJTheme.deckA)

                            Text("Key: \(track.musicalKey)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(DJTheme.cue)

                            if track.manualOverrides.isManual {
                                Text("MANUAL OVERRIDE")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(DJTheme.cue.opacity(0.2))
                                    .foregroundColor(DJTheme.cue)
                                    .cornerRadius(2)
                            }
                        }
                    }
                } else {
                    Text("NO TRACK LOADED — SELECT A TRACK IN CRATE")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(DJTheme.textMuted)
                }
            }

            Spacer()

            // Bypass AI Trim Toggle
            Button(action: {
                model.toggleAITrimBypass()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: model.aiTrimBypass ? "slash.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(model.aiTrimBypass ? .orange : DJTheme.master)

                    Text(model.aiTrimBypass ? "AI TRIM: BYPASSED" : "AI TRIM: ACTIVE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(model.aiTrimBypass ? .orange : DJTheme.master)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(model.aiTrimBypass ? Color.orange.opacity(0.15) : DJTheme.master.opacity(0.15))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(model.aiTrimBypass ? Color.orange : DJTheme.master.opacity(0.6), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help("Toggle AI Auto-Trim bypass (non-destructive playback trim)")

            Divider()
                .frame(height: 16)
                .background(DJTheme.border)

            // Zoom Controls
            HStack(spacing: 4) {
                Button(action: { model.zoomOut() }) {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.system(size: 11))
                        .padding(4)
                        .background(DJTheme.cardHeader)
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
                .disabled(model.zoomLevel <= 1.0)
                .help("Zoom out (-)")

                Text(String(format: "%.1fx", model.zoomLevel))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(DJTheme.textSecondary)
                    .frame(width: 36)

                Button(action: { model.zoomIn() }) {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 11))
                        .padding(4)
                        .background(DJTheme.cardHeader)
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
                .disabled(model.zoomLevel >= 32.0)
                .help("Zoom in (+)")

                if model.zoomLevel > 1.05 {
                    Button("FIT") {
                        model.resetZoom()
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(DJTheme.cardHeader)
                    .foregroundColor(DJTheme.deckA)
                    .cornerRadius(3)
                    .buttonStyle(.plain)
                    .help("Reset to full track view")
                }
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
                } else {
                    // Empty state
                    VStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.system(size: 28))
                            .foregroundColor(DJTheme.textMuted)
                        Text("No track loaded in waveform editor")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(DJTheme.textMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(DJTheme.border, lineWidth: 1)
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

        // Visible Waveform Bins (Strictly Bounded Work)
        let metadata = track.waveformMetadata
        guard let binRange = mapper.visibleBinRange() else { return }

        let visibleBinCount = binRange.count
        let columns = max(1, Int(width))
        let binsPerColumn = max(1, visibleBinCount / columns)
        let step = max(1.0, Double(visibleBinCount) / Double(columns))

        let startBin = binRange.lowerBound
        var col = 0
        while col < columns {
            let binIdx = min(binRange.upperBound, startBin + Int(Double(col) * step))
            guard binIdx < metadata.peakValues.count else { break }

            // Aggregate peaks across binsPerColumn to ensure transient accuracy without aliasing
            var peak: Float = 0.0
            var low: Float = 0.0
            var mid: Float = 0.0
            var high: Float = 0.0

            let endIdx = min(binIdx + binsPerColumn, metadata.peakValues.count)
            for i in binIdx..<endIdx {
                peak = max(peak, metadata.peakValues[i])
                low = max(low, metadata.lowBandPeaks[i])
                mid = max(mid, metadata.midBandPeaks[i])
                high = max(high, metadata.highBandPeaks[i])
            }

            let barHeight = max(2.0, CGFloat(peak) * maxHalfHeight)
            let colX = CGFloat(col)

            // Multiband Color Blending (Electric Cyan Lows + Amber Mids + Ice White Highs)
            let r = Double(min(1.0, mid * 0.95 + high * 0.8))
            let g = Double(min(1.0, low * 0.85 + mid * 0.65 + high * 0.9))
            let b = Double(min(1.0, low * 1.0 + high * 0.95))
            let blendedColor = Color(red: r, green: g, blue: b)

            var barPath = Path()
            barPath.move(to: CGPoint(x: colX, y: midY - barHeight))
            barPath.addLine(to: CGPoint(x: colX, y: midY + barHeight))
            context.stroke(barPath, with: .color(blendedColor), lineWidth: max(1.0, width / CGFloat(columns)))

            col += 1
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
                            if model.aiTrimBypass {
                                Text("TRIM BYPASSED")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundColor(.orange.opacity(0.8))
                                    .rotationEffect(.degrees(-90))
                                    .padding(.trailing, 2)
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
        ZStack(alignment: .leading) {
            ForEach(CueType.allCases) { cue in
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
            }
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
        VStack(spacing: 0) {
            // Top Badge Handle
            HStack(spacing: 2) {
                Text(cue.shortLabel)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(.black)

                Text(formatTime(cueTime))
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(.black)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(cue.color)
            .cornerRadius(3)
            .shadow(color: isDragging || isSelected ? cue.color.opacity(0.9) : .clear, radius: 4)
            .scaleEffect(isDragging ? 1.08 : (isHovered ? 1.04 : 1.0))

            // Vertical Guide Line
            Rectangle()
                .fill(cue.color)
                .frame(width: isDragging || isSelected ? 2.5 : 1.5)
                .shadow(color: cue.color.opacity(0.6), radius: 2)

            // Bottom Grip Pill
            Circle()
                .fill(cue.color)
                .frame(width: 8, height: 8)
                .shadow(color: cue.color.opacity(0.8), radius: 3)
        }
        .frame(width: 32)
        .position(x: x, y: height / 2.0)
        .onHover { inside in
            hoveredCue = inside ? cue : (hoveredCue == cue ? nil : hoveredCue)
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    isWaveformFocused = true
                    if model.activeDraggingCue == nil {
                        model.beginDrag(cue: cue)
                    }
                    let targetTime = model.xToTime(x: value.location.x, viewWidth: width)
                    model.updateDrag(cue: cue, toTime: targetTime)
                }
                .onEnded { _ in
                    model.endDrag(cue: cue)
                }
        )
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
                        let total = track.waveformMetadata.peakValues.count
                        guard total > 0 else { return }
                        let cols = max(1, Int(size.width))
                        let step = max(1, total / cols)
                        for c in 0..<cols {
                            let idx = min(total - 1, c * step)
                            let p = CGFloat(track.waveformMetadata.peakValues[idx])
                            var path = Path()
                            path.move(to: CGPoint(x: CGFloat(c), y: size.height / 2.0 - p * (size.height / 2.0)))
                            path.addLine(to: CGPoint(x: CGFloat(c), y: size.height / 2.0 + p * (size.height / 2.0)))
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
            ForEach(CueType.allCases) { cue in
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
                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                .foregroundColor(isSelected ? cue.color : DJTheme.textSecondary)

                            Text(formatTime(cueTime))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(DJTheme.textPrimary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isSelected ? cue.color.opacity(0.15) : DJTheme.cardHeader)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isSelected ? cue.color : DJTheme.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Nudge Controls for Selected Cue
            if let selected = model.selectedCue {
                HStack(spacing: 4) {
                    Text("NUDGE \(selected.shortLabel):")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(DJTheme.textMuted)

                    Button("-50ms") {
                        model.nudgeCue(selected, deltaSeconds: -0.050)
                    }
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(DJTheme.cardHeader)
                    .cornerRadius(3)
                    .buttonStyle(.plain)

                    Button("+50ms") {
                        model.nudgeCue(selected, deltaSeconds: 0.050)
                    }
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(DJTheme.cardHeader)
                    .cornerRadius(3)
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 4)
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

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00.00" }
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        let millis = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%d:%02d.%02d", minutes, secs, millis)
    }
}
