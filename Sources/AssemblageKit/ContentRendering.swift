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
