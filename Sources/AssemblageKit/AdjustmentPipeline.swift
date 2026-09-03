import CoreImage
import CoreImage.CIFilterBuiltins
import AssemblageModel

/// Übersetzt `ImageAdjustments` (Plan 5.5) in eine Core-Image-Filterkette
/// (Plan 7.2).
///
/// Nicht-destruktiv: Das Original im Dokumentpaket bleibt unangetastet, die
/// Kette wird bei jeder Änderung neu berechnet. Auf dem Bildschirm hängt sie
/// als `CALayer.filters` direkt im Compositor — ein Reglerzug kostet damit
/// keinen einzigen neu dekodierten Pixel, was Plan 4.4 („sofortiges visuelles
/// Feedback") überhaupt erst möglich macht. Beim Export läuft dieselbe Kette
/// über den `CIContext`.
///
/// Genau deshalb liegen beide Wege hier zusammen: Zwei Ketten würden früher
/// oder später auseinanderlaufen, und dann sähe der Export anders aus als das,
/// was man auf dem Bildschirm eingestellt hat.
enum AdjustmentPipeline {

    // Umrechnung der Modellwerte (-1…1 bzw. 0…1) auf die Wertebereiche der
    // Filter. Bewusst zurückhaltend: Ein Regler am Anschlag soll ein kräftiges,
    // aber noch brauchbares Bild ergeben — nicht Schwarz oder eine Farbfläche.
    private static let brightnessRange = 0.5      // ±0,5 in CIColorControls
    private static let contrastRange = 0.6        // 1 ± 0,6
    private static let warmthKelvin = 3000.0      // Abweichung von 6500 K
    private static let maximumBlurRadius = 25.0   // in Pixeln
    private static let maximumSharpness = 2.0

    /// Die Filter für diese Anpassungen, in Anwendungsreihenfolge.
    ///
    /// Leer bei neutralen Werten — bei einer Collage aus zwanzig
    /// unbearbeiteten Fotos wäre jede aufgebaute Kette verschenkte Arbeit.
    static func filters(for adjustments: ImageAdjustments) -> [CIFilter] {
        let werte = adjustments.clamped()
        var kette: [CIFilter] = []

        // Farbe zuerst, dann Weichzeichnen, dann Schärfen: Schärfen nach dem
        // Weichzeichnen anzuwenden würde einen Teil davon wieder aufheben —
        // und umgekehrt verstärkt Weichzeichnen nach dem Schärfen nur die
        // Schärfungsartefakte.
        if werte.brightness != 0 || werte.contrast != 0 || werte.saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.brightness = Float(werte.brightness * brightnessRange)
            // Neutral ist 1, nicht 0.
            filter.contrast = Float(1 + werte.contrast * contrastRange)
            // Neutral ist 1, 0 ist Graustufen, 2 ist übersättigt.
            filter.saturation = Float(1 + werte.saturation)
            kette.append(filter)
        }

        if werte.warmth != 0 {
            let filter = CIFilter.temperatureAndTint()
            // `neutral` beschreibt, welche Lichtfarbe das Bild *hat*,
            // `targetNeutral`, wohin sie gebracht werden soll. Ein **kleinerer**
            // Zielwert macht das Bild wärmer: Core Image rechnet dann so, als
            // müsste eine kühlere Beleuchtung ausgeglichen werden.
            filter.neutral = CIVector(x: 6500, y: 0)
            filter.targetNeutral = CIVector(x: 6500 - werte.warmth * warmthKelvin, y: 0)
            kette.append(filter)
        }

        if werte.blurRadius > 0 {
            let filter = CIFilter.gaussianBlur()
            filter.radius = Float(werte.blurRadius * maximumBlurRadius)
            kette.append(filter)
        }

        if werte.sharpenAmount > 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.sharpness = Float(werte.sharpenAmount * maximumSharpness)
            kette.append(filter)
        }

        return kette
    }

    /// Wendet die Kette auf ein Bild an (Weg für den Export).
    ///
    /// Gibt das Bild unverändert zurück, wenn nichts eingestellt ist.
    static func apply(_ adjustments: ImageAdjustments, to image: CIImage) -> CIImage? {
        let kette = filters(for: adjustments)
        guard !kette.isEmpty else { return image }

        let ausgangsgroesse = image.extent
        var aktuell = image

        for filter in kette {
            // Weichzeichnen greift über den Bildrand hinaus. Ohne Fortsetzung
            // der Randpixel entstünde ein durchsichtiger Saum, und das Bild
            // würde ausserdem grösser als das Original.
            let eingabe = filter is CIFilter & CIGaussianBlur
                ? aktuell.clampedToExtent()
                : aktuell
            filter.setValue(eingabe, forKey: kCIInputImageKey)
            guard let ergebnis = filter.outputImage else { return aktuell }
            aktuell = ergebnis
        }

        // Auf die ursprüngliche Grösse zurückschneiden: Sonst wäre die Ebene
        // nach dem Weichzeichnen grösser als vorher und sässe verschoben.
        return aktuell.cropped(to: ausgangsgroesse)
    }
}
