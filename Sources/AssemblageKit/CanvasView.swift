import AppKit
import QuartzCore
import AssemblageModel

/// Die Arbeitsfläche: rendert den Ebenenbaum als `CALayer`-Baum (Plan 7.2).
///
/// Die View ist genau so gross wie die Leinwand des Dokuments und liegt in
/// einer `NSScrollView` — Scrollen und Zoomen erledigt damit AppKit, inklusive
/// Pinch-Geste, die laut Plan 2.2 auch über Sidecar Direct Touch ankommt.
@MainActor
final class CanvasView: NSView {

    private var renderer: LayerRenderer
    /// Die Leinwand selbst — weisser Grund plus Schlagschatten, damit sie sich
    /// sichtbar vom Arbeitsbereich absetzt.
    private let canvasLayer = CALayer()
    /// Ebenen-ID → gerenderte Schicht, damit eine Änderung nicht den ganzen
    /// Baum neu aufbaut (das würde bei jedem Reglerzug alle Bilder neu
    /// hochladen und sichtbar ruckeln).
    private var renderedLayers: [UUID: CALayer] = [:]

    private var document: AssemblageModel.Document

    init(document: AssemblageModel.Document, images: ImageStore) {
        self.document = document
        self.renderer = LayerRenderer(images: images)
        super.init(frame: CGRect(origin: .zero, size: document.canvas.cgSize))

        wantsLayer = true
        layer?.addSublayer(canvasLayer)

        canvasLayer.backgroundColor = NSColor.white.cgColor
        // Ursprung oben links, y nach unten — das Koordinatensystem, auf das
        // sich das Modell festlegt (siehe LayerGeometryTests).
        canvasLayer.isGeometryFlipped = true
        // Ebenen enden an der Leinwandkante, statt darüber hinauszuragen.
        canvasLayer.masksToBounds = true
        canvasLayer.shadowColor = NSColor.black.cgColor
        canvasLayer.shadowOpacity = 0.18
        canvasLayer.shadowRadius = 12
        canvasLayer.shadowOffset = CGSize(width: 0, height: -2)

        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    // Bewusst *kein* `isFlipped = true`: eine geflippte NSView flippt bereits
    // ihre Trägerschicht, und zusammen mit `canvasLayer.isGeometryFlipped`
    // wäre unklar, welche Ebene das Koordinatensystem tatsächlich dreht.
    // Die Drehung passiert genau an einer Stelle — an `canvasLayer`.

    // MARK: - Aktualisierung

    func update(to newDocument: AssemblageModel.Document) {
        let canvasChanged = newDocument.canvas != document.canvas
        let structureChanged = newDocument.layers.map(\.id) != document.layers.map(\.id)
        document = newDocument

        if canvasChanged {
            frame = CGRect(origin: .zero, size: document.canvas.cgSize)
        }

        if structureChanged {
            rebuild()
        } else {
            // Häufigster Fall (ein Regler bewegt sich): nur Eigenschaften
            // auffrischen, kein Neuaufbau, keine neu dekodierten Bilder.
            for layer in document.layers {
                guard let rendered = renderedLayers[layer.id] else { continue }
                withoutAnimation { renderer.apply(layer, to: rendered) }
            }
        }
    }

    private func rebuild() {
        canvasLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        renderedLayers.removeAll()

        withoutAnimation {
            canvasLayer.frame = CGRect(origin: .zero, size: document.canvas.cgSize)
            // Reihenfolge im Modell = Kompositing-Reihenfolge, Index 0 zuunterst
            // — und genau so erwartet Core Animation seine `sublayers`.
            for layer in document.layers {
                let rendered = renderer.makeLayer(for: layer)
                renderedLayers[layer.id] = rendered
                canvasLayer.addSublayer(rendered)
            }
        }
    }

    /// Core Animation blendet Änderungen an Schicht-Eigenschaften
    /// standardmässig über eine Viertelsekunde ein. Beim Ziehen einer Ebene
    /// hinkt das Bild dadurch sichtbar dem Mauszeiger hinterher.
    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: - Bildschirmauflösung

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Beim Umziehen auf einen Bildschirm mit anderer Pixeldichte müssen
        // Text und Formen neu gerastert werden, sonst werden sie unscharf.
        let scale = window?.backingScaleFactor ?? 2
        guard scale != renderer.contentsScale else { return }
        renderer.contentsScale = scale
        rebuild()
    }
}

/// `NSClipView`, die ihren Inhalt zentriert, solange er kleiner als das
/// Fenster ist.
///
/// Ohne das klebt eine herausgezoomte Leinwand in der linken oberen Ecke —
/// AppKit kennt von sich aus keine Zentrierung.
final class CenteringClipView: NSClipView {

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }

        let content = documentView.frame

        if rect.width > content.width {
            rect.origin.x = (content.width - rect.width) / 2
        }
        if rect.height > content.height {
            rect.origin.y = (content.height - rect.height) / 2
        }
        return rect
    }
}
