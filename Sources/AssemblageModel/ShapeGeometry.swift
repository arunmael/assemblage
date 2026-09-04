import Foundation

/// Formvorlagen (aus missing.md).
public enum ShapeTemplate: String, Codable, CaseIterable, Sendable {
    case triangle
    case pentagon
    case hexagon
    case star
    case heart
    case arrow
    case speechBubble
}

public enum ShapeGeometry {

    /// Die Umrisspunkte einer Vorlage in einem Rechteck der Grösse `size`,
    /// mit dem Ursprung oben links.
    ///
    /// `pointCount` gilt nur für `.star` (Zacken) — die übrigen Vorlagen
    /// haben eine feste Punktzahl und ignorieren ihn.
    public static func outline(
        of template: ShapeTemplate,
        size: Size,
        pointCount: Int = 5
    ) -> [Point] {
        // Ungültige Grössen direkt abfangen, um Divisionen durch Null zu vermeiden
        guard size.width > 0.0, size.height > 0.0 else {
            return []
        }

        switch template {
        case .triangle:
            return [
                Point(x: size.width / 2.0, y: 0.0),
                Point(x: size.width, y: size.height),
                Point(x: 0.0, y: size.height)
            ]

        case .pentagon:
            var points: [Point] = []
            for i in 0..<5 {
                let angle = -Double.pi / 2.0 + Double(i) * (2.0 * Double.pi / 5.0)
                points.append(Point(x: cos(angle), y: sin(angle)))
            }
            return fitToRect(points, size: size)

        case .hexagon:
            var points: [Point] = []
            for i in 0..<6 {
                let angle = -Double.pi / 2.0 + Double(i) * (2.0 * Double.pi / 6.0)
                points.append(Point(x: cos(angle), y: sin(angle)))
            }
            return fitToRect(points, size: size)

        case .star:
            // Begrenzung laut Spezifikation, um extreme Rechenzeiten oder Artefakte zu verhindern
            let clampedCount = max(3, min(20, pointCount))
            let totalPoints = clampedCount * 2
            var points: [Point] = []
            for i in 0..<totalPoints {
                let angle = -Double.pi / 2.0 + Double(i) * (2.0 * Double.pi / Double(totalPoints))
                let radius = (i % 2 == 0) ? 1.0 : 0.4
                points.append(Point(x: radius * cos(angle), y: radius * sin(angle)))
            }
            return fitToRect(points, size: size)

        case .heart:
            // Gewährleistet eine visuell glatte Kurve ohne sichtbare Ecken
            let totalPoints = 80
            var points: [Point] = []
            for i in 0..<totalPoints {
                let t = Double(i) * (2.0 * Double.pi / Double(totalPoints))
                let sinT = sin(t)
                let x = 16.0 * sinT * sinT * sinT
                // Y-Wert spiegeln, da im mathematischen Koordinatensystem Y nach oben wächst,
                // im Zielsystem jedoch nach unten.
                let y = -(13.0 * cos(t) - 5.0 * cos(2.0 * t) - 2.0 * cos(3.0 * t) - cos(4.0 * t))
                points.append(Point(x: x, y: y))
            }
            return fitToRect(points, size: size)

        case .arrow:
            return [
                Point(x: 0.0, y: size.height * 0.25),
                Point(x: size.width * 0.6, y: size.height * 0.25),
                Point(x: size.width * 0.6, y: 0.0),
                Point(x: size.width, y: size.height * 0.5),
                Point(x: size.width * 0.6, y: size.height),
                Point(x: size.width * 0.6, y: size.height * 0.75),
                Point(x: 0.0, y: size.height * 0.75)
            ]

        case .speechBubble:
            return [
                Point(x: 0.0, y: 0.0),
                Point(x: size.width, y: 0.0),
                Point(x: size.width, y: size.height * 0.8),
                Point(x: size.width * 0.4, y: size.height * 0.8),
                Point(x: size.width * 0.2, y: size.height),
                Point(x: size.width * 0.2, y: size.height * 0.8),
                Point(x: 0.0, y: size.height * 0.8)
            ]
        }
    }

    /// Passt eine Punktwolke exakt in das Zielrechteck ein, sodass die äussersten
    /// Punkte die Ränder berühren und keine Verzerrung durch falsche Offsets entsteht.
    private static func fitToRect(_ points: [Point], size: Size) -> [Point] {
        guard !points.isEmpty else { return [] }

        let xs = points.map { $0.x }
        let ys = points.map { $0.y }

        // Extremwerte ermitteln, um den tatsächlichen Hüllkörper zu bestimmen
        let minX = xs.min() ?? 0.0
        let maxX = xs.max() ?? 0.0
        let minY = ys.min() ?? 0.0
        let maxY = ys.max() ?? 0.0

        let widthRange = maxX - minX
        let heightRange = maxY - minY

        // Division durch Null verhindern, falls alle Punkte auf einer Linie liegen
        let scaleX = widthRange > 0.0 ? size.width / widthRange : 1.0
        let scaleY = heightRange > 0.0 ? size.height / heightRange : 1.0

        return points.map { p in
            Point(
                x: (p.x - minX) * scaleX,
                y: (p.y - minY) * scaleY
            )
        }
    }
}
