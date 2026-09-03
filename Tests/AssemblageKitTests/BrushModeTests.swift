import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Der Pinselmodus auf dem Canvas (Plan 5.4).
///
/// Wie beim Zuschneiden bedeuten dieselben Mausbewegungen hier etwas anderes
/// als sonst — und genau solche Doppelbelegungen gehen leicht schief.
@MainActor
final class BrushModeTests: XCTestCase {

    private final class Protokoll: CanvasInteractionDelegate {
        var striche: [(id: UUID, daten: Data)] = []
        var aenderungen: [(id: UUID, transform: Transform2D)] = []
        var beendet: [String] = []
        var auswahl: [UUID?] = []
        func canvasView(_ canvasView: CanvasView, didSelectLayerWithID id: UUID?) { auswahl.append(id) }
        func canvasViewDidBeginInteraction(_ canvasView: CanvasView) {}
        func canvasView(_ canvasView: CanvasView, didChangeLayerWithID id: UUID, to transform: Transform2D) {
            aenderungen.append((id, transform))
        }
        func canvasView(_ canvasView: CanvasView, didEndInteractionNamed actionName: String) {
            beendet.append(actionName)
        }
        func canvasView(_ canvasView: CanvasView, didReceiveDropFrom pasteboard: NSPasteboard) {}
        func canvasView(_ canvasView: CanvasView, didChangeCropOfLayerWithID id: UUID, to crop: Rect) {}
        func canvasView(_ canvasView: CanvasView, didPaintMaskForLayerWithID id: UUID, pngData: Data) {
            striche.append((id, pngData))
        }
    }

    private var fenster: NSWindow!
    private var canvas: CanvasView!
    private var protokoll: Protokoll!
    private var bildID: UUID!

    override func setUpWithError() throws {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let png = try XCTUnwrap(
            NSBitmapImageRep(cgImage: try XCTUnwrap(ctx.makeImage()))
                .representation(using: .png, properties: [:])
        )

        let resources = DocumentResources()
        let referenz = resources.addOriginal(png, fileExtension: "png")
        let bild = Layer(
            name: "Foto",
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

    /// Der entscheidende Fall: Im Pinselmodus darf ein Zug die Ebene **nicht**
    /// verschieben. Sonst wandert das Bild beim ersten Strich davon.
    func testStrokePaintsInsteadOfMovingTheLayer() throws {
        canvas.brushLayerID = bildID

        try male(von: (60, 100), nach: (140, 100))

        XCTAssertEqual(protokoll.striche.count, 1, "genau ein Strich gemeldet")
        XCTAssertEqual(protokoll.striche.first?.id, bildID)
        XCTAssertTrue(protokoll.aenderungen.isEmpty, "die Ebene darf sich nicht bewegt haben")
        XCTAssertTrue(protokoll.beendet.isEmpty)
    }

    /// Ohne Pinselmodus verschiebt derselbe Zug wie bisher.
    func testWithoutBrushModeTheSameDragStillMoves() throws {
        try male(von: (60, 100), nach: (140, 100))

        XCTAssertTrue(protokoll.striche.isEmpty)
        XCTAssertEqual(protokoll.beendet, ["Ebene verschieben"])
    }

    /// Der Strich wird erst beim Loslassen gemeldet — sonst entstünde pro
    /// Mausmeldung eine Maskendatei und ein Undo-Schritt.
    func testStrokeIsReportedOnlyOnMouseUp() throws {
        canvas.brushLayerID = bildID

        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 60, y: 100))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: 100, y: 100))
        XCTAssertTrue(protokoll.striche.isEmpty, "während des Malens noch nichts")

        canvas.mouseUp(with: try ereignis(.leftMouseUp, atCanvasX: 100, y: 100))
        XCTAssertEqual(protokoll.striche.count, 1)
    }

    /// Während des Strichs muss man sofort sehen, was man malt (Plan 4.4) —
    /// die Maskenschicht hängt schon vor dem Loslassen.
    func testStrokeIsVisibleImmediately() throws {
        canvas.brushLayerID = bildID
        let schicht = try XCTUnwrap(canvas.layer?.sublayers?.first?.sublayers?.first)
        XCTAssertNil(schicht.mask, "vorher keine Maske")

        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 100, y: 100))

        XCTAssertNotNil(schicht.mask, "die Vorschau muss sofort sichtbar sein")
    }

    /// Die gemeldeten Daten müssen ein Bild in Bildauflösung sein — sonst
    /// passt die Maske beim Rendern nicht.
    func testReportedMaskHasImageResolution() throws {
        canvas.brushLayerID = bildID

        try male(von: (60, 100), nach: (140, 100))

        let daten = try XCTUnwrap(protokoll.striche.first?.daten)
        let bild = try XCTUnwrap(ImageDecoding.decode(daten))
        XCTAssertEqual(bild.width, 200)
        XCTAssertEqual(bild.height, 200)
    }

    /// Escape verlässt den Pinselmodus.
    func testEscapeLeavesBrushMode() throws {
        canvas.brushLayerID = bildID
        canvas.cancelOperation(nil)

        XCTAssertNil(canvas.brushLayerID)
    }

    /// Pinsel und Zuschneiden schliessen sich aus — dieselben Bewegungen
    /// können nicht zweierlei bedeuten.
    func testBrushModeLeavesCropMode() throws {
        canvas.croppingLayerID = bildID
        canvas.brushLayerID = bildID

        XCTAssertNil(canvas.croppingLayerID)
    }

    /// Ein Klick ohne Bewegung malt trotzdem einen Punkt — das ist gewollt,
    /// man tupft damit einzelne Stellen weg.
    func testSingleClickPaintsADot() throws {
        canvas.brushLayerID = bildID

        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 100, y: 100))
        canvas.mouseUp(with: try ereignis(.leftMouseUp, atCanvasX: 100, y: 100))

        XCTAssertEqual(protokoll.striche.count, 1)
    }
}
