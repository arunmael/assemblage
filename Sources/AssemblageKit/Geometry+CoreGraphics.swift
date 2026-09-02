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
    /// Rotation und Spiegelung als Matrix.
    ///
    /// Die *Grösse* steckt nicht in der Matrix, sondern in `bounds` der
    /// `CALayer` (siehe `unrotatedFrame(forContentSize:)`) — sonst würde ein
    /// skaliertes Bild als kleine Bitmap hochgezogen und dabei unscharf,
    /// statt in voller Auflösung neu gerastert zu werden.
    ///
    /// Vorzeichen: Die Leinwand rendert mit `isGeometryFlipped = true`
    /// (Ursprung oben links, y nach unten). Ein positiver Winkel dreht darin
    /// im Uhrzeigersinn — genau das, was man beim Ziehen am Rotationsgriff
    /// erwartet.
    var renderTransform: CATransform3D {
        let radians = rotationDegrees * .pi / 180
        let mirror = CATransform3DMakeScale(
            scaleX < 0 ? -1 : 1,
            scaleY < 0 ? -1 : 1,
            1
        )
        return CATransform3DConcat(mirror, CATransform3DMakeRotation(radians, 0, 0, 1))
    }
}
