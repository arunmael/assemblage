import AppKit
import QuartzCore
import AssemblageModel

/// Übersetzt eine Modell-Ebene in eine `CALayer` (Plan 7.2: Core Animation
/// für die Live-Komposition).
///
/// Warum Core Animation und nicht bei jeder Änderung neu rendern: Position,
/// Rotation, Deckkraft und Blend-Modus wandern damit direkt in den
/// Compositor auf der GPU. Eine Ebene zu verschieben kostet dann keinen
/// einzigen neu berechneten Pixel — genau das verlangt Plan 4.4
/// („sofortiges visuelles Feedback").
@MainActor
struct LayerRenderer {

    /// Sechs Felder pro Achse genügen bei Bildschirmauflösung für flüssige
    /// Griffbewegungen; der höher aufgelöste Export verwendet acht.
    private static let meshPreviewResolution = 6

    let images: ImageStore
    /// Pixel pro Punkt des Bildschirms — sonst sind Text und Formen auf
    /// Retina-Displays sichtbar unscharf.
    var contentsScale: CGFloat = 2

    // MARK: - Aufbau

    func makeLayer(for layer: Layer) -> CALayer {
        let rendered = if layer.distortion?.hasCurvedEdges == true {
            CALayer()
        } else {
            makeContentLayer(for: layer.content)
        }
        apply(layer, to: rendered)
        applyMask(layer, to: rendered)
        return rendered
    }

    /// Lässt sich diese Schicht für die Ebene weiterverwenden?
    ///
    /// Neben dem Wechsel der Ebenenart verlangt auch der Übergang zwischen
    /// nativer Vektorschicht und gerastertem Mesh eine neue Schicht. Alles
    /// andere, auch ein geänderter Text oder eine andere Füllfarbe, wird in
    /// der bestehenden Schicht aufgefrischt.
    func canReuse(_ renderedLayer: CALayer, for layer: Layer) -> Bool {
        if layer.distortion?.hasCurvedEdges == true {
            return !(renderedLayer is CATextLayer) && !(renderedLayer is CAShapeLayer)
        }
        switch layer.content {
        case .text: return renderedLayer is CATextLayer
        case .shape: return renderedLayer is CAShapeLayer
        case .image(let image):
            // Der Platzhalter für ein fehlendes Original ist eine schlichte
            // CALayer; taucht die Datei wieder auf, muss neu gebaut werden.
            guard !(renderedLayer is CATextLayer), !(renderedLayer is CAShapeLayer) else { return false }
            guard let bild = renderedLayer as? ImageContentLayer else { return false }
            let originalExists = images.image(named: image.originalFileReference) != nil
            return originalExists == (bild.bitmap.contents != nil)
        }
    }

    /// Hängt Schlagschatten und Leuchten an die Schicht.
    ///
    /// Core Animation bildet den Schatten aus dem **Alphakanal** der Schicht,
    /// er folgt also der Form der Ebene und nicht ihrem Rahmen — bei einem
    /// freigestellten Foto genau das Gewollte.
    ///
    /// Eine Schicht kann allerdings nur **einen** Schatten tragen. Sind
    /// Leuchten und Schlagschatten zugleich eingestellt, gewinnt hier der
    /// Schlagschatten, und das Leuchten kommt erst im Export vollständig zur
    /// Geltung. Das ist eine bewusste Einschränkung der Vorschau: Zwei
    /// Schichten übereinanderzulegen, nur um beide Effekte zu zeigen, würde
    /// den Schichtbaum verdoppeln und jede Trefferprüfung verkomplizieren.
    func applyEffects(_ effects: LayerEffects?, to renderedLayer: CALayer) {
        guard let effects, effects.isActive else {
            renderedLayer.shadowOpacity = 0
            renderedLayer.shadowRadius = 0
            renderedLayer.shadowOffset = .zero
            return
        }

        let werte = effects.clamped()
        if let schatten = werte.shadow, schatten.isActive {
            renderedLayer.shadowColor = (RGBA(hex: schatten.colorHex) ?? .black).cgColor
            renderedLayer.shadowOffset = CGSize(width: schatten.offsetX, height: schatten.offsetY)
            renderedLayer.shadowRadius = schatten.radius
            renderedLayer.shadowOpacity = Float(schatten.opacity)
        } else if let leuchten = werte.glow, leuchten.isActive {
            renderedLayer.shadowColor = (RGBA(hex: leuchten.colorHex) ?? .white).cgColor
            // Ein Leuchten ist ein Schatten ohne Versatz.
            renderedLayer.shadowOffset = .zero
            renderedLayer.shadowRadius = leuchten.radius
            renderedLayer.shadowOpacity = Float(leuchten.intensity)
        }
    }

