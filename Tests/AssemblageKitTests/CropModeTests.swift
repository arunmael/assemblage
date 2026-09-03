import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Der Zuschneiden-Modus auf dem Canvas (Plan 5.3).
///
/// Die Griffe bedeuten hier etwas anderes als sonst: nicht die Ebene
/// skalieren, sondern den sichtbaren Ausschnitt verschieben. Genau solche
/// Doppelbelegungen gehen leicht schief, deshalb mit echten Mausereignissen
/// geprüft.
@MainActor
final class CropModeTests: XCTestCase {

    private final class Protokoll: CanvasInteractionDelegate {
        var zuschnitte: [(id: UUID, crop: Rect)] = []
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
        func canvasView(_ canvasView: CanvasView, didChangeCropOfLayerWithID id: UUID, to crop: Rect) {
            zuschnitte.append((id, crop))
        }
    }

    private var fenster: NSWindow!
    private var canvas: CanvasView!
    private var protokoll: Protokoll!
    private var bildID: UUID!
    private var formID: UUID!

    override func setUpWithError() throws {
        // Testbild 200×100, damit sich Breite und Höhe unterscheiden.
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let png = try XCTUnwrap(
            NSBitmapImageRep(cgImage: try XCTUnwrap(ctx.makeImage()))
                .representation(using: .png, properties: [:])
        )

        let resources = DocumentResources()
        let referenz = resources.addOriginal(png, fileExtension: "png")

        let bild = Layer(
            name: "Foto",
            transform: Transform2D(x: 200, y: 200),
            content: .image(ImageLayerContent(originalFileReference: referenz))
        )
        let form = Layer(
            name: "Form",
            transform: Transform2D(x: 60, y: 340),
            content: .shape(ShapeLayerContent(kind: .rectangle, size: Size(width: 40, height: 40)))
        )
        bildID = bild.id
        formID = form.id

        canvas = CanvasView(
            document: AssemblageModel.Document(
                canvas: CanvasSize(width: 400, height: 400),
                layers: [bild, form]
            ),
            images: ImageStore(resources: resources)
        )
        protokoll = Protokoll()
        canvas.interactionDelegate = protokoll

        fenster = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        fenster.contentView?.addSubview(canvas)
        canvas.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    }

    private func ereignis(_ typ: NSEvent.EventType, atCanvasX x: Double, y: Double, klicks: Int = 1) throws -> NSEvent {
        let inView = NSPoint(x: x, y: Double(canvas.bounds.height) - y)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: typ, location: canvas.convert(inView, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: fenster.windowNumber, context: nil,
            eventNumber: 0, clickCount: klicks, pressure: 1
        ))
    }

    // MARK: - Modus betreten und verlassen

    func testDoubleClickOnImageEntersCropMode() throws {
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 200, y: 200, klicks: 2))

        XCTAssertEqual(canvas.croppingLayerID, bildID)
        XCTAssertFalse(canvas.cropPreviewLayerForTesting.isHidden, "das ganze Bild wird abgeschwächt gezeigt")
    }

    func testSecondDoubleClickLeavesCropMode() throws {
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 200, y: 200, klicks: 2))
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 200, y: 200, klicks: 2))

        XCTAssertNil(canvas.croppingLayerID)
        XCTAssertTrue(canvas.cropPreviewLayerForTesting.isHidden)
    }

    /// Nur Bildebenen lassen sich zuschneiden — bei einer Form gibt es kein
    /// Original, das man beschneiden könnte.
    func testDoubleClickOnShapeDoesNotEnterCropMode() throws {
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 60, y: 340, klicks: 2))

        XCTAssertNil(canvas.croppingLayerID)
    }

    func testEscapeLeavesCropMode() throws {
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 200, y: 200, klicks: 2))
        canvas.cancelOperation(nil)

        XCTAssertNil(canvas.croppingLayerID)
    }

    /// Wer eine andere Ebene anfasst, ist mit dem Zuschneiden fertig.
    func testClickingAnotherLayerLeavesCropMode() throws {
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 200, y: 200, klicks: 2))
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 60, y: 340))

        XCTAssertNil(canvas.croppingLayerID)
    }

    // MARK: - Zuschneiden

    /// Im Zuschneiden-Modus verschiebt derselbe Griff, der sonst skaliert,
    /// den Ausschnitt — und meldet ihn in **Bild**koordinaten.
    func testDraggingAHandleChangesTheCropNotTheScale() throws {
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 200, y: 200, klicks: 2))

        // Bild 200×100 mittig auf 200/200: linke Kante bei Leinwand-x 100.
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 100, y: 200))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: 140, y: 200))
        canvas.mouseUp(with: try ereignis(.leftMouseUp, atCanvasX: 140, y: 200))

        let letzter = try XCTUnwrap(protokoll.zuschnitte.last)
        XCTAssertEqual(letzter.id, bildID)
        XCTAssertEqual(letzter.crop.x, 40, accuracy: 0.001, "40 Bildpunkte von links weggeschnitten")
        XCTAssertEqual(letzter.crop.width, 160, accuracy: 0.001)
        XCTAssertEqual(letzter.crop.height, 100, accuracy: 0.001, "die Höhe bleibt unberührt")

        XCTAssertTrue(protokoll.aenderungen.isEmpty, "die Ebene selbst wird nicht skaliert")
        XCTAssertEqual(protokoll.beendet, ["Zuschneiden"])
    }

    /// Ohne Zuschneiden-Modus skaliert derselbe Griff wie zuvor — die
    /// Doppelbelegung darf nicht durchschlagen.
    func testOutsideCropModeTheSameHandleStillScales() throws {
        canvas.selectedLayerID = bildID

        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 100, y: 200))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: 140, y: 200))
        canvas.mouseUp(with: try ereignis(.leftMouseUp, atCanvasX: 140, y: 200))

        XCTAssertTrue(protokoll.zuschnitte.isEmpty)
        XCTAssertEqual(protokoll.beendet, ["Ebene skalieren"])
    }

    /// Ein Klick ohne Bewegung darf keinen Zuschnitt melden.
    func testClickWithoutDragChangesNoCrop() throws {
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 200, y: 200, klicks: 2))

        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 100, y: 200))
        canvas.mouseUp(with: try ereignis(.leftMouseUp, atCanvasX: 100, y: 200))

        XCTAssertTrue(protokoll.zuschnitte.isEmpty)
        XCTAssertTrue(protokoll.beendet.isEmpty)
    }
}
