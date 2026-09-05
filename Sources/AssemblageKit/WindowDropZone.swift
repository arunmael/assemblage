import AppKit
import AssemblageModel

/// Die eigentliche Ablagefläche fürs ganze Fenster (aus Anpassungen.md: „Man
/// soll ein File überall hin dropen können, nicht nur auf die Leinwand").
///
/// `CanvasView` war bisher das einzige Ablageziel; ein Bild über der
/// Ebenenliste oder dem Inspector losgelassen, zeigte gar nicht erst das
/// Kreuz-Symbol, weil dort niemand als `NSDraggingDestination` registriert
/// war. Diese Ansicht liegt als äusserste Hülle um den ganzen Fensterinhalt
/// und fängt jeden Wurf ab, der nicht ohnehin schon eine innere, spezifischere
/// Ablagefläche trifft (macOS bevorzugt beim Routen eines Wurfs die innerste
/// registrierte Ansicht — trifft der Zeiger direkt den Canvas, übernimmt der
/// wie bisher).
///
/// Wo genau im Fenster losgelassen wird, spielt keine Rolle: Ein importiertes
/// Bild landet immer über `LayerCreation`s Kaskaden-Platzierung mittig auf
/// der Leinwand, nie an der tatsächlichen Wurfstelle.
@MainActor
final class WindowDropZoneView: NSView {

    private lazy var dropHighlight = DropHighlightController(view: self)

    /// Wird vom Fenstercontroller gesetzt — derselbe Weg, den `CanvasView`
    /// über `didReceiveDropFrom` schon nimmt, nur eine Ebene höher.
    var onDrop: ((NSPasteboard) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let erlaubt = dropOperation(for: sender)
        dropHighlight.setActive(erlaubt != [])
        return erlaubt
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropHighlight.setActive(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dropHighlight.setActive(false)
    }

    private func dropOperation(for sender: any NSDraggingInfo) -> NSDragOperation {
        ImageImporter.canImport(from: sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropHighlight.setActive(false)
        guard ImageImporter.canImport(from: sender.draggingPasteboard) else { return false }
        onDrop?(sender.draggingPasteboard)
        return true
    }
}

/// Rahmt den bestehenden Fensterinhalt (`NSSplitViewController`) mit der
/// Ablagefläche oben drüber ein, ohne dessen eigene Grössen- und
/// Lebenszyklus-Verwaltung anzufassen.
///
/// Ein Container-View-Controller mit genau einem Kind statt eines Eingriffs
/// in `NSSplitViewController` selbst: Der Split View verwaltet seine
/// Spaltenbreiten und -constraints bereits vollständig; sie zu duplizieren
/// oder zu unterwandern wäre unnötig fehleranfällig.
@MainActor
final class WindowDropZoneViewController: NSViewController {

    private let dropZoneView = WindowDropZoneView(frame: .zero)

    var onDrop: ((NSPasteboard) -> Void)? {
        get { dropZoneView.onDrop }
        set { dropZoneView.onDrop = newValue }
    }

    init(embedding child: NSViewController) {
        super.init(nibName: nil, bundle: nil)
        addChild(child)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = dropZoneView

        guard let kindAnsicht = children.first?.view else { return }
        kindAnsicht.translatesAutoresizingMaskIntoConstraints = false
        dropZoneView.addSubview(kindAnsicht)
        NSLayoutConstraint.activate([
            kindAnsicht.topAnchor.constraint(equalTo: dropZoneView.topAnchor),
            kindAnsicht.bottomAnchor.constraint(equalTo: dropZoneView.bottomAnchor),
            kindAnsicht.leadingAnchor.constraint(equalTo: dropZoneView.leadingAnchor),
            kindAnsicht.trailingAnchor.constraint(equalTo: dropZoneView.trailingAnchor)
        ])
    }
}
