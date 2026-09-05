import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Der Farbpinsel auf dem Canvas (aus Anpassungen.md: „nicht nur radieren
/// sondern auch wie mit Farben ... auf einer eigenen Ebene").
@MainActor
final class ColorPaintModeTests: XCTestCase {

    private final class Protokoll: CanvasInteractionDelegate {
        var farbstriche: [(id: UUID, daten: Data)] = []
        var aenderungen: [(id: UUID, transform: Transform2D)] = []
        var beendet: [String] = []
        func canvasView(_ canvasView: CanvasView, didSelectLayerWithID id: UUID?) {}
        func canvasViewDidBeginInteraction(_ canvasView: CanvasView) {}
        func canvasView(_ canvasView: CanvasView, didChangeLayerWithID id: UUID, to transform: Transform2D) {
            aenderungen.append((id, transform))
        }
        func canvasView(_ canvasView: CanvasView, didEndInteractionNamed actionName: String) {
            beendet.append(actionName)
        }
        func canvasView(_ canvasView: CanvasView, didReceiveDropFrom pasteboard: NSPasteboard) {}
        func canvasView(_ canvasView: CanvasView, didChangeCropOfLayerWithID id: UUID, to crop: Rect) {}
        func canvasView(_ canvasView: CanvasView, didPaintMaskForLayerWithID id: UUID, pngData: Data) {}
        func canvasView(_ canvasView: CanvasView, didPaintColorForLayerWithID id: UUID, pngData: Data) {
            farbstriche.append((id, pngData))
        }
    }

    private var fenster: NSWindow!
    private var canvas: CanvasView!
    private var protokoll: Protokoll!
    private var bildID: UUID!

    override func setUpWithError() throws {
        // Eine leere, durchsichtige Fläche — wie eine frisch eingefügte
        // Malebene.
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.clear(CGRect(x: 0, y: 0, width: 200, height: 200))
        let png = try XCTUnwrap(
            NSBitmapImageRep(cgImage: try XCTUnwrap(ctx.makeImage()))
                .representation(using: .png, properties: [:])
        )

        let resources = DocumentResources()
        let referenz = resources.addOriginal(png, fileExtension: "png")
        let bild = Layer(
            name: "Malebene",
            transform: Transform2D(x: 100, y: 100),
            content: .image(ImageLayerContent(originalFileReference: referenz))
        )
        bildID = bild.id

        canvas = CanvasView(
            document: AssemblageModel.Document(
                canvas: CanvasSize(width: 200, height: 200),
                layers: [bild]
            ),
            images: ImageStore(resources: resources)
        )
        protokoll = Protokoll()
        canvas.interactionDelegate = protokoll
        canvas.paintBrush = PaintBrush(diameter: 20, hardness: 1, colorHex: "#FF0000", opacity: 1)

        fenster = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        fenster.contentView?.addSubview(canvas)
        canvas.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
    }

    private func ereignis(_ typ: NSEvent.EventType, atCanvasX x: Double, y: Double) throws -> NSEvent {
        let inView = NSPoint(x: x, y: Double(canvas.bounds.height) - y)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: typ, location: canvas.convert(inView, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: fenster.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    private func male(von: (Double, Double), nach: (Double, Double)) throws {
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: von.0, y: von.1))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: nach.0, y: nach.1))
        canvas.mouseUp(with: try ereignis(.leftMouseUp, atCanvasX: nach.0, y: nach.1))
    }

    // MARK: - Malen statt verschieben

    /// Wie beim Pinsel-Modus: Ein Zug darf die Ebene nicht verschieben.
    func testStrokePaintsInsteadOfMovingTheLayer() throws {
        canvas.paintLayerID = bildID

        try male(von: (60, 100), nach: (140, 100))

        XCTAssertEqual(protokoll.farbstriche.count, 1, "genau ein Farbstrich gemeldet")
        XCTAssertEqual(protokoll.farbstriche.first?.id, bildID)
        XCTAssertTrue(protokoll.aenderungen.isEmpty, "die Ebene darf sich nicht bewegt haben")
        XCTAssertTrue(protokoll.beendet.isEmpty)
    }

    func testWithoutPaintModeTheSameDragStillMoves() throws {
        try male(von: (60, 100), nach: (140, 100))

        XCTAssertTrue(protokoll.farbstriche.isEmpty)
        XCTAssertEqual(protokoll.beendet, ["Ebene verschieben"])
    }

    /// Der Strich wird erst beim Loslassen gemeldet, nicht bei jeder
    /// Mausmeldung — sonst entstünde pro Zwischenschritt eine neue Datei.
    func testStrokeIsReportedOnlyOnMouseUp() throws {
        canvas.paintLayerID = bildID

        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 60, y: 100))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: 100, y: 100))
        XCTAssertTrue(protokoll.farbstriche.isEmpty)

        canvas.mouseUp(with: try ereignis(.leftMouseUp, atCanvasX: 140, y: 100))
        XCTAssertEqual(protokoll.farbstriche.count, 1)
    }

    /// Ein Klick ohne Bewegung malt trotzdem einen Punkt — man will auch
    /// einen einzelnen Farbtupfer setzen können.
    func testASingleClickStillPaintsADot() throws {
        canvas.paintLayerID = bildID
        try male(von: (100, 100), nach: (100, 100))
        XCTAssertEqual(protokoll.farbstriche.count, 1)
    }

    // MARK: - Der entscheidende Fall: keine Spiegelung

    /// Derselbe Fehler, der beim Pinsel real aufgetreten ist
    /// (`BrushModeTests.testStrokeNearTheTopLandsNearTheTopNotTheBottom`),
    /// hier ausdrücklich auch für den neuen Farbpinsel geprüft.
    func testStrokeNearTheTopLandsNearTheTopNotTheBottom() throws {
        canvas.paintLayerID = bildID

        try male(von: (100, 10), nach: (100, 10))

        let daten = try XCTUnwrap(protokoll.farbstriche.first?.daten)
        let bild = try XCTUnwrap(NSBitmapImageRep(data: daten))

        let oben = try XCTUnwrap(bild.colorAt(x: 100, y: 10))
        let unten = try XCTUnwrap(bild.colorAt(x: 100, y: 190))

        XCTAssertGreaterThan(oben.alphaComponent, 0.5, "oben, wo gemalt wurde, müsste Farbe liegen")
        XCTAssertLessThan(unten.alphaComponent, 0.1, "unten, wo nicht gemalt wurde, müsste es leer bleiben")
    }

    // MARK: - Ausschliesslichkeit der Modi

    /// Farbe malen schliesst die anderen Modi aus wie jeder andere auch.
    func testPaintModeIsExclusiveWithOtherModes() {
        canvas.brushLayerID = bildID
        canvas.paintLayerID = bildID
        XCTAssertNil(canvas.brushLayerID, "Farbe malen müsste die Pinsel-Maske beenden")

        canvas.croppingLayerID = bildID
        XCTAssertNil(canvas.paintLayerID, "Zuschneiden müsste das Malen beenden")
    }
}
