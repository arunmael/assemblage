import Foundation

// Ausrichtungshilfen ("Smart Guides") aus Plan 5.3: Zentrieren, gleicher Abstand,
// Kantenausrichtung zu anderen Ebenen.
//
// Bewusst hier im portablen Modell statt in AssemblageKit: Es ist reine Geometrie
// auf `Rect`/`CanvasSize`, braucht kein AppKit und kann so in der Linux-CI mitlaufen.
//
// Rotation: `Rect` ist achsenparallel. Diese Datei rechnet ausschliesslich mit
// achsenparallelen Rechtecken und kennt keine Rotation. Für rotierte Ebenen muss
// der Aufrufer die achsenparallele Umschliessende (Bounding Box) der gedrehten
// Ebene übergeben, nicht deren gedrehten Umriss — ein Einrasten an den tatsächlich
// gedrehten Kanten ist bewusst nicht Teil dieser Funktion (das wäre ein eigenes,
// deutlich komplexeres Feature).
//
// Fangdistanz/Zoom: Der Parameter `snapDistance` ist ein reiner Wert in Canvas-Punkten.
// Beim Zoomen muss der Aufrufer ihn selbst durch die Zoomstufe teilen (z. B.
// `basisFangdistanz / zoomFaktor`), damit die gefühlte Fangdistanz auf dem Bildschirm
// bei jeder Zoomstufe gleich bleibt. Diese Datei weiss nichts von Zoom.

/// Ausrichtung einer Hilfslinie: senkrecht markiert eine x-Position (Kanten-/Mittel-
/// abgleich entlang der Breite), waagrecht eine y-Position (entlang der Höhe).
public enum GuideOrientation: Equatable, Sendable {
    case vertical
    case horizontal
}

/// Eine einzelne Hilfslinie, wie sie der Canvas zum Zeichnen braucht.
///
/// `start`/`end` sind die Ausdehnung der Linie auf der jeweils anderen Achse
/// (bei `.vertical` also ein y-Bereich, bei `.horizontal` ein x-Bereich) — die
/// Linie verbindet die beteiligten Ebenen, statt über die ganze Leinwand zu laufen.
public struct AlignmentGuideLine: Equatable, Sendable {
    public let orientation: GuideOrientation
    public let position: Double
    public let start: Double
    public let end: Double

    public init(orientation: GuideOrientation, position: Double, start: Double, end: Double) {
        self.orientation = orientation
        self.position = position
        self.start = start
        self.end = end
    }
}

/// Ergebnis eines Einrastversuchs: Versatz getrennt nach Achse (kann in x einrasten,
/// in y nicht, oder umgekehrt) sowie die dabei anzuzeigenden Hilfslinien.
public struct AlignmentSnapResult: Equatable, Sendable {
    public let offsetX: Double
    public let offsetY: Double
    public let lines: [AlignmentGuideLine]

    public init(offsetX: Double, offsetY: Double, lines: [AlignmentGuideLine]) {
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.lines = lines
    }

    /// Nichts rastet ein: Versatz null, keine Linien — nie "irgendwas Naheliegendes".
    public static let none = AlignmentSnapResult(offsetX: 0, offsetY: 0, lines: [])
}

/// Reine Funktion, kein Zustand: Ergebnis hängt nur von den Argumenten ab, nichts
/// wird über Aufrufe hinweg gemerkt (die Funktion läuft bei jeder Mausbewegung).
public enum AlignmentGuides {

    /// Berechnet den Versatz, um den `draggedFrame` einrasten soll, sowie die dabei
    /// zu zeichnenden Hilfslinien.
    ///
    /// - Parameters:
    ///   - draggedFrame: Achsenparalleler Rahmen der gerade gezogenen Ebene.
    ///   - otherFrames: Rahmen aller übrigen Ebenen (Reihenfolge ist egal — das
    ///     Ergebnis ist unabhängig davon, siehe Rangfolge unten).
    ///   - canvasSize: Grösse der Leinwand.
    ///   - snapDistance: Fangdistanz in Canvas-Punkten (Vorgabe 8pt, siehe Kommentar
    ///     oben zu Zoom).
    public static func snap(
        draggedFrame: Rect,
        otherFrames: [Rect],
        canvasSize: CanvasSize,
        snapDistance: Double = 8
    ) -> AlignmentSnapResult {
        let x = bestCandidate(
            from: axisCandidates(draggedFrame: draggedFrame, otherFrames: otherFrames, canvasSize: canvasSize, axis: .x),
            threshold: snapDistance
        )
        let y = bestCandidate(
            from: axisCandidates(draggedFrame: draggedFrame, otherFrames: otherFrames, canvasSize: canvasSize, axis: .y),
            threshold: snapDistance
        )

        var lines: [AlignmentGuideLine] = []
        if let x { lines.append(contentsOf: x.lines) }
        if let y { lines.append(contentsOf: y.lines) }

        return AlignmentSnapResult(offsetX: x?.offset ?? 0, offsetY: y?.offset ?? 0, lines: lines)
    }

