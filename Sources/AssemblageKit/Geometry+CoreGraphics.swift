import CoreGraphics
import QuartzCore
import AssemblageModel

// Brücke zwischen dem plattformunabhängigen Modell (Sources/AssemblageModel)
// und Core Graphics. Bewusst nur hier, damit das Modell frei von Apple-Typen
// bleibt und in der Linux-CI testbar ist.

extension Size {
    var cgSize: CGSize { CGSize(width: width, height: height) }

    init(_ size: CGSize) {
        self.init(width: Double(size.width), height: Double(size.height))
    }
}

extension Rect {
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    init(_ rect: CGRect) {
        self.init(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.width),
            height: Double(rect.height)
        )
    }
}

extension Transform2D {
    /// Skalierung, Spiegelung und Drehung als eine Matrix.
    ///
    /// Alle drei gehören hierher und nicht in die `bounds` der `CALayer`: Der
    /// Pfad einer `CAShapeLayer` wächst nicht mit ihren Bounds, und
    /// `CATextLayer` setzt in `fontSize`. Skalierung über die Bounds würde
    /// deshalb nur Bildebenen treffen — Formen und Text blieben stur in
    /// Originalgrösse.
    ///
    /// Die Spiegelung steckt bereits im Vorzeichen der Skalierung; sie braucht
    /// keinen eigenen Faktor.
    ///
    /// Vorzeichen der Drehung: Die Leinwand rendert mit
    /// `isGeometryFlipped = true` (Ursprung oben links, y nach unten). Ein
    /// positiver Winkel dreht darin im Uhrzeigersinn — genau das, was man beim
    /// Ziehen am Rotationsgriff erwartet.
    var renderTransform: CATransform3D {
        let radians = rotationDegrees * .pi / 180
        // Eine Skalierung von 0 macht die Matrix unumkehrbar; Core Animation
        // zeichnet dann gar nichts mehr und die Ebene wäre unauffindbar.
        let scale = CATransform3DMakeScale(
            scaleX == 0 ? .leastNormalMagnitude : scaleX,
            scaleY == 0 ? .leastNormalMagnitude : scaleY,
            1
        )
        return CATransform3DConcat(scale, CATransform3DMakeRotation(radians, 0, 0, 1))
    }

    /// Verbindet die projektive Verzerrung mit Skalierung und Drehung.
    ///
    /// `CALayer` transformiert um seinen Ankerpunkt, standardmässig die
    /// Bounds-Mitte. Die Homographie arbeitet deshalb ebenfalls mit der
    /// Mitte als Ursprung. Sie kommt in der Verkettung zuerst: Der Versatz
    /// ist laut Modell im Inhaltsmass definiert und muss anschliessend von
    /// derselben Skalierung und Drehung erfasst werden wie der Inhalt.
    func renderTransform(contentSize: Size, distortion: QuadDistortion?) -> CATransform3D? {
        guard let distortion, !distortion.isIdentity else { return nil }
        guard let projective = CATransform3D.projectiveTransform(
            from: CGRect(origin: .zero, size: contentSize.cgSize),
            to: localDistortedCorners(contentSize: contentSize, distortion: distortion)
        ) else { return nil }
        return CATransform3DConcat(projective, renderTransform)
    }

