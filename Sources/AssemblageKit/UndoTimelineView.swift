import AppKit
import Combine

/// Zeichnet den Verlauf als echte Zeitachse: kräftig bis zum aktuellen
/// Schritt, schwach für den widerrufenen Teil und mit einer senkrechten Marke
/// an der gegenwärtigen Position. Eine Zeichenansicht hält Linie und Marke
/// pixelgenau zusammen; mehrere Subviews würden bei Rundung und Layout leicht
/// sichtbare Lücken erzeugen.
@MainActor
final class UndoTimelineView: NSView {

    private var undoDepth = 0
    private var redoDepth = 0
    private var lastReportedDepth: Int?
    var onSelectDepth: ((Int) -> Void)?
    // `draw(_:)` liest `AssemblageTheme.textPrimary`/`textTertiary` bei jedem
    // Aufruf frisch — ohne diese Anmeldung würde die Ansicht aber erst beim
    // nächsten `setDepths(...)` neu zeichnen, nicht schon beim Themenwechsel
    // selbst.
    private var themeSubscription: AnyCancellable?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        themeSubscription = ThemeManager.shared.$current
            .sink { [weak self] _ in self?.needsDisplay = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstützt") }

    private var totalDepth: Int { undoDepth + redoDepth }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var lineRange: (min: CGFloat, max: CGFloat) {
        (min: 1, max: max(1, bounds.width - 1))
    }

    func setDepths(undo: Int, redo: Int) {
        undoDepth = max(0, undo)
        redoDepth = max(0, redo)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let total = totalDepth
        let markerFraction = total == 0 ? 1 : CGFloat(undoDepth) / CGFloat(total)
        let lineMinX = lineRange.min
        let lineMaxX = lineRange.max
        let markerX = lineMinX + (lineMaxX - lineMinX) * markerFraction
        let centerY = bounds.midY

        let weakLine = NSBezierPath()
        weakLine.move(to: NSPoint(x: total == 0 ? lineMinX : markerX, y: centerY))
        weakLine.line(to: NSPoint(x: lineMaxX, y: centerY))
        weakLine.lineWidth = 1.5
        AssemblageTheme.textTertiary.setStroke()
        weakLine.stroke()

        if total > 0 {
            let strongLine = NSBezierPath()
            strongLine.move(to: NSPoint(x: lineMinX, y: centerY))
            strongLine.line(to: NSPoint(x: markerX, y: centerY))
            strongLine.lineWidth = 1.5
            AssemblageTheme.textPrimary.setStroke()
            strongLine.stroke()
        }

        // Bei wenigen Schritten zeigt das Raster, dass die Zeitachse aus
        // erreichbaren Zuständen besteht. Ab 41 Positionen würden die Ticks
        // optisch ineinanderlaufen und die Richtung schlechter lesbar machen.
        if total > 0, total <= 40 {
            for step in 0...total {
                let fraction = CGFloat(step) / CGFloat(total)
                let x = lineMinX + (lineMaxX - lineMinX) * fraction
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: x, y: centerY - 4.5))
                tick.line(to: NSPoint(x: x, y: centerY + 4.5))
                tick.lineWidth = 2
                (step <= undoDepth ? AssemblageTheme.textPrimary : AssemblageTheme.textTertiary).setStroke()
                tick.stroke()
            }
        }

        let marker = NSBezierPath()
        marker.move(to: NSPoint(x: markerX, y: centerY - 9))
        marker.line(to: NSPoint(x: markerX, y: centerY + 9))
        marker.lineWidth = 1.5
        AssemblageTheme.textPrimary.setStroke()
        marker.stroke()
    }

    func depth(atX x: CGFloat) -> Int {
        let range = lineRange
        guard range.max > range.min else { return 0 }
        let relativePosition = min(1, max(0, (x - range.min) / (range.max - range.min)))
        return Int((relativePosition * CGFloat(totalDepth)).rounded())
    }

    /// Ein Drag darf pro Rasterposition nur einmal melden; sonst würde jedes
    /// Maus-Pixel eine vollständige Folge von Undo-Aktionen auslösen.
    func handlePointer(atX x: CGFloat) {
        let target = depth(atX: x)
        guard target != lastReportedDepth else { return }
        lastReportedDepth = target
        onSelectDepth?(target)
    }

    override func mouseDown(with event: NSEvent) {
        lastReportedDepth = nil
        handlePointer(atX: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseDragged(with event: NSEvent) {
        handlePointer(atX: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        handlePointer(atX: convert(event.locationInWindow, from: nil).x)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
}