    // MARK: - Rangfolge

    /// Rangfolge, nach der bei mehreren *gleich guten* Kandidaten (identischer
    /// Versatzbetrag) entschieden wird — die Hauptregel ist immer "der nächstliegende
    /// Kandidat gewinnt" (siehe `bestCandidate`); diese Rangfolge ist nur der
    /// Tiebreaker, wenn zwei Kandidaten exakt denselben Versatz ergeben:
    ///
    /// 1. Leinwand-Mitte — die Leinwand ist die einzige Referenz, die nicht vom
    ///    zufälligen Ebeneninhalt abhängt, und "auf der Seite zentrieren" ist die
    ///    bewussteste aller Positionierungsabsichten.
    /// 2. Leinwand-Kante — ebenfalls von der Leinwand, aber weniger absichtsvoll
    ///    als exakte Zentrierung.
    /// 3. Mitte einer anderen Ebene — eine zentrierte Beziehung zu einem Geschwister-
    ///    Objekt ist visuell auffälliger als eine reine Kantenberührung.
    /// 4. Kante einer anderen Ebene — Standardfall des bündigen Ausrichtens.
    /// 5. Gleicher Abstand — hängt von mindestens zwei anderen Ebenen ab und ist
    ///    damit der am wenigsten "absichtliche", am ehesten zufällige Treffer.
    private enum GuidePriority: Int, Comparable {
        case canvasCenter = 0
        case canvasEdge = 1
        case layerCenter = 2
        case layerEdge = 3
        case distribution = 4

