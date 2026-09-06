import Foundation

/// Baut aus einer grob abgetasteten Mauszug-Punktfolge (viele, dicht liegende
/// Punkte) einen geglätteten, offenen Bézier-Pfad.
///
/// Zwei Schritte, wie beim Freihandzeichnen üblich:
/// 1. **Vereinfachen** (Douglas-Peucker): unnötige, fast auf der Linie
///    liegende Zwischenpunkte verwerfen — sonst hätte jeder Strich Hunderte
///    Anker und liesse sich später kaum noch von Hand nachbearbeiten.
/// 2. **Glätten** (Catmull-Rom → kubische Bézier): aus den verbliebenen
///    Punkten eine durch alle Punkte laufende, weiche Kurve statt eines
///    kantigen Polyzugs bauen.
///
/// Übernommen aus dem Schwesterprojekt Sceau (`SceauCore/Geometry/FreehandStroke`),
/// auf das Punktmodell dieses Projekts übertragen. Reine Kerngeometrie.
public enum FreehandStroke {

    /// Deckel gegen eine ausufernde Punktzahl bei einer sehr langen oder sehr
    /// langsamen Zugbewegung (jedes `mouseDragged` fügt einen Punkt hinzu) —
    /// ohne ihn würde Douglas-Peucker auf Zehntausenden Punkten rechnen und
    /// die Zeichenfläche beim Loslassen kurz einfrieren.
    public static let maxInputPoints = 4000

    /// Baut den geglätteten Pfad. `smoothingTolerance` ist der maximale
    /// Abstand (in Dokumentpunkten), den ein verworfener Zwischenpunkt von
    /// der vereinfachten Linie haben darf — 0 behält jeden Punkt.
    public static func path(from rawPoints: [Point], smoothingTolerance: Double = 1.2) -> VectorPath {
        let points = downsampled(rawPoints)

        guard points.count >= 2 else {
            if let only = points.first {
                // Ein Tupfer (Klick ohne Zugbewegung): ein winziges, aber
                // sichtbares Liniensegment statt eines leeren, unsichtbaren
                // Pfads — sonst verschwindet ein einfacher Klick spurlos.
                let epsilon = 0.01
                let a = PathAnchor(corner: Point(x: only.x - epsilon, y: only.y))
                let b = PathAnchor(corner: Point(x: only.x + epsilon, y: only.y))
                return VectorPath(subpath: PathSubpath(anchors: [a, b]))
            }
            return VectorPath()
        }

        let simplified = douglasPeucker(points, tolerance: max(0, smoothingTolerance))
        return VectorPath(subpath: catmullRomSubpath(simplified))
    }

    /// Reduziert eine zu lange Rohpunktfolge gleichmässig auf ``maxInputPoints``,
    /// bevor überhaupt vereinfacht wird — Anfang und Ende bleiben erhalten.
    private static func downsampled(_ points: [Point]) -> [Point] {
        guard points.count > maxInputPoints else { return points }
        let schritt = Double(points.count) / Double(maxInputPoints)
        var result: [Point] = []
        result.reserveCapacity(maxInputPoints)
        var index = 0.0
        while index < Double(points.count) {
            result.append(points[Int(index)])
            index += schritt
        }
        if result.last != points.last { result.append(points[points.count - 1]) }
        return result
    }

    // MARK: - Douglas-Peucker

    /// Iterativ statt rekursiv: Bei fast geradlinigen, aber leicht
    /// verrauschten Eingaben (typisch für eine echte Mauszugbewegung) kann die
    /// Rekursion im ungünstigsten Fall bis zur vollen Punktzahl tief werden —
    /// bei mehreren tausend Punkten reicht das, um den Stack zum Überlaufen zu
    /// bringen. Ein eigenes Arbeits-Array auf dem Heap kennt diese Grenze nicht.
    private static func douglasPeucker(_ points: [Point], tolerance: Double) -> [Point] {
        guard points.count > 2, tolerance > 0 else { return points }

        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true

        var workStack: [(start: Int, end: Int)] = [(0, points.count - 1)]
        while let (start, end) = workStack.popLast() {
            guard end > start + 1 else { continue }

            var groessterAbstand = 0.0
            var index = start
            for i in (start + 1)..<end {
                let abstand = perpendicularDistance(
                    points[i], lineStart: points[start], lineEnd: points[end]
                )
                if abstand > groessterAbstand {
                    groessterAbstand = abstand
                    index = i
                }
            }

            guard groessterAbstand > tolerance else { continue }
            keep[index] = true
            workStack.append((start, index))
            workStack.append((index, end))
        }

        return points.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    private static func perpendicularDistance(
        _ point: Point, lineStart: Point, lineEnd: Point
    ) -> Double {
        let dx = lineEnd.x - lineStart.x
        let dy = lineEnd.y - lineStart.y
        let laengeQuadrat = dx * dx + dy * dy

        guard laengeQuadrat > 0 else {
            // Entartete „Linie" (Start == Ende): der Abstand zum Punkt selbst.
            let ddx = point.x - lineStart.x
            let ddy = point.y - lineStart.y
            return (ddx * ddx + ddy * ddy).squareRoot()
        }

        // Fläche des von den drei Punkten aufgespannten Parallelogramms
        // (Kreuzprodukt), geteilt durch die Grundlinienlänge — die klassische
        // Punkt-zu-Gerade-Abstandsformel ohne Fallunterscheidung.
        let kreuz = abs(dx * (lineStart.y - point.y) - dy * (lineStart.x - point.x))
        return kreuz / laengeQuadrat.squareRoot()
    }

    // MARK: - Catmull-Rom → kubische Bézier

    private static func catmullRomSubpath(_ points: [Point]) -> PathSubpath {
        guard points.count > 2 else {
            // Zwei Punkte oder weniger: eine gerade Strecke, für die eine
            // Catmull-Rom-Krümmung ohnehin nichts beizutragen hätte.
            return PathSubpath(anchors: points.map(PathAnchor.init(corner:)))
        }

        var anchors: [PathAnchor] = []
        anchors.reserveCapacity(points.count)

        for index in points.indices {
            // Offene Kurve: An den Enden wird der fehlende Nachbarpunkt durch
            // eine Spiegelung des jeweils übernächsten ersetzt (Standardtrick
            // für Catmull-Rom an offenen Rändern), statt die Kurve dort
            // künstlich zu schliessen.
            let p0 = index > 0 ? points[index - 1] : mirrored(points[1], around: points[0])
            let p1 = points[index]
            let p2 = index < points.count - 1
                ? points[index + 1]
                : mirrored(points[points.count - 2], around: points[points.count - 1])

            // Standard-Umrechnung Catmull-Rom → Bézier-Griffe für den Anker an
            // `p1`: Beide Griffe zeigen entlang der Verbindung seiner Nachbarn,
            // ein Sechstel dieser Strecke lang.
            let controlIn = Point(x: p1.x - (p2.x - p0.x) / 6, y: p1.y - (p2.y - p0.y) / 6)
            let controlOut = Point(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)

            anchors.append(PathAnchor(
                point: p1,
                controlIn: index == 0 ? p1 : controlIn,
                controlOut: index == points.count - 1 ? p1 : controlOut
            ))
        }

        return PathSubpath(anchors: anchors)
    }

    private static func mirrored(_ point: Point, around center: Point) -> Point {
        Point(x: 2 * center.x - point.x, y: 2 * center.y - point.y)
    }
}
