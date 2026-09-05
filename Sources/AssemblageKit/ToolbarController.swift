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
        case .crop, .brush:
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
    static let distortTool = NSToolbarItem.Identifier("Assemblage.Werkzeug.Verziehen")
    static let removeSubject = NSToolbarItem.Identifier("Assemblage.Werkzeug.Freistellen")
    static let insertText = NSToolbarItem.Identifier("Assemblage.Einfuegen.Text")
    static let insertShape = NSToolbarItem.Identifier("Assemblage.Einfuegen.Form")
    static let brushSettings = NSToolbarItem.Identifier("Assemblage.Pinsel.Einstellungen")
    static let zoom = NSToolbarItem.Identifier("Assemblage.Zoom")
    static let share = NSToolbarItem.Identifier("Assemblage.Teilen")
}

/// Bindet die testbare Werkzeuglogik an `NSToolbar` und den Canvas.
///
/// Der Controller besitzt keinen Dokumentzustand neben `DocumentState`: Er
/// übersetzt nur Auswahl und Bedienung in die bereits vorhandenen Canvas-Modi.
@MainActor
final class ToolbarController: NSObject, NSToolbarDelegate, NSMenuItemValidation, @preconcurrency NSSharingServicePickerDelegate {

    let toolbar: NSToolbar

    private let state: DocumentState
    private weak var canvasViewController: CanvasViewController?
    private weak var commandTarget: DocumentWindowController?
    private var observations: Set<AnyCancellable> = []

    private var currentTool: CanvasTool = .select {
        didSet { state.reportToolState(currentTool, brush: brush) }
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
        didSet { state.reportToolState(currentTool, brush: brush) }
    }
    /// Am Leben gehalten, waehrend der Teilen-Dialog offen ist.
    private var sharingPicker: NSSharingServicePicker?

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

    // MARK: - Pinsel

    // MARK: - Zugang für Tests

    /// Derselbe Weg wie der Grössen-Regler in der Werkzeugleiste, ohne einen
    /// echten `NSSlider` zu brauchen.
    func setBrushDiameterForTesting(_ diameter: Double) {
        brush.diameter = diameter
        canvasViewController?.setBrush(brush)
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

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        // Verzoegert statt sofort: Der Delegat wird noch innerhalb dieses
        // Aufrufs gebraucht, um den gewaehlten Dienst tatsaechlich zu starten.
        DispatchQueue.main.async { [weak self] in
            self?.sharingPicker = nil
        }
    }

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
        toolbarDefaultItemIdentifiers(toolbar) + [.brushSettings, .space]
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

    /// Rendert das Dokument und oeffnet den System-Teilen-Dialog daran.
    ///
    /// Als eigener Task statt "async"-Aktion: "@objc"-Handler koennen nicht
    /// async sein, und das Rendern (Bilddekodierung, Kompositing) soll die
    /// Oberflaeche waehrenddessen nicht blockieren (Plan 2.1).
    @objc private func shareDocument(_ sender: NSButton) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let bild = try await ShareCommand.renderedImage(of: self.state.document, resources: self.state.resources)
                let picker = NSSharingServicePicker(items: [bild])
                picker.delegate = self
                // Muss bis zum Schliessen am Leben bleiben - sonst verschwindet
                // der Dialog, sobald diese Methode zurueckkehrt.
                self.sharingPicker = picker
                picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            } catch {
                // Kein Dialog fuer einen Fehler, der praktisch nie eintritt
                // (dasselbe Rendern laeuft beim gewoehnlichen Export klaglos) -
                // ein Signalton reicht, das Dokument bleibt unveraendert.
                NSSound.beep()
            }
        }
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
