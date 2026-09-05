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

private extension NSToolbarItem.Identifier {
    static let selectTool = NSToolbarItem.Identifier("Assemblage.Werkzeug.Auswaehlen")
    static let cropTool = NSToolbarItem.Identifier("Assemblage.Werkzeug.Zuschneiden")
    static let brushTool = NSToolbarItem.Identifier("Assemblage.Werkzeug.Pinsel")
    static let lassoTool = NSToolbarItem.Identifier("Assemblage.Werkzeug.Lasso")
    static let distortTool = NSToolbarItem.Identifier("Assemblage.Werkzeug.Verziehen")
    static let removeSubject = NSToolbarItem.Identifier("Assemblage.Werkzeug.Freistellen")
    static let insertText = NSToolbarItem.Identifier("Assemblage.Einfuegen.Text")
    static let insertShape = NSToolbarItem.Identifier("Assemblage.Einfuegen.Form")
    static let brushSettings = NSToolbarItem.Identifier("Assemblage.Pinsel.Einstellungen")
    static let lassoSettings = NSToolbarItem.Identifier("Assemblage.Lasso.Einstellungen")
    static let paintTool = NSToolbarItem.Identifier("Assemblage.Werkzeug.Farbe")
    static let paintSettings = NSToolbarItem.Identifier("Assemblage.Farbe.Einstellungen")
    static let zoom = NSToolbarItem.Identifier("Assemblage.Zoom")
    static let share = NSToolbarItem.Identifier("Assemblage.Teilen")
}

/// Bindet die testbare Werkzeuglogik an `NSToolbar` und den Canvas.
///
/// Der Controller besitzt keinen Dokumentzustand neben `DocumentState`: Er
/// übersetzt nur Auswahl und Bedienung in die bereits vorhandenen Canvas-Modi.
@MainActor
final class ToolbarController: NSObject, NSToolbarDelegate, NSMenuItemValidation {

    let toolbar: NSToolbar

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
    /// Die aufklappende Werkzeug-Seitenleiste, falls das Fenster eine hat.
    /// Sie spiegelt denselben Zustand wie die Knöpfe oben — eine zweite
    /// Zustandshaltung wäre genau die Art Dopplung, die auseinanderläuft.
    weak var sidebar: ToolSidebarView? {
        didSet {
            sidebar?.onSelect = { [weak self] tool in self?.toggle(tool) }
            updatePresentation()
        }
    }

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
        toolbar = NSToolbar(identifier: "Assemblage.DocumentWerkzeugleiste")
        super.init()

        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .regular
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false

