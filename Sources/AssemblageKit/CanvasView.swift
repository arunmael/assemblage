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

    weak var interactionDelegate: CanvasInteractionDelegate?

    /// Die ausgewählte Ebene bekommt einen Rahmen. Nur eine — Assemblage
    /// kennt bewusst keine Mehrfachauswahl (Plan 4: „Ein Fenster, ein Fokus").
    var selectedLayerID: UUID? {
        didSet {
            guard selectedLayerID != oldValue else { return }
            updateSelectionOutline()
        }
    }

    /// Die Zoomstufe der umgebenden Bildlaufansicht.
    ///
    /// Der Auswahlrahmen wird mitskaliert wie alles andere; ohne Ausgleich
    /// wäre er bei 8-fachem Zoom ein fetter Balken und bei 10 % unsichtbar.
    var zoomScale: CGFloat = 1 {
        didSet {
            guard zoomScale != oldValue else { return }
            updateSelectionOutline()
        }
    }

    /// Liegt über der Leinwand statt darin: Der Auswahlrahmen einer Ebene am
    /// Bildrand soll nicht am Leinwandrand abgeschnitten werden.
    private let overlayLayer = CALayer()
    private let selectionOutline = CAShapeLayer()
    /// Alle Griffe in einer Schicht: Sie werden gemeinsam neu gezeichnet, und
    /// neun einzelne Schichten zu verwalten brächte nichts.
    private let handleShapes = CAShapeLayer()
    /// Die Ausrichtungslinien beim Ziehen (Plan 5.3).
    private let guideShapes = CAShapeLayer()

    /// Kantenlänge der gezeichneten Griffe, in Bildschirmpunkten.
    ///
    /// Bewusst grosszügig: Plan 2.2 hält fest, dass kleine Elemente bei
    /// direkter Fingerbedienung über Sidecar zu Fehltippern führen — und
    /// grosse Griffe passen ohnehin zur reduzierten Optik.
    static let handleSide: CGFloat = 10
    /// Fangbereich, etwas grösser als die sichtbare Fläche — man trifft dann
    /// auch, was man knapp verfehlt.
    static let handleHitRadius: Double = 11
    /// Abstand des Drehgriffs über der Oberkante.
    static let rotationHandleDistance: Double = 28
    /// Fangdistanz der Ausrichtungshilfen, in Bildschirmpunkten.
    ///
    /// In Bildschirm- und nicht in Leinwandpunkten gemessen: Beim Hineinzoomen
    /// arbeitet man feiner und will nicht aus grosser Entfernung eingefangen
    /// werden. Geteilt wird durch die Zoomstufe an der Aufrufstelle.
    static let snapDistance: Double = 8

    private var drag: CanvasDrag?

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

        overlayLayer.isGeometryFlipped = true
        overlayLayer.addSublayer(selectionOutline)
        overlayLayer.addSublayer(guideShapes)
        overlayLayer.addSublayer(handleShapes)
        guideShapes.fillColor = nil
        // Kräftiges Magenta wie in anderen Gestaltungsprogrammen: Die Linien
        // müssen sich von der Auswahlfarbe unterscheiden, sonst hält man sie
        // für einen Teil des Rahmens.
        guideShapes.strokeColor = NSColor.systemPink.cgColor
        selectionOutline.fillColor = nil
        selectionOutline.strokeColor = NSColor.controlAccentColor.cgColor
        // Weisse Griffe mit farbigem Rand: Sie müssen sowohl auf einem dunklen
        // Foto als auch auf weissem Grund erkennbar bleiben.
        handleShapes.fillColor = NSColor.white.cgColor
        handleShapes.strokeColor = NSColor.controlAccentColor.cgColor
        layer?.addSublayer(overlayLayer)

        // Fotos aus dem Finder oder der Fotos-App direkt auf die Leinwand
        // ziehen (Plan 5.1).
        registerForDraggedTypes([.fileURL, .tiff, .png])

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

        updateSelectionOutline()
    }

    private func rebuild() {
        canvasLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        renderedLayers.removeAll()

        withoutAnimation {
            canvasLayer.frame = CGRect(origin: .zero, size: document.canvas.cgSize)
            overlayLayer.frame = canvasLayer.frame
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

    // MARK: - Auswahlrahmen

    private func updateSelectionOutline() {
        guard let id = selectedLayerID, let layer = document.layer(withID: id) else {
            selectionOutline.path = nil
            handleShapes.path = nil
            return
        }

        let groesse = renderer.contentSize(of: layer.content)
        let ecken = layer.transform.corners(contentSize: groesse)

        let rahmen = CGMutablePath()
        rahmen.addLines(between: ecken.map { CGPoint(x: $0.x, y: $0.y) })
        rahmen.closeSubpath()

        // Alle Längen durch die Zoomstufe teilen: Rahmen und Griffe sollen bei
        // jeder Vergrösserung gleich gross wirken — sonst ist der Griff bei
        // 8-fachem Zoom ein Klotz und bei 10 % nicht mehr zu treffen.
        let seite = Self.handleSide / zoomScale
        let griffe = CGMutablePath()
        for griff in ResizeHandle.allCases {
            let mitte = layer.transform.position(of: griff, contentSize: groesse)
            griffe.addRect(CGRect(
                x: mitte.x - seite / 2, y: mitte.y - seite / 2,
                width: seite, height: seite
            ))
        }

        // Der Drehgriff rund, damit er sich ohne Hinsehen von den eckigen
        // Skaliergriffen unterscheidet.
        let dreh = layer.transform.rotationHandlePosition(
            contentSize: groesse,
            distance: Self.rotationHandleDistance / zoomScale
        )
        griffe.addEllipse(in: CGRect(
            x: dreh.x - seite / 2, y: dreh.y - seite / 2,
            width: seite, height: seite
        ))
        // Verbindungsstrich zur Ebene, sonst schwebt der Griff ohne Bezug.
        let oben = layer.transform.position(of: .top, contentSize: groesse)
        griffe.move(to: CGPoint(x: oben.x, y: oben.y))
        griffe.addLine(to: CGPoint(x: dreh.x, y: dreh.y))

        withoutAnimation {
            selectionOutline.path = rahmen
            selectionOutline.lineWidth = 1.5 / zoomScale
            handleShapes.path = griffe
            handleShapes.lineWidth = 1 / zoomScale
        }
    }

    // MARK: - Maus

    override var acceptsFirstResponder: Bool { true }

    /// Rechnet einen Punkt aus der Ansicht in Leinwandkoordinaten um.
    ///
    /// Die Ansicht selbst ist nicht geflippt (Ursprung unten links), die
    /// Leinwand rechnet oben links — die Umrechnung passiert genau hier und
    /// sonst nirgends.
    private func canvasPoint(from event: NSEvent) -> Point {
        let inView = convert(event.locationInWindow, from: nil)
        return Point(x: Double(inView.x), y: Double(bounds.height - inView.y))
    }

    override func mouseDown(with event: NSEvent) {
        let punkt = canvasPoint(from: event)

        // Griffe zuerst: Sie liegen zum Teil ausserhalb der Ebene (der
        // Drehgriff ganz) und würden sonst nie erreicht — man träfe stets die
        // Ebene darunter oder gar nichts.
        if let (kind, ebene) = handleDrag(at: punkt) {
            drag = CanvasDrag(
                kind: kind,
                layerID: ebene.id,
                startTransform: ebene.transform,
                contentSize: renderer.contentSize(of: ebene.content),
                startPoint: punkt
            )
            return
        }

        let getroffen = document.topmostLayer(at: punkt) { layer in
            renderer.contentSize(of: layer.content)
        }

        selectedLayerID = getroffen?.id
        interactionDelegate?.canvasView(self, didSelectLayerWithID: getroffen?.id)

        guard let getroffen else {
            drag = nil
            return
        }
        drag = CanvasDrag(
            kind: .move,
            layerID: getroffen.id,
            startTransform: getroffen.transform,
            contentSize: renderer.contentSize(of: getroffen.content),
            startPoint: punkt
        )
    }

    /// Sitzt der Punkt auf einem Griff der ausgewählten Ebene?
    private func handleDrag(at punkt: Point) -> (CanvasDrag.Kind, Layer)? {
        guard let id = selectedLayerID, let ebene = document.layer(withID: id) else { return nil }
        let groesse = renderer.contentSize(of: ebene.content)

        // Fangbereich grösser als die gezeichnete Fläche: Plan 2.2 warnt
        // ausdrücklich davor, dass kleine Ziele bei Fingerbedienung über
        // Sidecar zu Fehltippern führen.
        let toleranz = Self.handleHitRadius / zoomScale

        let dreh = ebene.transform.rotationHandlePosition(
            contentSize: groesse,
            distance: Self.rotationHandleDistance / zoomScale
        )
        if abs(dreh.x - punkt.x) <= toleranz, abs(dreh.y - punkt.y) <= toleranz {
            return (.rotate, ebene)
        }

        if let griff = ebene.transform.handle(at: punkt, contentSize: groesse, tolerance: toleranz) {
            return (.resize(griff), ebene)
        }
        return nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard var laufend = drag else { return }
        let warSchonAmZiehen = laufend.hasPassedThreshold

        let neu = laufend.transform(
            draggedTo: canvasPoint(from: event),
            constrains: event.modifierFlags.contains(.shift)
        )
        drag = laufend

        guard var neu else { return }  // Schwelle noch nicht erreicht

        // Nur beim Verschieben einrasten. Beim Skalieren und Drehen würde es
        // die Ebene unter dem Griff wegspringen lassen, statt zu helfen.
        if case .move = laufend.kind {
            neu = einrasten(neu, of: laufend)
        } else {
            zeigeAusrichtungslinien([])
        }

        // Die Undo-Klammer erst beim ersten echten Ziehen öffnen: Ein blosser
        // Klick zum Auswählen soll keinen leeren Schritt hinterlassen.
        if !warSchonAmZiehen {
            interactionDelegate?.canvasViewDidBeginInteraction(self)
        }

        interactionDelegate?.canvasView(self, didChangeLayerWithID: laufend.layerID, to: neu)
    }

    /// Wendet die Ausrichtungshilfen aus Plan 5.3 an und zeigt ihre Linien.
    private func einrasten(_ transform: Transform2D, of laufend: CanvasDrag) -> Transform2D {
        let gezogen = transform.boundingFrame(contentSize: laufend.contentSize)

        // Unsichtbare Ebenen zählen nicht: An etwas auszurichten, das man
        // nicht sieht, wäre nicht nachvollziehbar.
        let andere = document.layers
            .filter { $0.id != laufend.layerID && $0.isVisible }
            .map { $0.transform.boundingFrame(contentSize: renderer.contentSize(of: $0.content)) }

        let ergebnis = AlignmentGuides.snap(
            draggedFrame: gezogen,
            otherFrames: andere,
            canvasSize: document.canvas,
            snapDistance: Self.snapDistance / zoomScale
        )

        zeigeAusrichtungslinien(ergebnis.lines)

        var eingerastet = transform
        eingerastet.x += ergebnis.offsetX
        eingerastet.y += ergebnis.offsetY
        return eingerastet
    }

    private func zeigeAusrichtungslinien(_ linien: [AlignmentGuideLine]) {
        guard !linien.isEmpty else {
            withoutAnimation { guideShapes.path = nil }
            return
        }

        let pfad = CGMutablePath()
        for linie in linien {
            switch linie.orientation {
            case .vertical:
                pfad.move(to: CGPoint(x: linie.position, y: linie.start))
                pfad.addLine(to: CGPoint(x: linie.position, y: linie.end))
            case .horizontal:
                pfad.move(to: CGPoint(x: linie.start, y: linie.position))
                pfad.addLine(to: CGPoint(x: linie.end, y: linie.position))
            }
        }

        withoutAnimation {
            guideShapes.path = pfad
            guideShapes.lineWidth = 1 / zoomScale
        }
    }

    override func mouseUp(with event: NSEvent) {
        // Die Linien sind eine Hilfe *während* des Ziehens; danach wären sie
        // nur noch Striche ohne Bezug.
        zeigeAusrichtungslinien([])
        defer { drag = nil }
        guard let laufend = drag, laufend.hasPassedThreshold else { return }
        interactionDelegate?.canvasView(self, didEndInteractionNamed: laufend.kind.actionName)
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

// MARK: - Bilder auf die Leinwand ziehen

extension CanvasView {

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    /// Meldet nur dann Bereitschaft, wenn tatsächlich etwas Brauchbares
    /// dabei ist — sonst zeigt der Finder ein Pluszeichen an und die App
    /// verschluckt den Wurf danach wortlos.
    private func dropOperation(for sender: any NSDraggingInfo) -> NSDragOperation {
        ImageImporter.canImport(from: sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard ImageImporter.canImport(from: sender.draggingPasteboard) else { return false }
        interactionDelegate?.canvasView(self, didReceiveDropFrom: sender.draggingPasteboard)
        return true
    }
}
