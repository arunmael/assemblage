import AppKit
import Combine
import AssemblageModel

/// Beherbergt den Canvas in einer scroll- und zoombaren Fläche.
@MainActor
final class CanvasViewController: NSViewController {

    private let state: DocumentState
    private var canvasView: CanvasView!
    private var boardView: CanvasBoardView!
    private let scrollView = CanvasScrollView()
    private let clipView = CenteringClipView()
    private var observations: Set<AnyCancellable> = []
    /// Beim ersten Anzeigen einmal auf Fenstergrösse einpassen — danach nicht
    /// mehr, sonst würde jede Fenstergrössenänderung den vom Nutzer gewählten
    /// Zoom zurücksetzen.
    private var hasPerformedInitialFit = false
    var selectToolFromKeyboard: ((CanvasTool) -> Bool)?
    private var freehandColorHex = "#1D3557"
    private var freehandStrokeWidth = 6.0
    private var themeSubscription: AnyCancellable?

    init(state: DocumentState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    override func loadView() {
        canvasView = CanvasView(document: state.document, images: state.images)
        boardView = CanvasBoardView(canvasView: canvasView)

        scrollView.contentView = clipView
        scrollView.documentView = boardView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        // Ohne Elastizität lässt AppKit den Bildlauf ganz aus, sobald die
        // Leinwand kleiner als das Fenster ist — dann liesse sie sich gerade
        // beim Herauszoomen nicht mehr verschieben.
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .allowed
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        // Zoomen übernimmt AppKit — damit funktioniert die Pinch-Geste
        // automatisch, auch über Sidecar Direct Touch (Plan 2.2).
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 16

        canvasView.interactionDelegate = self
        canvasView.keyboardCommandDelegate = self
        canvasView.selectedLayerID = state.selectedLayerID

        // Die Zoomstufe ändert sich auch durch Pinch und Bildlauf, nicht nur
        // durch unsere Menübefehle — deshalb beobachten statt nur setzen.
        scrollView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(zoomDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        view = scrollView

        applyStageBackground()
        // Auf den nächsten Durchlauf verschieben: `sink` feuert, *bevor*
        // `@Published` den neuen Wert geschrieben hat — siehe `viewDidLoad`
        // weiter unten für dieselbe Einschränkung bei `state.$document`.
        themeSubscription = ThemeManager.shared.$current
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyStageBackground() } }
    }

    /// Der Fensterhintergrund hinter dem Canvas-Rahmen. In „Soulless"
    /// unverändert das System-Semantikfarbe (passt sich automatisch Hell/
    /// Dunkel an). In „Beautifull" liegt dahinter der Schreibtisch/andere
    /// Programme (`DocumentWindowController.applyWindowOpacity` macht das
    /// Fenster dafür nicht-deckend) — ein ganz leichter heller Schleier
    /// (`stageMilkTint`) sorgt dafür, dass die Fensterkante trotzdem als
    /// solche erkennbar bleibt, statt wie ein reines Loch zu wirken
    /// (Nutzer-Rückmeldung: „etwas milchiger, damit man erkennt, wo das
    /// Fenster aufhört").
    private func applyStageBackground() {
        if AssemblageTheme.aqua != nil {
            // Malt selbst nichts mehr: Den milchigen Schleier legt
            // `DocumentStageViewController.applyStageTint()` auf die
            // Container-Ansicht dahinter. Der Weg über den Bildlauf selbst
            // (`backgroundColor` oder eigene Ebene) trug nicht — AppKit
            // verwaltet dessen Ebene für den Bildlauf mit und räumte die
            // Farbe wieder weg.
            scrollView.drawsBackground = false
        } else {
            scrollView.drawsBackground = true
            scrollView.backgroundColor = .underPageBackgroundColor
        }
    }

