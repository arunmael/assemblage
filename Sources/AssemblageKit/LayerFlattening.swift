import AppKit
import AssemblageModel

/// Wandelt bearbeitbaren Text oder eine Vektorform in ein Bildobjekt um.
/// Das ist inhaltlich eine Einbahnstrasse; ein unmittelbares Widerrufen stellt
/// dank des Dokument-Schnappschusses dennoch den vollständig bearbeitbaren
/// Ursprung wieder her.
@MainActor
enum LayerFlattening {

    static func canFlatten(_ content: LayerContent) -> Bool {
        switch content {
        case .text, .shape: true
        case .image: false
        }
    }

    /// Rastert die ausgewählte Ebene und ersetzt sie in genau einer
    /// Dokumentänderung. `false` bedeutet: ungeeignete Auswahl oder die
    /// Bitmap konnte wegen ungültiger bzw. zu grosser Masse nicht entstehen.
    @discardableResult
    static func flattenSelected(in state: DocumentState) -> Bool {
        guard let owner = state.owner,
              let id = state.selectedLayerID,
              let layer = state.document.layer(withID: id),
              canFlatten(layer.content),
              let raster = rasterize(layer)
        else { return false }

        let referenz = state.resources.addOriginal(raster.pngData, fileExtension: "png")
        owner.modify("In Objekt umwandeln") { document in
            try? document.updateLayer(id: id) { ebene in
                ebene.content = .image(ImageLayerContent(originalFileReference: referenz))

                // Die Bitmap trägt nun `pixelSize` statt der bisherigen
                // Inhaltsgrösse. Die inverse Korrektur der Skalierung hält
                // jede Ecke exakt an Ort und Stelle; Position, Drehung,
                // Maske, Deckkraft, Blend-Modus und Verzerrung bleiben dabei
                // unverändert.
                ebene.transform.scaleX *= raster.contentSize.width / raster.pixelSize.width
                ebene.transform.scaleY *= raster.contentSize.height / raster.pixelSize.height
            }
        }
        return true
    }

    private struct Raster {
        let pngData: Data
        let contentSize: Size
        let pixelSize: Size
    }

    private static func rasterize(_ layer: Layer) -> Raster? {
        let contentSize: CGSize
        switch layer.content {
        case .text(let text): contentSize = TextLayout.naturalSize(of: text)
        case .shape(let shape): contentSize = shape.size.cgSize
        case .image: return nil
        }

        guard contentSize.width > 0, contentSize.height > 0 else { return nil }

        // Ein Inhaltspunkt entspricht bei neutraler Grösse einem Bildpixel.
        // Vergrössert die Ebene den Inhalt, wird schon beim Umwandeln mit der
        // grössten Achsenskalierung gerastert: Schriftgrösse 96 bei 400 %
        // erhält damit viermal so viele Pixel pro Achse und bleibt scharf.
        // Ein einheitlicher Faktor verhindert, dass Schrift und Rundungen bei
        // ungleichmässiger Skalierung bereits in der Bitmap verzogen werden.
        let faktor = max(abs(layer.transform.scaleX), abs(layer.transform.scaleY), 1)
        let breiteDouble = ceil(contentSize.width * faktor)
        let hoeheDouble = ceil(contentSize.height * faktor)

        // Core Graphics kann extrem grosse Kontexte ablehnen; die Schranken
        // verhindern vorhersehbar eine mehrere Gigabyte grosse Zuteilung.
        guard breiteDouble.isFinite, hoeheDouble.isFinite,
              breiteDouble <= 32_768, hoeheDouble <= 32_768,
              breiteDouble * hoeheDouble <= 100_000_000
        else { return nil }

        let breite = Int(breiteDouble)
        let hoehe = Int(hoeheDouble)
        guard let kontext = CGContext(
            data: nil,
            width: breite,
            height: hoehe,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        kontext.scaleBy(
            x: CGFloat(breite) / contentSize.width,
            y: CGFloat(hoehe) / contentSize.height
        )
        draw(layer.content, size: contentSize, in: kontext)

        guard let bild = kontext.makeImage(),
              let png = NSBitmapImageRep(cgImage: bild).representation(using: .png, properties: [:])
        else { return nil }

        return Raster(
            pngData: png,
            contentSize: Size(contentSize),
            pixelSize: Size(width: Double(breite), height: Double(hoehe))
        )
    }

    private static func draw(_ content: LayerContent, size: CGSize, in context: CGContext) {
        switch content {
        case .text(let text):
            // Das gespeicherte CGImage wird beim späteren Bildzeichnen lokal
            // gespiegelt (siehe `DocumentExporter.drawImage`). Deshalb wird
            // Text hier ungeflippt in die Bitmap gesetzt; die beiden Schritte
            // heben sich auf und Grundlinie sowie Glyphenlage bleiben gleich.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            TextLayout.attributedString(for: text).draw(in: CGRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()

        case .shape(let shape):
            // Über denselben Pfadbau wie Leinwand und Export. Solange es nur
            // Rechteck, Ellipse und abgerundetes Rechteck gab, war eine eigene
            // Nachbildung hier harmlos — alle drei sind senkrecht symmetrisch.
            // Bei einem Dreieck oder Herz wäre sie es nicht mehr.
            //
            // Ungeflippt gezeichnet, aus demselben Grund wie beim Text darüber:
            // Das entstehende Bild wird später beim Zeichnen lokal gespiegelt,
            // die beiden Schritte heben sich auf.
            if let pfad = ShapePath.cgPath(for: shape, in: CGRect(origin: .zero, size: size)) {
                context.setFillColor((RGBA(hex: shape.fillColorHex) ?? .white).cgColor)
                context.addPath(pfad)
                context.fillPath()
            }

        case .image:
            break
        }
    }
}
