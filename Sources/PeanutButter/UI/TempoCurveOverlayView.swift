import SwiftUI
import AppKit

public enum TempoCurveTool: String, CaseIterable, Sendable {
    case pointer = "Pointer"
    case draw = "Draw"
}

struct TempoCurveScaleHelper {
    let minBPM: Double
    let maxBPM: Double

    static let verticalPad: CGFloat = 18.0

    init(song: Song, extraBPMs: [Double] = []) {
        var vals: [Double] = [song.bpm]
        for span in song.resolvedTempoSpans() {
            vals.append(span.startBPM)
            vals.append(span.endBPM)
            for pt in span.event.customPoints {
                vals.append(pt.bpm)
            }
        }
        vals.append(contentsOf: extraBPMs)
        let rawMin = vals.min() ?? song.bpm
        let rawMax = vals.max() ?? song.bpm
        var lo = max(20.0, floor((rawMin - 25.0) / 10.0) * 10.0)
        var hi = min(280.0, ceil((rawMax + 25.0) / 10.0) * 10.0)
        if hi - lo < 40.0 {
            let mid = (hi + lo) * 0.5
            lo = max(20.0, floor((mid - 20.0) / 10.0) * 10.0)
            hi = min(280.0, lo + 40.0)
        }
        self.minBPM = lo
        self.maxBPM = hi
    }

    func yForBPM(_ bpm: Double, height: CGFloat) -> CGFloat {
        let usableH = max(20.0, height - Self.verticalPad * 2.0)
        let norm = (bpm - minBPM) / max(1.0, maxBPM - minBPM)
        let clamped = max(0.0, min(1.0, norm))
        return Self.verticalPad + (1.0 - CGFloat(clamped)) * usableH
    }

    func bpmForY(_ y: CGFloat, height: CGFloat, snapHalfBPM: Bool = true) -> Double {
        let usableH = max(20.0, height - Self.verticalPad * 2.0)
        let norm = 1.0 - Double((y - Self.verticalPad) / usableH)
        let clamped = max(0.0, min(1.0, norm))
        let raw = minBPM + clamped * (maxBPM - minBPM)
        let bounded = max(20.0, min(280.0, raw))
        return snapHalfBPM ? ((bounded * 2.0).rounded() / 2.0) : bounded
    }

    func gridBPMTicks() -> [Double] {
        let range = maxBPM - minBPM
        let step: Double = range > 120.0 ? 20.0 : 10.0
        var ticks: [Double] = []
        var cur = ceil(minBPM / step) * step
        while cur <= maxBPM + 0.01 {
            ticks.append(cur)
            cur += step
        }
        return ticks
    }
}

/// Interactive DAW-style tempo curve drawn directly atop the dimmed waveform in 1:1 pixel sync.
struct TempoCurveScrollingOverlay: View {
    @ObservedObject var engine: MultitrackAudioEngine
    let pixelsPerSecond: CGFloat
    let waveformWidth: CGFloat
    let waveformHeight: CGFloat
    let tool: TempoCurveTool
    let snapToBeat: Bool
    @Binding var editingTempoEvent: TempoChangeEvent?

    @State private var drawnStrokePoints: [(displayTime: TimeInterval, bpm: Double, x: CGFloat, y: CGFloat)] = []
    @State private var hoveredTooltip: (text: String, x: CGFloat, y: CGFloat)? = nil
    @State private var dragStartAudioTimeById: [UUID: TimeInterval] = [:]
    @State private var dragStartEndTimeById: [UUID: TimeInterval] = [:]
    @State private var dragStartPointNormById: [UUID: Double] = [:]

    private let accentAmber = Color(red: 0.98, green: 0.68, blue: 0.18)

    private func displayTime(forSourceTime sourceTime: TimeInterval) -> TimeInterval {
        if let sec = engine.currentSong.sections.first(where: {
            sourceTime >= $0.sourceAudioStartTime - 0.01 &&
            sourceTime <= $0.sourceAudioStartTime + $0.duration + 0.01
        }) {
            return sec.startTime + (sourceTime - sec.sourceAudioStartTime)
        }
        return sourceTime
    }