    @objc private func zoomDidChange() {
        canvasView.zoomScale = scrollView.magnification
        onZoomPercentChange?(zoomPercent)
        // Feuert auch beim blossen Verschieben (es hängt an
        // `boundsDidChangeNotification` des Bildlaufs) — genau das brauchen die
        // Lineale, deren Nullpunkt sich dabei mitbewegt.
        onCanvasGeometryChange?()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        state.$document
            .sink { [weak self] document in
                // Auf den nächsten Durchlauf verschieben: `sink` feuert,
                // *bevor* `@Published` den neuen Wert geschrieben hat.
                DispatchQueue.main.async {
                    self?.canvasView.update(to: document)
                    // Eine geänderte Leinwandgrösse verschiebt den Nullpunkt
                    // der Lineale, ohne dass ein Bildlauf stattfindet.
                    self?.onCanvasGeometryChange?()
                }
            }
            .store(in: &observations)

        // Auswahl über die Ebenenliste muss den Rahmen auf dem Canvas
        // mitziehen — sonst zeigen Liste und Leinwand Verschiedenes.
        state.$selectedLayerID
            .sink { [weak self] id in
                DispatchQueue.main.async {
                    self?.canvasView.selectedLayerID = id
                    // Ein laufender Vorher/Nachher-Vergleich endet mit der
                    // Auswahl: Sonst bliebe eine Ebene unbearbeitet stehen,
                    // ohne dass noch etwas darauf hinweist, und man hielte
                    // den Vergleichszustand für das Ergebnis.
                    self?.endComparisonIfNeeded()
                }
            }
            .store(in: &observations)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !hasPerformedInitialFit, view.bounds.width > 0 else { return }
        hasPerformedInitialFit = true
        zoomToFit()
    }

    // MARK: - Zoom

    /// Setzt genau einen der von der Werkzeugleiste angebotenen Canvas-Modi.
    /// `select` ist der gemeinsame Normalmodus für Auswählen und Verschieben:
    /// Ein Klick wählt, ein Zug verschiebt die getroffene Ebene.
    func setTool(_ tool: CanvasTool, forSelected layer: Layer?) {
        loadViewIfNeeded()
        guard let canvasView else { return }

        let imageLayerID: UUID?
        if let layer, case .image = layer.content {
            imageLayerID = layer.id
        } else {
            imageLayerID = nil
        }

        switch tool {
        case .select:
            canvasView.freehandIsActive = false
            canvasView.croppingLayerID = nil
            canvasView.brushLayerID = nil
            canvasView.lassoLayerID = nil
            canvasView.paintLayerID = nil
            canvasView.distortingLayerID = nil
        case .crop:
            canvasView.freehandIsActive = false
            canvasView.brushLayerID = nil
            canvasView.lassoLayerID = nil
            canvasView.paintLayerID = nil
            canvasView.distortingLayerID = nil
            canvasView.croppingLayerID = imageLayerID
        case .brush:
            canvasView.freehandIsActive = false
            canvasView.croppingLayerID = nil
            canvasView.lassoLayerID = nil
            canvasView.paintLayerID = nil
            canvasView.distortingLayerID = nil
            canvasView.brushLayerID = imageLayerID
        case .lasso:
            canvasView.freehandIsActive = false
            canvasView.croppingLayerID = nil
            canvasView.brushLayerID = nil
            canvasView.paintLayerID = nil
            canvasView.distortingLayerID = nil
            canvasView.lassoLayerID = imageLayerID
        case .paint:
            canvasView.freehandIsActive = false
            canvasView.croppingLayerID = nil
            canvasView.brushLayerID = nil
            canvasView.lassoLayerID = nil
            canvasView.distortingLayerID = nil
            canvasView.paintLayerID = imageLayerID
        case .freehand:
            canvasView.croppingLayerID = nil
            canvasView.brushLayerID = nil
            canvasView.lassoLayerID = nil
            canvasView.paintLayerID = nil
            canvasView.distortingLayerID = nil
            canvasView.freehandIsActive = true
        case .distort:
            canvasView.freehandIsActive = false
            canvasView.croppingLayerID = nil
            canvasView.brushLayerID = nil
            canvasView.lassoLayerID = nil
            canvasView.paintLayerID = nil
            canvasView.distortingLayerID = layer?.id
        }
    }

    /// Übergibt die sichtbaren Pinsel-Einstellungen unverändert an den Canvas.
    func setBrush(_ brush: MaskBrush) {
        loadViewIfNeeded()
        canvasView?.brush = brush
    }

    func setLassoMode(_ mode: MaskBrush.Mode) {
        loadViewIfNeeded()
        canvasView?.lassoMode = mode
    }

    func setPaintBrush(_ brush: PaintBrush) {
        loadViewIfNeeded()
        canvasView?.paintBrush = brush
    }

    /// Übergibt Farbe und Breite an Vorschau und Einfügebefehl.
    func setFreehand(colorHex: String, width: Double) {
        freehandColorHex = colorHex
        freehandStrokeWidth = width
        loadViewIfNeeded()
        canvasView?.freehandColorHex = colorHex
        canvasView?.freehandStrokeWidth = width
    }

