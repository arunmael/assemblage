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

/// Der Pfad einer Formebene (Plan 5.7 und die Vorlagen aus missing.md).
///
/// Eine Stelle für beide Renderwege, aus demselben Grund wie bei
/// `ImageDecoding` und `TextLayout`: Zwei Kopien einer Formberechnung driften
/// auseinander, und das fällt erst beim Exportieren auf.
enum ShapePath {

    /// `nil` nur bei einem Rechteck ohne Fläche — dann ist nichts zu zeichnen.
    static func cgPath(for content: ShapeLayerContent, in rect: CGRect) -> CGPath? {
        guard rect.width > 0, rect.height > 0 else { return nil }

        // Die drei Grundformen kennt Core Graphics selbst und zeichnet sie
        // dabei als echte Kurven. Ein Streckenzug wäre hier nicht nur Aufwand,
        // sondern sichtbar kantiger.
        switch content.kind {
        case .rectangle:
            return CGPath(rect: rect, transform: nil)
        case .roundedRectangle:
            return CGPath(
                roundedRect: rect,
                cornerWidth: min(content.cornerRadius, rect.width / 2),
                cornerHeight: min(content.cornerRadius, rect.height / 2),
                transform: nil
            )
        case .ellipse:
            return CGPath(ellipseIn: rect, transform: nil)
        default:
            break
        }

        guard let vorlage = content.kind.template else { return nil }
        let punkte = ShapeGeometry.outline(
            of: vorlage,
            size: Size(width: rect.width, height: rect.height),
            pointCount: content.pointCount
        )
        guard punkte.count >= 3 else { return nil }

        let pfad = CGMutablePath()
        // `ShapeGeometry` liefert die Punkte relativ zum Ursprung des
        // Rechtecks; hier auf dessen tatsächliche Lage verschieben.
        pfad.move(to: CGPoint(x: rect.minX + punkte[0].x, y: rect.minY + punkte[0].y))
        for punkt in punkte.dropFirst() {
            pfad.addLine(to: CGPoint(x: rect.minX + punkt.x, y: rect.minY + punkt.y))
        }
        pfad.closeSubpath()
        return pfad
    }