    private func xForSourceTime(_ sourceTime: TimeInterval) -> CGFloat {
        CGFloat(max(0.0, displayTime(forSourceTime: sourceTime))) * pixelsPerSecond
    }

    private func sourceTime(forX x: CGFloat, snapOverride: Bool? = nil) -> TimeInterval {
        let rawDisp = max(0.0, TimeInterval(x / max(1.0, pixelsPerSecond)))
        let optionDown = NSEvent.modifierFlags.contains(.option)
        let shouldSnap = snapOverride ?? (snapToBeat && !optionDown)
        let dispTime = shouldSnap ? engine.snapTimeToBeatGrid(rawDisp) : rawDisp
        return max(0.0, engine.audioTime(forArrangementTime: dispTime))
    }

    private func curveDisplayBPM(atSourceTime srcT: TimeInterval, spans: [ResolvedTempoSpan]) -> Double {
        let baseBPM = max(20.0, min(300.0, engine.currentSong.bpm))
        var activeBPM = baseBPM
        for span in spans {
            if srcT < span.startTime - 0.0005 { break }
            if span.event.isRamp && srcT < span.endTime - 0.0005 {
                let u = (srcT - span.startTime) / max(0.001, span.endTime - span.startTime)
                return Song.evaluateRampBPM(event: span.event, startBPM: span.startBPM, endBPM: span.endBPM, u: u)
            }
            activeBPM = span.endBPM
        }
        return activeBPM
    }

