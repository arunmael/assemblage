import AppKit
import SwiftUI
import AssemblageModel

/// Das Dokumentfenster: Ebenen links, Canvas in der Mitte, Eigenschaften
/// rechts (Plan 8).
///
/// `NSSplitViewController` mit Sidebar-Elementen, weil daran die
/// Liquid-Glass-Optik aus Plan 4.5 hängt: Nur eine echte Sidebar bekommt vom
/// System die durchscheinende Materialfläche — nachgebaut sieht sie immer
/// falsch aus.
@MainActor
final class DocumentWindowController: NSWindowController, NSMenuItemValidation {

    private var splitViewController: NSSplitViewController?
    private var canvasViewController: CanvasViewController?
    private var toolbarController: ToolbarController?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Bewusst ohne `.fullSizeContentView`: Der dreigeteilte Inhalt soll
        // weder unter dem Dokumentnamen noch unter der Werkzeugleiste liegen.

        // Mindestgrösse **vor** dem Wiederherstellen des gesicherten Rahmens
        // setzen, sonst zieht AppKit sie nicht heran.
        //
        // Ohne sie kann das Fenster auf einen Streifen in Höhe der Titelleiste
        // zusammenfallen — und `setFrameAutosaveName` schreibt genau das in
        // die Voreinstellungen, sodass die App bei jedem weiteren Start leer
        // hochkommt und sich ohne Eingriff von Hand nicht mehr erholt. Die
        // Werte reichen für die drei Bereiche aus Plan 8: Ebenenliste (200),
        // Leinwand (400) und Eigenschaften (260).
        window.contentMinSize = NSSize(width: 880, height: 480)
        window.setFrameAutosaveName("AssemblageDocumentWindow")

