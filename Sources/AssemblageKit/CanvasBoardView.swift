import AppKit

/// Die Fläche, auf der die Leinwand liegt. Nur innerhalb des `documentView`
/// lässt AppKit Positionen wirklich anfahren; jenseits davon federt der
/// elastische Bildlauf zurück. Der grosse Rand ringsum ist deshalb der
/// eigentliche freie Bildlauf.
@MainActor
final class CanvasBoardView: NSView {

    static let margin: CGFloat = 3_000

    let canvasView: CanvasView

    init(canvasView: CanvasView) {
        self.canvasView = canvasView
        super.init(frame: .zero)
        addSubview(canvasView)
        layoutCanvas()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    /// Das Fenster ist `isMovableByWindowBackground` (randloser Look, siehe
    /// `DocumentWindowController`). AppKit fängt einen Mausklick dann *vor*
    /// der Ansicht ab und verschiebt stattdessen das Fenster — und zwar
    /// überall dort, wo keine deckend zeichnende Ansicht widerspricht. Seit
    /// die Leinwandfläche im Erscheinungsbild „Beautifull" durchsichtig ist,
    /// traf das auch die Arbeitsfläche selbst: Ziehen mit dem Zeiger-Werkzeug
    /// verschob das ganze Fenster statt der Ebene. Deshalb hier ausdrücklich
    /// widersprechen — unabhängig vom Erscheinungsbild, denn die Fläche ist in
    /// beiden Fällen Arbeitsfläche und keine Fenster-Ziehzone.
    override var mouseDownCanMoveWindow: Bool { false }

    /// Passt Brettgrösse und Lage der Leinwand an die aktuelle Leinwandgrösse
    /// an. Muss nach jeder Änderung der Leinwandgrösse laufen.
    func layoutCanvas() {
        let canvasSize = canvasView.frame.size
        setFrameSize(CGSize(
            width: canvasSize.width + 2 * Self.margin,
            height: canvasSize.height + 2 * Self.margin
        ))
        canvasView.setFrameOrigin(CGPoint(x: Self.margin, y: Self.margin))
    }
}
