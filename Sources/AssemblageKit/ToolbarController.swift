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
    case distort
}

/// Regeln der Werkzeugauswahl, getrennt von der AppKit-Darstellung.
@MainActor
struct ToolSelection {

    /// Ist das Werkzeug bei dieser Auswahl überhaupt benutzbar?
    static func isAvailable(_ tool: CanvasTool, forSelected layer: Layer?) -> Bool {
        switch tool {
        case .select:
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
    private weak var removeSubjectButton: NSButton?
    private var timelineIsExpanded = false
    private weak var collapsedTimelineRow: NSView?
    private weak var expandedTimelineRow: NSView?
    private weak var undoTimeline: UndoTimelineView?

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
        }
    }

    private func updatePresentation() {
        for (tool, button) in toolButtons {
            let available = ToolSelection.isAvailable(tool, forSelected: selectedLayer)
            button.isEnabled = available
            button.alphaValue = available ? 1 : 0.35
            let isActive = tool == currentTool
            button.state = isActive ? .on : .off
            button.layer?.backgroundColor = isActive
                ? AssemblageTheme.accentSoft.cgColor
                : NSColor.clear.cgColor
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
    func buildFloatingToolbarRow() -> NSView {
        let row = NSStackView(views: [
            makePrimaryToolCluster(),
            makeSecondaryToolCluster(),
            makeSearchField(),
            makeShareButton()
        ])
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
        row.heightAnchor.constraint(equalToConstant: 50).isActive = true
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
        let brush = makeToolButton(tool: .brush, label: "Pinsel (B)", icon: .brush, size: 38, action: #selector(brushTool(_:)))
        // Lasso und Farbpinsel haben im Mockup keinen eigenen Platz — es kennt
        // beide Werkzeuge nicht. Damit sie erreichbar bleiben, stehen sie im
        // selben visuellen Stil direkt daneben.
        let lasso = makeToolButton(tool: .lasso, label: "Bild ausschneiden", icon: .removeSubject, size: 38, action: #selector(lassoTool(_:)))
        let paint = makeToolButton(tool: .paint, label: "Farbe malen", icon: .brush, size: 38, action: #selector(paintTool(_:)))

        let stack = NSStackView(views: [select, crop, brush, lasso, paint])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)

        return wrapInGlassPanel(stack, cornerRadius: AssemblageTheme.toolClusterCornerRadius)
    }

    private func makeSecondaryToolCluster() -> NSView {
        let warp = makeToolButton(tool: .distort, label: "Verziehen", icon: .warp, size: 36, action: #selector(distortTool(_:)))

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let removeSubject = makePillButton(label: "Freistellen", icon: .removeSubject, action: #selector(removeSubject(_:)))
        removeSubjectButton = removeSubject

        let text = makeCommandPill(label: "Text", icon: .insertText, action: #selector(insertText(_:)))
        let shape = makeShapePillMenu()
        let grid = makeGridPillMenu()

        let stack = NSStackView(views: [warp, divider, removeSubject, text, shape, grid])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)

        return wrapInGlassPanel(stack, cornerRadius: AssemblageTheme.toolClusterCornerRadius)
    }

    private func makeSearchField() -> NSView {
        let icon = NSImageView(image: MockupIcons.image(.search, pointSize: 15, tintColor: AssemblageTheme.textTertiary))
        icon.translatesAutoresizingMaskIntoConstraints = false

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
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        for row in rows {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let content = NSViewController()
        content.view = stack
        stack.widthAnchor.constraint(equalToConstant: 220).isActive = true

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
        let button = plainIconButton(icon: .share, pointSize: 17, label: "Teilen", action: #selector(shareDocument(_:)))
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let panel = GlassPanel(cornerRadius: 16)
        panel.content = button
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        panel.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return panel
    }

    /// Ein sichtbares Form-Icon, dessen Menü genau die drei Formen aus Plan
    /// 5.7 anbietet. So belegen die Formen nicht drei Plätze in der Leiste.
    private func makeShapePillMenu() -> NSView {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false

        let title = NSMenuItem(title: "Form", action: nil, keyEquivalent: "")
        title.image = MockupIcons.image(.insertShape, pointSize: 16, tintColor: AssemblageTheme.textPrimary)
        button.menu?.addItem(title)

        let rectangle = NSMenuItem(title: "Rechteck", action: #selector(DocumentWindowController.insertRectangleLayer(_:)), keyEquivalent: "")
        let rounded = NSMenuItem(title: "Abgerundetes Rechteck", action: #selector(DocumentWindowController.insertRoundedRectangleLayer(_:)), keyEquivalent: "")
        let ellipse = NSMenuItem(title: "Ellipse", action: #selector(DocumentWindowController.insertEllipseLayer(_:)), keyEquivalent: "")
        for item in [rectangle, rounded, ellipse] {
            item.target = commandTarget
            button.menu?.addItem(item)
        }

        button.font = .systemFont(ofSize: 12.5, weight: .semibold)
        button.toolTip = "Form"
        button.setAccessibilityLabel("Form")
        return button
    }

    /// „Raster" — Collage-Vorlagen (2×2, 3×3, Polaroid-Stapel). Vorher ohne
    /// Aktion verdrahtet, weshalb ein Klick sichtbar nichts tat.
    private func makeGridPillMenu() -> NSView {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false

        let title = NSMenuItem(title: "Raster", action: nil, keyEquivalent: "")
        title.image = MockupIcons.image(.collageGrid, pointSize: 16, tintColor: AssemblageTheme.textPrimary)
        button.menu?.addItem(title)

        let grid2x2 = NSMenuItem(title: "Raster 2×2", action: #selector(DocumentWindowController.applyGrid2x2Template(_:)), keyEquivalent: "")
        let grid3x3 = NSMenuItem(title: "Raster 3×3", action: #selector(DocumentWindowController.applyGrid3x3Template(_:)), keyEquivalent: "")
        let polaroid = NSMenuItem(title: "Polaroid-Stapel", action: #selector(DocumentWindowController.applyPolaroidStackTemplate(_:)), keyEquivalent: "")
        for item in [grid2x2, grid3x3, polaroid] {
            item.target = commandTarget
            button.menu?.addItem(item)
        }

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
        let button = NSButton(title: "", target: self, action: action)
        button.image = MockupIcons.image(icon, pointSize: 18, tintColor: AssemblageTheme.textPrimary)
        button.isBordered = false
        button.setButtonType(.toggle)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.wantsLayer = true
        button.layer?.cornerRadius = AssemblageTheme.toolButtonCornerRadius
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: size).isActive = true
        button.heightAnchor.constraint(equalToConstant: size).isActive = true
        button.isEnabled = ToolSelection.isAvailable(tool, forSelected: selectedLayer)
        toolButtons[tool] = button
        return button
    }

    /// Ein Icon+Text-Knopf wie „Freistellen"/„Text"/„Raster" im Mockup.
    private func makeCommandPill(label: String, icon: MockupIcon, action: Selector?) -> NSButton {
        makePillButton(label: label, icon: icon, action: action)
    }

    private func makePillButton(label: String, icon: MockupIcon, action: Selector?) -> NSButton {
        let button = NSButton(title: label, target: action == nil ? nil : self, action: action)
        button.image = MockupIcons.image(icon, pointSize: 16, tintColor: AssemblageTheme.textPrimary)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.isBordered = false
        button.font = .systemFont(ofSize: 12.5, weight: .semibold)
        button.contentTintColor = AssemblageTheme.textPrimary
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func plainIconButton(
        icon: MockupIcon,
        pointSize: CGFloat,
        hitSize: CGFloat? = nil,
        label: String,
        action: Selector?
    ) -> NSButton {
        let button = NSButton(
            image: MockupIcons.image(icon, pointSize: pointSize, tintColor: AssemblageTheme.textPrimary),
            target: action == nil ? nil : self,
            action: action
        )
        button.isBordered = false
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

        let minus = plainIconButton(icon: .zoomOut, pointSize: 13, label: "Verkleinern", action: #selector(zoomOut(_:)))
        let plus = plainIconButton(icon: .zoomIn, pointSize: 13, label: "Vergrössern", action: #selector(zoomIn(_:)))

        let stack = NSStackView(views: [percent, minus, plus])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)

        let panel = GlassPanel(cornerRadius: 0, isPill: true)
        panel.content = stack
        return panel
    }

    /// Die Verlaufsleiste unten im Mockup — Widerrufen/Wiederholen
    /// laufen über dieselbe Responder-Kette wie die Menüzeilen, damit die
    /// bestehende Tastenwiederholungs-/Undo-Logik in
    /// `DocumentWindowController.undo(_:)` unverändert greift.
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

        let history = UndoTimelineView()
        history.translatesAutoresizingMaskIntoConstraints = false
        history.widthAnchor.constraint(equalToConstant: 140).isActive = true
        history.heightAnchor.constraint(equalToConstant: 28).isActive = true
        history.toolTip = "Verlaufs-Timeline"
        history.setDepths(undo: state.undoDepth, redo: state.redoDepth)
        history.onSelectDepth = { [weak self] targetDepth in
            self?.jumpInTimeline(to: targetDepth)
        }
        undoTimeline = history

        let collapsed = NSStackView(views: [undo, expand, redo])
        collapsed.orientation = .horizontal
        collapsed.alignment = .centerY
        collapsed.spacing = 14
        collapsed.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)

        let expanded = NSStackView(views: [history, collapse])
        expanded.orientation = .horizontal
        expanded.alignment = .centerY
        expanded.spacing = 14
        expanded.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        expanded.isHidden = true

        // Beide Zustände bleiben Teil derselben Ansicht. `NSStackView`
        // nimmt die ausgeblendete Zeile aus seiner intrinsischen Grösse,
        // sodass die Pille beim Umschalten ohne Neuaufbau mitwachsen darf.
        let rows = NSStackView(views: [collapsed, expanded])
        rows.orientation = .vertical
        rows.alignment = .centerX
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

    private func jumpInTimeline(to targetDepth: Int) {
        let difference = targetDepth - state.undoDepth
        if difference < 0 {
            for _ in 0..<(-difference) { undoTapped(undoTimeline) }
        } else if difference > 0 {
            for _ in 0..<difference { redoTapped(undoTimeline) }
        }
    }

    @objc private func undoTapped(_ sender: Any?) {
        NSApp.sendAction(#selector(DocumentWindowController.undo(_:)), to: nil, from: sender)
    }

    @objc private func redoTapped(_ sender: Any?) {
        NSApp.sendAction(Selector(("redo:")), to: nil, from: sender)
    }
}

/// Zeichnet den Verlauf als echte Zeitachse: kräftig bis zum aktuellen
/// Schritt, schwach für den widerrufenen Teil und mit einer senkrechten Marke
/// an der gegenwärtigen Position. Eine Zeichenansicht hält Linie und Marke
/// pixelgenau zusammen; mehrere Subviews würden bei Rundung und Layout leicht
/// sichtbare Lücken erzeugen.
@MainActor
final class UndoTimelineView: NSView {

    private var undoDepth = 0
    private var redoDepth = 0
    var onSelectDepth: ((Int) -> Void)?

    func setDepths(undo: Int, redo: Int) {
        undoDepth = max(0, undo)
        redoDepth = max(0, redo)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let total = undoDepth + redoDepth
        let markerFraction = total == 0 ? 1 : CGFloat(undoDepth) / CGFloat(total)
        let lineMinX: CGFloat = 1
        let lineMaxX = max(lineMinX, bounds.width - 1)
        let markerX = lineMinX + (lineMaxX - lineMinX) * markerFraction
        let centerY = bounds.midY

        let weakLine = NSBezierPath()
        weakLine.move(to: NSPoint(x: total == 0 ? lineMinX : markerX, y: centerY))
        weakLine.line(to: NSPoint(x: lineMaxX, y: centerY))
        weakLine.lineWidth = 1.5
        AssemblageTheme.textTertiary.setStroke()
        weakLine.stroke()

        if total > 0 {
            let strongLine = NSBezierPath()
            strongLine.move(to: NSPoint(x: lineMinX, y: centerY))
            strongLine.line(to: NSPoint(x: markerX, y: centerY))
            strongLine.lineWidth = 1.5
            AssemblageTheme.textPrimary.setStroke()
            strongLine.stroke()
        }

        let marker = NSBezierPath()
        marker.move(to: NSPoint(x: markerX, y: centerY - 9))
        marker.line(to: NSPoint(x: markerX, y: centerY + 9))
        marker.lineWidth = 1.5
        AssemblageTheme.textPrimary.setStroke()
        marker.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard bounds.width > 0 else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let relativePosition = min(1, max(0, x / bounds.width))
        let total = undoDepth + redoDepth
        onSelectDepth?(Int((relativePosition * CGFloat(total)).rounded()))
    }
}

extension CanvasTool {
    /// Die Werkzeuge, die eine eigene Schaltfläche in der schwebenden
    /// Werkzeugleiste haben (alle ausser dem impliziten `.select`, das schon
    /// als Rückfall aller anderen Werkzeuge zählt — hier trotzdem mit drin,
    /// weil es ebenfalls einen Knopf hat).
    static let allToolbarCases: [CanvasTool] = [.select, .crop, .brush, .lasso, .paint, .distort]
}
