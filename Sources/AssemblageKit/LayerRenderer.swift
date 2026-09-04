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

    let images: ImageStore
    /// Pixel pro Punkt des Bildschirms — sonst sind Text und Formen auf
    /// Retina-Displays sichtbar unscharf.
    var contentsScale: CGFloat = 2

    // MARK: - Aufbau

    func makeLayer(for layer: Layer) -> CALayer {
        let rendered = makeContentLayer(for: layer.content)
        apply(layer, to: rendered)
        applyMask(layer, to: rendered)
        return rendered
    }

    /// Lässt sich diese Schicht für den Inhalt weiterverwenden?
    ///
    /// Nur der Wechsel der Ebenen*art* verlangt eine neue Schicht — Text
    /// braucht eine `CATextLayer`, eine Form eine `CAShapeLayer`. Alles
    /// andere, auch ein geänderter Text oder eine andere Füllfarbe, wird in
    /// der bestehenden Schicht aufgefrischt: Sie neu zu bauen hiesse bei
    /// Bildebenen, das Foto erneut zu dekodieren.
    func canReuse(_ renderedLayer: CALayer, for content: LayerContent) -> Bool {
        switch content {
        case .text: return renderedLayer is CATextLayer
        case .shape: return renderedLayer is CAShapeLayer
        case .image:
            // Der Platzhalter für ein fehlendes Original ist eine schlichte
            // CALayer; taucht die Datei wieder auf, muss neu gebaut werden.
            guard !(renderedLayer is CATextLayer), !(renderedLayer is CAShapeLayer) else { return false }
            return renderedLayer.contents != nil
        }
    }

    /// Hängt die Ebenenmaske als `CALayer.mask` an (Plan 5.4).
    ///
    /// Core Animation wendet sie damit auf der GPU an — dasselbe Vorgehen wie
    /// bei den Anpassungen, und aus demselben Grund: Eine Maske zu ändern darf
    /// kein Neuzeichnen des Bildes auslösen.
    func applyMask(_ layer: Layer, to renderedLayer: CALayer) {
        let ausschnitt: Rect?
        if case .image(let inhalt) = layer.content {
            ausschnitt = inhalt.cropRect
        } else {
            ausschnitt = nil
        }

        guard let maskenbild = MaskRendering.alphaMaskImage(
            for: layer,
            cropRect: ausschnitt,
            resources: images.resources
        ) else {
            renderedLayer.mask = nil
            return
        }

        let maske = CALayer()
        maske.contents = maskenbild
        maske.contentsGravity = .resize
        // Deckungsgleich mit der Ebene: Die Maske liegt im selben
        // Koordinatensystem wie ihr Inhalt.
        maske.frame = CGRect(origin: .zero, size: renderedLayer.bounds.size)
        renderedLayer.mask = maske
    }

    /// Überträgt alles, was unabhängig vom Ebenentyp gilt — und frischt den
    /// Inhalt der Schicht auf.
    ///
    /// Das Auffrischen gehört hierher und nicht nur in `makeLayer`: Sonst
    /// zeigte die Leinwand nach dem Umschreiben eines Textes weiter den
    /// alten, weil die Schicht ja schon existiert. Ein Neuaufbau passiert
    /// nur, wenn sich die Ebenenstruktur ändert — beim Tippen also nie.
    func apply(_ layer: Layer, to renderedLayer: CALayer) {
        applyContent(layer.content, to: renderedLayer)
        let contentSize = self.contentSize(of: layer.content)

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

        renderedLayer.isHidden = !layer.isVisible
        renderedLayer.opacity = Float(layer.opacity.clamped(to: 0...1))
        renderedLayer.compositingFilter = layer.blendMode.compositingFilterName

        // Anpassungen als Filterkette an die Schicht hängen statt das Bild neu
        // zu berechnen (Plan 7.2): Core Animation wendet sie auf der GPU an,
        // ein Reglerzug kostet damit keinen neu dekodierten Pixel. Genau das
        // macht das sofortige Feedback aus Plan 4.4 möglich.
        if case .image(let inhalt) = layer.content {
            let kette = AdjustmentPipeline.filters(for: inhalt.adjustments)
            renderedLayer.filters = kette.isEmpty ? nil : kette
        } else {
            renderedLayer.filters = nil
        }
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
            guard let loaded = images.image(named: image.originalFileReference) else {
                // Fehlendes Original: feste Platzhaltergrösse, damit die Ebene
                // in der Liste und auf dem Canvas auffindbar bleibt.
                return Size(width: 320, height: 320)
            }
            return Size(width: Double(loaded.width), height: Double(loaded.height))

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
            guard let bild = images.image(named: image.originalFileReference) else { return }
            renderedLayer.contents = bild
            applyCrop(image.cropRect, imageWidth: bild.width, imageHeight: bild.height, to: renderedLayer)
        }
    }

    private func makeImageLayer(_ content: ImageLayerContent) -> CALayer {
        guard let image = images.image(named: content.originalFileReference) else {
            return Self.makePlaceholderLayer()
        }

        let layer = CALayer()
        layer.contents = image
        // `.resize` und nicht `.resizeAspect`: die Ebene hat bereits exakt das
        // Seitenverhältnis ihres Inhalts, ein Einpassen würde nur Rundungs-
        // ränder erzeugen.
        layer.contentsGravity = .resize
        layer.magnificationFilter = .trilinear
        layer.minificationFilter = .trilinear
        applyCrop(content.cropRect, imageWidth: image.width, imageHeight: image.height, to: layer)
        return layer
    }

    /// Zuschnitt nicht-destruktiv (Plan 5.3): Core Animation zeigt einen
    /// Ausschnitt der Bitmap, das Original bleibt ganz.
    private func applyCrop(_ crop: Rect?, imageWidth: Int, imageHeight: Int, to layer: CALayer) {
        guard let crop, imageWidth > 0, imageHeight > 0 else {
            layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }
        layer.contentsRect = CGRect(
            x: crop.x / Double(imageWidth),
            y: crop.y / Double(imageHeight),
            width: crop.width / Double(imageWidth),
            height: crop.height / Double(imageHeight)
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
        let bounds = CGRect(origin: .zero, size: content.size.cgSize)

        layer.path = switch content.kind {
        case .rectangle:
            CGPath(rect: bounds, transform: nil)
        case .roundedRectangle:
            // Der Radius kann nicht grösser als die halbe kürzere Seite sein —
            // sonst zeichnet Core Graphics gar nichts.
            CGPath(
                roundedRect: bounds,
                cornerWidth: min(content.cornerRadius, bounds.width / 2),
                cornerHeight: min(content.cornerRadius, bounds.height / 2),
                transform: nil
            )
        case .ellipse:
            CGPath(ellipseIn: bounds, transform: nil)
        }

        layer.fillColor = (RGBA(hex: content.fillColorHex) ?? .white).cgColor
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