        // Einen bereits zusammengefallen gesicherten Rahmen aufrichten.
        // `contentMinSize` allein genügt nicht: Sie begrenzt das Ziehen am
        // Fensterrand, nicht das Wiederherstellen eines gesicherten Rahmens.
        // Ohne diese Zeile bliebe eine App, der das einmal passiert ist, für
        // immer kaputt.
        let mindest = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
        if window.frame.width < mindest.width || window.frame.height < mindest.height {
            window.setFrame(
                NSRect(
                    origin: window.frame.origin,
                    size: NSSize(
                        width: max(window.frame.width, mindest.width),
                        height: max(window.frame.height, mindest.height)
                    )
                ),
                display: false
            )
        }
        self.init(window: window)
    }

    /// Der Inhalt entsteht erst, wenn das Dokument zugewiesen ist.
    ///
    /// Nicht in `windowDidLoad()`: Das läuft, *bevor*
    /// `NSDocument.addWindowController(_:)` das Dokument setzt — der Aufbau
    /// fände dort kein `state` vor und das Fenster bliebe leer.
    override var document: AnyObject? {
        didSet { buildContentIfNeeded() }
    }

    private func buildContentIfNeeded() {
        guard contentViewController == nil,
              let state = (document as? AssemblageDocument)?.state
        else { return }

        let layers = NSHostingController(rootView: LayerListView(state: state))
        let canvas = CanvasViewController(state: state)
        let inspector = NSHostingController(rootView: InspectorView(state: state))
        canvasViewController = canvas

        let layersItem = NSSplitViewItem(sidebarWithViewController: layers)
        layersItem.minimumThickness = 200
        layersItem.maximumThickness = 360
        // Die Ebenenliste ist der Kern der App — sie soll beim Verkleinern
        // des Fensters nicht als Erstes verschwinden.
        layersItem.canCollapse = true

        // Die Werkzeugleiste sitzt zwischen Ebenenliste und Leinwand — dort,
        // wo bei Pixelmator die Werkzeuge liegen, und in Griffweite des
        // Bildes, auf das sie wirken.
        //
        // Als eigene Spalte im Split View und nicht als schwebende Ansicht auf
        // der Leinwand: Eine schwebende Leiste verdeckte beim Aufklappen genau
        // den Bildrand, an dem man gerade arbeitet.
        let toolSidebar = ToolSidebarViewController()
        let toolItem = NSSplitViewItem(viewController: toolSidebar)
        toolItem.canCollapse = false
        toolItem.holdingPriority = .defaultHigh + 1
        toolItem.minimumThickness = ToolSidebarView.collapsedWidth
        toolItem.maximumThickness = ToolSidebarView.collapsedWidth

        let canvasItem = NSSplitViewItem(viewController: canvas)
        canvasItem.minimumThickness = 400

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 260
        inspectorItem.maximumThickness = 380

        let splitViewController = NSSplitViewController()
        splitViewController.addSplitViewItem(layersItem)
        splitViewController.addSplitViewItem(toolItem)
        splitViewController.addSplitViewItem(canvasItem)
        splitViewController.addSplitViewItem(inspectorItem)
        self.splitViewController = splitViewController

        contentViewController = splitViewController
        window?.toolbarStyle = .unified

        let toolbarController = ToolbarController(
            state: state,
            canvasViewController: canvas,
            commandTarget: self
        )
        toolbarController.sidebar = toolSidebar.sidebar
        canvas.selectToolFromKeyboard = { [weak toolbarController] tool in
            toolbarController?.select(tool) ?? false
        }
        self.toolbarController = toolbarController
        if let window {
            toolbarController.install(on: window)
        }
    }

    /// Wird beim Laden aus einer Feder aufgerufen; bei uns entsteht das
    /// Fenster im Code. Trotzdem hier abgesichert, falls das Dokument
    /// ausnahmsweise schon vor dem Laden gesetzt war.
    override func windowDidLoad() {
        super.windowDidLoad()
        buildContentIfNeeded()
    }

    // MARK: - Menübefehle

    @IBAction func zoomToFit(_ sender: Any?) { canvasViewController?.zoomToFit() }
    @IBAction func zoomToActualSize(_ sender: Any?) { canvasViewController?.zoomToActualSize() }
    @IBAction func zoomIn(_ sender: Any?) { canvasViewController?.zoomIn() }
    @IBAction func zoomOut(_ sender: Any?) { canvasViewController?.zoomOut() }

    @IBAction func insertTextLayer(_ sender: Any?) { insertLayer(.text) }
    @IBAction func insertRectangleLayer(_ sender: Any?) { insertLayer(.rectangle) }
    @IBAction func insertRoundedRectangleLayer(_ sender: Any?) { insertLayer(.roundedRectangle) }
    @IBAction func insertEllipseLayer(_ sender: Any?) { insertLayer(.ellipse) }

    @IBAction func applyGrid2x2Template(_ sender: Any?) { applyTemplate(.grid2x2) }
    @IBAction func applyGrid3x3Template(_ sender: Any?) { applyTemplate(.grid3x3) }
    @IBAction func applyPolaroidStackTemplate(_ sender: Any?) { applyTemplate(.polaroidStack) }

    @IBAction func toggleSelectedLayerVisibility(_ sender: Any?) {
        guard let state = (document as? AssemblageDocument)?.state,
              let id = state.selectedLayerID
        else { return }
        LayerListEditing(state: state).toggleVisibility(of: id)
    }

    @IBAction func deleteSelectedLayer(_ sender: Any?) {
        guard let state = (document as? AssemblageDocument)?.state,
              let id = state.selectedLayerID
        else { return }
        LayerListEditing(state: state).delete(id)
    }

    @IBAction func moveSelectedLayerUp(_ sender: Any?) { moveSelectedLayer(.up) }
    @IBAction func moveSelectedLayerDown(_ sender: Any?) { moveSelectedLayer(.down) }
    @IBAction func moveSelectedLayerToTop(_ sender: Any?) { moveSelectedLayer(.toTop) }
    @IBAction func moveSelectedLayerToBottom(_ sender: Any?) { moveSelectedLayer(.toBottom) }

    @IBAction func selectDistortTool(_ sender: Any?) { _ = toolbarController?.select(.distort) }

    @IBAction func resetSelectedLayerDistortion(_ sender: Any?) {
        guard let state = (document as? AssemblageDocument)?.state else { return }
        DistortionCommands.resetSelected(in: state)
    }

    @IBAction func addLayerTexture(_ sender: Any?) {
        guard let state = (document as? AssemblageDocument)?.state else { return }
        TextureCommand.chooseTexture(in: state, host: window)
    }

    @IBAction func removeLayerTexture(_ sender: Any?) {
        guard let state = (document as? AssemblageDocument)?.state else { return }
        if TextureCommand.removeTexture(in: state) != .removed { NSSound.beep() }
    }

    @IBAction func toggleLayerComparison(_ sender: Any?) {
        guard canvasViewController?.toggleComparison() == false else { return }
        // Nichts zu vergleichen: kurz akustisch quittieren statt still nichts
        // zu tun, damit der Befehl nicht kaputt wirkt.
        NSSound.beep()
    }

    @IBAction func flattenSelectedLayer(_ sender: Any?) {
        guard let state = (document as? AssemblageDocument)?.state else { return }
        _ = LayerFlattening.flattenSelected(in: state)
    }

    private func moveSelectedLayer(_ command: LayerOrderCommand) {
        guard let state = (document as? AssemblageDocument)?.state else { return }
        LayerListEditing(state: state).moveSelected(command)
    }

    private func insertLayer(_ kind: NewLayerKind) {
        guard let state = (document as? AssemblageDocument)?.state else { return }
        LayerCreation.insert(kind, into: state)
    }

    private func applyTemplate(_ template: CollageTemplate) {
        guard let state = (document as? AssemblageDocument)?.state else { return }
        CollageTemplateCommand.apply(template, to: state)
    }

    /// „Bearbeiten › Motiv freistellen“ wirkt ausschliesslich auf die aktuell
    /// ausgewählte Bildebene. Die eigentliche Arbeit und Darstellung liegen
    /// in `ForegroundMaskingCommand.swift`.
    @IBAction func removeSubjectBackground(_ sender: Any?) {
        guard let document = document as? AssemblageDocument, let window else { return }
        ForegroundMaskingCommandController.perform(in: document, host: window)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let action = menuItem.action,
           [
            #selector(toggleSelectedLayerVisibility(_:)),
            #selector(deleteSelectedLayer(_:)),
            #selector(moveSelectedLayerUp(_:)),
            #selector(moveSelectedLayerDown(_:)),
            #selector(moveSelectedLayerToTop(_:)),
            #selector(moveSelectedLayerToBottom(_:))
           ].contains(action) {
            return (document as? AssemblageDocument)?.state.selectedLayer != nil
        }

        if menuItem.action == #selector(removeSubjectBackground(_:)) {
            guard let document = document as? AssemblageDocument else { return false }
            return ForegroundMaskingCommandController.canPerform(in: document)
        }

        if menuItem.action == #selector(selectDistortTool(_:)) {
            return (document as? AssemblageDocument)?.state.selectedLayer != nil
        }

        // Ausgrauen statt piepsen, wo sich der Zustand vorher sicher sagen
        // lässt: Ein Befehl, der beim Klicken nur einen Ton macht, wirkt
        // kaputt.
        if menuItem.action == #selector(addLayerTexture(_:)) {
            return (document as? AssemblageDocument)?.state.selectedLayer != nil
        }

        if menuItem.action == #selector(removeLayerTexture(_:)) {
            return (document as? AssemblageDocument)?.state.selectedLayer?.texture != nil
        }

        if menuItem.action == #selector(toggleLayerComparison(_:)) {
            guard let controller = canvasViewController else { return false }
            // Während eines laufenden Vergleichs bleibt der Befehl wählbar —
            // sonst käme man nicht mehr zurück.
            return controller.isComparing
                || (document as? AssemblageDocument)?.state.selectedLayer?.hasEdits == true
        }

        if menuItem.action == #selector(resetSelectedLayerDistortion(_:)) {
            return (document as? AssemblageDocument)?.state.selectedLayer?.distortion != nil
        }

        if menuItem.action == #selector(flattenSelectedLayer(_:)) {
            guard let inhalt = (document as? AssemblageDocument)?.state.selectedLayer?.content else {
                return false
            }
            return LayerFlattening.canFlatten(inhalt)
        }

        if let action = menuItem.action,
           [
            #selector(applyGrid2x2Template(_:)),
            #selector(applyGrid3x3Template(_:)),
            #selector(applyPolaroidStackTemplate(_:))
           ].contains(action) {
            guard let state = (document as? AssemblageDocument)?.state else { return false }
            return CollageTemplateCommand.canApply(to: state)
        }

        return true
    }

    /// „Ablage › Exportieren…" (Plan 5.8). Ohne Dokument oder Fenster passiert
    /// nichts — dieselbe Absicherung wie beim Rest der Menübefehle hier;
    /// ohne Ziel ist der Menüpunkt über die Responder-Chain-Validierung
    /// ohnehin schon ausgegraut.
    @IBAction func exportDocument(_ sender: Any?) {
        guard let assemblageDocument = document as? AssemblageDocument, let window else { return }
        ExportPanelController.present(for: assemblageDocument, host: window)
    }
}

