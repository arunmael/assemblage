import AppKit
import Combine
import AssemblageModel

/// Beherbergt den Canvas in einer scroll- und zoombaren Fläche.
@MainActor
final class CanvasViewController: NSViewController {

    private let state: DocumentState
    private var canvasView: CanvasView!
    private let scrollView = NSScrollView()
    private var observations: Set<AnyCancellable> = []
    /// Beim ersten Anzeigen einmal auf Fenstergrösse einpassen — danach nicht
    /// mehr, sonst würde jede Fenstergrössenänderung den vom Nutzer gewählten
    /// Zoom zurücksetzen.
    private var hasPerformedInitialFit = false

    init(state: DocumentState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    override func loadView() {
        canvasView = CanvasView(document: state.document, images: state.images)

        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvasView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor

        // Zoomen übernimmt AppKit — damit funktioniert die Pinch-Geste
        // automatisch, auch über Sidecar Direct Touch (Plan 2.2).
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 16

        canvasView.interactionDelegate = self
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
    }

    @objc private func zoomDidChange() {
        canvasView.zoomScale = scrollView.magnification
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        state.$document
            .sink { [weak self] document in
                // Auf den nächsten Durchlauf verschieben: `sink` feuert,
                // *bevor* `@Published` den neuen Wert geschrieben hat.
                DispatchQueue.main.async { self?.canvasView.update(to: document) }
            }
            .store(in: &observations)

        // Auswahl über die Ebenenliste muss den Rahmen auf dem Canvas
        // mitziehen — sonst zeigen Liste und Leinwand Verschiedenes.
        state.$selectedLayerID
            .sink { [weak self] id in
                DispatchQueue.main.async { self?.canvasView.selectedLayerID = id }
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
        scrollView.contentView.scrollToVisible(canvasView.bounds)
    }

    @objc func zoomToActualSize() {
        scrollView.magnification = 1
    }

    @objc func zoomIn() {
        scrollView.magnification = min(scrollView.magnification * 1.5, scrollView.maxMagnification)
    }

    @objc func zoomOut() {
        scrollView.magnification = max(scrollView.magnification / 1.5, scrollView.minMagnification)
    }
}


// MARK: - Was auf dem Canvas passiert

extension CanvasViewController: CanvasInteractionDelegate {

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
}