    var body: some View {
        let strokeBPMs = drawnStrokePoints.map(\.bpm)
        let scale = TempoCurveScaleHelper(song: engine.currentSong, extraBPMs: strokeBPMs)
        let spans = engine.currentSong.resolvedTempoSpans()
        let ticks = scale.gridBPMTicks()

        ZStack(alignment: .topLeading) {
            // 1. Horizontal BPM reference gridlines + amber curve + area fill
            Canvas { context, size in
                let dashStyle = StrokeStyle(lineWidth: 0.75, dash: [4, 4])
                for tick in ticks {
                    let y = scale.yForBPM(tick, height: size.height)
                    var gridLine = Path()
                    gridLine.move(to: CGPoint(x: 0, y: y))
                    gridLine.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(gridLine, with: .color(Color.white.opacity(0.11)), style: dashStyle)
                }

                guard size.width > 1 else { return }
                let stepPx: CGFloat = 4.0
                var curvePath = Path()
                var fillPath = Path()

                var x: CGFloat = 0.0
                var isFirst = true
                var lastY = scale.yForBPM(engine.currentSong.bpm, height: size.height)

                while x <= size.width + stepPx {
                    let clampedX = min(size.width, x)
                    let dispT = TimeInterval(clampedX / max(1.0, pixelsPerSecond))
                    let srcT = max(0.0, engine.audioTime(forArrangementTime: dispT))
                    let bpmAtX = curveDisplayBPM(atSourceTime: srcT, spans: spans)
                    let yAtX = scale.yForBPM(bpmAtX, height: size.height)

                    if isFirst {
                        curvePath.move(to: CGPoint(x: clampedX, y: yAtX))
                        fillPath.move(to: CGPoint(x: clampedX, y: size.height))
                        fillPath.addLine(to: CGPoint(x: clampedX, y: yAtX))
                        isFirst = false
                    } else {
                        curvePath.addLine(to: CGPoint(x: clampedX, y: yAtX))
                        fillPath.addLine(to: CGPoint(x: clampedX, y: yAtX))
                    }
                    lastY = yAtX
                    if clampedX >= size.width { break }
                    x += stepPx
                }

                fillPath.addLine(to: CGPoint(x: size.width, y: size.height))
                fillPath.closeSubpath()

                context.fill(
                    fillPath,
                    with: .linearGradient(
                        Gradient(colors: [accentAmber.opacity(0.20), accentAmber.opacity(0.03)]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )
                context.stroke(curvePath, with: .color(accentAmber), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                _ = lastY
            }
            .frame(width: max(1, waveformWidth), height: waveformHeight)
            .allowsHitTesting(false)

            // 2. Background interaction surface (Draw freehand stroke vs Pointer click-to-add)
            if tool == .draw {
                Color.clear
                    .frame(width: max(1, waveformWidth), height: waveformHeight)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                let clampedX = max(0.0, min(waveformWidth, value.location.x))
                                let clampedY = max(4.0, min(waveformHeight - 4.0, value.location.y))
                                let dispT = max(0.0, TimeInterval(clampedX / max(1.0, pixelsPerSecond)))
                                let bpmVal = scale.bpmForY(clampedY, height: waveformHeight, snapHalfBPM: false)
                                drawnStrokePoints.append((displayTime: dispT, bpm: bpmVal, x: clampedX, y: clampedY))
                                let labelBPM = Song.formatBPM(bpmVal, decimals: 1)
                                hoveredTooltip = ("\(labelBPM) BPM", clampedX, max(22.0, clampedY - 22.0))
                            }
                            .onEnded { _ in
                                let stroke = drawnStrokePoints.map { (displayTime: $0.displayTime, bpm: $0.bpm) }
                                drawnStrokePoints.removeAll()
                                hoveredTooltip = nil
                                engine.applyDrawnTempoStroke(points: stroke)
                            }
                    )

                if drawnStrokePoints.count >= 2 {
                    Path { p in
                        p.move(to: CGPoint(x: drawnStrokePoints[0].x, y: drawnStrokePoints[0].y))
                        for pt in drawnStrokePoints.dropFirst() {
                            p.addLine(to: CGPoint(x: pt.x, y: pt.y))
                        }
                    }
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.2, dash: [5, 3]))
                    .allowsHitTesting(false)
                }
            } else {
                Color.clear
                    .frame(width: max(1, waveformWidth), height: waveformHeight)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                let dist = hypot(value.translation.width, value.translation.height)
                                guard dist < 4.0 else { return }
                                let targetSrc = sourceTime(forX: value.location.x)
                                let targetBPM = scale.bpmForY(value.location.y, height: waveformHeight, snapHalfBPM: true)
                                let dispTime = displayTime(forSourceTime: targetSrc)
                                engine.addInstantTempoChange(atDisplayTime: dispTime, bpm: targetBPM, snap: false)
                            }
                    )
            }

            // 3. Interactive Event & Custom Curve Handles (Pointer Mode)
            if tool == .pointer {
                ForEach(spans, id: \.event.id) { span in
                    eventHandles(span: span, scale: scale)
                }
            }

            // 4. Live Tooltip Pill during Drag / Draw
            if let tip = hoveredTooltip {
                Text(tip.text)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(accentAmber)
                    .cornerRadius(4)
                    .shadow(color: .black.opacity(0.6), radius: 3)
                    .position(x: max(46, min(waveformWidth - 46, tip.x)), y: max(14, tip.y))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: max(1, waveformWidth), height: waveformHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private func eventHandles(span: ResolvedTempoSpan, scale: TempoCurveScaleHelper) -> some View {
        let ev = span.event
        let startX = xForSourceTime(span.startTime)
        let startY = scale.yForBPM(span.startBPM, height: waveformHeight)
        let endX = xForSourceTime(span.endTime)
        let endY = scale.yForBPM(span.endBPM, height: waveformHeight)

        if !ev.isRamp {
            // Instant Tempo Step Diamond Node
            ZStack {
                Rectangle()
                    .fill(accentAmber)
                    .frame(width: 11, height: 11)
                    .rotationEffect(.degrees(45))
                    .overlay(
                        Rectangle()
                            .stroke(Color.white, lineWidth: 1.4)
                            .frame(width: 11, height: 11)
                            .rotationEffect(.degrees(45))
                    )
                    .shadow(color: .black.opacity(0.75), radius: 2)
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .position(x: startX, y: endY)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartAudioTimeById[ev.id] == nil {
                            dragStartAudioTimeById[ev.id] = ev.audioTime
                        }
                        let newSrc = sourceTime(forX: value.location.x)
                        let newBPM = scale.bpmForY(value.location.y, height: waveformHeight, snapHalfBPM: !NSEvent.modifierFlags.contains(.option))
                        var updated = ev
                        updated.audioTime = newSrc
                        updated.targetBPM = newBPM
                        hoveredTooltip = ("\(Song.formatBPM(newBPM, decimals: 1)) BPM", xForSourceTime(newSrc), max(16.0, value.location.y - 22.0))
                        engine.updateTempoChangeEvent(updated, commit: false)
                    }
                    .onEnded { value in
                        let newSrc = sourceTime(forX: value.location.x)
                        let newBPM = scale.bpmForY(value.location.y, height: waveformHeight, snapHalfBPM: !NSEvent.modifierFlags.contains(.option))
                        var updated = ev
                        updated.audioTime = newSrc
                        updated.targetBPM = newBPM
                        dragStartAudioTimeById.removeValue(forKey: ev.id)
                        hoveredTooltip = nil
                        engine.updateTempoChangeEvent(updated, commit: true)
                    }
            )
            .onTapGesture(count: 2) {
                editingTempoEvent = ev
            }
            .contextMenu {
                Button("Edit Tempo Change...") { editingTempoEvent = ev }
                Button("Convert to 2-Bar Ramp") {
                    var updated = ev
                    let ts = engine.currentSong.timeSignature(atSourceTime: ev.audioTime)
                    updated.isRamp = true
                    updated.spanMode = .barsBeats
                    updated.rampBeats = Double(max(1, ts.numerator) * 2)
                    updated.curve = .easeIn
                    engine.updateTempoChangeEvent(updated, commit: true)
                }
                Divider()
                Button("Delete", role: .destructive) {
                    engine.removeTempoChangeEvent(id: ev.id)
                }
            }
        } else {
            // Ramp Start Handle (horizontal drag)
            Circle()
                .fill(Color(red: 0.14, green: 0.15, blue: 0.17))
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(accentAmber, lineWidth: 2))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .position(x: startX, y: startY)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let newStartSrc = min(max(0.0, span.endTime - 0.1), sourceTime(forX: value.location.x))
                            var updated = ev
                            updated.audioTime = newStartSrc
                            hoveredTooltip = ("Start \(String(format: "%.1fs", displayTime(forSourceTime: newStartSrc)))", xForSourceTime(newStartSrc), max(16.0, startY - 22.0))
                            engine.updateTempoChangeEvent(updated, commit: false)
                        }
                        .onEnded { value in
                            let newStartSrc = min(max(0.0, span.endTime - 0.1), sourceTime(forX: value.location.x))
                            var updated = ev
                            updated.audioTime = newStartSrc
                            hoveredTooltip = nil
                            engine.updateTempoChangeEvent(updated, commit: true)
                        }
                )
                .onTapGesture(count: 2) {
                    editingTempoEvent = ev
                }

            // Ramp / Custom End Handle (horizontal + vertical drag)
            Circle()
                .fill(accentAmber)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .position(x: endX, y: endY)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if dragStartEndTimeById[ev.id] == nil {
                                dragStartEndTimeById[ev.id] = span.endTime
                            }
                            let rawSrcEnd = sourceTime(forX: value.location.x)
                            let clampedEnd = max(ev.audioTime + 0.15, rawSrcEnd)
                            let newEndBPM = scale.bpmForY(value.location.y, height: waveformHeight, snapHalfBPM: !NSEvent.modifierFlags.contains(.option))
                            var updated = ev
                            updated.spanMode = .audioAnchor
                            updated.endAudioTime = clampedEnd
                            updated.lockBeatCountToAudioEnd = false
                            updated.targetBPM = newEndBPM
                            hoveredTooltip = ("\(Song.formatBPM(newEndBPM, decimals: 1)) BPM", xForSourceTime(clampedEnd), max(16.0, value.location.y - 22.0))
                            engine.updateTempoChangeEvent(updated, commit: false)
                        }
                        .onEnded { value in
                            let rawSrcEnd = sourceTime(forX: value.location.x)
                            let clampedEnd = max(ev.audioTime + 0.15, rawSrcEnd)
                            let newEndBPM = scale.bpmForY(value.location.y, height: waveformHeight, snapHalfBPM: !NSEvent.modifierFlags.contains(.option))
                            var updated = ev
                            updated.spanMode = .audioAnchor
                            updated.endAudioTime = clampedEnd
                            updated.lockBeatCountToAudioEnd = false
                            updated.targetBPM = newEndBPM
                            dragStartEndTimeById.removeValue(forKey: ev.id)
                            hoveredTooltip = nil
                            engine.updateTempoChangeEvent(updated, commit: true)
                        }
                )
                .onTapGesture(count: 2) {
                    editingTempoEvent = ev
                }
                .contextMenu {
                    Button("Edit Ramp...") { editingTempoEvent = ev }
                    Button("Add Custom Control Point") {
                        var updated = ev
                        updated.curve = .custom
                        updated.spanMode = .audioAnchor
                        updated.endAudioTime = updated.endAudioTime ?? span.endTime
                        let midBPM = Song.evaluateRampBPM(event: ev, startBPM: span.startBPM, endBPM: span.endBPM, u: 0.5)
                        updated.customPoints.append(TempoCurvePoint(normalizedTime: 0.5, bpm: midBPM))
                        updated.customPoints.sort { $0.normalizedTime < $1.normalizedTime }
                        engine.updateTempoChangeEvent(updated, commit: true)
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        engine.removeTempoChangeEvent(id: ev.id)
                    }
                }

            // Preset Curve Midpoint Tension Handle OR Custom Interior Control Points
            if ev.curve == .custom {
                ForEach(ev.customPoints) { pt in
                    let ptSrcTime = span.startTime + pt.normalizedTime * max(0.05, span.endTime - span.startTime)
                    let ptX = xForSourceTime(ptSrcTime)
                    let ptY = scale.yForBPM(pt.bpm, height: waveformHeight)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(accentAmber, lineWidth: 2))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .position(x: ptX, y: ptY)
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    if dragStartPointNormById[pt.id] == nil {
                                        dragStartPointNormById[pt.id] = pt.normalizedTime
                                    }
                                    let draggedSrc = sourceTime(forX: value.location.x, snapOverride: false)
                                    let normT = (draggedSrc - span.startTime) / max(0.05, span.endTime - span.startTime)
                                    let clampedNorm = max(0.005, min(0.995, normT))
                                    let newBPM = scale.bpmForY(value.location.y, height: waveformHeight, snapHalfBPM: !NSEvent.modifierFlags.contains(.option))
                                    var updated = ev
                                    if let ptIdx = updated.customPoints.firstIndex(where: { $0.id == pt.id }) {
                                        updated.customPoints[ptIdx].normalizedTime = clampedNorm
                                        updated.customPoints[ptIdx].bpm = newBPM
                                    }
                                    hoveredTooltip = ("\(Song.formatBPM(newBPM, decimals: 1)) BPM", xForSourceTime(span.startTime + clampedNorm * (span.endTime - span.startTime)), max(16.0, value.location.y - 22.0))
                                    engine.updateTempoChangeEvent(updated, commit: false)
                                }
                                .onEnded { value in
                                    let draggedSrc = sourceTime(forX: value.location.x, snapOverride: false)
                                    let normT = (draggedSrc - span.startTime) / max(0.05, span.endTime - span.startTime)
                                    let clampedNorm = max(0.005, min(0.995, normT))
                                    let newBPM = scale.bpmForY(value.location.y, height: waveformHeight, snapHalfBPM: !NSEvent.modifierFlags.contains(.option))
                                    var updated = ev
                                    if let ptIdx = updated.customPoints.firstIndex(where: { $0.id == pt.id }) {
                                        updated.customPoints[ptIdx].normalizedTime = clampedNorm
                                        updated.customPoints[ptIdx].bpm = newBPM
                                    }
                                    dragStartPointNormById.removeValue(forKey: pt.id)
                                    hoveredTooltip = nil
                                    engine.updateTempoChangeEvent(updated, commit: true)
                                }
                        )
                        .contextMenu {
                            Button("Remove Point", role: .destructive) {
                                var updated = ev
                                updated.customPoints.removeAll { $0.id == pt.id }
                                engine.updateTempoChangeEvent(updated, commit: true)
                            }
                        }
                }
            } else if endX - startX >= 28 {
                let midSrcT = (span.startTime + span.endTime) * 0.5
                let midBPM = Song.evaluateRampBPM(event: ev, startBPM: span.startBPM, endBPM: span.endBPM, u: 0.5)
                let midX = xForSourceTime(midSrcT)
                let midY = scale.yForBPM(midBPM, height: waveformHeight)
                let directionSign: Double = (span.endBPM >= span.startBPM) ? -1.0 : 1.0

                Circle()
                    .fill(Color.black.opacity(0.85))
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .position(x: midX, y: midY)
                    .help("Drag vertically to bend curve")
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let deltaY = Double(value.translation.height)
                                let normShift = (deltaY / max(30.0, Double(waveformHeight) * 0.45)) * directionSign
                                let tension = max(-1.0, min(1.0, normShift * 2.0))
                                var updated = ev
                                updated.curveTension = tension
                                hoveredTooltip = (String(format: "Curve %.0f%%", tension * 100), midX, max(16.0, midY - 22.0))
                                engine.updateTempoChangeEvent(updated, commit: false)
                            }
                            .onEnded { _ in
                                hoveredTooltip = nil
                                if let latest = engine.currentSong.tempoEvents.first(where: { $0.id == ev.id }) {
                                    engine.updateTempoChangeEvent(latest, commit: true)
                                }
                            }
                    )
            }
        }
    }
}

