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
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Bewusst ohne `.fullSizeContentView`: Ohne Werkzeugleiste liefe die
        // Leinwand sonst unter die Titelleiste und überdeckte den
        // Dokumentnamen. Sobald die Werkzeugleiste aus Plan 8 dazukommt, kann
        // sie den Platz übernehmen und der durchgehende Inhalt wieder rein.

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

    /// „Ablage › Exportieren…" (Plan 5.8). Ohne Dokument oder Fenster passiert
    /// nichts — dieselbe Absicherung wie beim Rest der Menübefehle hier;
    /// ohne Ziel ist der Menüpunkt über die Responder-Chain-Validierung
    /// ohnehin schon ausgegraut.
    @IBAction func exportDocument(_ sender: Any?) {
        guard let assemblageDocument = document as? AssemblageDocument, let window else { return }
        ExportPanelController.present(for: assemblageDocument, host: window)
    }
}
