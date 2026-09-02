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
        rendered.contentsScale = contentsScale
        apply(layer, to: rendered)
        return rendered
    }

    /// Überträgt alles, was unabhängig vom Ebenentyp gilt.
    func apply(_ layer: Layer, to renderedLayer: CALayer) {
        let contentSize = self.contentSize(of: layer.content)
        let frame = layer.transform.unrotatedFrame(forContentSize: contentSize).cgRect

        // Erst bounds/position setzen, dann die Matrix: `frame` ist bei einer
        // gedrehten Ebene nicht mehr sinnvoll beschreibbar, deshalb nie
        // `renderedLayer.frame = …` verwenden.
        renderedLayer.bounds = CGRect(origin: .zero, size: frame.size)
        renderedLayer.position = CGPoint(x: frame.midX, y: frame.midY)
        renderedLayer.transform = layer.transform.renderTransform

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
            guard let loaded = images.image(named: image.originalFileReference) else {
                // Fehlendes Original: feste Platzhaltergrösse, damit die Ebene
                // in der Liste und auf dem Canvas auffindbar bleibt.
                return Size(width: 320, height: 320)
            }
            return Size(width: Double(loaded.width), height: Double(loaded.height))

        case .text(let text):
            return Size(Self.naturalSize(of: text))

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

        if let crop = content.cropRect {
            // Zuschnitt nicht-destruktiv (Plan 5.3): Core Animation zeigt
            // einfach einen Ausschnitt der Bitmap, das Original bleibt ganz.
            layer.contentsRect = CGRect(
                x: crop.x / Double(image.width),
                y: crop.y / Double(image.height),
                width: crop.width / Double(image.width),
                height: crop.height / Double(image.height)
            )
        }
        return layer
    }

    private func makeTextLayer(_ content: TextLayerContent) -> CATextLayer {
        let layer = CATextLayer()
        layer.string = Self.attributedString(for: content)
        layer.isWrapped = false
        layer.truncationMode = .none
        layer.alignmentMode = switch content.alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        return layer
    }

    private func makeShapeLayer(_ content: ShapeLayerContent) -> CAShapeLayer {
        let layer = CAShapeLayer()
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
        return layer
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

    // MARK: - Textsatz

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

extension RGBA {
    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