/// Non-scrolling Y-axis BPM ruler & floating Draw/Pointer toolbar anchored over the waveform when editing tempo curves.
struct TempoCurveOverlayHUD: View {
    @ObservedObject var engine: MultitrackAudioEngine
    let waveformHeight: CGFloat
    @Binding var tool: TempoCurveTool
    @Binding var snapToBeat: Bool

    private let accentAmber = Color(red: 0.98, green: 0.68, blue: 0.18)

    var body: some View {
        let scale = TempoCurveScaleHelper(song: engine.currentSong)
        let ticks = scale.gridBPMTicks()

        ZStack(alignment: .topLeading) {
            // Left BPM Y-axis labels
            ZStack(alignment: .topTrailing) {
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 34, height: waveformHeight)
                    .overlay(
                        Rectangle()
                            .fill(accentAmber.opacity(0.28))
                            .frame(width: 1),
                        alignment: .trailing
                    )

                ForEach(ticks, id: \.self) { tick in
                    let y = scale.yForBPM(tick, height: waveformHeight)
                    Text("\(Int(tick.rounded()))")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.75))
                        .position(x: 16, y: y)
                }
            }
            .frame(width: 34, height: waveformHeight)
            .allowsHitTesting(false)

            // Top-right floating toolbar pill
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    Text("TEMPO CURVE")
                        .font(.system(size: 9, weight: .black))
                        .foregroundColor(accentAmber)
                        .padding(.leading, 4)

                    HStack(spacing: 2) {
                        toolButton(label: "Pointer", icon: "cursorarrow", value: .pointer)
                        toolButton(label: "Draw", icon: "pencil.tip", value: .draw)
                    }
                    .padding(2)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(5)

                    Button(action: { snapToBeat.toggle() }) {
                        HStack(spacing: 3) {
                            Image(systemName: snapToBeat ? "magnet.fill" : "magnet")
                                .font(.system(size: 9.5, weight: .bold))
                            Text(snapToBeat ? "Beat Snap" : "Free")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(snapToBeat ? .black : Color(white: 0.78))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(snapToBeat ? accentAmber : Color.white.opacity(0.08))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help("Snap nodes to beat grid (hold Option for free placement)")

                    if !engine.currentSong.tempoEvents.isEmpty {
                        Button(action: { engine.clearAllTempoEvents() }) {
                            Text("Clear")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.45))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.06))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: { engine.setTempoCurveEditing(false) }) {
                        Text("Done")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(accentAmber)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(red: 0.11, green: 0.12, blue: 0.14).opacity(0.95))
                .cornerRadius(7)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(accentAmber.opacity(0.45), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.6), radius: 5)
            }
            .padding(.top, 8)
            .padding(.trailing, 10)
        }
    }

    private func toolButton(label: String, icon: String, value: TempoCurveTool) -> some View {
        let isSelected = tool == value
        return Button(action: { tool = value }) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .bold))
                Text(label)
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundColor(isSelected ? .black : Color(white: 0.78))
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(isSelected ? accentAmber : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}

