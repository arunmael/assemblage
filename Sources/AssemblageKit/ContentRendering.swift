import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import AssemblageModel

// Gemeinsame Grundlagen für die beiden Wege, auf denen Ebenen zu Pixeln
// werden: den Bildschirm-Canvas (`LayerRenderer`) und den Export
// (`DocumentExporter`).
//
// Warum eigene Stelle: Beide brauchen dieselbe Bilddekodierung und denselben
// Textsatz, aber `LayerRenderer` und `ImageStore` sind `@MainActor`-gebunden
// (sie halten Zwischenspeicher und Bildschirmauflösung), während der Export
// bewusst ohne Hauptakteur läuft. Diese Funktionen sind zustandslos und
// deshalb an keinen Akteur gebunden — so brauchen sie nicht doppelt zu
// existieren.
//
// Die Dopplung gab es kurzzeitig, und sie ist gefährlicher, als sie aussieht:
// Zwei Kopien der EXIF-Behandlung oder des Textsatzes driften mit der Zeit
// auseinander, und das Ergebnis ist der ärgerlichste Fehler einer solchen
// App — der Export sieht anders aus als das, was man auf dem Bildschirm
// zusammengestellt hat.

/// Dekodiert Bilddaten zu einem `CGImage`.
enum ImageDecoding {

    /// `nil` bei unlesbaren Daten — der Aufrufer zeichnet dann einen
    /// Platzhalter, statt abzustürzen (Plan 2.1).
    ///
    /// Richtet das Bild nach seiner EXIF-Orientierung aus: Fotos vom iPhone
    /// liegen sonst quer, weil die Kamera sie in Sensor-Lage speichert und die
    /// Drehung nur als Metadatum vermerkt, das `CGImage` von sich aus
    /// ignoriert. Die Drehung übernimmt Core Image statt einer selbstgebauten
    /// Matrix — die acht EXIF-Fälle (besonders die gespiegelten 5 und 7)
    /// falsch zusammenzusetzen ist ein klassischer, schwer zu bemerkender
    /// Fehler.
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
        guard orientation > 1, orientation <= 8 else { return image }

        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation))
        // Scheitert das Neuzeichnen, lieber das ungedrehte Bild zeigen als gar keines.
        return RenderContext.shared.createCGImage(oriented, from: oriented.extent) ?? image
    }
}

/// Textsatz für Textebenen (Plan 5.6).
enum TextLayout {

    static func attributedString(for content: TextLayerContent) -> NSAttributedString {
        let font = NSFont(name: content.fontName, size: content.fontSize)
            // Fehlt die Schrift auf diesem Mac (Dokument von einem anderen
            // Rechner), auf die Systemschrift ausweichen statt nichts zu zeigen.
            ?? .systemFont(ofSize: content.fontSize)
        let color = RGBA(hex: content.colorHex) ?? .black

        return NSAttributedString(
            string: content.string,
            attributes: [.font: font, .foregroundColor: NSColor(cgColor: color.cgColor) ?? .black]
        )
    }

    /// Der Platz, den der Text tatsächlich braucht — eine Textebene hat keine
    /// im Modell gespeicherte Grösse, sie ergibt sich aus dem Satz.
    static func naturalSize(of content: TextLayerContent) -> CGSize {
        var size = attributedString(for: content).size()
        // Leerer Text hätte Grösse null und wäre damit weder sicht- noch
        // anklickbar — dem Nutzer bliebe nur, die Ebene zu löschen.
        size.width = max(size.width.rounded(.up), content.fontSize)
        size.height = max(size.height.rounded(.up), content.fontSize)
        return size
    }
}

/// Ebenenmasken (Plan 5.4, 7.3).
///
/// Festlegung: Die Maskenbitmap liegt in **Bildauflösung** und deckt das ganze
/// Original ab — genauso wie der Zuschnitt-Rahmen. Nur so bleiben Maske und
/// Zuschnitt unabhängig änderbar; läge die Maske im zugeschnittenen
/// Koordinatensystem, müsste jede Zuschnitt-Änderung die Bitmap umrechnen und
/// verlöre dabei Pixel. Weiss heisst sichtbar, Schwarz heisst ausgeblendet.
enum MaskRendering {

    /// Die auf den sichtbaren Ausschnitt zugeschnittene, gegebenenfalls
    /// umgekehrte Maske — oder `nil`, wenn keine wirksam ist.
    ///
    /// `nil` heisst ausdrücklich „keine Maske anwenden" und nicht „alles
    /// ausblenden": Eine Maske ohne Bitmap (die Vision-Anfrage läuft noch)
    /// oder eine abgeschaltete Maske darf die Ebene nicht verschwinden lassen
    /// (Plan 2.1).
    /// Für `CALayer.mask`: Die Deckung liegt danach im **Alphakanal**.
    ///
    /// Core Animation wertet bei einer Maskenschicht ausschliesslich Alpha
    /// aus. Eine schwarz-weisse Bitmap ist überall deckend und würde deshalb
    /// gar nichts ausblenden — ein Fehler, den man dem Bild nicht ansieht.
    static func alphaMaskImage(
        for layer: Layer,
        cropRect: Rect?,
        resources: DocumentResources
    ) -> CGImage? {
        guard let bild = maskImage(for: layer, cropRect: cropRect, resources: resources) else { return nil }

        // `CIMaskToAlpha` macht aus Helligkeit Deckung — genau die Umrechnung,
        // die Core Animation erwartet.
        let alpha = CIImage(cgImage: bild).applyingFilter("CIMaskToAlpha")
        return RenderContext.shared.createCGImage(alpha, from: alpha.extent)
    }

    /// Für `CGContext.clip(to:mask:)`: Graustufen **ohne** Alphakanal.
    ///
    /// Core Graphics verlangt für eine Bildmaske genau dieses Format und
    /// ignoriert alles andere stillschweigend — die Maske wirkt dann einfach
    /// nicht, ohne dass ein Fehler gemeldet würde.
    static func grayMaskImage(
        for layer: Layer,
        cropRect: Rect?,
        resources: DocumentResources
    ) -> CGImage? {
        guard let bild = maskImage(for: layer, cropRect: cropRect, resources: resources) else { return nil }

        guard let kontext = CGContext(
            data: nil,
            width: bild.width,
            height: bild.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        kontext.draw(bild, in: CGRect(x: 0, y: 0, width: bild.width, height: bild.height))
        return kontext.makeImage()
    }

    /// Die rohe Maskenbitmap, zugeschnitten und bei Bedarf umgekehrt.
    /// Deckung liegt hier in der **Helligkeit**: Weiss sichtbar, Schwarz
    /// ausgeblendet.
    private static func maskImage(
        for layer: Layer,
        cropRect: Rect?,
        resources: DocumentResources
    ) -> CGImage? {
        guard let maske = layer.mask, maske.isEnabled,
              let referenz = maske.maskImageReference,
              let daten = resources.data(for: referenz),
              var bild = ImageDecoding.decode(daten)
        else { return nil }

        if let cropRect {
            guard let zugeschnitten = bild.cropping(to: CGRect(
                x: cropRect.x, y: cropRect.y, width: cropRect.width, height: cropRect.height
            )) else { return nil }
            bild = zugeschnitten
        }

        guard maske.isInverted else { return bild }

        // Umkehren über Core Image statt über eine eigene Pixelschleife: Das
        // läuft auf der GPU und behandelt Farbräume richtig.
        let umgekehrt = CIImage(cgImage: bild).applyingFilter("CIColorInvert")
        return RenderContext.shared.createCGImage(umgekehrt, from: umgekehrt.extent) ?? bild
    }
}