    /// Passt die Leinwand mit etwas Luft ins Fenster ein.
    @objc func zoomToFit() {
        let available = scrollView.contentView.bounds.size
        let canvas = state.document.canvas
        guard canvas.width > 0, canvas.height > 0, available.width > 0 else { return }

        let padding: CGFloat = 40
        let scale = min(
            (available.width - padding) / canvas.width,
            (available.height - padding) / canvas.height
        )
        // Nicht über 100 % hinaus vergrössern: ein Instagram-Post soll beim
        // Öffnen nicht formatfüllend aufgeblasen werden.
        scrollView.magnification = min(max(scale, scrollView.minMagnification), 1)
        clipView.centerDocument()
        zoomDidChange()
    }

    @objc func zoomToActualSize() {
        scrollView.magnification = 1
        zoomDidChange()
    }

    @objc func zoomIn() {
        scrollView.magnification = Self.steppedMagnification(from: scrollView.magnification, up: true)
        zoomDidChange()
    }

    @objc func zoomOut() {
        scrollView.magnification = Self.steppedMagnification(from: scrollView.magnification, up: false)
        zoomDidChange()
    }

    /// Die nächste Zoomstufe in 20-Prozent-Schritten (Nutzer-Auftrag): 60, 80,
    /// 100, 120 … statt der früheren Multiplikation mit 1.5.
    ///
    /// Von der aktuellen Stufe aus auf- bzw. abgerundet, damit ein per Pinch
    /// erreichter krummer Wert (82 %) beim nächsten Druck auf einer runden
    /// Stufe landet (100 % bzw. 80 %) und nicht krumm bleibt.
    ///
    /// Nach unten ist bei einer vollen Stufe Schluss statt bei den 5 % des
    /// Bildlaufs — eine halbe Stufe wäre genau der krumme Wert, den die
    /// Rundung sonst vermeidet.
    nonisolated static func steppedMagnification(
        from current: CGFloat, up: Bool, step: CGFloat = 0.2, maximum: CGFloat = 16
    ) -> CGFloat {
        // Toleranz, weil `magnification` nach Pinch und Fenstergrösse selten
        // exakt auf einer Stufe liegt: Ohne sie führte ein Druck bei 99.9997 %
        // nach 100 % statt nach 120 %.
        let stufen = current / step
        let ziel = up ? (floor(stufen + 0.001) + 1) : (ceil(stufen - 0.001) - 1)
        return min(max(ziel * step, step), maximum)
    }

    // Beide fragen die Stufenrechnung selbst, statt die Grenzen des Bildlaufs
    // zu vergleichen: Seit dem Zoom in festen 20-Prozent-Schritten ist die
    // unterste erreichbare Stufe 20 % und nicht mehr die technische
    // Mindestvergrösserung. Der Befehl ist damit genau dann verfügbar, wenn
    // ein Druck darauf auch etwas ändert.
    var canZoomIn: Bool {
        Self.steppedMagnification(from: scrollView.magnification, up: true)
            > scrollView.magnification + 0.0001
    }
    var canZoomOut: Bool {
        Self.steppedMagnification(from: scrollView.magnification, up: false)
            < scrollView.magnification - 0.0001
    }

    /// Aktuelle Zoomstufe, gerundet auf ganze Prozent — für die schwebende
    /// Zoom-Pille (Liquid-Glass-Mockup). Aktualisiert sich auch bei Pinch-
    /// und Bildlauf-Zoom, weil sie über `zoomDidChange()` läuft statt nur
    /// bei den eigenen Menübefehlen gesetzt zu werden.
    var zoomPercent: Int { Int((scrollView.magnification * 100).rounded()) }
    var onZoomPercentChange: ((Int) -> Void)?

    // MARK: - Lage der Leinwand (Grundlage der Lineale)

    /// Die Leinwand, wie sie gerade im Fenster liegt — inklusive Zoom und
    /// Bildlauf, weil `convert` die ganze Ansichtskette mitrechnet. Die
    /// Lineale leiten daraus Nullpunkt und Massstab ab.
    var canvasRectInWindow: NSRect { canvasView.convert(canvasView.bounds, to: nil) }

    /// Grösse der Leinwand in Dokumentpixeln (`CanvasView` setzt ihren Rahmen
    /// genau darauf, siehe `update(to:)`).
    var canvasDocumentSize: NSSize { canvasView.bounds.size }

    /// Läuft nach jeder Änderung von Zoom, Bildlauf oder Leinwandgrösse.
    var onCanvasGeometryChange: (() -> Void)?
}


// MARK: - Was auf dem Canvas passiert

extension CanvasViewController: CanvasInteractionDelegate, CanvasKeyboardCommandDelegate {