private struct TempoPopoverHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Pill-anchored editor popover for inspecting, retargeting, converting, or deleting a TempoChangeEvent.
struct TempoChangeEditorPopover: View {
    let event: TempoChangeEvent
    let activeStartBPM: Double
    let currentPlayheadDisplayTime: TimeInterval
    let onSetEndAtPlayhead: () -> TimeInterval
    let onOpenWaveformCurve: () -> Void
    let onUpdate: (TempoChangeEvent) -> Void
    let onDelete: () -> Void
    let onContentHeightChange: ((CGFloat) -> Void)?

    @State private var isRamp: Bool
    @State private var bpmText: String
    @State private var targetBPM: Double
    @State private var spanMode: TempoRampSpanMode
    @State private var rampBeats: Double
    @State private var endAudioTime: TimeInterval
    @State private var lockBeatCountToAudioEnd: Bool
    @State private var curve: TempoCurveType

    private let accentAmber = Color(red: 0.98, green: 0.68, blue: 0.18)

    init(
        event: TempoChangeEvent,
        activeStartBPM: Double,
        currentPlayheadDisplayTime: TimeInterval,
        onSetEndAtPlayhead: @escaping () -> TimeInterval,
        onOpenWaveformCurve: @escaping () -> Void,
        onUpdate: @escaping (TempoChangeEvent) -> Void,
        onDelete: @escaping () -> Void,
        onContentHeightChange: ((CGFloat) -> Void)? = nil
    ) {
        self.event = event
        self.activeStartBPM = activeStartBPM
        self.currentPlayheadDisplayTime = currentPlayheadDisplayTime
        self.onSetEndAtPlayhead = onSetEndAtPlayhead
        self.onOpenWaveformCurve = onOpenWaveformCurve
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self.onContentHeightChange = onContentHeightChange

        _isRamp = State(initialValue: event.isRamp)
        _targetBPM = State(initialValue: event.targetBPM)
        _bpmText = State(initialValue: Song.formatBPM(event.targetBPM, decimals: Song.tempoDecimalPrecision(for: event.targetBPM)))
        _spanMode = State(initialValue: event.spanMode)
        _rampBeats = State(initialValue: event.rampBeats ?? 8.0)
        _endAudioTime = State(initialValue: event.endAudioTime ?? (event.audioTime + 4.0))
        _lockBeatCountToAudioEnd = State(initialValue: event.lockBeatCountToAudioEnd)
        _curve = State(initialValue: event.curve)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Edit Tempo Change")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Text("From \(Song.formatBPM(activeStartBPM, decimals: 1))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
            }

