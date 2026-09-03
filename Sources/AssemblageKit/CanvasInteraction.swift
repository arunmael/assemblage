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

    /// Auf die Leinwand gezogene Bilder (Plan 5.1). Der Canvas nimmt sie nur
    /// entgegen; was damit geschieht, entscheidet das Dokument.
    func canvasView(_ canvasView: CanvasView, didReceiveDropFrom pasteboard: NSPasteboard)

    /// Neuer Zuschnitt für eine Bildebene (Plan 5.3), in Bildkoordinaten.
    func canvasView(_ canvasView: CanvasView, didChangeCropOfLayerWithID id: UUID, to crop: Rect)
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

/// Ein laufendes Ziehen an einem Zuschnitt-Griff (Plan 5.3).
///
/// Bewusst getrennt von `CanvasDrag`: Zuschneiden ändert ein Rechteck in
/// **Bild**koordinaten, nicht die Transformation der Ebene. Beides in eine
/// Struktur zu zwingen hiesse, überall zu unterscheiden, was gerade gemeint
/// ist.
struct CropDrag {
    let layerID: UUID
    let handle: ResizeHandle
    /// Der Ausschnitt beim Aufsetzen der Maus. Jede Zwischenmeldung rechnet
    /// dagegen, nicht gegen den zuletzt gesetzten Wert.
    let startCrop: Rect
    let imageSize: Size
    private(set) var hasPassedThreshold = false
    private let startPoint: Point

    init(layerID: UUID, handle: ResizeHandle, startCrop: Rect, imageSize: Size, startPoint: Point) {
        self.layerID = layerID
        self.handle = handle
        self.startCrop = startCrop
        self.imageSize = imageSize
        self.startPoint = startPoint
    }

    /// Neuer Ausschnitt für einen Punkt in **Bild**koordinaten.
    mutating func crop(draggedTo imagePoint: Point, canvasPoint: Point) -> Rect? {
        if !hasPassedThreshold {
            let dx = canvasPoint.x - startPoint.x
            let dy = canvasPoint.y - startPoint.y
            guard (dx * dx + dy * dy).squareRoot() >= CanvasDrag.threshold else { return nil }
            hasPassedThreshold = true
        }
        return startCrop.adjusted(handle: handle, to: imagePoint)
    }
}