    func canvasView(_ canvasView: CanvasView, perform command: KeyboardCommand) -> Bool {
        if case .selectTool(let tool) = command {
            return selectToolFromKeyboard?(tool) ?? false
        }
        KeyboardCommands.perform(command, in: state)
        return true
    }

    func canvasView(_ canvasView: CanvasView, didSelectLayerWithID id: UUID?) {
        // Auswahl ist keine Dokumentänderung: Sie gehört nicht in den
        // Undo-Stack und macht das Dokument nicht ungesichert.
        state.selectedLayerID = id
    }

    func canvasViewDidBeginInteraction(_ canvasView: CanvasView) {
        state.owner?.beginInteraction()
    }

    func canvasView(_ canvasView: CanvasView, didChangeLayerWithID id: UUID, to transform: Transform2D) {
        // Der Name landet nur dann im Undo-Menü, wenn kein Ziehen läuft;
        // während eines Zugs setzt ihn `endInteraction(actionName:)`.
        state.owner?.modify("Ebene ändern") {
            try? $0.updateLayer(id: id) { $0.transform = transform }
        }
    }

    func canvasView(_ canvasView: CanvasView, didEndInteractionNamed actionName: String) {
        state.owner?.endInteraction(actionName: actionName)
    }

    func canvasView(
        _ canvasView: CanvasView,
        didDropImageLayerWithID imageID: UUID,
        ontoShapeWithID shapeID: UUID
    ) {
        ImageInShapeCommand.apply(imageLayerID: imageID, shapeLayerID: shapeID, fit: .cover, to: state)
    }

    func canvasView(_ canvasView: CanvasView, didChangeCropOfLayerWithID id: UUID, to crop: Rect) {
        guard let ebene = state.document.layer(withID: id),
              case .image(let inhalt) = ebene.content,
              state.images.image(named: inhalt.originalFileReference) != nil,
              let pixelSize = state.images.pixelSize(named: inhalt.originalFileReference)
        else { return }

        let groesse = Size(pixelSize)
        state.owner?.modify("Zuschneiden") {
            try? $0.updateLayer(id: id) { $0 = $0.cropped(to: crop, imageSize: groesse) }
        }
    }

    func canvasView(_ canvasView: CanvasView, didFinishEditingTextOfLayerWithID id: UUID, text: String) {
        state.owner?.modify("Text bearbeiten") {
            try? $0.updateLayer(id: id) { ebene in
                guard case .text(var inhalt) = ebene.content else { return }
                inhalt.string = text
                ebene.content = .text(inhalt)
            }
        }
    }

    func canvasView(
        _ canvasView: CanvasView,
        didChangeDistortionOfLayerWithID id: UUID,
        to distortion: QuadDistortion?
    ) {
        state.owner?.modify("Ebene verziehen") {
            try? $0.updateLayer(id: id) { $0.distortion = distortion }
        }
    }

    func canvasView(_ canvasView: CanvasView, didPaintMaskForLayerWithID id: UUID, pngData: Data) {
        // Jeder Strich legt eine **neue** Maskendatei an, statt die bestehende
        // zu überschreiben. Nur so holt ⌘Z die alten Pixel zurück: Der
        // Undo-Schnappschuss hält bloss die Referenz, nicht die Bitmap.
        //
        // Vertretbar ist das, weil Masken als PNG liegen und eine Maske sich
        // sehr gut komprimiert — grosse Flächen einer Farbe. Verwaiste
        // Maskendateien räumt `removeUnreferencedFiles` beim Sichern weg.
        let referenz = state.resources.addMask(pngData)

        state.owner?.modify("Maske malen") {
            try? $0.updateLayer(id: id) { ebene in
                ebene.mask = LayerMask(maskImageReference: referenz, source: .manualBrush)
            }
        }
    }

    func canvasView(_ canvasView: CanvasView, didFillLassoForLayerWithID id: UUID, pngData: Data) {
        // Wie beim Pinsel bleibt jede Fassung als eigene Ressource erhalten,
        // damit Undo nicht auf bereits überschriebene Pixel zeigt.
        let referenz = state.resources.addMask(pngData)

        state.owner?.modify("Bild ausschneiden") {
            try? $0.updateLayer(id: id) { ebene in
                ebene.mask = LayerMask(maskImageReference: referenz, source: .manualBrush)
            }
        }
    }

