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
}