    /// Name der Texturschicht. Sie wird über den Namen wiedergefunden statt
    /// über einen Index: Die Maskenschicht und künftige Zusätze hängen an
    /// derselben Schicht, und ein Index würde beim nächsten Zusatz stillschweigend
    /// auf das Falsche zeigen.
    static let textureLayerName = "assemblage.textur"

    /// Legt die Textur als Unterschicht über den Ebeneninhalt (aus missing.md).
    ///
    /// Als Unterschicht und nicht als eigene Ebene: Eine Textur gehört zu dem,
    /// was sie überzieht. So wird sie von Verschieben, Drehen, Skalieren und
    /// der Ebenenmaske automatisch mitgenommen — die Maske der Elternschicht
    /// wirkt auch auf deren Unterschichten.
    ///
    /// Beschnitten wird sie zusätzlich auf die **Silhouette** des Inhalts:
    /// Ohne das liefe die Textur bei einem freigestellten Motiv über dessen
    /// Rand hinaus in den leeren Rahmen. Im Export leistet dasselbe
    /// `DocumentExporter.drawTexture`.
    func applyTexture(_ layer: Layer, to renderedLayer: CALayer) {
        let vorhandene = renderedLayer.sublayers?.first { $0.name == Self.textureLayerName }

        guard let textur = layer.texture?.clamped(), textur.opacity > 0,
              renderedLayer.bounds.width > 0, renderedLayer.bounds.height > 0,
              let gekachelt = TextureRendering.tiledImage(
                  for: textur,
                  size: renderedLayer.bounds.size,
                  resources: images.resources
              )
        else {
            vorhandene?.removeFromSuperlayer()
            return
        }

        let schicht = vorhandene ?? {
            let neu = CALayer()
            neu.name = Self.textureLayerName
            renderedLayer.addSublayer(neu)
            return neu
        }()

        schicht.contents = gekachelt
        schicht.contentsGravity = .resize
        schicht.frame = CGRect(origin: .zero, size: renderedLayer.bounds.size)
        schicht.opacity = Float(textur.opacity)
        schicht.compositingFilter = textur.blendMode.compositingFilterName

        // Die Silhouette entsteht aus einer zweiten Ausfertigung des Inhalts.
        // Bei Bildebenen zeigt sie auf dasselbe zwischengespeicherte `CGImage`,
        // kostet also keinen zweiten Dekodiervorgang.
        let silhouette = makeContentLayer(for: layer.content)
        silhouette.frame = CGRect(origin: .zero, size: renderedLayer.bounds.size)
        if case .image(let image) = layer.content {
            applyImageLayout(image, to: silhouette)
        }
        // Nur der Bildinhalt bildet die Silhouette — ein Rahmen gehört nicht
        // zur Form des Motivs.
        schicht.mask = (silhouette as? ImageContentLayer)?.bitmap ?? silhouette
    }

