import AppKit
import SwiftUI

/// Das Dokumentfenster: Ebenen links, Canvas in der Mitte, Eigenschaften
/// rechts (Plan 8).
///
/// `NSSplitViewController` mit Sidebar-Elementen, weil daran die
/// Liquid-Glass-Optik aus Plan 4.5 hängt: Nur eine echte Sidebar bekommt vom
/// System die durchscheinende Materialfläche — nachgebaut sieht sie immer
/// falsch aus.
@MainActor
final class DocumentWindowController: NSWindowController {

    private var splitViewController: NSSplitViewController?
    private var canvasViewController: CanvasViewController?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.setFrameAutosaveName("AssemblageDocumentWindow")
        self.init(window: window)
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        guard let state = (document as? AssemblageDocument)?.state else { return }

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

        let canvasItem = NSSplitViewItem(viewController: canvas)
        canvasItem.minimumThickness = 400

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 260
        inspectorItem.maximumThickness = 380

        let splitViewController = NSSplitViewController()
        splitViewController.addSplitViewItem(layersItem)
        splitViewController.addSplitViewItem(canvasItem)
        splitViewController.addSplitViewItem(inspectorItem)
        self.splitViewController = splitViewController

        contentViewController = splitViewController
        window?.toolbarStyle = .unified
    }

    // MARK: - Menübefehle

    @IBAction func zoomToFit(_ sender: Any?) { canvasViewController?.zoomToFit() }
    @IBAction func zoomToActualSize(_ sender: Any?) { canvasViewController?.zoomToActualSize() }
    @IBAction func zoomIn(_ sender: Any?) { canvasViewController?.zoomIn() }
    @IBAction func zoomOut(_ sender: Any?) { canvasViewController?.zoomOut() }
}
