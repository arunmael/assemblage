import Foundation

/// Ein Punkt auf der Leinwand. Ursprung oben links, y wächst nach unten.
///
/// Bewusst eigene Struktur statt `CGPoint` — das Modell bleibt so
/// plattformunabhängig (siehe Package.swift).
public struct Point: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(x: 0, y: 0)
}

extension Transform2D {

    /// Liegt der Punkt auf der Ebene?
    ///
    /// Rechnet den Punkt in das Koordinatensystem der Ebene zurück, statt ihn
    /// mit dem achsenparallelen Rahmen zu vergleichen. Der Unterschied ist bei
    /// gedrehten Ebenen erheblich: Bei 45° gehört fast die Hälfte des
    /// umschliessenden Rechtecks gar nicht mehr zur Ebene, und ein Klick dort
    /// würde die falsche erwischen.
    public func contains(_ point: Point, contentSize: Size) -> Bool {
        let halfWidth = contentSize.width * abs(scaleX) / 2
        let halfHeight = contentSize.height * abs(scaleY) / 2

        // Eine Ebene ohne Ausdehnung kann nicht getroffen werden — und die
        // Rechnung unten wäre für sie ohnehin sinnlos.
        guard halfWidth > 0, halfHeight > 0 else { return false }

        let local = pointInLayerSpace(point)
        return abs(local.x) <= halfWidth && abs(local.y) <= halfHeight
    }

    /// Rechnet einen Leinwandpunkt in das (ungedrehte, aber skalierte)
    /// Koordinatensystem der Ebene um, Ursprung in deren Mittelpunkt.
    ///
    /// Gegenstück zur Matrix im Renderer: Dort wird gedreht, hier wird
    /// zurückgedreht. Beide müssen dieselbe Drehrichtung annehmen — positiv
    /// ist im Uhrzeigersinn, weil y nach unten wächst.
    public func pointInLayerSpace(_ point: Point) -> Point {
        let dx = point.x - x
        let dy = point.y - y

        let radians = rotationDegrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)

        return Point(
            x: dx * cosine + dy * sine,
            y: -dx * sine + dy * cosine
        )
    }
}

extension Document {

    /// Die oberste sichtbare Ebene unter dem Punkt — oder `nil`, wenn dort
    /// nichts liegt.
    ///
    /// `contentSize` wird hereingereicht, weil das Modell die Grösse einer
    /// Bild- oder Textebene nicht kennen kann: Sie steckt in der Bilddatei
    /// bzw. im Textsatz, also in AppKit-Gebiet.
    public func topmostLayer(at point: Point, contentSize: (Layer) -> Size) -> Layer? {
        // Von oben nach unten suchen: Index 0 liegt zuunterst, also rückwärts.
        layers.reversed().first { layer in
            // Unsichtbare Ebenen sind nicht anklickbar — man sieht sie nicht,
            // und ein Klick, der etwas Unsichtbares auswählt, wirkt wie ein
            // Fehler der App.
            layer.isVisible && layer.transform.contains(point, contentSize: contentSize(layer))
        }
    }
}

extension Transform2D {

    /// Die vier Eckpunkte der Ebene auf der Leinwand, im Uhrzeigersinn ab
    /// oben links.
    ///
    /// Gegenstück zu `pointInLayerSpace(_:)`: dieselbe Drehung, nur in die
    /// andere Richtung. Beide müssen zusammenpassen, sonst zeigt der
    /// Auswahlrahmen woandershin als der Klick trifft.
    public func corners(contentSize: Size) -> [Point] {
        let halfWidth = contentSize.width * abs(scaleX) / 2
        let halfHeight = contentSize.height * abs(scaleY) / 2

        return [
            Point(x: -halfWidth, y: -halfHeight),
            Point(x: halfWidth, y: -halfHeight),
            Point(x: halfWidth, y: halfHeight),
            Point(x: -halfWidth, y: halfHeight)
        ].map(pointOnCanvas)
    }

    /// Rechnet einen Punkt aus dem Koordinatensystem der Ebene (Ursprung in
    /// deren Mittelpunkt, ungedreht) auf die Leinwand um.
    public func pointOnCanvas(_ local: Point) -> Point {
        let radians = rotationDegrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)

        return Point(
            x: x + local.x * cosine - local.y * sine,
            y: y + local.x * sine + local.y * cosine
        )
    }
}

extension Transform2D {

    /// Die achsenparallele Umschliessende der Ebene.
    ///
    /// Die Ausrichtungshilfen rechnen mit achsenparallelen Rechtecken und
    /// kennen keine Drehung; sie brauchen deshalb genau diesen Rahmen. Bei
    /// einer um 45° gedrehten Ebene ist er spürbar grösser als die Ebene
    /// selbst — das ist gewollt und der Grund, warum es diese Funktion
    /// überhaupt gibt.
    public func boundingFrame(contentSize: Size) -> Rect {
        let ecken = corners(contentSize: contentSize)
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
