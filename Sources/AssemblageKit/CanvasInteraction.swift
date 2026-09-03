import AppKit
import AssemblageModel

/// Was der Canvas meldet, wenn der Nutzer auf ihm arbeitet.
///
/// Der Canvas kennt das Dokument bewusst nicht — er meldet nur, was passiert
/// ist. So bleibt er ohne Dokument testbar (siehe CanvasRenderingTests), und
/// die Regel „Änderungen laufen ausschliesslich über
/// `AssemblageDocument.modify(_:_:)`" bleibt an einer Stelle durchsetzbar.
@MainActor
protocol CanvasInteractionDelegate: AnyObject {

    func canvasView(_ canvasView: CanvasView, didSelectLayerWithID id: UUID?)

    /// Ein Ziehen beginnt. Alles bis `didEndInteraction` wird ein Undo-Schritt.
    func canvasViewDidBeginInteraction(_ canvasView: CanvasView)

    /// Verschieben, Skalieren und Drehen melden alle dasselbe: eine neue
    /// Transformation. Getrennte Meldungen je Art würden dreimal dieselbe
    /// Verdrahtung brauchen.
    func canvasView(_ canvasView: CanvasView, didChangeLayerWithID id: UUID, to transform: Transform2D)

    func canvasView(_ canvasView: CanvasView, didEndInteractionNamed actionName: String)
}

/// Ein laufendes Ziehen auf dem Canvas.
struct CanvasDrag {

    enum Kind {
        case move
        case resize(ResizeHandle)
        case rotate

        /// Beschriftung des Undo-Schritts — der Nutzer soll im Menü lesen
        /// können, was er rückgängig macht.
        var actionName: String {
            switch self {
            case .move: return "Ebene verschieben"
            case .resize: return "Ebene skalieren"
            case .rotate: return "Ebene drehen"
            }
        }
    }

    let kind: Kind
    let layerID: UUID
    /// Zustand beim Aufsetzen der Maus. Jede Zwischenmeldung rechnet gegen
    /// diesen Ausgangspunkt statt gegen den letzten Stand — sonst summieren
    /// sich Rundungsfehler über hundert Mausmeldungen sichtbar auf.
    let startTransform: Transform2D
    let contentSize: Size
    let startPoint: Point

    /// Erst ab einer Mindestbewegung gilt es als Ziehen. Ohne diese Schwelle
    /// verschiebt schon ein leicht wackelnder Klick die Ebene um einen Punkt.
    private(set) var hasPassedThreshold = false

    static let threshold: Double = 3
    /// Rasterschritt beim Drehen mit gedrückter Umschalttaste.
    static let rotationStep: Double = 15

    init(kind: Kind, layerID: UUID, startTransform: Transform2D, contentSize: Size, startPoint: Point) {
        self.kind = kind
        self.layerID = layerID
        self.startTransform = startTransform
        self.contentSize = contentSize
        self.startPoint = startPoint
    }

    /// Neue Transformation für die aktuelle Zeigerposition — oder `nil`,
    /// solange die Schwelle noch nicht überschritten ist.
    ///
    /// `constrains` ist die Umschalttaste: beim Skalieren hält sie das
    /// Seitenverhältnis, beim Drehen rastet sie in Schritten ein.
    mutating func transform(draggedTo point: Point, constrains: Bool) -> Transform2D? {
        let dx = point.x - startPoint.x
        let dy = point.y - startPoint.y

        if !hasPassedThreshold {
            guard (dx * dx + dy * dy).squareRoot() >= Self.threshold else { return nil }
            hasPassedThreshold = true
        }

        switch kind {
        case .move:
            var verschoben = startTransform
            verschoben.x = startTransform.x + dx
            verschoben.y = startTransform.y + dy
            return verschoben

        case .resize(let handle):
            return startTransform.resized(
                handle: handle,
                draggedTo: point,
                contentSize: contentSize,
                keepingAspectRatio: constrains
            )

        case .rotate:
            return startTransform.rotated(
                towards: point,
                snappingTo: constrains ? Self.rotationStep : nil
            )
        }
    }
}