    /// Hängt die Ebenenmaske als `CALayer.mask` an (Plan 5.4).
    ///
    /// Core Animation wendet sie damit auf der GPU an — dasselbe Vorgehen wie
    /// bei den Anpassungen, und aus demselben Grund: Eine Maske zu ändern darf
    /// kein Neuzeichnen des Bildes auslösen.
    func applyMask(_ layer: Layer, to renderedLayer: CALayer) {
        // Im Mesh-Pfad ist die Maske bereits zusammen mit dem Inhalt
        // gerastert. Eine zweite rechteckige CALayer-Maske wäre geometrisch
        // falsch und würde sie ausserdem doppelt anwenden.
        guard layer.distortion?.hasCurvedEdges != true else {
            renderedLayer.mask = nil
            return
        }
        // Die Maske gehört an den Bildinhalt, nicht an die Hülle: Sonst
        // schnitte sie den Rahmen gleich mit weg, der ja gerade den Rand
        // zeigen soll.
        let maskTarget = (renderedLayer as? ImageContentLayer)?.bitmap ?? renderedLayer
        let ausschnitt: Rect?
        if case .image(let inhalt) = layer.content {
            ausschnitt = inhalt.cropRect
        } else {
            ausschnitt = nil
        }

        guard let maskenbild = MaskRendering.alphaMaskImage(
            for: layer,
            cropRect: ausschnitt,
            resources: images.resources,
            displayedSize: renderedLayer.bounds.size
        ) else {
            maskTarget.mask = nil
            return
        }

        let maske = CALayer()
        maske.contents = maskenbild
        maske.contentsGravity = .resize
        // Deckungsgleich mit der Ebene: Die Maske liegt im selben
        // Koordinatensystem wie ihr Inhalt.
        maske.frame = CGRect(origin: .zero, size: maskTarget.bounds.size)
        maskTarget.mask = maske
    }

    /// Überträgt alles, was unabhängig vom Ebenentyp gilt — und frischt den
    /// Inhalt der Schicht auf.
    ///
    /// Das Auffrischen gehört hierher und nicht nur in `makeLayer`: Sonst
    /// zeigte die Leinwand nach dem Umschreiben eines Textes weiter den
    /// alten, weil die Schicht ja schon existiert. Ein Neuaufbau passiert
    /// nur, wenn sich die Ebenenstruktur ändert — beim Tippen also nie.
    func apply(_ layer: Layer, to renderedLayer: CALayer) {
        let contentSize = self.contentSize(of: layer.content)

        if let distortion = layer.distortion, distortion.hasCurvedEdges,
           let preview = DocumentExporter.curvedPreview(
               of: layer,
               distortion: distortion,
               contentSize: contentSize.cgSize,
               contentsScale: contentsScale,
               resources: images.resources,
               resolution: Self.meshPreviewResolution
           ) {
            renderedLayer.sublayers?.first { $0.name == Self.textureLayerName }?.removeFromSuperlayer()
            renderedLayer.contents = preview.image
            renderedLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            renderedLayer.contentsGravity = .resize
            renderedLayer.magnificationFilter = .trilinear
            renderedLayer.minificationFilter = .trilinear
            renderedLayer.bounds = CGRect(origin: .zero, size: preview.frame.size)
            renderedLayer.position = CGPoint(x: preview.frame.midX, y: preview.frame.midY)
            // Skalierung, Spiegelung, Drehung und Krümmung sind schon in der
            // Bitmap. Jeder weitere Transform würde sie doppelt anwenden.
            renderedLayer.transform = CATransform3DIdentity
            renderedLayer.contentsScale = contentsScale
            renderedLayer.filters = nil
            applyEffects(layer.effects, to: renderedLayer)
            applyCommonProperties(layer, to: renderedLayer)
            return
        }

        applyContent(layer.content, to: renderedLayer)

        // `bounds` bleibt die *unskalierte* Inhaltsgrösse; Skalierung,
        // Spiegelung und Drehung stecken zusammen in der Matrix.
        //
        // Das muss so herum sein: Der Pfad einer `CAShapeLayer` wächst nicht
        // mit ihren Bounds, und `CATextLayer` setzt in `fontSize` statt auf
        // Bounds-Grösse. Skalierung über `bounds` würde also nur Bildebenen
        // treffen und Formen wie Text unverändert lassen.
        //
        // Nie `renderedLayer.frame = …` verwenden: Bei einer gedrehten Ebene
        // ist `frame` nicht mehr sinnvoll beschreibbar.
        renderedLayer.bounds = CGRect(origin: .zero, size: contentSize.cgSize)
        renderedLayer.position = CGPoint(x: layer.transform.x, y: layer.transform.y)
        // Der Normalfall bleibt ohne Zusatzrechnung auf dem bisherigen Pfad.
        // Nur eine echte Verzerrung benötigt die projektive Matrix.
        renderedLayer.transform = layer.transform.renderTransform(
            contentSize: contentSize,
            distortion: layer.distortion
        ) ?? layer.transform.renderTransform

        // Vektorinhalte bei starker Vergrösserung feiner rastern, sonst wird
        // eine hochskalierte Schrift sichtbar unscharf. Bei Bildern bringt das
        // nichts — deren Pixelzahl steht fest.
        renderedLayer.contentsScale = switch layer.content {
        case .image: contentsScale
        case .text, .shape: contentsScale * max(abs(layer.transform.scaleX), abs(layer.transform.scaleY), 1)
        }

        if case .image(let image) = layer.content {
            applyImageLayout(image, to: renderedLayer)
        }

        applyEffects(layer.effects, to: renderedLayer)
        applyTexture(layer, to: (renderedLayer as? ImageContentLayer)?.bitmap ?? renderedLayer)
        applyCommonProperties(layer, to: renderedLayer)

        // Anpassungen als Filterkette an die Schicht hängen statt das Bild neu
        // zu berechnen (Plan 7.2): Core Animation wendet sie auf der GPU an,
        // ein Reglerzug kostet damit keinen neu dekodierten Pixel. Genau das
        // macht das sofortige Feedback aus Plan 4.4 möglich.
        if case .image(let inhalt) = layer.content {
            let kette = AdjustmentPipeline.filters(for: inhalt.adjustments)
            // Wie bei Maske und Textur: an den Inhalt, damit der Rahmen
            // unverfälscht bleibt.
            let filterTarget = (renderedLayer as? ImageContentLayer)?.bitmap ?? renderedLayer
            filterTarget.filters = kette.isEmpty ? nil : kette
            if filterTarget !== renderedLayer { renderedLayer.filters = nil }
        } else {
            renderedLayer.filters = nil
        }
    }