    private func localDistortedCorners(contentSize: Size, distortion: QuadDistortion) -> [CGPoint] {
        let sx = scaleX < 0 ? -1.0 : 1.0
        let sy = scaleY < 0 ? -1.0 : 1.0
        let halfWidth = contentSize.width / 2
        let halfHeight = contentSize.height / 2
        let geometric = [
            CGPoint(x: -halfWidth + distortion.topLeft.x, y: -halfHeight + distortion.topLeft.y),
            CGPoint(x: halfWidth + distortion.topRight.x, y: -halfHeight + distortion.topRight.y),
            CGPoint(x: halfWidth + distortion.bottomRight.x, y: halfHeight + distortion.bottomRight.y),
            CGPoint(x: -halfWidth + distortion.bottomLeft.x, y: halfHeight + distortion.bottomLeft.y)
        ]
        // Bei einer Spiegelung gehört die linke Quellkante geometrisch nach
        // rechts (bzw. oben nach unten). Die Zielzuordnung wird deshalb vor
        // der signierten Basisskalierung vertauscht; so bleibt die Spiegelung
        // des Inhalts erhalten, während die Modellecken ihre Namen behalten.
        let indices: [Int]
        switch (scaleX < 0, scaleY < 0) {
        case (false, false): indices = [0, 1, 2, 3]
        case (true, false): indices = [1, 0, 3, 2]
        case (false, true): indices = [3, 2, 1, 0]
        case (true, true): indices = [2, 3, 0, 1]
        }
        return indices.map { index in
            CGPoint(x: sx * geometric[index].x, y: sy * geometric[index].y)
        }
    }
}

extension CATransform3D {
    /// Homographie vom Rechteck auf ein Viereck. Core Animation teilt nach
    /// der Multiplikation durch `w`; deshalb liegen die beiden projektiven
    /// Koeffizienten in `m14` und `m24`.
    fileprivate static func projectiveTransform(from rect: CGRect, to corners: [CGPoint]) -> CATransform3D? {
        guard rect.width > 0, rect.height > 0, corners.count == 4 else { return nil }
        let p0 = corners[0], p1 = corners[1], p2 = corners[2], p3 = corners[3]
        let dx1 = p1.x - p2.x
        let dx2 = p3.x - p2.x
        let dx3 = p0.x - p1.x + p2.x - p3.x
        let dy1 = p1.y - p2.y
        let dy2 = p3.y - p2.y
        let dy3 = p0.y - p1.y + p2.y - p3.y
        let determinant = dx1 * dy2 - dx2 * dy1

        let g: CGFloat
        let h: CGFloat
        if abs(dx3) < 1e-12, abs(dy3) < 1e-12 {
            g = 0
            h = 0
        } else {
            guard abs(determinant) > 1e-12 else { return nil }
            g = (dx3 * dy2 - dx2 * dy3) / determinant
            h = (dx1 * dy3 - dx3 * dy1) / determinant
        }

        let a = p1.x - p0.x + g * p1.x
        let b = p3.x - p0.x + h * p3.x
        let c = p0.x
        let d = p1.y - p0.y + g * p1.y
        let e = p3.y - p0.y + h * p3.y
        let f = p0.y

        var result = CATransform3DIdentity
        result.m11 = a / rect.width
        result.m21 = b / rect.height
        result.m41 = c + (a + b) / 2
        result.m12 = d / rect.width
        result.m22 = e / rect.height
        result.m42 = f + (d + e) / 2
        result.m14 = g / rect.width
        result.m24 = h / rect.height
        result.m44 = 1 + (g + h) / 2
        return result
    }

    /// Bildet die vier Bounds-Ecken so ab, wie `CALayer` es um den
    /// Ankerpunkt tut. Dient auch dem direkten Paritätstest gegen das Modell.
    func projectedCorners(bounds: CGRect, position: CGPoint) -> [CGPoint] {
        let halfWidth = bounds.width / 2
        let halfHeight = bounds.height / 2
        return [
            CGPoint(x: -halfWidth, y: -halfHeight),
            CGPoint(x: halfWidth, y: -halfHeight),
            CGPoint(x: halfWidth, y: halfHeight),
            CGPoint(x: -halfWidth, y: halfHeight)
        ].map { projectedPoint($0, position: position) }
    }

    func projectedPoint(_ point: CGPoint, position: CGPoint) -> CGPoint {
        let w = point.x * m14 + point.y * m24 + m44
        guard abs(w) > .leastNormalMagnitude else { return position }
        return CGPoint(
            x: position.x + (point.x * m11 + point.y * m21 + m41) / w,
            y: position.y + (point.x * m12 + point.y * m22 + m42) / w
        )
    }
}
