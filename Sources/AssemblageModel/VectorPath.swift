import Foundation

/// Ein Ankerpunkt eines Pfades samt seinen beiden Kurvengriffen.
///
/// Beide Griffe stehen in **absoluten** Koordinaten, nicht als Abstand zum
/// Anker — das entspricht der SVG-Sicht und erspart beim Zeichnen jedes Mal
/// eine Umrechnung. Ein Eckpunkt ohne Kurvenwirkung wird dadurch ausgedrückt,
/// dass ein Griff auf dem Anker selbst liegt; es gibt bewusst keine Optionals,
/// damit jede Pfadstelle gleich behandelt werden kann.
///
/// Übernommen aus dem Schwesterprojekt Sceau, dort dasselbe Modell.
public struct PathAnchor: Codable, Equatable, Sendable {
    public var point: Point
    /// Griff in Richtung des *vorhergehenden* Segments.
    public var controlIn: Point
    /// Griff in Richtung des *nachfolgenden* Segments.
    public var controlOut: Point

    public init(point: Point, controlIn: Point, controlOut: Point) {
        self.point = point
        self.controlIn = controlIn
        self.controlOut = controlOut
    }

    /// Ein Eckpunkt: Beide Griffe liegen auf dem Anker, die Segmente zu den
    /// Nachbarn sind damit exakt gerade.
    public init(corner point: Point) {
        self.init(point: point, controlIn: point, controlOut: point)
    }

    public func moved(by dx: Double, _ dy: Double) -> PathAnchor {
        PathAnchor(
            point: Point(x: point.x + dx, y: point.y + dy),
            controlIn: Point(x: controlIn.x + dx, y: controlIn.y + dy),
            controlOut: Point(x: controlOut.x + dx, y: controlOut.y + dy)
        )
    }

    public func scaled(by sx: Double, _ sy: Double) -> PathAnchor {
        PathAnchor(
            point: Point(x: point.x * sx, y: point.y * sy),
            controlIn: Point(x: controlIn.x * sx, y: controlIn.y * sy),
            controlOut: Point(x: controlOut.x * sx, y: controlOut.y * sy)
        )
    }
}

/// Ein zusammenhängender Teilpfad aus Ankerpunkten, offen oder geschlossen.
public struct PathSubpath: Codable, Equatable, Sendable {
    public var anchors: [PathAnchor]
    public var isClosed: Bool

    public init(anchors: [PathAnchor], isClosed: Bool = false) {
        self.anchors = anchors
        self.isClosed = isClosed
    }
}

/// Die gespeicherte Vektorform eines gezeichneten Zuges.
///
/// Bewusst **kein** `CGPath`: Der ist unveränderlich und gibt einzelne
/// Ankerpunkte nicht wieder her. Aus dieser Darstellung wird beim Zeichnen ein
/// `CGPath` gebaut — und nur dort, damit das Modell frei von Core Graphics
/// bleibt und sich unverändert sichern lässt.
public struct VectorPath: Codable, Equatable, Sendable {
    public var subpaths: [PathSubpath]

    public init(subpaths: [PathSubpath] = []) {
        self.subpaths = subpaths
    }

    public init(subpath: PathSubpath) {
        self.init(subpaths: [subpath])
    }

    public var isEmpty: Bool {
        subpaths.allSatisfy { $0.anchors.isEmpty }
    }

    /// Der Hüllrahmen über alle Anker **und** Griffe.
    ///
    /// Bewusst die Griffe mit einbezogen: Sie sind zwar nicht Teil der Kurve,
    /// liegen aber nie weiter aussen als deren Ausbuchtung. Der Rahmen ist
    /// damit garantiert gross genug — der exakte Kurvenrahmen wäre teurer zu
    /// rechnen und würde hier nichts verbessern.
    public var boundingBox: Rect? {
        let punkte = subpaths.flatMap(\.anchors).flatMap { [$0.point, $0.controlIn, $0.controlOut] }
        guard let erste = punkte.first else { return nil }

        var minX = erste.x, maxX = erste.x
        var minY = erste.y, maxY = erste.y
        for punkt in punkte.dropFirst() {
            minX = min(minX, punkt.x); maxX = max(maxX, punkt.x)
            minY = min(minY, punkt.y); maxY = max(maxY, punkt.y)
        }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Verschiebt den Pfad so, dass sein Hüllrahmen bei (0, 0) beginnt, und
    /// liefert dazu die Grösse dieses Rahmens.
    ///
    /// Eine Formebene führt ihre Lage in `Transform2D` und ihre Ausdehnung in
    /// `size`; der Pfad selbst muss deshalb im eigenen Rechteck sitzen und
    /// nicht in Leinwandkoordinaten. Ohne diese Normalisierung wäre ein Zug
    /// doppelt verschoben — einmal durch seine Punkte, einmal durch die Ebene.
    public func normalized() -> (path: VectorPath, size: Size) {
        guard let rahmen = boundingBox else { return (self, Size(width: 0, height: 0)) }
        let verschoben = VectorPath(subpaths: subpaths.map { teil in
            PathSubpath(
                anchors: teil.anchors.map { $0.moved(by: -rahmen.x, -rahmen.y) },
                isClosed: teil.isClosed
            )
        })
        return (verschoben, Size(width: rahmen.width, height: rahmen.height))
    }
}