    /// Der Umriss, dem der Rahmen einer Bildebene folgt: der Formzuschnitt,
    /// sonst das Bildrechteck.
    static func borderPath(for content: ImageLayerContent, in rect: CGRect) -> CGPath? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        guard let clipShape = content.clipShape else {
            return CGPath(rect: rect, transform: nil)
        }
        return cgPath(
            for: ShapeLayerContent(kind: clipShape, size: Size(rect.size)),
            in: rect
        )
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
        resources: DocumentResources,
        displayedSize: CGSize = .zero
    ) -> CGImage? {
        guard let bild = maskImage(
            for: layer, cropRect: cropRect, resources: resources, displayedSize: displayedSize
        ) else { return nil }

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
        resources: DocumentResources,
        displayedSize: CGSize = .zero
    ) -> CGImage? {
        guard let bild = maskImage(
            for: layer, cropRect: cropRect, resources: resources, displayedSize: displayedSize
        ) else { return nil }

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
        resources: DocumentResources,
        displayedSize: CGSize
    ) -> CGImage? {
        let gemalt = paintedMaskImage(for: layer, cropRect: cropRect, resources: resources)

        // Der Formzuschnitt („Bild in Form") ist eine zweite Maske. Beide
        // laufen hier zusammen, statt dass die Form ein eigener Zeichenweg
        // wäre: So gilt sie automatisch überall, wo schon eine Maske gilt —
        // auf der Leinwand ebenso wie beim Export, der dieselbe Quelle über
        // `grayMaskImage` benutzt.
        guard let form = clipShapeMaskImage(
            for: layer, cropRect: cropRect, referenz: gemalt, displayedSize: displayedSize
        ) else {
            return gemalt
        }
        guard let gemalt else { return form }
        return multiplied(gemalt, form) ?? gemalt
    }

    /// Die von Hand gemalte bzw. automatisch erzeugte Maske.
    private static func paintedMaskImage(
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

    /// Der Umriss aus `ImageLayerContent.clipShape`, weiss auf schwarz — die
    /// Helligkeitskonvention, die `maskImage` durchgehend benutzt.
    ///
    /// Die Pixelgrösse richtet sich nach der schon vorhandenen Maske, damit
    /// beide ohne Skalierung übereinanderpassen; ohne eine solche gibt der
    /// sichtbare Bildausschnitt das Mass vor.
    private static func clipShapeMaskImage(
        for layer: Layer,
        cropRect: Rect?,
        referenz: CGImage?,
        displayedSize: CGSize
    ) -> CGImage? {
        guard case .image(let inhalt) = layer.content,
              let form = inhalt.clipShape
        else { return nil }

        // Reihenfolge der Bezugsgrössen: die vorhandene Maske (dann passen
        // beide ohne Skalierung übereinander), sonst der Zuschnitt, sonst die
        // dargestellte Grösse. Nur das Seitenverhältnis muss stimmen — die
        // Maske wird beim Anwenden ohnehin auf die Ebene gestreckt.
        let (breite, hoehe) = maskPixelSize(
            referenz: referenz, cropRect: cropRect, displayedSize: displayedSize
        )
        guard breite > 0, hoehe > 0 else { return nil }

        guard let kontext = CGContext(
            data: nil,
            width: breite,
            height: hoehe,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        kontext.setFillColor(gray: 0, alpha: 1)
        kontext.fill(CGRect(x: 0, y: 0, width: breite, height: hoehe))
        kontext.setFillColor(gray: 1, alpha: 1)

        // Derselbe Pfadbau wie für eine echte Formebene — `ShapePath` ist die
        // eine Stelle, an der ein Umriss entsteht. Eckenradius und Zackenzahl
        // sind hier die Vorgabewerte; eine Bildebene führt sie nicht mit.
        let flaeche = CGRect(x: 0, y: 0, width: breite, height: hoehe)
        let vorlage = ShapeLayerContent(
            kind: form,
            size: Size(width: Double(breite), height: Double(hoehe))
        )
        guard let pfad = ShapePath.cgPath(for: vorlage, in: flaeche) else { return nil }
        kontext.addPath(pfad)
        kontext.fillPath()
        return kontext.makeImage()
    }

    /// Wie gross die Formmaske in Pixeln angelegt wird.
    ///
    /// Ohne Bezug aus Maske oder Zuschnitt wird die dargestellte Grösse
    /// verdoppelt, damit der Umriss auch auf einem Retina-Bildschirm glatt
    /// bleibt, und nach oben gedeckelt, damit eine sehr gross gezogene Ebene
    /// keine übermässige Bitmap anlegt.
    private static func maskPixelSize(
        referenz: CGImage?,
        cropRect: Rect?,
        displayedSize: CGSize
    ) -> (Int, Int) {
        if let referenz { return (referenz.width, referenz.height) }
        if let cropRect, cropRect.width > 0, cropRect.height > 0 {
            return (Int(cropRect.width.rounded()), Int(cropRect.height.rounded()))
        }
        guard displayedSize.width > 0, displayedSize.height > 0 else { return (0, 0) }
        let obergrenze: CGFloat = 2048
        let faktor = min(2, obergrenze / max(displayedSize.width, displayedSize.height))
        return (
            max(1, Int((displayedSize.width * faktor).rounded())),
            max(1, Int((displayedSize.height * faktor).rounded()))
        )
    }

    /// Multipliziert zwei Helligkeitsmasken — sichtbar bleibt, was in beiden
    /// hell ist. Genau das erwartet man, wenn ein freigestelltes Motiv
    /// zusätzlich in eine Form gesetzt wird.
    private static func multiplied(_ a: CGImage, _ b: CGImage) -> CGImage? {
        let hintergrund = CIImage(cgImage: a)
        let vordergrund = CIImage(cgImage: b)
        let ergebnis = vordergrund.applyingFilter(
            "CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: hintergrund]
        )
        return RenderContext.shared.createCGImage(ergebnis, from: hintergrund.extent)
    }
}
