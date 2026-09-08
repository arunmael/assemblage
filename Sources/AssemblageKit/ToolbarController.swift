import AppKit
import Combine
import AssemblageModel

/// Die drei Zustände, welche die vorhandene Canvas-Interaktion tatsächlich
/// kennt. Auswählen und Verschieben aus der Vorlage sind bewusst ein Werkzeug:
/// Im Normalmodus wählt ein Klick eine Ebene aus und ein Zug verschiebt sie.
/// Zwei Knöpfe würden daher denselben Canvas-Zustand vortäuschen.
enum CanvasTool: Equatable {
    case select
    case crop
    case brush
    case lasso
    case paint
    case freehand
    case distort
}

/// Regeln der Werkzeugauswahl, getrennt von der AppKit-Darstellung.
@MainActor
struct ToolSelection {

    /// Ist das Werkzeug bei dieser Auswahl überhaupt benutzbar?
    static func isAvailable(_ tool: CanvasTool, forSelected layer: Layer?) -> Bool {
        switch tool {
        case .select, .freehand:
            return true
        case .crop, .brush, .lasso, .paint:
            guard let layer, case .image = layer.content else { return false }
            return true
        case .distort:
            return layer != nil
        }
    }

    /// Auf welches Werkzeug wird geschaltet, wenn `tool` angetippt wird,
    /// während `current` aktiv ist? Ein zweiter Klick führt zum Auswählen.
    static func toggled(_ tool: CanvasTool, current: CanvasTool) -> CanvasTool {
        tool == current ? .select : tool
    }

    /// Auf welches Werkzeug fällt man zurück, wenn sich die Auswahl ändert?
    static func adjusted(_ current: CanvasTool, forSelected layer: Layer?) -> CanvasTool {
        isAvailable(current, forSelected: layer) ? current : .select
    }
}

/// Bindet die testbare Werkzeuglogik an die schwebende Liquid-Glass-
/// Werkzeugleiste (aus dem Claude-Design-Mockup „Assemblage UI") und den
/// Canvas.
///
/// Der Controller besitzt keinen Dokumentzustand neben `DocumentState`: Er
/// übersetzt nur Auswahl und Bedienung in die bereits vorhandenen Canvas-Modi.
/// Anders als zuvor baut er keine `NSToolbar` mehr, sondern liefert fertige
/// `NSView`s, die `DocumentStageViewController` als schwebende Panels über
/// dem Canvas platziert — das Mockup zeigt keine native Titelleisten-
/// Werkzeugleiste, sondern eigenständige, abgerundete Glas-Cluster.
@MainActor
final class ToolbarController: NSObject, NSMenuItemValidation, NSTextFieldDelegate {

    private let state: DocumentState
    private weak var canvasViewController: CanvasViewController?
    private weak var commandTarget: DocumentWindowController?
    private var observations: Set<AnyCancellable> = []

    private var currentTool: CanvasTool = .select {
        didSet { reportToolState() }
    }
    private var selectedLayer: Layer?
    private var toolButtons: [CanvasTool: NSButton] = [:]

    /// Um wie viel der aktive Werkzeugknopf grösser gezeichnet wird — statt
    /// des früheren blauen Leuchtens. 10 % waren dem Nutzer zu wenig, um den
    /// Unterschied auf einen Blick zu sehen; bei 30 % ragt der aktive Knopf
    /// deutlich aus der Reihe. Mehr geht nicht ohne höhere Werkzeugleiste:
    /// Die Zeilenhöhe (`toolbarRowHeight`) begrenzt ihn nach oben.
    private static let activeToolScale: CGFloat = 1.3

    /// Was `applyActiveIndicator` braucht, um einen Werkzeugknopf zwischen
    /// Normal- und Aktiv-Grösse umzuschalten: die Grundmasse und die beiden
    /// Zwänge, deren Konstanten dafür verändert werden.
    @MainActor
    private struct ToolButtonSizing {
        let icon: MockupIcon
        let baseSize: CGFloat
        let baseIconPointSize: CGFloat
        let width: NSLayoutConstraint
        let height: NSLayoutConstraint
    }
    private var toolButtonSizing: [CanvasTool: ToolButtonSizing] = [:]
    private weak var removeSubjectButton: NSButton?
    private var timelineIsExpanded = false
    private weak var collapsedTimelineRow: NSView?
    private weak var expandedTimelineRow: NSView?
    private weak var undoTimeline: UndoTimelineView?

    private var undoManager: UndoManager? {
        (commandTarget?.document as? AssemblageDocument)?.undoManager
    }

    /// Die Werkzeugsuche (Anpassungen.md / Nutzer-Rückmeldung): ein
    /// Ergebnis-Popover, das beim Tippen sowohl Werkzeuge als auch
    /// Ebenennamen durchsucht.
    private weak var searchField: NSTextField?
    private var searchPopover: NSPopover?
    private var searchResultActions: [Int: () -> Void] = [:]

    /// Der schwebende Einstellungs-Streifen unterhalb der Werkzeugleiste, der
    /// nur bei Pinsel/Lasso/Farbe erscheint — im Mockup nicht vorgesehen
    /// (dort gibt es weder Lasso noch Farbpinsel), aber ohne ihn gäbe es für
    /// diese bestehenden Werkzeuge keine Bedienelemente mehr.
    private weak var settingsBar: GlassPanel?
    private var settingsContent: NSView?

    private var brush = MaskBrush(diameter: 60, hardness: 0.5, mode: .hide) {
        didSet { reportToolState() }
    }

    private var lassoMode: MaskBrush.Mode = .hide {
        didSet { reportToolState() }
    }

    /// Einstellungen des Farbpinsels (aus Anpassungen.md).
    private var paintBrush = PaintBrush(diameter: 30, hardness: 0.8, colorHex: "#000000", opacity: 1) {
        didSet { reportToolState() }
    }

    private var freehandColorHex = "#1D3557"
    private var freehandStrokeWidth = 6.0

    /// Jeder über `makeToolButton`/`makePillButton`/`plainIconButton`
    /// erzeugte Icon-Knopf trägt sich hier ein. `MockupIcons.image` malt die
    /// Tönung fest in die Bilddaten (kein Template-Bild, siehe dortiger
    /// Kommentar) — beim Themenwechsel muss das Bild deshalb neu gezeichnet
    /// werden, ein blosses Neuzeichnen des Knopfs würde die alte Farbe
    /// unverändert weiter anzeigen.
    @MainActor
    private struct ThemedIconButton {
        let button: NSButton
        let icon: MockupIcon
        let pointSize: CGFloat
        /// Meist `AssemblageTheme.textPrimary` — der „Verlauf ausblenden"-
        /// Knopf zeigt aber dauerhaft die Akzentfarbe (siehe `buildUndoBar`)
        /// und würde sonst bei jedem Themenwechsel auf die normale Textfarbe
        /// zurückfallen.
        var tint: @MainActor () -> NSColor = { AssemblageTheme.textPrimary }
    }
    private var themedIconButtons: [ThemedIconButton] = []
    private weak var searchIconView: NSImageView?
    private weak var shapeMenuTitleItem: NSMenuItem?
    private weak var gridMenuTitleItem: NSMenuItem?
    private weak var zoomPercentLabel: NSTextField?
    private weak var zoomLCDBackdrop: NSView?
    private var zoomLCDPadding: (leading: NSLayoutConstraint, trailing: NSLayoutConstraint, top: NSLayoutConstraint, bottom: NSLayoutConstraint)?
    private var themeSubscription: AnyCancellable?