            // Instant vs Ramp Mode Switcher
            HStack(spacing: 4) {
                modeChip("Instant", selected: !isRamp) { isRamp = false }
                modeChip("Ramp (Rit / Acc)", selected: isRamp) { isRamp = true }
            }

            // Target BPM row
            HStack(spacing: 8) {
                Text("Target BPM")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(white: 0.75))
                Spacer()
                TextField("BPM", text: $bpmText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(accentAmber)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(white: 0.18))
                    .cornerRadius(4)
                    .onChange(of: bpmText) { newVal in
                        if let parsed = Double(newVal), parsed >= 20.0, parsed <= 300.0 {
                            targetBPM = parsed
                        }
                    }
                Stepper("", value: Binding(
                    get: { targetBPM },
                    set: { val in
                        let c = max(20.0, min(300.0, val))
                        targetBPM = c
                        bpmText = Song.formatBPM(c, decimals: Song.tempoDecimalPrecision(for: c))
                    }
                ), in: 20...300, step: 1)
                .labelsHidden()
            }

            if isRamp {
                Divider().background(Color(white: 0.22))

                // Span Mode
                HStack(spacing: 4) {
                    modeChip("Bars / Beats", selected: spanMode == .barsBeats && curve != .custom) {
                        spanMode = .barsBeats
                        if curve == .custom { curve = .easeIn }
                    }
                    modeChip("Audio End", selected: spanMode == .audioAnchor || curve == .custom) {
                        spanMode = .audioAnchor
                    }
                }

                if spanMode == .barsBeats && curve != .custom {
                    HStack {
                        Text("Beats in Ramp")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(white: 0.75))
                        Spacer()
                        Stepper(String(format: "%.1f beats", rampBeats), value: $rampBeats, in: 1...64, step: 1)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(String(format: "End: %.2fs", endAudioTime))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(Color(white: 0.85))
                            Spacer()
                            Button("Set End at Playhead") {
                                let src = onSetEndAtPlayhead()
                                endAudioTime = max(event.audioTime + 0.15, src)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        if curve != .custom {
                            Toggle("Lock Beats to Audio End", isOn: $lockBeatCountToAudioEnd)
                                .toggleStyle(SwitchToggleStyle(tint: accentAmber))
                                .font(.system(size: 10.5, weight: .medium))

                            if lockBeatCountToAudioEnd {
                                HStack {
                                    Text("Beats")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(Color(white: 0.75))
                                    Spacer()
                                    Stepper(String(format: "%.0f beats", rampBeats), value: $rampBeats, in: 1...64, step: 1)
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                }
                            }
                        }
                    }
                }

                // Curve Selector
                VStack(alignment: .leading, spacing: 4) {
                    Text("Curve")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(white: 0.55))
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            curveChip(.linear)
                            curveChip(.easeIn)
                            curveChip(.easeOut)
                        }
                        HStack(spacing: 4) {
                            curveChip(.sCurve)
                            curveChip(.custom)
                        }
                    }
                }
            }

            Button(action: {
                saveAndClose()
                onOpenWaveformCurve()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 11, weight: .bold))
                    Text("Draw / Edit on Waveform")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundColor(accentAmber)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(accentAmber.opacity(0.14))
                .cornerRadius(5)
            }
            .buttonStyle(.plain)

            HStack {
                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save") { saveAndClose() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: TempoPopoverHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(TempoPopoverHeightKey.self) { height in
            if height > 10 {
                onContentHeightChange?(height)
            }
        }
        .background(Color(red: 0.12, green: 0.13, blue: 0.15).ignoresSafeArea())
    }

    private func curveChip(_ c: TempoCurveType) -> some View {
        let selected = curve == c
        return Button(action: {
            curve = c
            if c == .custom {
                spanMode = .audioAnchor
                lockBeatCountToAudioEnd = false
            }
        }) {
            Text(c.rawValue)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(selected ? .black : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(selected ? accentAmber : Color(white: 0.18))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    private func modeChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundColor(selected ? .black : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(selected ? accentAmber : Color(white: 0.18))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    private func saveAndClose() {
        var updated = event
        updated.isRamp = isRamp
        updated.targetBPM = max(20.0, min(300.0, Double(bpmText) ?? targetBPM))
        updated.spanMode = (isRamp && curve == .custom) ? .audioAnchor : spanMode
        updated.rampBeats = isRamp ? max(0.5, rampBeats) : nil
        updated.endAudioTime = (isRamp && updated.spanMode == .audioAnchor) ? max(event.audioTime + 0.15, endAudioTime) : nil
        updated.lockBeatCountToAudioEnd = isRamp && updated.spanMode == .audioAnchor && curve != .custom && lockBeatCountToAudioEnd
        updated.curve = isRamp ? curve : .linear
        onUpdate(updated)
    }
}
