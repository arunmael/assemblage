import AppKit
import Combine
import AssemblageModel

/// Beherbergt den Canvas in einer scroll- und zoombaren Fläche.
@MainActor
final class CanvasViewController: NSViewController {

    private let state: DocumentState
    private var canvasView: CanvasView!
    private let scrollView = NSScrollView()
    private var observation: AnyCancellable?
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

        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation = state.$document.sink { [weak self] document in
            // Auf den nächsten Durchlauf verschieben: `sink` feuert, *bevor*
            // `@Published` den neuen Wert geschrieben hat.
            DispatchQueue.main.async { self?.canvasView.update(to: document) }
        }
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
