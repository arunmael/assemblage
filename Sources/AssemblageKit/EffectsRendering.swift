import AppKit
import CoreImage
import AssemblageModel

/// Leuchten und Schlagschatten (aus missing.md).
///
/// Beide zeichnen **ausserhalb** der Ebene und folgen dabei ihrer Form, nicht
/// ihrem rechteckigen Rahmen: Bei einem freigestellten Foto soll der Schatten
/// dem Motiv folgen, nicht seinem Ausschnitt. Auf der Leinwand leistet das
/// Core Animation von sich aus, weil es den Schatten aus dem Alphakanal der
/// Schicht bildet; im Export machen wir dasselbe über Core Image.
///
/// Warum beide Wege hier zusammenliegen: Getrennte Ketten laufen mit der Zeit
/// auseinander, und das Ergebnis ist der ärgerlichste Fehler einer solchen
/// App — der Export sieht anders aus als das, was man eingestellt hat. Genau
/// das ist in diesem Projekt schon mehrfach passiert.
enum EffectsRendering {

    /// Legt Schatten **und** Leuchten auf ein bereits gezeichnetes Bild.
    ///
    /// Reihenfolge: Zuerst das Leuchten, dann der Schatten, dann die Ebene
    /// selbst. So liegt das Leuchten wie ein Hof unter dem Motiv, und der
    /// Schatten fällt darüber hinweg — die umgekehrte Reihenfolge liesse den
    /// Schatten im Leuchten verschwinden.
    static func apply(_ effects: LayerEffects, to image: CIImage) -> CIImage {
        let werte = effects.clamped()
        var ergebnis = image

        if let glow = werte.glow, glow.isActive {
            // Ein Leuchten ist im Kern ein Schatten ohne Versatz in heller
            // Farbe. Dieselbe Rechnung, andere Parameter — kein Grund für
            // einen zweiten Weg.
            ergebnis = composite(
                shadowOf: image,
                onto: ergebnis,
                offsetX: 0, offsetY: 0,
                radius: glow.radius,
                color: RGBA(hex: glow.colorHex) ?? .white,
                opacity: glow.intensity
            )
        }

        if let shadow = werte.shadow, shadow.isActive {
            ergebnis = composite(
                shadowOf: image,
                onto: ergebnis,
                offsetX: shadow.offsetX,
                // y wächst bei uns nach unten, in Core Image nach oben.
                offsetY: -shadow.offsetY,
                radius: shadow.radius,
                color: RGBA(hex: shadow.colorHex) ?? .black,
                opacity: shadow.opacity
            )
        }

        return ergebnis
    }

    /// Erzeugt aus der **Silhouette** von `source` einen farbigen, weich
    /// gezeichneten Abdruck und legt `top` darüber.
    private static func composite(
        shadowOf source: CIImage,
        onto top: CIImage,
        offsetX: Double,
        offsetY: Double,
        radius: Double,
        color: RGBA,
        opacity: Double
    ) -> CIImage {
        // Aus dem Alphakanal eine einfarbige Fläche machen: Der Schatten
        // folgt damit der Form der Ebene und nicht ihrem Rahmen.
        let silhouette = source.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
            "inputBiasVector": CIVector(x: color.red, y: color.green, z: color.blue, w: 0)
        ])

        var abdruck = silhouette
        if radius > 0 {
            // Ohne Fortsetzung der Randpixel bekäme der weiche Rand einen
            // harten Abriss an der Bildkante.
            abdruck = silhouette
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius])
                // Der Weichzeichner greift weit über die Vorlage hinaus;
                // grosszügig beschneiden, damit das Bild nicht unbegrenzt wächst.
                .cropped(to: silhouette.extent.insetBy(dx: -radius * 3, dy: -radius * 3))
        }

        return top.composited(over: abdruck.transformed(
            by: CGAffineTransform(translationX: offsetX, y: offsetY)
        ))
    }
}

extension Glow {
    /// Ob dieses Leuchten überhaupt etwas zeichnet.
    var isActive: Bool { radius > 0 && intensity > 0 }
}

extension Shadow {
    var isActive: Bool { opacity > 0 && (offsetX != 0 || offsetY != 0 || radius > 0) }
}