        static func < (lhs: GuidePriority, rhs: GuidePriority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    fileprivate enum Axis {
        case x
        case y
    }

    private struct Candidate {
        let offset: Double
        let priority: GuidePriority
        /// Nur für den deterministischen Tiebreak gedacht, siehe `sortKey`.
        let referencePosition: Double
        let lines: [AlignmentGuideLine]

        /// Deckt den seltenen Fall ab, dass zwei Kandidaten in Versatz *und* Rangfolge
        /// gleichauf liegen (z. B. zwei verschiedene Ebenen mit exakt derselben linken
        /// Kante). Dann ist das Ergebnis inhaltlich ohnehin identisch (gleiche Position,
        /// gleiche Linie) — dieser Schlüssel sorgt nur dafür, dass `min(by:)` nicht von
        /// der zufälligen Reihenfolge im `otherFrames`-Array abhängt, sondern von den
        /// Werten selbst.
        var sortKey: String {
            let lineKey = lines
                .map { "\($0.orientation)-\($0.position)-\($0.start)-\($0.end)" }
                .joined(separator: ",")
            return "\(referencePosition)|\(lineKey)"
        }
    }

    /// Wählt aus den (bereits auf die Fangdistanz gefilterten) Kandidaten den besten:
    /// zuerst der kleinste Versatzbetrag (das "nächstliegende" Einrasten — alles
    /// andere wäre überraschend), erst bei Gleichstand die Rangfolge oben, zuletzt
    /// der reine Wertevergleich für volle Determinismus-Garantie.
    private static func bestCandidate(from candidates: [Candidate], threshold: Double) -> Candidate? {
        let eligible = candidates.filter { abs($0.offset) <= threshold }
        guard !eligible.isEmpty else { return nil }
        return eligible.min { lhs, rhs in
            if abs(lhs.offset) != abs(rhs.offset) { return abs(lhs.offset) < abs(rhs.offset) }
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.sortKey < rhs.sortKey
        }
    }

    // MARK: - Kandidaten pro Achse

    private static func axisCandidates(
        draggedFrame: Rect,
        otherFrames: [Rect],
        canvasSize: CanvasSize,
        axis: Axis
    ) -> [Candidate] {
        let dragged = draggedFrame.range(on: axis)
        let draggedOrth = draggedFrame.range(on: axis.orthogonal)

        var candidates: [Candidate] = []

        // Leinwand: Kanten und Mitte.
        let canvasRange = AxisRange(low: 0, high: canvasSize.length(on: axis))
        let canvasOrth = AxisRange(low: 0, high: canvasSize.length(on: axis.orthogonal))
        candidates += edgeAndCenterCandidates(
            dragged: dragged, draggedOrth: draggedOrth,
            reference: canvasRange, referenceOrth: canvasOrth,
            edgePriority: .canvasEdge, centerPriority: .canvasCenter,
            axis: axis
        )

        // Andere Ebenen: Kantenausrichtung (gleiche und gegenüberliegende Kante) und Zentrieren.
        for other in otherFrames {
            let otherRange = other.range(on: axis)
            let otherOrth = other.range(on: axis.orthogonal)
            candidates += edgeAndCenterCandidates(
                dragged: dragged, draggedOrth: draggedOrth,
                reference: otherRange, referenceOrth: otherOrth,
                edgePriority: .layerEdge, centerPriority: .layerCenter,
                axis: axis
            )
        }

        // Gleicher Abstand zwischen zwei benachbarten Ebenen in einer Reihe.
        candidates += distributionCandidates(draggedFrame: draggedFrame, otherFrames: otherFrames, axis: axis)

        return candidates
    }

    /// Erzeugt die Kandidaten für Kantenausrichtung (4 Kombinationen: gleiche Kante an
    /// gleiche Kante, Kante an gegenüberliegende Kante — "bündig anlegen") und Zentrieren
    /// (1 Kombination: Mitte an Mitte) zwischen der gezogenen Ebene und einer Referenz
    /// (andere Ebene oder Leinwand).
    ///
    /// `draggedOrth`/`referenceOrth` sind die Ausdehnung auf der jeweils anderen Achse —
    /// daraus ergibt sich die Ausdehnung der gezeichneten Linie: von der einen bis zur
    /// anderen beteiligten Ebene, nicht über die ganze Leinwand.
    private static func edgeAndCenterCandidates(
        dragged: AxisRange,
        draggedOrth: AxisRange,
        reference: AxisRange,
        referenceOrth: AxisRange,
        edgePriority: GuidePriority,
        centerPriority: GuidePriority,
        axis: Axis
    ) -> [Candidate] {
        let orientation: GuideOrientation = (axis == .x) ? .vertical : .horizontal
        let extentStart = min(draggedOrth.low, referenceOrth.low)
        let extentEnd = max(draggedOrth.high, referenceOrth.high)

        func line(at position: Double) -> AlignmentGuideLine {
            AlignmentGuideLine(orientation: orientation, position: position, start: extentStart, end: extentEnd)
        }

        var result: [Candidate] = []

        let edgePairs: [(Double, Double)] = [
            (dragged.low, reference.low),    // Kante an gleiche Kante (z. B. links an links)
            (dragged.low, reference.high),   // Kante an gegenüberliegende Kante (bündig anlegen)
            (dragged.high, reference.low),
            (dragged.high, reference.high)
        ]
        for (draggedValue, referenceValue) in edgePairs {
            let offset = referenceValue - draggedValue
            result.append(Candidate(
                offset: offset,
                priority: edgePriority,
                referencePosition: referenceValue,
                lines: [line(at: referenceValue)]
            ))
        }

        let centerOffset = reference.center - dragged.center
        result.append(Candidate(
            offset: centerOffset,
            priority: centerPriority,
            referencePosition: reference.center,
            lines: [line(at: reference.center)]
        ))

        return result
    }

    /// Gleicher Abstand: Rastet ein, wenn die gezogene Ebene zwischen zwei unmittelbar
    /// benachbarten Ebenen derselben Reihe liegen könnte, so dass die Lücke auf beiden
    /// Seiten gleich gross wird.
    ///
    /// "Reihe" heisst hier: Nur Ebenen, deren Ausdehnung auf der jeweils anderen Achse
    /// sich mit der gezogenen Ebene überschneidet, kommen überhaupt in Frage — sonst
    /// wäre ein gleicher "Abstand" geometrisch bedeutungslos (z. B. eine Ebene weit
    /// oberhalb und eine weit unterhalb hätten nichts mit einer waagrechten Reihe zu tun).
    ///
    /// "Unmittelbar benachbart" heisst: Von den in Frage kommenden Ebenen werden nur nach
    /// Position sortierte Nachbarpaare betrachtet, keine beliebigen Paare. Läge eine dritte
    /// Ebene zwischen L und R, würde ein Einrasten "zwischen L und R" die gezogene Ebene
    /// über diese dritte legen — das ist nicht gemeint mit "gleicher Abstand". Das hat
    /// ausserdem den Nebeneffekt, dass diese Funktion mit Sortieren bei O(n log n) bleibt
    /// statt bei O(n²) über alle Paare zu explodieren (wichtig, da sie bei jeder
    /// Mausbewegung läuft).
    private static func distributionCandidates(draggedFrame: Rect, otherFrames: [Rect], axis: Axis) -> [Candidate] {
        let orientation: GuideOrientation = (axis == .x) ? .vertical : .horizontal
        let dragged = draggedFrame.range(on: axis)
        let draggedOrth = draggedFrame.range(on: axis.orthogonal)
        let draggedLength = dragged.high - dragged.low

        let row = otherFrames
            .map { ($0.range(on: axis), $0.range(on: axis.orthogonal)) }
            .filter { _, orth in rangesOverlap(draggedOrth, orth) }
            .sorted { $0.0.low < $1.0.low }

        guard row.count >= 2 else { return [] }

        var candidates: [Candidate] = []
        for i in 0..<(row.count - 1) {
            let (left, leftOrth) = row[i]
            let (right, rightOrth) = row[i + 1]
            // Echte Lücke nötig (keine Überlappung) — sonst ist "L" und "R" keine reale
            // linke/rechte Nachbarschaft.
            guard left.high <= right.low else { continue }

            let gap = right.low - left.high
            let target = left.high + (gap - draggedLength) / 2
            let offset = target - dragged.low

            let extentStart = min(draggedOrth.low, min(leftOrth.low, rightOrth.low))
            let extentEnd = max(draggedOrth.high, max(leftOrth.high, rightOrth.high))

            candidates.append(Candidate(
                offset: offset,
                priority: .distribution,
                referencePosition: target,
                lines: [
                    AlignmentGuideLine(orientation: orientation, position: left.high, start: extentStart, end: extentEnd),
                    AlignmentGuideLine(orientation: orientation, position: right.low, start: extentStart, end: extentEnd)
                ]
            ))
        }
        return candidates
    }

    private static func rangesOverlap(_ a: AxisRange, _ b: AxisRange) -> Bool {
        max(a.low, b.low) <= min(a.high, b.high)
    }
}

// MARK: - Achsen-Hilfstypen

/// Ein 1D-Bereich auf einer Achse — hält die Kanten-/Zentrieren-Logik oben
/// unabhängig davon, ob gerade x oder y betrachtet wird.
fileprivate struct AxisRange {
    let low: Double
    let high: Double

    var center: Double { (low + high) / 2 }
}

private extension AlignmentGuides.Axis {
    var orthogonal: AlignmentGuides.Axis { self == .x ? .y : .x }
}

private extension Rect {
    // Normalisiert gegen Rects mit negativer Breite/Höhe, statt sich stillschweigend
    // darauf zu verlassen, dass `width`/`height` immer positiv sind.
    var minX: Double { min(x, x + width) }
    var maxX: Double { max(x, x + width) }
    var minY: Double { min(y, y + height) }
    var maxY: Double { max(y, y + height) }

    func range(on axis: AlignmentGuides.Axis) -> AxisRange {
        switch axis {
        case .x: return AxisRange(low: minX, high: maxX)
        case .y: return AxisRange(low: minY, high: maxY)
        }
    }
}

private extension CanvasSize {
    func length(on axis: AlignmentGuides.Axis) -> Double {
        switch axis {
        case .x: return width
        case .y: return height
        }
    }
}