    /// Ein fertig gemalter Farbstrich (aus Anpassungen.md). Anders als beim
    /// Pinsel-Modus ist das PNG hier nicht die Maske, sondern der neue,
    /// sichtbare Inhalt der Ebene selbst — dieselbe Rolle wie ein importiertes
    /// Foto.
    func canvasView(_ canvasView: CanvasView, didPaintColorForLayerWithID id: UUID, pngData: Data) {
        // Aus demselben Grund wie bei der Maske eine **neue** Datei statt
        // eines Überschreibens: Nur so bringt ⌘Z die vorherigen Pixel
        // zurück, weil der Undo-Schnappschuss nur die Referenz hält.
        let referenz = state.resources.addOriginal(pngData, fileExtension: "png")

        state.owner?.modify("Farbe malen") {
            try? $0.updateLayer(id: id) { ebene in
                guard case .image(var inhalt) = ebene.content else { return }
                inhalt.originalFileReference = referenz
                ebene.content = .image(inhalt)
            }
        }
    }

    func canvasView(_ canvasView: CanvasView, didDrawFreehand rawPoints: [Point]) {
        FreehandDrawCommand.insert(
            rawPoints: rawPoints,
            strokeColorHex: freehandColorHex,
            strokeWidth: freehandStrokeWidth,
            into: state
        )
    }

    func canvasView(_ canvasView: CanvasView, didReceiveDropFrom pasteboard: NSPasteboard) {
        ImageDropCommand.handle(pasteboard: pasteboard, state: state, presentingWindow: canvasView.window)
    }
}

extension CanvasViewController {

    /// Zeigt die ausgewählte Ebene ohne ihre Bearbeitungen — oder wieder mit
    /// (Vorher/Nachher-Vergleich, aus missing.md).
    ///
    /// Ein Umschalter und kein gehaltener Knopf: Zum Vergleichen will man
    /// hin- und herschauen, oft mehrfach, und dabei nicht die ganze Zeit eine
    /// Taste festhalten müssen.
    ///
    /// `false` heisst „es gab nichts zu vergleichen" — der Aufrufer kann den
    /// Befehl dann ausgrauen, statt einen Umschalter anzubieten, der nichts tut.
    @discardableResult
    func toggleComparison() -> Bool {
        if canvasView.comparisonLayerID != nil {
            canvasView.comparisonLayerID = nil
            return true
        }

        guard let id = state.selectedLayerID,
              let layer = state.document.layer(withID: id),
              layer.hasEdits
        else { return false }

        canvasView.comparisonLayerID = id
        return true
    }

    var isComparing: Bool { canvasView.comparisonLayerID != nil }

    /// Der Vergleich endet, sobald eine andere Ebene gewählt wird — sonst
    /// zeigte die Leinwand eine Ebene unbearbeitet, ohne dass noch etwas
    /// darauf hinweist.
    func endComparisonIfNeeded() {
        guard let id = canvasView.comparisonLayerID, id != state.selectedLayerID else { return }
        canvasView.comparisonLayerID = nil
    }
}

/// Nur wegen `mouseDownCanMoveWindow` eine eigene Klasse: Das Fenster ist
/// `isMovableByWindowBackground`, und ohne diesen Widerspruch verschöbe ein
/// Zug auf der (im Erscheinungsbild „Beautifull" durchsichtigen) Fläche das
/// ganze Fenster, statt die Ebene zu bewegen — siehe ausführliche Begründung
/// in `CanvasBoardView`.
@MainActor
final class CanvasScrollView: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { false }

    /// Zeigerposition beim letzten Schritt des Ziehens mit der rechten Taste.
    private var panPosition: NSPoint?

    /// Mit der rechten Maustaste lässt sich die Leinwand frei verschieben
    /// (Nutzer-Auftrag) — dieselbe Geste, die Bildbearbeitungen sonst auf die
    /// Leertaste legen. Der linke Knopf bleibt dabei unangetastet, er gehört
    /// weiterhin den Werkzeugen.
    override func rightMouseDown(with event: NSEvent) {
        panPosition = event.locationInWindow
        NSCursor.closedHand.push()
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let vorher = panPosition else { return }
        let jetzt = event.locationInWindow

        // Der Inhalt folgt dem Zeiger, der sichtbare Ausschnitt wandert also
        // entgegengesetzt.
        var ursprung = contentView.bounds.origin
        ursprung.x -= jetzt.x - vorher.x
        ursprung.y -= (jetzt.y - vorher.y) * (contentView.isFlipped ? -1 : 1)

        contentView.setBoundsOrigin(contentView.constrainBoundsRect(
            NSRect(origin: ursprung, size: contentView.bounds.size)
        ).origin)
        reflectScrolledClipView(contentView)
        panPosition = jetzt
    }

    override func rightMouseUp(with event: NSEvent) {
        guard panPosition != nil else { return }
        panPosition = nil
        NSCursor.pop()
    }
}