    private func applyCommonProperties(_ layer: Layer, to renderedLayer: CALayer) {
        renderedLayer.isHidden = !layer.isVisible
        renderedLayer.opacity = Float(layer.opacity.clamped(to: 0...1))
        renderedLayer.compositingFilter = layer.blendMode.compositingFilterName
    }

    // MARK: - Inhaltsgrösse

    /// Die Grösse einer Ebene *vor* Skalierung. Bild- und Textebenen leiten
    /// sie aus ihrem Inhalt ab, Formen führen sie selbst (siehe
    /// `ShapeLayerContent.size`).
    func contentSize(of content: LayerContent) -> Size {
        switch content {
        case .image(let image):
            if let crop = image.cropRect {
                return Size(width: crop.width, height: crop.height)
            }
            guard images.image(named: image.originalFileReference) != nil,
                  let pixelSize = images.pixelSize(named: image.originalFileReference)
            else {
                // Fehlendes Original: feste Platzhaltergrösse, damit die Ebene
                // in der Liste und auf dem Canvas auffindbar bleibt.
                return Size(width: 320, height: 320)
            }
            return Size(pixelSize)

        case .text(let text):
            return Size(TextLayout.naturalSize(of: text))

        case .shape(let shape):
            return shape.size
        }
    }

    // MARK: - Ebenentypen

    private func makeContentLayer(for content: LayerContent) -> CALayer {
        switch content {
        case .image(let image): return makeImageLayer(image)
        case .text(let text): return makeTextLayer(text)
        case .shape(let shape): return makeShapeLayer(shape)
        }
    }

    /// Schreibt die inhaltsabhängigen Eigenschaften in eine bestehende
    /// Schicht. Passt die Art nicht zur Schicht, passiert nichts — dann baut
    /// der Aufrufer neu (siehe `canReuse(_:for:)`).
    private func applyContent(_ content: LayerContent, to renderedLayer: CALayer) {
        switch content {
        case .text(let text):
            guard let schicht = renderedLayer as? CATextLayer else { return }
            applyText(text, to: schicht)

        case .shape(let shape):
            guard let schicht = renderedLayer as? CAShapeLayer else { return }
            applyShape(shape, to: schicht)

        case .image(let image):
            guard !(renderedLayer is CATextLayer), !(renderedLayer is CAShapeLayer) else { return }
            guard let bild = images.image(named: image.originalFileReference),
                  let pixelSize = images.pixelSize(named: image.originalFileReference)
            else { return }
            guard let schicht = renderedLayer as? ImageContentLayer else { return }
            schicht.bitmap.contents = bild
            applyCrop(image.cropRect, imageSize: pixelSize, to: schicht.bitmap)
        }
    }

