import Foundation

/// Freies Verziehen einer Ebene: Versatz der vier Ecken, jede unabhängig.
///
/// Bewusst **neben** `Transform2D` und nicht darin. `Transform2D` beschreibt
/// eine Ähnlichkeitsabbildung — Position, Skalierung, Drehung —, und darauf
/// bauen Trefferprüfung, Griffpunkte, Ausrichtungshilfen und beide
/// Rendering-Wege auf. Ein verzogenes Viereck ist dagegen eine projektive
/// Abbildung; beides in einen Typ zu zwingen würde jede dieser Rechnungen
/// verkomplizieren, obwohl die allermeisten Ebenen nie verzogen werden.
///
/// Der Versatz gilt im **ungedrehten Inhaltsmass** der Ebene, nicht in
/// Leinwandpunkten: So fühlt sich das Ziehen an einer gedrehten Ebene entlang
/// ihrer eigenen Achsen an, und die Verzerrung bleibt beim Skalieren und
/// Drehen erhalten — dieselbe Festlegung wie beim Skalieren mit den Griffen.
public struct QuadDistortion: Codable, Equatable, Sendable {
    public var topLeft: Point
    public var topRight: Point
    public var bottomRight: Point
    public var bottomLeft: Point

    public init(
        topLeft: Point = .zero,
        topRight: Point = .zero,
        bottomRight: Point = .zero,
        bottomLeft: Point = .zero
    ) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// Keine Verzerrung — die Ebene bleibt ein Rechteck.
    public static let identity = QuadDistortion()

    /// Wird beim Sichern geprüft: Eine unverzerrte Ebene soll gar keine
    /// Verzerrung speichern. Das hält die document.json schlank und macht
    /// „unverzerrt" eindeutig erkennbar.
    public var isIdentity: Bool { self == .identity }

    /// Die vier Versätze in der Reihenfolge, in der `corners` sie erwartet:
    /// im Uhrzeigersinn ab oben links.
    var offsetsClockwise: [Point] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// Verschiebt eine einzelne Ecke. Wird vom Verziehen-Werkzeug gebraucht.
    public func moving(_ corner: QuadCorner, by delta: Point) -> QuadDistortion {
        var kopie = self
        switch corner {
        case .topLeft: kopie.topLeft = Point(x: topLeft.x + delta.x, y: topLeft.y + delta.y)
        case .topRight: kopie.topRight = Point(x: topRight.x + delta.x, y: topRight.y + delta.y)
        case .bottomRight: kopie.bottomRight = Point(x: bottomRight.x + delta.x, y: bottomRight.y + delta.y)
        case .bottomLeft: kopie.bottomLeft = Point(x: bottomLeft.x + delta.x, y: bottomLeft.y + delta.y)
        }
        return kopie
    }

    /// Verschiebt **alle** Ecken gleich — die Verzerrung bleibt in ihrer Form
    /// erhalten. Das ist gemeint mit „mit gedrückter Wahltaste verzieht sich
    /// alles proportional".
    public func movingAll(by delta: Point) -> QuadDistortion {
        QuadCorner.allCases.reduce(self) { $0.moving($1, by: delta) }
    }
}

/// Die vier Ecken, im Uhrzeigersinn ab oben links — dieselbe Reihenfolge wie
/// bei `Transform2D.corners(contentSize:)`.
public enum QuadCorner: CaseIterable, Sendable {
    case topLeft, topRight, bottomRight, bottomLeft

    /// Anteilige Lage im Rahmen: -1 links/oben, 1 rechts/unten.
    var unitOffset: (x: Double, y: Double) {
        switch self {
        case .topLeft: return (-1, -1)
        case .topRight: return (1, -1)
        case .bottomRight: return (1, 1)
        case .bottomLeft: return (-1, 1)
        }
    }
}

extension Transform2D {

    /// Die vier Eckpunkte auf der Leinwand, mit Verzerrung.
    ///
    /// Ohne Verzerrung (oder mit `.identity`) liefert das exakt dasselbe wie
    /// `corners(contentSize:)` — sonst würde allein das Einschalten des
    /// Werkzeugs die Ebene verschieben.
    public func corners(contentSize: Size, distortion: QuadDistortion?) -> [Point] {
        guard let distortion, !distortion.isIdentity else {
            return corners(contentSize: contentSize)
        }

        let halfWidth = contentSize.width * abs(scaleX) / 2
        let halfHeight = contentSize.height * abs(scaleY) / 2

        return zip(QuadCorner.allCases, distortion.offsetsClockwise).map { ecke, versatz in
            let einheit = ecke.unitOffset
            // Der Versatz ist im Inhaltsmass angegeben und wird deshalb
            // mitskaliert — eine doppelt so grosse Ebene ist auch doppelt so
            // stark verzogen.
            return pointOnCanvas(Point(
                x: einheit.x * halfWidth + versatz.x * abs(scaleX),
                y: einheit.y * halfHeight + versatz.y * abs(scaleY)
            ))
        }
    }

    /// Trefferprüfung für eine verzogene Ebene.
    public func contains(_ point: Point, contentSize: Size, distortion: QuadDistortion?) -> Bool {
        guard let distortion, !distortion.isIdentity else {
            return contains(point, contentSize: contentSize)
        }
        return Geometry.quadContains(corners(contentSize: contentSize, distortion: distortion), point)
    }

    /// Achsenparallele Umschliessende einer verzogenen Ebene — die
    /// Ausrichtungshilfen rechnen damit.
    public func boundingFrame(contentSize: Size, distortion: QuadDistortion?) -> Rect {
        guard let distortion, !distortion.isIdentity else {
            return boundingFrame(contentSize: contentSize)
        }

        let ecken = corners(contentSize: contentSize, distortion: distortion)
        let xs = ecken.map(\.x)
        let ys = ecken.map(\.y)
        let minX = xs.min() ?? x
        let minY = ys.min() ?? y
        return Rect(
            x: minX,
            y: minY,
            width: (xs.max() ?? x) - minX,
            height: (ys.max() ?? y) - minY
        )
    }
}

enum Geometry {

    /// Liegt der Punkt im Viereck?
    ///
    /// Zerlegt in zwei Dreiecke statt über Winkelsummen: Das kommt ohne
    /// trigonometrische Funktionen aus und bleibt auch bei einem
    /// überschlagenen Viereck endlich — beim Verziehen kann man die Ecken
    /// über Kreuz ziehen, und dann darf die App nicht hängen.
    static func quadContains(_ corners: [Point], _ point: Point) -> Bool {
        guard corners.count == 4 else { return false }
        return triangleContains(corners[0], corners[1], corners[2], point)
            || triangleContains(corners[0], corners[2], corners[3], point)
    }

    private static func triangleContains(_ a: Point, _ b: Point, _ c: Point, _ p: Point) -> Bool {
        let d1 = cross(a, b, p)
        let d2 = cross(b, c, p)
        let d3 = cross(c, a, p)

        // Gemischte Vorzeichen heissen: ausserhalb. Nullen (genau auf einer
        // Kante) zählen als innerhalb, damit die Kante selbst noch trifft.
        let negativ = d1 < 0 || d2 < 0 || d3 < 0
        let positiv = d1 > 0 || d2 > 0 || d3 > 0
        return !(negativ && positiv)
    }

    private static func cross(_ a: Point, _ b: Point, _ p: Point) -> Double {
        (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
    }
}