extension DocumentWindowController {
    @IBAction func insertTriangleLayer(_ sender: Any?) {
        guard let state = (document as? AssemblageDocument)?.state else { return }
        LayerCreation.insert(.triangle, into: state)
    }

    @IBAction func insertPentagonLayer(_ sender: Any?) {
        guard let state = (document as? AssemblageDocument)?.state else { return }
        LayerCreation.insert(.pentagon, into: state)
    }

    @IBAction func insertHexagonLayer(_ sender: Any?) {
        guard let state = (document as? AssemblageDocument)?.state else { return }
        LayerCreation.insert(.hexagon, into: state)
    }

    @IBAction func insertStarLayer(_ sender: Any?) {
        guard let state = (document as? AssemblageDocument)?.state else { return }
        LayerCreation.insert(.star, into: state)
    }

    @IBAction func insertHeartLayer(_ sender: Any?) {
        guard let state = (document as? AssemblageDocument)?.state else { return }
        LayerCreation.insert(.heart, into: state)
    }

    @IBAction func insertArrowLayer(_ sender: Any?) {
        guard let state = (document as? AssemblageDocument)?.state else { return }
        LayerCreation.insert(.arrow, into: state)
    }

    @IBAction func insertSpeechBubbleLayer(_ sender: Any?) {
        guard let state = (document as? AssemblageDocument)?.state else { return }
        LayerCreation.insert(.speechBubble, into: state)
    }
}