    private func makeImageLayer(_ content: ImageLayerContent) -> CALayer {
        let schicht = ImageContentLayer()
        if let image = images.image(named: content.originalFileReference),
           let pixelSize = images.pixelSize(named: content.originalFileReference) {
            schicht.bitmap.contents = image
            applyCrop(content.cropRect, imageSize: pixelSize, to: schicht.bitmap)
        } else {
            ImageContentLayer.markAsPlaceholder(schicht.bitmap)
        }
        return schicht
    }

    /// Legt Inhalt und Rahmen auf die Grösse der Ebene und zeichnet den
    /// Rahmen — oder nimmt ihn weg, wenn keiner eingestellt ist.
    private func applyImageLayout(_ content: ImageLayerContent, to container: CALayer) {
        guard let schicht = container as? ImageContentLayer else { return }
        schicht.layoutContents()

        guard content.borderWidth > 0, let pfad = ShapePath.borderPath(
            for: content, in: CGRect(origin: .zero, size: schicht.bounds.size)
        ) else {
            schicht.clearBorder()
            return
        }
        schicht.drawBorder(
            pfad,
            width: content.borderWidth,
            color: (RGBA(hex: content.borderColorHex) ?? .white).cgColor
        )
    }

    /// Zuschnitt nicht-destruktiv (Plan 5.3): Core Animation zeigt einen
    /// Ausschnitt der Bitmap, das Original bleibt ganz.
    private func applyCrop(_ crop: Rect?, imageSize: CGSize, to layer: CALayer) {
        guard let crop, imageSize.width > 0, imageSize.height > 0 else {
            layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }
        layer.contentsRect = CGRect(
            x: crop.x / imageSize.width,
            y: crop.y / imageSize.height,
            width: crop.width / imageSize.width,
            height: crop.height / imageSize.height
        )
    }

    private func makeTextLayer(_ content: TextLayerContent) -> CATextLayer {
        let layer = CATextLayer()
        layer.isWrapped = false
        layer.truncationMode = .none
        applyText(content, to: layer)
        return layer
    }

    private func applyText(_ content: TextLayerContent, to layer: CATextLayer) {
        layer.string = TextLayout.attributedString(for: content)
        layer.alignmentMode = switch content.alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
    }

    private func makeShapeLayer(_ content: ShapeLayerContent) -> CAShapeLayer {
        let layer = CAShapeLayer()
        applyShape(content, to: layer)
        return layer
    }

    private func applyShape(_ content: ShapeLayerContent, to layer: CAShapeLayer) {
        layer.path = ShapePath.cgPath(for: content, in: CGRect(origin: .zero, size: content.size.cgSize))
        layer.fillColor = (RGBA(hex: content.fillColorHex) ?? .white).cgColor
        // `strokeWidth == 0` heisst „kein Rand" — `CAShapeLayer` zeichnet bei
        // Breite 0 ohnehin nichts, aber `strokeColor = nil` macht die Absicht
        // zusätzlich explizit und spart eine (wirkungslose) Farbzuweisung.
        if content.strokeWidth > 0 {
            layer.strokeColor = (RGBA(hex: content.strokeColorHex) ?? .black).cgColor
            layer.lineWidth = content.strokeWidth
        } else {
            layer.strokeColor = nil
            layer.lineWidth = 0
        }
    }

    /// Sichtbarer Platzhalter für eine Ebene, deren Originaldatei fehlt.
    /// Besser als eine unsichtbare Ebene: der Fehler bleibt so auffindbar.
    private static func makePlaceholderLayer() -> CALayer {
        let layer = CALayer()
        layer.backgroundColor = NSColor.systemGray.withAlphaComponent(0.25).cgColor
        layer.borderColor = NSColor.systemRed.cgColor
        layer.borderWidth = 2
        return layer
    }
}

extension RGBA {
    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