    init(
        state: DocumentState,
        canvasViewController: CanvasViewController,
        commandTarget: DocumentWindowController
    ) {
        self.state = state
        self.canvasViewController = canvasViewController
        self.commandTarget = commandTarget
        super.init()

        state.$document
            .combineLatest(state.$selectedLayerID)
            .sink { [weak self] document, selectedLayerID in
                let layer = selectedLayerID.flatMap { document.layer(withID: $0) }
                self?.selectionDidChange(to: layer)
            }
            .store(in: &observations)

        state.$undoDepth
            .combineLatest(state.$redoDepth)
            .sink { [weak self] undoDepth, redoDepth in
                self?.undoTimeline?.setDepths(undo: undoDepth, redo: redoDepth)
            }
            .store(in: &observations)

        // Läuft auch einmal sofort beim Erstellen (siehe `@Published`), also
        // vor dem eigentlichen Aufbau der Werkzeugleiste in
        // `buildFloatingToolbarRow()` — zu diesem Zeitpunkt sind Registrierung
        // und Wörterbücher noch leer, `refreshTheme()` ist dann ein No-op.
        // Auf den nächsten Durchlauf verschieben: `sink` feuert, *bevor*
        // `@Published` den neuen Wert geschrieben hat (siehe auch
        // `CanvasViewController.viewDidLoad`) — `refreshTheme()` läse sonst
        // noch das alte Erscheinungsbild.
        themeSubscription = ThemeManager.shared.$current
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshTheme() } }
    }

    /// Zieht alle Icon-Knöpfe und die LCD-Anzeige auf das gerade aktive
    /// Erscheinungsbild nach — läuft bei jedem Themenwechsel (siehe `init`).
    private func refreshTheme() {
        for entry in themedIconButtons {
            entry.button.image = MockupIcons.image(entry.icon, pointSize: entry.pointSize, tintColor: entry.tint())
            entry.button.needsDisplay = true
        }
        searchIconView?.image = MockupIcons.image(.search, pointSize: 15, tintColor: AssemblageTheme.textTertiary)
        shapeMenuTitleItem?.image = MockupIcons.image(.insertShape, pointSize: 16, tintColor: AssemblageTheme.textPrimary)
        gridMenuTitleItem?.image = MockupIcons.image(.collageGrid, pointSize: 16, tintColor: AssemblageTheme.textPrimary)
        updatePresentation()
        applyZoomLCDStyle()
    }

    // MARK: - Werkzeugzustand

    private func selectionDidChange(to layer: Layer?) {
        selectedLayer = layer
        currentTool = ToolSelection.adjusted(currentTool, forSelected: layer)
        applyCurrentToolToCanvas()
        updatePresentation()
    }

    @objc private func selectTool(_ sender: Any?) { toggle(.select) }
    @objc private func cropTool(_ sender: Any?) { toggle(.crop) }
    @objc private func brushTool(_ sender: Any?) { toggle(.brush) }
    @objc private func lassoTool(_ sender: Any?) { toggle(.lasso) }
    @objc private func paintTool(_ sender: Any?) { toggle(.paint) }
    @objc private func freehandTool(_ sender: Any?) { toggle(.freehand) }
    @objc private func distortTool(_ sender: Any?) { toggle(.distort) }

    private func toggle(_ tool: CanvasTool) {
        guard ToolSelection.isAvailable(tool, forSelected: selectedLayer) else { return }
        currentTool = ToolSelection.toggled(tool, current: currentTool)
        applyCurrentToolToCanvas()
        updatePresentation()
    }

    /// Wählt ein Werkzeug direkt über die Tastatur. Anders als ein erneuter
    /// Klick auf den aktiven Knopf schaltet derselbe Befehl nicht zurück.
    func select(_ tool: CanvasTool) -> Bool {
        guard ToolSelection.isAvailable(tool, forSelected: selectedLayer) else { return false }
        currentTool = tool
        applyCurrentToolToCanvas()
        updatePresentation()
        return true
    }

    private func applyCurrentToolToCanvas() {
        canvasViewController?.setTool(currentTool, forSelected: selectedLayer)
        if currentTool == .brush {
            canvasViewController?.setBrush(brush)
        } else if currentTool == .lasso {
            canvasViewController?.setLassoMode(lassoMode)
        } else if currentTool == .freehand {
            canvasViewController?.setFreehand(colorHex: freehandColorHex, width: freehandStrokeWidth)
        }
    }

    private func updatePresentation() {
        for (tool, button) in toolButtons {
            let available = ToolSelection.isAvailable(tool, forSelected: selectedLayer)
            button.isEnabled = available
            button.alphaValue = available ? 1 : 0.35
            let isActive = tool == currentTool
            button.state = isActive ? .on : .off
            applyActiveIndicator(to: button, tool: tool, isActive: isActive)
            button.contentTintColor = isActive ? AssemblageTheme.accentDark : AssemblageTheme.textPrimary
        }

        // Freistellen ist ein einmaliger Befehl und kein vierter Canvas-Modus.
        // Der bestehende Befehlscontroller blockiert doppelte laufende Aufrufe.
        let removeSubjectAvailable = ToolSelection.isAvailable(.brush, forSelected: selectedLayer)
        removeSubjectButton?.isEnabled = removeSubjectAvailable
        // Ohne diese Zeile sah der Knopf bei fehlender Bildauswahl weiterhin
        // vollständig anklickbar aus (randlose Knöpfe dimmen bei
        // `isEnabled = false` nicht von selbst) — ein Klick tat dann
        // sichtbar nichts, ohne erkennbar zu sein, warum.
        removeSubjectButton?.alphaValue = removeSubjectAvailable ? 1 : 0.35
        updateSettingsBarVisibility()
    }

    /// Zeigt den aktiven Zustand eines Werkzeugknopfs an: Er wird 10 % grösser
    /// dargestellt als die übrigen (Nutzer-Auftrag).
    ///
    /// Ersetzt die beiden früheren, farbigen Anzeigen — die Akzent-Füllung in
    /// „Soulless" und das „Blue LED"-Leuchten in „Beautifull". Grösse statt
    /// Farbe funktioniert in beiden Erscheinungsbildern gleich; das Leuchten
    /// war nur nötig, weil eine Füllung unter dem deckenden Glas-Bezel von
    /// `AquaButtonCell` unsichtbar geblieben wäre.
    ///
    /// Das Icon wird dabei neu gezeichnet statt hochskaliert: `MockupIcons`
    /// malt Pfade, ein vergrössertes Bitmap hätte weiche Kanten.
    private func applyActiveIndicator(to button: NSButton, tool: CanvasTool, isActive: Bool) {
        // Reste der früheren Anzeigen abräumen (ein einmal gesetzter Schatten
        // bliebe sonst am Knopf hängen).
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.layer?.shadowOpacity = 0

        guard let sizing = toolButtonSizing[tool] else { return }
        let faktor = isActive ? Self.activeToolScale : 1
        sizing.width.constant = sizing.baseSize * faktor
        sizing.height.constant = sizing.baseSize * faktor
        button.image = MockupIcons.image(
            sizing.icon,
            pointSize: sizing.baseIconPointSize * faktor,
            tintColor: AssemblageTheme.textPrimary
        )
    }

    /// Ersetzt den Inhalt des Einstellungs-Streifens passend zum aktiven
    /// Werkzeug und blendet ihn nur ein, wenn es überhaupt Regler gibt.
    /// Meldet den Sichtbarkeitswechsel zusätzlich nach aussen, damit
    /// `DocumentStageViewController` das Eigenschaften-Panel darunter aus dem
    /// Weg rücken kann — sonst überlappten sich beide Panels bei Pinsel/Farbe
    /// (deren Regler-Streifen höher ist als der feste Standardabstand).
    private func updateSettingsBarVisibility() {
        let content: NSView?
        switch currentTool {
        case .brush: content = makeBrushSettingsView()
        case .lasso: content = makeLassoSettingsView()
        case .paint: content = makePaintSettingsView()
        case .freehand: content = makeFreehandSettingsView()
        case .select, .crop, .distort: content = nil
        }
        settingsContent = content
        settingsBar?.content = content
        settingsBar?.isHidden = content == nil
        onSettingsBarVisibilityChange?(content != nil)
    }

    /// Sagt, ob der Einstellungs-Streifen gerade sichtbar ist (Pinsel/Lasso/
    /// Farbe) — `DocumentStageViewController` verschiebt danach den Ankerpunkt
    /// des Eigenschaften-Panels.
    var onSettingsBarVisibilityChange: ((Bool) -> Void)?

    // MARK: - Zugang für Tests

    /// Derselbe Weg wie der Grössen-Regler in der Werkzeugleiste, ohne einen
    /// echten `NSSlider` zu brauchen.
    func setBrushDiameterForTesting(_ diameter: Double) {
        brush.diameter = diameter
        canvasViewController?.setBrush(brush)
    }

    func setLassoModeForTesting(_ mode: MaskBrush.Mode) {
        lassoMode = mode
        canvasViewController?.setLassoMode(mode)
    }

    /// Derselbe Weg wie die Werkzeugleisten-Regler des Farbpinsels, ohne
    /// echte `NSSlider`/`NSColorWell` zu brauchen.
    func setPaintBrushForTesting(_ neu: PaintBrush) {
        paintBrush = neu
        canvasViewController?.setPaintBrush(paintBrush)
    }

    /// Für Tests der schwebenden Werkzeugleiste: derselbe Weg wie ein
    /// Mausklick auf den Werkzeugknopf, ohne ein echtes Ereignis zu bauen.
    func simulateToolTapForTesting(_ tool: CanvasTool) {
        toggle(tool)
    }

    var availableToolsForTesting: Set<CanvasTool> {
        Set(CanvasTool.allToolbarCases.filter { ToolSelection.isAvailable($0, forSelected: selectedLayer) })
    }

    var currentToolForTesting: CanvasTool { currentTool }

    @objc private func diameterChanged(_ sender: NSSlider) {
        brush.diameter = sender.doubleValue
        canvasViewController?.setBrush(brush)
    }

    @objc private func hardnessChanged(_ sender: NSSlider) {
        brush.hardness = sender.doubleValue
        canvasViewController?.setBrush(brush)
    }

    @objc private func brushModeChanged(_ sender: NSSegmentedControl) {
        brush.mode = sender.selectedSegment == 1 ? .reveal : .hide
        canvasViewController?.setBrush(brush)
    }

    @objc private func lassoModeChanged(_ sender: NSSegmentedControl) {
        lassoMode = sender.selectedSegment == 1 ? .reveal : .hide
        canvasViewController?.setLassoMode(lassoMode)
    }

    private func reportToolState() {
        state.reportToolState(
            currentTool,
            brush: brush,
            lassoMode: lassoMode,
            paintBrush: paintBrush
        )
    }

    // MARK: - Befehle

    @objc private func removeSubject(_ sender: Any?) {
        commandTarget?.removeSubjectBackground(sender)
        updatePresentation()
    }

    @objc private func insertText(_ sender: Any?) {
        commandTarget?.insertTextLayer(sender)
    }

    @objc private func zoomToFit(_ sender: Any?) { canvasViewController?.zoomToFit() }
    @objc private func zoomToActualSize(_ sender: Any?) { canvasViewController?.zoomToActualSize() }
    @objc private func zoomIn(_ sender: Any?) { canvasViewController?.zoomIn() }
    @objc private func zoomOut(_ sender: Any?) { canvasViewController?.zoomOut() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(zoomIn(_:)) {
            return canvasViewController?.canZoomIn == true
        }
        if menuItem.action == #selector(zoomOut(_:)) {
            return canvasViewController?.canZoomOut == true
        }
        return true
    }

    /// Öffnet den normalen Export-Dialog (Format/Qualität/Grösse + Sichern-
    /// Panel) — der Knopf selbst trägt zwar Apples Teilen-Symbol (aus
    /// Anpassungen.md: „nutze dafür bitte den normalen Apple Teilen Button"),
    /// aber der System-Teilen-Dialog (`NSSharingServicePicker`, nur AirDrop/
    /// Mail/Nachrichten) bot keine Wahl von Format, Qualität oder Grösse.
    /// Nutzt deshalb denselben Weg wie „Ablage › Exportieren…" (Problems.md).
    @objc private func shareDocument(_ sender: NSButton) {
        commandTarget?.exportDocument(sender)
    }

    // MARK: - Schwebende Werkzeugleiste (Liquid-Glass-Mockup)

    /// Baut die komplette obere rechte Zeile: Werkzeug-Cluster, Sekundär-
    /// Cluster, Suchfeld, Teilen-Knopf — exakt die vier Gruppen aus dem
    /// Mockup, im selben Abstand (14 pt).
    /// Höhe jedes Panels der schwebenden Werkzeugzeile. Das Mass gibt der
    /// grösste Fall im Werkzeug-Cluster vor: der *aktive* Knopf mit 38 pt ×
    /// `activeToolScale` (49.4 pt) plus 4 pt Rand oben und unten.
    static let toolbarRowHeight: CGFloat = 58

    func buildFloatingToolbarRow() -> NSView {
        let panels = [
            makePrimaryToolCluster(),
            makeSecondaryToolCluster(),
            makeSearchField(),
            makeShareButton()
        ]
        let row = NSStackView(views: panels)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        // Ohne feste Höhe zieht die Kette Werkzeugleiste → Regler-Streifen →
        // Eigenschaften-Panel (dessen Unterkante am Fenster festhängt) diese
        // Zeile bei Pinsel/Lasso/Farbe auf über 400 pt auseinander; die
        // Cluster drifteten dann sichtbar über die halbe Fensterhöhe.
        // Hugging-Prioritäten helfen hier nicht: Die geerbte
        // Content-Hugging-Priorität steuert die Höhe eines `NSStackView`
        // nicht, und die Stack-eigene liesse ihn auf die kleinste
        // Clusterhöhe (44 pt) zusammenfallen. Massgeblich ist der
        // 50 pt hohe Werkzeug-Cluster.
        row.heightAnchor.constraint(equalToConstant: Self.toolbarRowHeight).isActive = true

        // Alle vier Panels gleich hoch. `NSStackView` kennt dafür — anders als
        // `UIStackView` — keine füllende Ausrichtung: Seine `alignment` legt
        // nur fest, woran die Ansichten ausgerichtet werden, nicht dass sie
        // sich dehnen. Die gemeinsame Höhe muss deshalb ausdrücklich gesetzt
        // werden. `GlassPanel` spannt seinen Inhalt randlos über die volle
        // Fläche, die Panelhöhe ist also zugleich die Inhaltshöhe.
        for panel in panels {
            panel.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
        }
        return row
    }

    /// Der Einstellungs-Streifen für Pinsel/Lasso/Farbe — eine eigene
    /// schwebende Pille direkt unter der Werkzeugleiste, nur sichtbar,
    /// solange eines dieser drei Werkzeuge aktiv ist.
    func buildToolSettingsBar() -> GlassPanel {
        let bar = GlassPanel(cornerRadius: AssemblageTheme.toolClusterCornerRadius)
        settingsBar = bar
        updateSettingsBarVisibility()
        return bar
    }

    private func makePrimaryToolCluster() -> NSView {
        let select = makeToolButton(tool: .select, label: "Auswählen (V)", icon: .select, size: 38, action: #selector(selectTool(_:)))
        let crop = makeToolButton(tool: .crop, label: "Zuschneiden (C)", icon: .crop, size: 38, action: #selector(cropTool(_:)))
        let warp = makeToolButton(tool: .distort, label: "Verziehen", icon: .warp, size: 38, action: #selector(distortTool(_:)))

        let stack = NSStackView(views: [select, crop, warp])
        stack.orientation = .horizontal
        // Grösserer Abstand als früher (4 pt), weil der aktive Knopf jetzt
        // 10 % mehr Platz einnimmt (siehe `applyActiveIndicator`) und sonst
        // fast an seine Nachbarn stiesse.
        stack.spacing = 9
        // Oben/unten knapper als vorher (6 pt): Die Panelhöhe ist über
        // `toolbarRowHeight` fest auf 50 pt gesetzt, der aktive Knopf braucht
        // davon 41.8 pt — mit 6 pt Rand wären es 53.8 pt und die Zwänge
        // widersprächen sich.
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        return wrapInGlassPanel(stack, cornerRadius: AssemblageTheme.toolClusterCornerRadius)
    }

    private func makeSecondaryToolCluster() -> NSView {
        // Lasso und Farbpinsel haben im Mockup keinen eigenen Platz — es kennt
        // beide Werkzeuge nicht. Damit sie erreichbar bleiben, stehen sie mit
        // dem Pinsel im rechten Werkzeug-Cluster.
        let brush = makeToolButton(tool: .brush, label: "Pinsel (B)", icon: .brush, size: 36, action: #selector(brushTool(_:)))
        let lasso = makeToolButton(tool: .lasso, label: "Bild ausschneiden", icon: .lasso, size: 36, action: #selector(lassoTool(_:)))
        let paint = makeToolButton(tool: .paint, label: "Farbe malen", icon: .paintDrop, size: 36, action: #selector(paintTool(_:)))
        let freehand = makeToolButton(tool: .freehand, label: "Freihand zeichnen", icon: .pen, size: 36, action: #selector(freehandTool(_:)))

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let removeSubject = makePillButton(label: "Freistellen", icon: .removeSubject, action: #selector(removeSubject(_:)), zeigtTitel: false)
        removeSubjectButton = removeSubject

        let text = makePillButton(label: "Text", icon: .insertText, action: #selector(insertText(_:)), zeigtTitel: false)
        let shape = makeShapePillMenu()
        let grid = makeGridPillMenu()

        let stack = NSStackView(views: [brush, lasso, paint, freehand, divider, removeSubject, text, shape, grid])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        // Wie im ersten Cluster: mehr Luft für den 10 % grösseren aktiven
        // Knopf, oben/unten dafür knapper wegen der festen Panelhöhe.
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        return wrapInGlassPanel(stack, cornerRadius: AssemblageTheme.toolClusterCornerRadius)
    }

    private func makeSearchField() -> NSView {
        let icon = NSImageView(image: MockupIcons.image(.search, pointSize: 15, tintColor: AssemblageTheme.textTertiary))
        icon.translatesAutoresizingMaskIntoConstraints = false
        searchIconView = icon

        let field = NSTextField()
        field.placeholderString = "Werkzeug suchen…"
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 12.5)
        // Ohne das hier zeichnet AppKit beim Fokussieren/Tippen ein
        // deutliches Rechteck um das Feld — hier unerwünscht, weil die
        // Werkzeugleisten-Pille selbst schon die sichtbare Umrandung ist.
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        let preferredWidth = field.widthAnchor.constraint(equalToConstant: 150)
        preferredWidth.priority = .defaultLow
        preferredWidth.isActive = true
        // Das Suchfeld gibt bei knapper Fensterbreite zuerst Platz frei,
        // damit die eigentlichen Werkzeugbefehle vollständig bedienbar bleiben.
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchField = field

        let stack = NSStackView(views: [icon, field])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)

        return wrapInGlassPanel(stack, cornerRadius: AssemblageTheme.toolClusterCornerRadius)
    }

    // MARK: - Werkzeugsuche

    /// Ein einzelner Treffer im Such-Popover: entweder ein Werkzeug/Befehl
    /// (mit Icon) oder eine Ebene (ohne Icon, dafür mit Typ als Untertitel).
    private struct SearchResult {
        let title: String
        let subtitle: String?
        let icon: MockupIcon?
        let action: () -> Void
    }

    /// Alle über die Suche erreichbaren Werkzeuge und Befehle — dieselben
    /// Aktionen wie ihre Knöpfe in der Werkzeugleiste, nur zusätzlich über
    /// den Namen auffindbar (auch die im Cluster nicht sichtbaren wie Lasso
    /// und Farbpinsel).
    private func searchableTools() -> [SearchResult] {
        [
            SearchResult(title: "Auswählen", subtitle: nil, icon: .select) { [weak self] in self?.toggle(.select) },
            SearchResult(title: "Zuschneiden", subtitle: nil, icon: .crop) { [weak self] in self?.toggle(.crop) },
            SearchResult(title: "Pinsel", subtitle: nil, icon: .brush) { [weak self] in self?.toggle(.brush) },
            SearchResult(title: "Bild ausschneiden", subtitle: "Lasso", icon: .removeSubject) { [weak self] in self?.toggle(.lasso) },
            SearchResult(title: "Farbe malen", subtitle: nil, icon: .brush) { [weak self] in self?.toggle(.paint) },
            SearchResult(title: "Freihand zeichnen", subtitle: nil, icon: .pen) { [weak self] in self?.toggle(.freehand) },
            SearchResult(title: "Verziehen", subtitle: nil, icon: .warp) { [weak self] in self?.toggle(.distort) },
            SearchResult(title: "Freistellen", subtitle: nil, icon: .removeSubject) { [weak self] in self?.removeSubject(nil) },
            SearchResult(title: "Text einfügen", subtitle: nil, icon: .insertText) { [weak self] in self?.insertText(nil) },
            SearchResult(title: "Rechteck einfügen", subtitle: "Form", icon: .insertShape) { [weak self] in
                self?.commandTarget?.insertRectangleLayer(nil)
            },
            SearchResult(title: "Ellipse einfügen", subtitle: "Form", icon: .insertShape) { [weak self] in
                self?.commandTarget?.insertEllipseLayer(nil)
            },
            SearchResult(title: "Raster 2×2", subtitle: "Vorlage", icon: .collageGrid) { [weak self] in
                self?.commandTarget?.applyGrid2x2Template(nil)
            },
            SearchResult(title: "Raster 3×3", subtitle: "Vorlage", icon: .collageGrid) { [weak self] in
                self?.commandTarget?.applyGrid3x3Template(nil)
            },
            SearchResult(title: "Polaroid-Stapel", subtitle: "Vorlage", icon: .collageGrid) { [weak self] in
                self?.commandTarget?.applyPolaroidStackTemplate(nil)
            },
            SearchResult(title: "Teilen", subtitle: "Exportieren…", icon: .share) { [weak self] in
                self?.commandTarget?.exportDocument(nil)
            },
            SearchResult(title: "Vergrössern", subtitle: "Zoom", icon: .zoomIn) { [weak self] in self?.canvasViewController?.zoomIn() },
            SearchResult(title: "Verkleinern", subtitle: "Zoom", icon: .zoomOut) { [weak self] in self?.canvasViewController?.zoomOut() },
            SearchResult(title: "An Fenster anpassen", subtitle: "Zoom", icon: nil) { [weak self] in self?.canvasViewController?.zoomToFit() }
        ]
    }

    private func searchableLayers(matching query: String) -> [SearchResult] {
        LayerListEditing(state: state).layersInListOrder
            .filter { $0.name.lowercased().contains(query) }
            .map { layer in
                SearchResult(title: layer.name, subtitle: layerTypeName(layer), icon: nil) { [weak self] in
                    self?.state.selectedLayerID = layer.id
                }
            }
    }

    private func layerTypeName(_ layer: Layer) -> String {
        switch layer.content {
        case .image: "Bild"
        case .text: "Text"
        case .shape: "Form"
        }
    }

    /// Läuft bei jeder Texteingabe im Suchfeld (`NSTextFieldDelegate`).
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === searchField else { return }
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            searchPopover?.performClose(nil)
            return
        }

        let layerMatches = searchableLayers(matching: query)
        let toolMatches = searchableTools().filter { $0.title.lowercased().contains(query) }

        guard !layerMatches.isEmpty || !toolMatches.isEmpty else {
            searchPopover?.performClose(nil)
            return
        }

        showSearchResults(layers: layerMatches, tools: toolMatches, anchor: field)
    }

    /// Schliesst das Popover, wenn das Suchfeld den Fokus verliert, ohne
    /// dass ein Ergebnis angeklickt wurde.
    func controlTextDidEndEditing(_ obj: Notification) {
        searchPopover?.performClose(nil)
    }

    private func showSearchResults(layers: [SearchResult], tools: [SearchResult], anchor: NSView) {
        searchResultActions.removeAll()
        var tag = 0
        var rows: [NSView] = []

        func addSection(_ title: String, _ results: [SearchResult]) {
            guard !results.isEmpty else { return }
            let header = NSTextField(labelWithString: title.uppercased())
            header.font = .systemFont(ofSize: 10, weight: .bold)
            header.textColor = AssemblageTheme.textTertiary
            rows.append(header)
            for result in results.prefix(6) {
                rows.append(makeResultRow(result, tag: &tag))
            }
        }
        addSection("Ebenen", layers)
        addSection("Werkzeuge", tools)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        let seitenrand: CGFloat = 16
        stack.edgeInsets = NSEdgeInsets(top: 12, left: seitenrand, bottom: 12, right: seitenrand)
        for row in rows {
            row.translatesAutoresizingMaskIntoConstraints = false
            // Um beide Seitenränder verkürzt statt auf die volle Stack-Breite:
            // Sonst reicht jede Zeile über die `edgeInsets` hinaus bis an den
            // Popover-Rand, und Überschrift wie Ergebniszeilen kleben dort
            // (Nutzer-Rückmeldung: Text weiter weg vom Rand).
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -seitenrand * 2).isActive = true
        }

        let content = NSViewController()
        content.view = stack
        // Etwas breiter als früher (220), damit die Ergebniszeilen trotz der
        // neuen Seitenränder gleich viel Text zeigen wie vorher.
        stack.widthAnchor.constraint(equalToConstant: 252).isActive = true

        let popover = searchPopover ?? NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        searchPopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private func makeResultRow(_ result: SearchResult, tag: inout Int) -> NSButton {
        let button = NSButton(title: result.subtitle.map { "\(result.title)  ·  \($0)" } ?? result.title, target: self, action: #selector(searchResultTapped(_:)))
        button.isBordered = false
        button.alignment = .left
        button.font = .systemFont(ofSize: 12.5)
        button.contentTintColor = AssemblageTheme.textPrimary
        if let icon = result.icon {
            button.image = MockupIcons.image(icon, pointSize: 14, tintColor: AssemblageTheme.textPrimary)
            button.imagePosition = .imageLeading
        }
        button.tag = tag
        searchResultActions[tag] = result.action
        tag += 1
        return button
    }

    @objc private func searchResultTapped(_ sender: NSButton) {
        searchResultActions[sender.tag]?()
        searchPopover?.performClose(nil)
        searchField?.stringValue = ""
    }

    private func makeShareButton() -> NSView {
        // Die Klickfläche kommt aus `hitSize`; eine zweite, abweichende
        // Grössenangabe daneben ergäbe zwei widersprüchliche Zwänge.
        let button = plainIconButton(
            icon: .share, pointSize: 17, hitSize: 44, label: "Teilen", action: #selector(shareDocument(_:))
        )

        // Nutzer-Rückmeldung: kein umschliessendes Glas-Panel mehr — der
        // Knopf (schon rund über `AquaButtonCell`) steht für sich, ohne
        // Kachel-Umrandung. Trotzdem eine zentrierende Zwischenansicht statt
        // des Knopfs direkt: `buildFloatingToolbarRow()` zieht jedes Element
        // dieser Zeile auf dieselbe 50-pt-Zeilenhöhe hoch — ohne Hülle stiesse
        // das direkt mit der festen 44-pt-Knopfhöhe zusammen.
        let huelle = NSView()
        huelle.translatesAutoresizingMaskIntoConstraints = false
        huelle.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: huelle.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: huelle.centerYAnchor),
            huelle.widthAnchor.constraint(equalToConstant: 44)
        ])
        return huelle
    }

    /// Ein sichtbares Form-Icon, dessen Menü alle verfügbaren Formen anbietet.
    private func makeShapePillMenu() -> NSView {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false

        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.image = MockupIcons.image(.insertShape, pointSize: 16, tintColor: AssemblageTheme.textPrimary)
        button.menu?.addItem(title)
        shapeMenuTitleItem = title

        let shapeKinds = NewLayerKind.allCases.filter { $0 != .text }
        for (index, kind) in shapeKinds.enumerated() {
            if index == 3 {
                button.menu?.addItem(.separator())
            }
            let item = NSMenuItem(
                title: kind.localizedName,
                action: #selector(DocumentWindowController.insertShapeFromMenu(_:)),
                keyEquivalent: ""
            )
            item.representedObject = kind
            item.target = commandTarget
            button.menu?.addItem(item)
        }

        button.font = .systemFont(ofSize: 12.5, weight: .semibold)
        button.toolTip = "Form"
        button.setAccessibilityLabel("Form")
        return button
    }

    /// „Raster" — alle kuratierten Collage-Vorlagen.
    private func makeGridPillMenu() -> NSView {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false

        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.image = MockupIcons.image(.collageGrid, pointSize: 16, tintColor: AssemblageTheme.textPrimary)
        button.menu?.addItem(title)
        gridMenuTitleItem = title

        for template in CollageTemplate.allCases {
            let item = NSMenuItem(
                title: template.localizedName,
                action: #selector(DocumentWindowController.applyTemplateFromMenu(_:)),
                keyEquivalent: ""
            )
            item.representedObject = template
            item.target = commandTarget
            button.menu?.addItem(item)
        }
        button.menu?.addItem(.separator())
        let remove = NSMenuItem(title: "Raster aufheben", action: #selector(DocumentWindowController.removeGridTemplate(_:)), keyEquivalent: "")
        remove.target = commandTarget
        button.menu?.addItem(remove)

        button.font = .systemFont(ofSize: 12.5, weight: .semibold)
        button.toolTip = "Raster"
        button.setAccessibilityLabel("Raster")
        return button
    }

    // MARK: - Bausteine

    private func makeToolButton(
        tool: CanvasTool,
        label: String,
        icon: MockupIcon,
        size: CGFloat,
        action: Selector
    ) -> NSButton {
        // Leer erstellen und `cell` sofort tauschen, bevor Titel/Bild/
        // Ziel gesetzt werden: `NSButton(title:target:action:)` würde diese
        // Werte auf der alten Zelle ablegen, ein späterer Zellentausch liesse
        // sie dann verschwinden (neue Zellen starten leer).
        let button = NSButton()
        button.cell = AquaButtonCell()
        button.title = ""
        button.target = self
        button.action = action
        button.image = MockupIcons.image(icon, pointSize: 18, tintColor: AssemblageTheme.textPrimary)
        themedIconButtons.append(ThemedIconButton(button: button, icon: icon, pointSize: 18))
        // Immer `true`: Im Erscheinungsbild „Soulless" zeichnet
        // `AquaButtonCell.drawBezel` nichts (siehe dort), das Ergebnis bleibt
        // also der bisherige randlose Look; „Beautifull" bekommt dieselbe
        // Zelle als glänzenden Aqua-Knopf.
        button.isBordered = true
        button.setButtonType(.toggle)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.wantsLayer = true
        // Nur für die „Soulless"-Aktiv-Füllung relevant (siehe
        // `applyActiveIndicator`) — deren `layer.backgroundColor` braucht
        // einen passenden Eckenradius, um wie eine abgerundete Fläche statt
        // eines Rechtecks auszusehen. Der Glas-Knopf in „Beautifull" bestimmt
        // seine eigene (pillenförmige) Kontur unabhängig davon selbst.
        button.layer?.cornerRadius = AssemblageTheme.toolButtonCornerRadius
        button.translatesAutoresizingMaskIntoConstraints = false
        // Als Variablen statt inline aktiviert: `applyActiveIndicator` schaltet
        // den aktiven Knopf über genau diese beiden Konstanten auf 110 %.
        let width = button.widthAnchor.constraint(equalToConstant: size)
        let height = button.heightAnchor.constraint(equalToConstant: size)
        NSLayoutConstraint.activate([width, height])
        toolButtonSizing[tool] = ToolButtonSizing(
            icon: icon, baseSize: size, baseIconPointSize: 18, width: width, height: height
        )
        button.isEnabled = ToolSelection.isAvailable(tool, forSelected: selectedLayer)
        toolButtons[tool] = button
        return button
    }

    /// Ein Icon+Text-Knopf wie „Freistellen"/„Text"/„Raster" im Mockup.
    private func makePillButton(label: String, icon: MockupIcon, action: Selector?, zeigtTitel: Bool = true) -> NSButton {
        let button = NSButton()
        button.cell = AquaButtonCell()
        button.title = zeigtTitel ? label : ""
        button.target = action == nil ? nil : self
        button.action = action
        button.image = MockupIcons.image(icon, pointSize: 16, tintColor: AssemblageTheme.textPrimary)
        themedIconButtons.append(ThemedIconButton(button: button, icon: icon, pointSize: 16))
        button.imagePosition = zeigtTitel ? .imageLeading : .imageOnly
        button.imageHugsTitle = true
        button.isBordered = true
        button.wantsLayer = true
        button.font = .systemFont(ofSize: 12.5, weight: .semibold)
        button.contentTintColor = AssemblageTheme.textPrimary
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        if !zeigtTitel {
            button.widthAnchor.constraint(equalToConstant: 36).isActive = true
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }
        return button
    }

    private func plainIconButton(
        icon: MockupIcon,
        pointSize: CGFloat,
        hitSize: CGFloat? = nil,
        label: String,
        action: Selector?
    ) -> NSButton {
        let button = NSButton()
        button.cell = AquaButtonCell()
        button.target = action == nil ? nil : self
        button.action = action
        button.image = MockupIcons.image(icon, pointSize: pointSize, tintColor: AssemblageTheme.textPrimary)
        themedIconButtons.append(ThemedIconButton(button: button, icon: icon, pointSize: pointSize))
        button.isBordered = true
        button.wantsLayer = true
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        let buttonSize = hitSize ?? pointSize
        button.widthAnchor.constraint(equalToConstant: buttonSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: buttonSize).isActive = true
        return button
    }

    private func wrapInGlassPanel(_ content: NSView, cornerRadius: CGFloat) -> NSView {
        let panel = GlassPanel(cornerRadius: cornerRadius)
        panel.content = content
        return panel
    }

    // MARK: - Werkzeug-Einstellungen (Pinsel/Lasso/Farbe)

    private func makeBrushSettingsView() -> NSView {
        let diameter = NSSlider(
            value: brush.diameter, minValue: 1, maxValue: 500,
            target: self, action: #selector(diameterChanged(_:))
        )
        diameter.isContinuous = true
        diameter.translatesAutoresizingMaskIntoConstraints = false
        diameter.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let hardness = NSSlider(
            value: brush.hardness, minValue: 0, maxValue: 1,
            target: self, action: #selector(hardnessChanged(_:))
        )
        hardness.isContinuous = true
        hardness.translatesAutoresizingMaskIntoConstraints = false
        hardness.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let mode = NSSegmentedControl(
            labels: ["Abdecken", "Zurückholen"], trackingMode: .selectOne,
            target: self, action: #selector(brushModeChanged(_:))
        )
        mode.selectedSegment = brush.mode == .hide ? 0 : 1
        mode.controlSize = .large

        let stack = NSStackView(views: [
            labelledControl("Grösse", control: diameter),
            labelledControl("Härte", control: hardness),
            mode
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        return stack
    }

    private func makeLassoSettingsView() -> NSView {
        let mode = NSSegmentedControl(
            labels: ["Abdecken", "Zurückholen"], trackingMode: .selectOne,
            target: self, action: #selector(lassoModeChanged(_:))
        )
        mode.selectedSegment = lassoMode == .hide ? 0 : 1
        mode.controlSize = .large

        let stack = NSStackView(views: [mode])
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        return stack
    }

    private func makeFreehandSettingsView() -> NSView {
        let farbe = NSColorWell()
        let anfangsfarbe = RGBA(hex: freehandColorHex) ?? .black
        farbe.color = NSColor(
            srgbRed: anfangsfarbe.red, green: anfangsfarbe.green,
            blue: anfangsfarbe.blue, alpha: anfangsfarbe.alpha
        )
        farbe.target = self
        farbe.action = #selector(freehandColorChanged(_:))

        let breite = NSSlider(
            value: freehandStrokeWidth, minValue: 1, maxValue: 40,
            target: self, action: #selector(freehandWidthChanged(_:))
        )
        breite.isContinuous = true
        breite.translatesAutoresizingMaskIntoConstraints = false
        breite.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let stack = NSStackView(views: [
            farbe,
            labelledControl("Strichbreite", control: breite)
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        return stack
    }

    @objc private func freehandColorChanged(_ sender: NSColorWell) {
        guard let umgerechnet = sender.color.usingColorSpace(.sRGB) else { return }
        freehandColorHex = RGBA(
            red: Double(umgerechnet.redComponent),
            green: Double(umgerechnet.greenComponent),
            blue: Double(umgerechnet.blueComponent),
            alpha: Double(umgerechnet.alphaComponent)
        ).hexString
        canvasViewController?.setFreehand(colorHex: freehandColorHex, width: freehandStrokeWidth)
    }

    @objc private func freehandWidthChanged(_ sender: NSSlider) {
        freehandStrokeWidth = sender.doubleValue
        canvasViewController?.setFreehand(colorHex: freehandColorHex, width: freehandStrokeWidth)
    }

    private func makePaintSettingsView() -> NSView {
        let farbe = NSColorWell()
        let anfangsfarbe = RGBA(hex: paintBrush.colorHex) ?? .black
        farbe.color = NSColor(
            srgbRed: anfangsfarbe.red, green: anfangsfarbe.green,
            blue: anfangsfarbe.blue, alpha: anfangsfarbe.alpha
        )
        farbe.target = self
        farbe.action = #selector(paintColorChanged(_:))

        let diameter = NSSlider(
            value: paintBrush.diameter, minValue: 1, maxValue: 300,
            target: self, action: #selector(paintDiameterChanged(_:))
        )
        diameter.isContinuous = true
        diameter.translatesAutoresizingMaskIntoConstraints = false
        diameter.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let hardness = NSSlider(
            value: paintBrush.hardness, minValue: 0, maxValue: 1,
            target: self, action: #selector(paintHardnessChanged(_:))
        )
        hardness.isContinuous = true
        hardness.translatesAutoresizingMaskIntoConstraints = false
        hardness.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let opacity = NSSlider(
            value: paintBrush.opacity, minValue: 0, maxValue: 1,
            target: self, action: #selector(paintOpacityChanged(_:))
        )
        opacity.isContinuous = true
        opacity.translatesAutoresizingMaskIntoConstraints = false
        opacity.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let stack = NSStackView(views: [
            farbe,
            labelledControl("Grösse", control: diameter),
            labelledControl("Härte", control: hardness),
            labelledControl("Deckkraft", control: opacity)
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        return stack
    }

    @objc private func paintColorChanged(_ sender: NSColorWell) {
        guard let umgerechnet = sender.color.usingColorSpace(.sRGB) else { return }
        paintBrush.colorHex = RGBA(
            red: Double(umgerechnet.redComponent),
            green: Double(umgerechnet.greenComponent),
            blue: Double(umgerechnet.blueComponent),
            alpha: Double(umgerechnet.alphaComponent)
        ).hexString
        canvasViewController?.setPaintBrush(paintBrush)
    }

    @objc private func paintDiameterChanged(_ sender: NSSlider) {
        paintBrush.diameter = sender.doubleValue
        canvasViewController?.setPaintBrush(paintBrush)
    }

    @objc private func paintHardnessChanged(_ sender: NSSlider) {
        paintBrush.hardness = sender.doubleValue
        canvasViewController?.setPaintBrush(paintBrush)
    }

    @objc private func paintOpacityChanged(_ sender: NSSlider) {
        paintBrush.opacity = sender.doubleValue
        canvasViewController?.setPaintBrush(paintBrush)
    }

    private func labelledControl(_ label: String, control: NSView) -> NSView {
        let field = NSTextField(labelWithString: label)
        field.font = .systemFont(ofSize: 11)
        field.textColor = AssemblageTheme.textSecondary
        let stack = NSStackView(views: [field, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }

    // MARK: - Zoom- und Verlaufsleiste

    /// Die Zoom-Pille — nur Prozentzahl und Minus/Plus, ohne Beschriftung
    /// (auf ausdrücklichen Wunsch ohne „Einpassen"-Text; „An Fenster
    /// anpassen" bleibt über Menü/Zoom-Menü in der Werkzeugleiste erreichbar).
    func buildZoomBar() -> GlassPanel {
        let percent = NSTextField(labelWithString: "100 %")
        percent.font = .systemFont(ofSize: 12, weight: .semibold)
        percent.textColor = AssemblageTheme.textSecondary
        canvasViewController?.onZoomPercentChange = { [weak percent] value in
            percent?.stringValue = "\(value) %"
        }
        percent.stringValue = "\(canvasViewController?.zoomPercent ?? 100) %"
        zoomPercentLabel = percent

        // Umhüllung statt Text direkt in den Stack: Regel D der Theme-Vorgabe
        // verlangt für Zahlen-Anzeigen einen „versenkten dunklen Container" —
        // in „Soulless" bleibt diese Hülle unsichtbar (kein Hintergrund,
        // keine Extra-Abstände ausserhalb der Textgrösse).
        let lcdBackdrop = NSView()
        lcdBackdrop.wantsLayer = true
        lcdBackdrop.translatesAutoresizingMaskIntoConstraints = false
        percent.translatesAutoresizingMaskIntoConstraints = false
        lcdBackdrop.addSubview(percent)
        let leading = percent.leadingAnchor.constraint(equalTo: lcdBackdrop.leadingAnchor)
        let trailing = percent.trailingAnchor.constraint(equalTo: lcdBackdrop.trailingAnchor)
        let top = percent.topAnchor.constraint(equalTo: lcdBackdrop.topAnchor)
        let bottom = percent.bottomAnchor.constraint(equalTo: lcdBackdrop.bottomAnchor)
        NSLayoutConstraint.activate([leading, trailing, top, bottom])
        zoomLCDPadding = (leading, trailing, top, bottom)
        zoomLCDBackdrop = lcdBackdrop

        let minus = plainIconButton(icon: .zoomOut, pointSize: 13, label: "Verkleinern", action: #selector(zoomOut(_:)))
        let plus = plainIconButton(icon: .zoomIn, pointSize: 13, label: "Vergrössern", action: #selector(zoomIn(_:)))

        let stack = NSStackView(views: [lcdBackdrop, minus, plus])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)

        let panel = GlassPanel(cornerRadius: 0, isPill: true)
        panel.content = stack
        applyZoomLCDStyle()
        return panel
    }

    /// Passt die Zoom-Prozentanzeige an: „Beautifull" bekommt einen dunklen,
    /// versenkten Hintergrund und eine LCD-/Mono-Schrift (Regel D der Theme-
    /// Vorgabe); „Soulless" bleibt unverändert reiner Text ohne Hülle.
    private func applyZoomLCDStyle() {
        guard let label = zoomPercentLabel, let backdrop = zoomLCDBackdrop else { return }
        if let aqua = AssemblageTheme.aqua {
            label.font = aqua.lcdFont
            label.textColor = aqua.lcdForeground
            backdrop.layer?.backgroundColor = aqua.lcdBackground.cgColor
            backdrop.layer?.cornerRadius = 4
            backdrop.layer?.borderWidth = 0
            zoomLCDPadding?.leading.constant = 6
            zoomLCDPadding?.trailing.constant = -6
            zoomLCDPadding?.top.constant = 2
            zoomLCDPadding?.bottom.constant = -2
        } else {
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = AssemblageTheme.textSecondary
            backdrop.layer?.backgroundColor = NSColor.clear.cgColor
            zoomLCDPadding?.leading.constant = 0
            zoomLCDPadding?.trailing.constant = 0
            zoomLCDPadding?.top.constant = 0
            zoomLCDPadding?.bottom.constant = 0
        }
    }

    /// Die Verlaufsleiste unten im Mockup — Widerrufen/Wiederholen gehen
    /// bewusst direkt an den Dokumentcontroller: Die Pille ist selbst kein
    /// Responder, weshalb ein nil-Ziel nur zufällig beim Dokument ankam.
    func buildUndoBar() -> GlassPanel {
        let undo = plainIconButton(icon: .undo, pointSize: 16, hitSize: 28, label: "Zurück (⌘Z)", action: #selector(undoTapped(_:)))
        let redo = plainIconButton(icon: .redo, pointSize: 16, hitSize: 28, label: "Vor (⌘⇧Z)", action: #selector(redoTapped(_:)))
        let expand = plainIconButton(icon: .timeline, pointSize: 16, hitSize: 28, label: "Verlauf einblenden", action: #selector(toggleTimeline(_:)))
        let collapse = plainIconButton(icon: .timeline, pointSize: 16, hitSize: 28, label: "Verlauf ausblenden", action: #selector(toggleTimeline(_:)))
        collapse.contentTintColor = AssemblageTheme.accentDark
        // Die Mockup-Bilder sind absichtlich keine Template-Bilder; die
        // aktive Farbe muss deshalb auch im Bild stecken, sonst bliebe die
        // gesetzte Tint-Farbe am reinen Icon unsichtbar.
        collapse.image = MockupIcons.image(.timeline, pointSize: 16, tintColor: AssemblageTheme.accentDark)
        // Überschreibt den generischen (textPrimary-getönten) Registry-
        // Eintrag von `plainIconButton` mit der Akzentfarbe — sonst würde
        // `refreshTheme()` das Icon beim nächsten Themenwechsel zurück auf
        // die normale Textfarbe stellen.
        if let index = themedIconButtons.lastIndex(where: { $0.button === collapse }) {
            themedIconButtons[index].tint = { AssemblageTheme.accentDark }
        }

        let history = UndoTimelineView()
        history.translatesAutoresizingMaskIntoConstraints = false
        history.widthAnchor.constraint(equalToConstant: 140).isActive = true
        history.heightAnchor.constraint(equalToConstant: 28).isActive = true
        history.toolTip = "Verlauf — ziehen, um zu einem früheren Schritt zurückzugehen"
        history.setDepths(undo: state.undoDepth, redo: state.redoDepth)
        history.onSelectDepth = { [weak self] targetDepth in
            self?.jumpInTimeline(to: targetDepth)
        }
        undoTimeline = history

        let collapsed = NSStackView(views: [undo, expand, redo])
        collapsed.orientation = .horizontal
        collapsed.alignment = .centerY
        collapsed.distribution = .fill
        collapsed.spacing = 14
        collapsed.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)

        let expanded = NSStackView(views: [history, collapse])
        expanded.orientation = .horizontal
        expanded.alignment = .centerY
        expanded.distribution = .fill
        expanded.spacing = 14
        expanded.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        expanded.isHidden = true

        // Beide Zustände bleiben Teil derselben Ansicht. `NSStackView`
        // nimmt die ausgeblendete Zeile aus seiner intrinsischen Grösse,
        // sodass die Pille beim Umschalten ohne Neuaufbau mitwachsen darf.
        let rows = NSStackView(views: [collapsed, expanded])
        rows.orientation = .vertical
        rows.alignment = .centerX
        rows.distribution = .fill
        rows.spacing = 0
        collapsedTimelineRow = collapsed
        expandedTimelineRow = expanded

        let panel = GlassPanel(cornerRadius: 0, isPill: true)
        panel.content = rows
        return panel
    }

    @objc private func toggleTimeline(_ sender: Any?) {
        timelineIsExpanded.toggle()
        collapsedTimelineRow?.isHidden = timelineIsExpanded
        expandedTimelineRow?.isHidden = !timelineIsExpanded
    }

    /// Springt im Verlauf auf `targetDepth` — die Anzahl der Schritte, die
    /// danach noch widerrufbar sein sollen.
    ///
    /// `DocumentState` ist dabei die einzige Quelle der Wahrheit: Seine
    /// Zähler folgen den Undo-Benachrichtigungen synchron und sind auch
    /// innerhalb dieser Schleife nach jedem Schritt aktuell (siehe
    /// `UndoTimelineTests`). Die Ansicht führt deshalb bewusst keinen
    /// eigenen Zählerstand mit; sie wird über die Combine-Anbindung in
    /// `observeState()` nachgezogen.
    private func jumpInTimeline(to targetDepth: Int) {
        let target = min(max(0, targetDepth), state.undoDepth + state.redoDepth)
        while state.undoDepth > target, undoManager?.canUndo == true {
            undoTapped(nil)
        }
        while state.undoDepth < target, undoManager?.canRedo == true {
            redoTapped(nil)
        }
    }

    @objc private func undoTapped(_ sender: Any?) {
        commandTarget?.undo(sender)
    }

    @objc private func redoTapped(_ sender: Any?) {
        commandTarget?.redo(sender)
    }
}

extension CanvasTool {
    /// Die Werkzeuge, die eine eigene Schaltfläche in der schwebenden
    /// Werkzeugleiste haben (alle ausser dem impliziten `.select`, das schon
    /// als Rückfall aller anderen Werkzeuge zählt — hier trotzdem mit drin,
    /// weil es ebenfalls einen Knopf hat).
    static let allToolbarCases: [CanvasTool] = [.select, .crop, .brush, .lasso, .paint, .freehand, .distort]
}
