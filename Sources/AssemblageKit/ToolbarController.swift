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
final class ToolbarController: NSObject, NSMenuItemValidation {

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
        removeSubjectButton = removeSubject.subviews.compactMap { $0 as? NSButton }.first

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
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let stack = NSStackView(views: [icon, field])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)

        return wrapInGlassPanel(stack, cornerRadius: AssemblageTheme.toolClusterCornerRadius)
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

        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.image = MockupIcons.image(.insertShape, pointSize: 16, tintColor: AssemblageTheme.textPrimary)
        button.menu?.addItem(title)

        let rectangle = NSMenuItem(title: "Rechteck", action: #selector(DocumentWindowController.insertRectangleLayer(_:)), keyEquivalent: "")
        let rounded = NSMenuItem(title: "Abgerundetes Rechteck", action: #selector(DocumentWindowController.insertRoundedRectangleLayer(_:)), keyEquivalent: "")
        let ellipse = NSMenuItem(title: "Ellipse", action: #selector(DocumentWindowController.insertEllipseLayer(_:)), keyEquivalent: "")
        for item in [rectangle, rounded, ellipse] {
            item.target = commandTarget
            button.menu?.addItem(item)
        }

        let label = NSTextField(labelWithString: "Form")
        label.font = .systemFont(ofSize: 12.5, weight: .semibold)
        label.textColor = AssemblageTheme.textPrimary

        let stack = NSStackView(views: [button, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        return stack
    }

    /// „Raster" — Collage-Vorlagen (2×2, 3×3, Polaroid-Stapel). Vorher ohne
    /// Aktion verdrahtet, weshalb ein Klick sichtbar nichts tat.
    private func makeGridPillMenu() -> NSView {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false

        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.image = MockupIcons.image(.collageGrid, pointSize: 16, tintColor: AssemblageTheme.textPrimary)
        button.menu?.addItem(title)

        let grid2x2 = NSMenuItem(title: "Raster 2×2", action: #selector(DocumentWindowController.applyGrid2x2Template(_:)), keyEquivalent: "")
        let grid3x3 = NSMenuItem(title: "Raster 3×3", action: #selector(DocumentWindowController.applyGrid3x3Template(_:)), keyEquivalent: "")
        let polaroid = NSMenuItem(title: "Polaroid-Stapel", action: #selector(DocumentWindowController.applyPolaroidStackTemplate(_:)), keyEquivalent: "")
        for item in [grid2x2, grid3x3, polaroid] {
            item.target = commandTarget
            button.menu?.addItem(item)
        }

        let label = NSTextField(labelWithString: "Raster")
        label.font = .systemFont(ofSize: 12.5, weight: .semibold)
        label.textColor = AssemblageTheme.textPrimary

        let stack = NSStackView(views: [button, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        return stack
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
    private func makeCommandPill(label: String, icon: MockupIcon, action: Selector?) -> NSView {
        makePillButton(label: label, icon: icon, action: action)
    }

    private func makePillButton(label: String, icon: MockupIcon, action: Selector?) -> NSView {
        let button = plainIconButton(icon: icon, pointSize: 16, label: label, action: action)
        let text = NSTextField(labelWithString: label)
        text.font = .systemFont(ofSize: 12.5, weight: .semibold)
        text.textColor = AssemblageTheme.textPrimary

        let stack = NSStackView(views: [button, text])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }

    private func plainIconButton(icon: MockupIcon, pointSize: CGFloat, label: String, action: Selector?) -> NSButton {
        let button = NSButton(
            image: MockupIcons.image(icon, pointSize: pointSize, tintColor: AssemblageTheme.textPrimary),
            target: action == nil ? nil : self,
            action: action
        )
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: pointSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: pointSize).isActive = true
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

    /// Die Verlaufsleiste unten rechts im Mockup — Widerrufen/Wiederholen
    /// laufen über dieselbe Responder-Kette wie die Menüzeilen, damit die
    /// bestehende Tastenwiederholungs-/Undo-Logik in
    /// `DocumentWindowController.undo(_:)` unverändert greift.
    func buildUndoBar() -> GlassPanel {
        let undo = plainIconButton(icon: .undo, pointSize: 16, label: "Zurück (⌘Z)", action: #selector(undoTapped(_:)))
        let redo = plainIconButton(icon: .redo, pointSize: 16, label: "Vor (⌘⇧Z)", action: #selector(redoTapped(_:)))

        let history = NSStackView(views: [10, 16, 8, 14].map { height -> NSView in
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.backgroundColor = AssemblageTheme.textPrimary.cgColor
            bar.layer?.cornerRadius = 1.5
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 3).isActive = true
            bar.heightAnchor.constraint(equalToConstant: height).isActive = true
            return bar
        })
        history.orientation = .horizontal
        history.alignment = .centerY
        history.spacing = 2
        history.toolTip = "Verlaufs-Timeline"

        let dividerLeading = NSBox()
        dividerLeading.boxType = .separator
        let dividerTrailing = NSBox()
        dividerTrailing.boxType = .separator

        let stack = NSStackView(views: [undo, dividerLeading, history, dividerTrailing, redo])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let panel = GlassPanel(cornerRadius: 0, isPill: true)
        panel.content = stack
        return panel
    }

    @objc private func undoTapped(_ sender: Any?) {
        NSApp.sendAction(#selector(DocumentWindowController.undo(_:)), to: nil, from: sender)
    }

    @objc private func redoTapped(_ sender: Any?) {
        NSApp.sendAction(Selector(("redo:")), to: nil, from: sender)
    }
}

extension CanvasTool {
    /// Die Werkzeuge, die eine eigene Schaltfläche in der schwebenden
    /// Werkzeugleiste haben (alle ausser dem impliziten `.select`, das schon
    /// als Rückfall aller anderen Werkzeuge zählt — hier trotzdem mit drin,
    /// weil es ebenfalls einen Knopf hat).
    static let allToolbarCases: [CanvasTool] = [.select, .crop, .brush, .lasso, .paint, .distort]
}
