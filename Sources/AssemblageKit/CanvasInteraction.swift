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

    func canvasView(_ canvasView: CanvasView, didMoveLayerWithID id: UUID, toCentre centre: Point)

    func canvasView(_ canvasView: CanvasView, didEndInteractionNamed actionName: String)
}

/// Ein laufendes Ziehen.
struct CanvasDrag {
    let layerID: UUID
    /// Wo die Ebene stand, als das Ziehen begann. Der Versatz wird immer gegen
    /// diesen Ausgangspunkt gerechnet und nicht Schritt für Schritt
    /// aufaddiert — sonst summieren sich Rundungsfehler über hundert
    /// Mausmeldungen sichtbar auf.
    let startCentre: Point
    let startPoint: Point
    /// Erst ab einer Mindestbewegung gilt es als Ziehen. Ohne diese Schwelle
    /// verschiebt schon ein leicht wackelnder Klick die Ebene um einen Punkt.
    private(set) var hasPassedThreshold = false

    static let threshold: Double = 3

    init(layerID: UUID, startCentre: Point, startPoint: Point) {
        self.layerID = layerID
        self.startCentre = startCentre
        self.startPoint = startPoint
    }

    /// Neuer Mittelpunkt für die aktuelle Zeigerposition — oder `nil`, solange
    /// die Schwelle noch nicht überschritten ist.
    mutating func centre(draggedTo point: Point) -> Point? {
        let dx = point.x - startPoint.x
        let dy = point.y - startPoint.y

        if !hasPassedThreshold {
            guard (dx * dx + dy * dy).squareRoot() >= Self.threshold else { return nil }
            hasPassedThreshold = true
        }
        return Point(x: startCentre.x + dx, y: startCentre.y + dy)
    }
}
