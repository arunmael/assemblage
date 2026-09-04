import AppKit
import CoreGraphics
import AssemblageModel

/// Texturen (aus missing.md): eine Überlagerung, die auf einer Ebene liegt —
/// Papier, Korn, Kratzer.
///
/// Gekachelt und nicht gestreckt: Eine Papierstruktur, die man auf die halbe
/// Grösse stellt, soll feiner werden und trotzdem die ganze Ebene bedecken.
/// Würde sie stattdessen gestaucht, hätte der Massstab bei jeder Ebene eine
/// andere Wirkung, und unter 1 bliebe ein Teil der Ebene unbedeckt.
///
/// Beide Renderwege — Bildschirm und Export — holen ihre Kachelung hier. Das
/// ist in diesem Projekt keine Formsache: Zwei getrennte Ketten sind schon
/// mehrfach auseinandergelaufen, und das Ergebnis ist der ärgerlichste Fehler
/// einer solchen App, nämlich ein Export, der anders aussieht als die
/// Vorschau.
enum TextureRendering {

    /// Ab so vielen Kacheln wird gestreckt statt gekachelt. Eine winzige
    /// Textur auf einer grossen Leinwand ergäbe sonst Millionen Zeichenbefehle
    /// — bei dieser Kachelzahl ist von der Struktur ohnehin nichts mehr zu
    /// erkennen.
    static let maximumTileCount = 100_000

    /// Grösse einer einzelnen Kachel bei gegebenem Massstab.
    ///
    /// Nie kleiner als ein Punkt: Eine Kachel der Grösse null würde die
    /// Kachelschleife nie beenden.
    static func tileSize(of textureImage: CGImage, scale: Double) -> CGSize {
        let massstab = max(0.01, scale)
        return CGSize(
            width: max(1, Double(textureImage.width) * massstab),
            height: max(1, Double(textureImage.height) * massstab)
        )
    }

    /// Kachelt die Textur auf ein Bild der Grösse `size`.
    ///
    /// `nil`, wenn die Bilddatei fehlt oder die Grösse unbrauchbar ist — der
    /// Aufrufer zeichnet die Ebene dann einfach ohne Textur, statt den ganzen
    /// Aufbau scheitern zu lassen (Plan 2.1).
    ///
    /// Deckkraft und Blend-Modus bleiben bewusst aussen vor: Auf dem Bildschirm
    /// setzt Core Animation sie an der Schicht, im Export Core Graphics am
    /// Kontext. Hier entsteht nur die reine Fläche.
    static func tiledImage(
        for texture: LayerTexture,
        size: CGSize,
        resources: DocumentResources
    ) -> CGImage? {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }

        let werte = texture.clamped()
        guard let daten = resources.data(for: werte.imageReference),
              let bild = ImageDecoding.decode(daten)
        else { return nil }

        // Mindestens ein Pixel: Eine Ebene, die schmaler als ein halber Punkt
        // ist, soll eine (winzige) Textur bekommen statt gar keine.
        guard let gerundeteBreite = Int(exactly: size.width.rounded()),
              let gerundeteHoehe = Int(exactly: size.height.rounded())
        else { return nil }
        let breite = max(1, gerundeteBreite)
        let hoehe = max(1, gerundeteHoehe)

        guard let context = CGContext(
            data: nil,
            width: breite,
            height: hoehe,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high

        // Kein Geometrie-Flip des Kontexts. Das ist bewusst anders als an den
        // vier anderen Stellen im Projekt, die einen brauchen: Dort kommt das
        // Bild aus Core Image oder wird in den Export-Kontext gesetzt, der
        // seinerseits gedreht ist. Ein eigenständiger Bitmap-Kontext wie hier
        // nimmt ein `CGImage` von `draw(_:in:)` dagegen aufrecht entgegen —
        // nachgemessen, nicht angenommen (siehe `testTextureIsNotFlippedVertically`).
        // Ein Flip würde die Textur also erst kippen, statt etwas auszugleichen.
        let kachel = tileSize(of: bild, scale: werte.scale)
        let spalten = Int(ceil(Double(breite) / kachel.width))
        let reihen = Int(ceil(Double(hoehe) / kachel.height))

        if spalten * reihen > maximumTileCount {
            context.draw(bild, in: CGRect(x: 0, y: 0, width: Double(breite), height: Double(hoehe)))
        } else {
            for reihe in 0..<reihen {
                for spalte in 0..<spalten {
                    // Reihe 0 liegt **oben**: Der Kontext zählt y von unten,
                    // das Modell von oben. Damit sitzt eine angeschnittene
                    // Kachel unten am Rand und nicht oben — dieselbe Richtung,
                    // in der auch die Leinwand aufgebaut ist.
                    context.draw(bild, in: CGRect(
                        x: Double(spalte) * kachel.width,
                        y: Double(hoehe) - Double(reihe + 1) * kachel.height,
                        width: kachel.width,
                        height: kachel.height
                    ))
                }
            }
        }

        return context.makeImage()
    }

    /// Übersetzt die **Deckung** eines Bildes in ein Graustufenbild: deckend
    /// wird weiss, durchsichtig schwarz.
    ///
    /// Das ist genau die Form, die `CGContext.clip(to:mask:)` erwartet — eine
    /// Maske **ohne** Alphakanal, deren Helligkeit die Deckung bestimmt.
    /// Dieselbe Zweiteilung wie bei `MaskRendering`: `CALayer.mask` braucht das
    /// Gegenteil, nämlich einen Alphakanal. Die beiden zu verwechseln ist in
    /// diesem Projekt schon vorgekommen und äussert sich als vollständig
    /// unsichtbare oder vollständig unbeschnittene Ebene.
    static func grayMask(fromAlphaOf image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // Weiss zeichnen, aber nur dort, wo die Vorlage deckt: Ihr Alphakanal
        // steuert dabei, wie viel Weiss ankommt. Der Grund bleibt schwarz —
        // also durchsichtig im Sinne der späteren Beschneidung.
        let flaeche = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(flaeche)
        context.clip(to: flaeche, mask: image)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(flaeche)

        return context.makeImage()
    }
}