        state.$document
            .combineLatest(state.$selectedLayerID)
            .sink { [weak self] document, selectedLayerID in
                let layer = selectedLayerID.flatMap { document.layer(withID: $0) }
                self?.selectionDidChange(to: layer)
            }
            .store(in: &observations)
    }

    func install(on window: NSWindow) {
        window.toolbar = toolbar
        updatePresentation()
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
            button.isEnabled = ToolSelection.isAvailable(tool, forSelected: selectedLayer)
            button.state = tool == currentTool ? .on : .off
        }

        if let sidebar {
            sidebar.selectedTool = currentTool
            sidebar.availableTools = Set(
                ToolSidebarView.allTools.filter {
                    ToolSelection.isAvailable($0, forSelected: selectedLayer)
                }
            )
        }

        // Freistellen ist ein einmaliger Befehl und kein vierter Canvas-Modus.
        // Der bestehende Befehlscontroller blockiert doppelte laufende Aufrufe.
        removeSubjectButton?.isEnabled = ToolSelection.isAvailable(
            .brush,
            forSelected: selectedLayer
        )
        updateBrushSettingsVisibility()
        updateLassoSettingsVisibility()
        updatePaintSettingsVisibility()
    }

    private func updateLassoSettingsVisibility() {
        let index = toolbar.items.firstIndex { $0.itemIdentifier == .lassoSettings }
        if currentTool == .lasso, index == nil {
            let zoomIndex = toolbar.items.firstIndex { $0.itemIdentifier == .zoom }
                ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: .lassoSettings, at: zoomIndex)
        } else if currentTool != .lasso, let index {
            toolbar.removeItem(at: index)
        }
    }

    private func updateBrushSettingsVisibility() {
        let index = toolbar.items.firstIndex { $0.itemIdentifier == .brushSettings }
        if currentTool == .brush, index == nil {
            let zoomIndex = toolbar.items.firstIndex { $0.itemIdentifier == .zoom }
                ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: .brushSettings, at: zoomIndex)
        } else if currentTool != .brush, let index {
            toolbar.removeItem(at: index)
        }
    }

    private func updatePaintSettingsVisibility() {
        let index = toolbar.items.firstIndex { $0.itemIdentifier == .paintSettings }
        if currentTool == .paint, index == nil {
            let zoomIndex = toolbar.items.firstIndex { $0.itemIdentifier == .zoom }
                ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: .paintSettings, at: zoomIndex)
        } else if currentTool != .paint, let index {
            toolbar.removeItem(at: index)
        }
    }

    // MARK: - Pinsel

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

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .selectTool,
            .cropTool,
            .brushTool,
            .lassoTool,
            .paintTool,
            .distortTool,
            .removeSubject,
            .insertText,
            .insertShape,
            .flexibleSpace,
            .zoom,
            .share
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.brushSettings, .lassoSettings, .paintSettings, .space]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .selectTool:
            return makeToolItem(
                identifier: itemIdentifier,
                tool: .select,
                label: "Auswählen und verschieben",
                symbolName: "cursorarrow",
                action: #selector(selectTool(_:))
            )
        case .cropTool:
            return makeToolItem(
                identifier: itemIdentifier,
                tool: .crop,
                label: "Zuschneiden",
                symbolName: "crop",
                action: #selector(cropTool(_:))
            )
        case .brushTool:
            return makeToolItem(
                identifier: itemIdentifier,
                tool: .brush,
                label: "Pinsel-Maske",
                symbolName: "paintbrush",
                action: #selector(brushTool(_:))
            )
        case .lassoTool:
            let symbolName = NSImage(systemSymbolName: "lasso", accessibilityDescription: nil) == nil
                ? "scissors" : "lasso"
            return makeToolItem(
                identifier: itemIdentifier,
                tool: .lasso,
                label: "Bild ausschneiden",
                symbolName: symbolName,
                action: #selector(lassoTool(_:))
            )
        case .paintTool:
            return makeToolItem(
                identifier: itemIdentifier,
                tool: .paint,
                label: "Farbe malen",
                symbolName: "paintpalette",
                action: #selector(paintTool(_:))
            )
        case .distortTool:
            return makeToolItem(
                identifier: itemIdentifier,
                tool: .distort,
                label: "Verziehen",
                symbolName: "skew",
                action: #selector(distortTool(_:))
            )
        case .removeSubject:
            return makeRemoveSubjectItem(identifier: itemIdentifier)
        case .insertText:
            return makeCommandItem(
                identifier: itemIdentifier,
                label: "Text einfügen",
                symbolName: "textformat",
                action: #selector(insertText(_:))
            )
        case .insertShape:
            return makeShapeItem(identifier: itemIdentifier)
        case .brushSettings:
            return makeBrushSettingsItem(identifier: itemIdentifier)
        case .lassoSettings:
            return makeLassoSettingsItem(identifier: itemIdentifier)
        case .paintSettings:
            return makePaintSettingsItem(identifier: itemIdentifier)
        case .zoom:
            return makeZoomItem(identifier: itemIdentifier)
        case .share:
            return makeShareItem(identifier: itemIdentifier)
        default:
            return nil
        }
    }

    private func makeToolItem(
        identifier: NSToolbarItem.Identifier,
        tool: CanvasTool,
        label: String,
        symbolName: String,
        action: Selector
    ) -> NSToolbarItem {
        let button = toolbarButton(label: label, symbolName: symbolName, action: action)
        button.setButtonType(.toggle)
        button.isEnabled = ToolSelection.isAvailable(tool, forSelected: selectedLayer)
        button.state = tool == currentTool ? .on : .off
        toolButtons[tool] = button

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.view = button
        return item
    }

    private func makeRemoveSubjectItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let label = "Motiv freistellen"
        let button = toolbarButton(
            label: label,
            symbolName: "person.crop.rectangle",
            action: #selector(removeSubject(_:))
        )
        removeSubjectButton = button

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.view = button
        return item
    }

    private func makeCommandItem(
        identifier: NSToolbarItem.Identifier,
        label: String,
        symbolName: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        item.target = self
        item.action = action
        return item
    }

    /// Ein sichtbares Form-Icon, dessen Menü genau die drei Formen aus Plan
    /// 5.7 anbietet. So belegen die Formen nicht drei Plätze in der Leiste.
    private func makeShapeItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let label = "Form einfügen"
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: "square.on.circle", accessibilityDescription: label)

        let menu = NSMenu(title: label)
        menu.addItem(withTitle: "Rechteck", action: #selector(DocumentWindowController.insertRectangleLayer(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Abgerundetes Rechteck", action: #selector(DocumentWindowController.insertRoundedRectangleLayer(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Ellipse", action: #selector(DocumentWindowController.insertEllipseLayer(_:)), keyEquivalent: "")
        for menuItem in menu.items { menuItem.target = commandTarget }
        item.menu = menu
        return item
    }

    private func toolbarButton(label: String, symbolName: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
            ?? NSImage(size: NSSize(width: 22, height: 22))
        let button = NSButton(image: image, target: self, action: action)
        button.bezelStyle = .toolbar
        button.controlSize = .large
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 36)
        ])
        return button
    }

    /// Der Apple-typische Teilen-Knopf (aus Anpassungen.md). Ein Export-Weg
    /// existierte bereits ueber die Ablage-Menue-Zeile "Exportieren..." -
    /// nur ohne sichtbaren Knopf im Fenster, weshalb er leicht zu uebersehen war.
    private func makeShareItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let button = toolbarButton(label: "Teilen", symbolName: "square.and.arrow.up", action: #selector(shareDocument(_:)))
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Teilen"
        item.paletteLabel = "Teilen"
        item.toolTip = "Teilen"
        item.view = button
        return item
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

    private func makeBrushSettingsItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let diameter = NSSlider(
            value: brush.diameter,
            minValue: 1,
            maxValue: 500,
            target: self,
            action: #selector(diameterChanged(_:))
        )
        diameter.isContinuous = true
        diameter.toolTip = "Pinselgrösse"
        diameter.setAccessibilityLabel("Pinselgrösse")
        diameter.translatesAutoresizingMaskIntoConstraints = false
        diameter.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let hardness = NSSlider(
            value: brush.hardness,
            minValue: 0,
            maxValue: 1,
            target: self,
            action: #selector(hardnessChanged(_:))
        )
        hardness.isContinuous = true
        hardness.toolTip = "Pinselhärte"
        hardness.setAccessibilityLabel("Pinselhärte")
        hardness.translatesAutoresizingMaskIntoConstraints = false
        hardness.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let mode = NSSegmentedControl(
            labels: ["Abdecken", "Zurückholen"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(brushModeChanged(_:))
        )
        mode.selectedSegment = brush.mode == .hide ? 0 : 1
        mode.controlSize = .large
        mode.setAccessibilityLabel("Pinselmodus")

        let stack = NSStackView(views: [
            labelledControl("Grösse", control: diameter),
            labelledControl("Härte", control: hardness),
            mode
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Pinsel-Einstellungen"
        item.paletteLabel = "Pinsel-Einstellungen"
        item.view = stack
        return item
    }

    private func makeLassoSettingsItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let mode = NSSegmentedControl(
            labels: ["Abdecken", "Zurückholen"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(lassoModeChanged(_:))
        )
        mode.selectedSegment = lassoMode == .hide ? 0 : 1
        mode.controlSize = .large
        mode.setAccessibilityLabel("Lassomodus")

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Lasso-Einstellungen"
        item.paletteLabel = "Lasso-Einstellungen"
        item.view = mode
        return item
    }

    private func makePaintSettingsItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let farbe = NSColorWell()
        let anfangsfarbe = RGBA(hex: paintBrush.colorHex) ?? .black
        farbe.color = NSColor(
            srgbRed: anfangsfarbe.red, green: anfangsfarbe.green,
            blue: anfangsfarbe.blue, alpha: anfangsfarbe.alpha
        )
        farbe.target = self
        farbe.action = #selector(paintColorChanged(_:))
        farbe.toolTip = "Malfarbe"
        farbe.setAccessibilityLabel("Malfarbe")

        let diameter = NSSlider(
            value: paintBrush.diameter,
            minValue: 1,
            maxValue: 300,
            target: self,
            action: #selector(paintDiameterChanged(_:))
        )
        diameter.isContinuous = true
        diameter.toolTip = "Pinselgrösse"
        diameter.setAccessibilityLabel("Pinselgrösse")
        diameter.translatesAutoresizingMaskIntoConstraints = false
        diameter.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let hardness = NSSlider(
            value: paintBrush.hardness,
            minValue: 0,
            maxValue: 1,
            target: self,
            action: #selector(paintHardnessChanged(_:))
        )
        hardness.isContinuous = true
        hardness.toolTip = "Pinselhärte"
        hardness.setAccessibilityLabel("Pinselhärte")
        hardness.translatesAutoresizingMaskIntoConstraints = false
        hardness.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let opacity = NSSlider(
            value: paintBrush.opacity,
            minValue: 0,
            maxValue: 1,
            target: self,
            action: #selector(paintOpacityChanged(_:))
        )
        opacity.isContinuous = true
        opacity.toolTip = "Deckkraft"
        opacity.setAccessibilityLabel("Deckkraft")
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
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Farbpinsel-Einstellungen"
        item.paletteLabel = "Farbpinsel-Einstellungen"
        item.view = stack
        return item
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
        let stack = NSStackView(views: [field, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }

    private func makeZoomItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let definitions: [(String, String, Selector)] = [
            ("Verkleinern", "minus.magnifyingglass", #selector(zoomOut(_:))),
            ("Vergrössern", "plus.magnifyingglass", #selector(zoomIn(_:))),
            ("Tatsächliche Grösse", "1.magnifyingglass", #selector(zoomToActualSize(_:))),
            ("An Fenster anpassen", "arrow.down.right.and.arrow.up.left", #selector(zoomToFit(_:)))
        ]
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.label = "Zoom"
        item.paletteLabel = "Zoom"
        item.toolTip = "Zoom"
        item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Zoom")
        let menu = NSMenu(title: "Zoom")
        for (label, symbol, action) in definitions {
            let menuItem = NSMenuItem(title: label, action: action, keyEquivalent: "")
            menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            menuItem.target = self
            menu.addItem(menuItem)
        }
        item.menu = menu
        return item
    }
}
