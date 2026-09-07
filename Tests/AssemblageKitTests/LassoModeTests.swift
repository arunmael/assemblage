import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Verdrahtung des Freihand-Lassos von echten Mausereignissen bis zur Maske.
@MainActor
final class LassoModeTests: XCTestCase {

    private final class Protokoll: CanvasInteractionDelegate {
        var lassos: [(id: UUID, daten: Data)] = []
        var aenderungen: [(id: UUID, transform: Transform2D)] = []

        func canvasView(_ canvasView: CanvasView, didSelectLayerWithID id: UUID?) {}
        func canvasViewDidBeginInteraction(_ canvasView: CanvasView) {}
        func canvasView(_ canvasView: CanvasView, didChangeLayerWithID id: UUID, to transform: Transform2D) {
            aenderungen.append((id, transform))
        }
        func canvasView(_ canvasView: CanvasView, didEndInteractionNamed actionName: String) {}
        func canvasView(_ canvasView: CanvasView, didReceiveDropFrom pasteboard: NSPasteboard) {}
        func canvasView(_ canvasView: CanvasView, didChangeCropOfLayerWithID id: UUID, to crop: Rect) {}
        func canvasView(_ canvasView: CanvasView, didPaintMaskForLayerWithID id: UUID, pngData: Data) {}
        func canvasView(_ canvasView: CanvasView, didFillLassoForLayerWithID id: UUID, pngData: Data) {
            lassos.append((id, pngData))
        }
    }

    private var fenster: NSWindow!
    private var canvas: CanvasView!
    private var protokoll: Protokoll!
    private var bildID: UUID!
    private var resources: DocumentResources!

    override func setUpWithError() throws {
        let (resources, bild) = try Self.bildressourcen()
        self.resources = resources
        bildID = bild.id
        canvas = CanvasView(
            document: AssemblageModel.Document(
                canvas: CanvasSize(width: 200, height: 200), layers: [bild]
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

    private static func bildressourcen() throws -> (DocumentResources, Layer) {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let png = try XCTUnwrap(
            NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
                .representation(using: .png, properties: [:])
        )
        let resources = DocumentResources()
        let referenz = resources.addOriginal(png, fileExtension: "png")
        return (resources, Layer(
            name: "Foto",
            transform: Transform2D(x: 100, y: 100),
            content: .image(ImageLayerContent(originalFileReference: referenz))
        ))
    }

    private func ereignis(_ typ: NSEvent.EventType, x: Double, y: Double) throws -> NSEvent {
        let inView = NSPoint(x: x, y: Double(canvas.bounds.height) - y)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: typ, location: canvas.convert(inView, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: fenster.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    private func zieheRechteck() throws {
        canvas.mouseDown(with: try ereignis(.leftMouseDown, x: 40, y: 40))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, x: 160, y: 40))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, x: 160, y: 160))
        canvas.mouseUp(with: try ereignis(.leftMouseUp, x: 40, y: 160))
    }

    func testLassoFillsMaskInsteadOfMovingLayerAndUsesProtocolDispatch() throws {
        canvas.lassoLayerID = bildID
        try zieheRechteck()

        XCTAssertEqual(protokoll.lassos.count, 1)
        XCTAssertEqual(protokoll.lassos.first?.id, bildID)
        XCTAssertTrue(protokoll.aenderungen.isEmpty)

        let maske = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(protokoll.lassos.first?.daten)))
        XCTAssertLessThan(try XCTUnwrap(maske.colorAt(x: 100, y: 100)).whiteComponent, 0.5)
        XCTAssertGreaterThan(try XCTUnwrap(maske.colorAt(x: 10, y: 10)).whiteComponent, 0.5)
    }

    func testLassoPathIsVisibleOnlyWhileDragging() throws {
        canvas.lassoLayerID = bildID
        canvas.mouseDown(with: try ereignis(.leftMouseDown, x: 40, y: 40))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, x: 160, y: 40))
        XCTAssertNotNil(canvas.lassoPreviewLayerForTesting.path)

        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, x: 160, y: 160))
        canvas.mouseUp(with: try ereignis(.leftMouseUp, x: 40, y: 160))
        XCTAssertNil(canvas.lassoPreviewLayerForTesting.path)
    }

    func testLassoNeedsAtLeastThreeSeparatedPoints() throws {
        canvas.lassoLayerID = bildID
        canvas.mouseDown(with: try ereignis(.leftMouseDown, x: 100, y: 100))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, x: 101, y: 100))
        canvas.mouseUp(with: try ereignis(.leftMouseUp, x: 101, y: 101))
        XCTAssertTrue(protokoll.lassos.isEmpty)
    }

    func testRevealModeUsesTheCurrentLassoSetting() throws {
        canvas.lassoLayerID = bildID
        try zieheRechteck()
        let verdeckt = try XCTUnwrap(protokoll.lassos.last?.daten)
        let referenz = resources.addMask(verdeckt)
        var dokument = canvas.documentForTesting
        try dokument.updateLayer(id: bildID) {
            $0.mask = LayerMask(maskImageReference: referenz, source: .manualBrush)
        }
        canvas.update(to: dokument)

        protokoll.lassos.removeAll()
        canvas.lassoMode = .reveal
        canvas.mouseDown(with: try ereignis(.leftMouseDown, x: 70, y: 70))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, x: 130, y: 70))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, x: 130, y: 130))
        canvas.mouseUp(with: try ereignis(.leftMouseUp, x: 70, y: 130))

        let maske = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(protokoll.lassos.first?.daten)))
        XCTAssertGreaterThan(try XCTUnwrap(maske.colorAt(x: 100, y: 100)).whiteComponent, 0.5)
        XCTAssertLessThan(try XCTUnwrap(maske.colorAt(x: 50, y: 50)).whiteComponent, 0.5)
    }

    func testLassoModeIsExclusiveWithOtherModes() {
        canvas.brushLayerID = bildID
        canvas.lassoLayerID = bildID
        XCTAssertNil(canvas.brushLayerID)

        canvas.paintLayerID = bildID
        XCTAssertNil(canvas.lassoLayerID)

        canvas.lassoLayerID = bildID
        canvas.croppingLayerID = bildID
        XCTAssertNil(canvas.lassoLayerID)
    }

    func testMouseSequenceCommitsThroughDocumentModifyAndIsUndoable() throws {
        let (resources, bild) = try Self.bildressourcen()
        let document = AssemblageDocument()
        document.state.replaceContents(
            document: AssemblageModel.Document(
                canvas: CanvasSize(width: 200, height: 200), layers: [bild]
            ),
            resources: resources
        )
        document.state.selectedLayerID = bild.id
        let undo = UndoManager()
        document.undoManager = undo

        let controller = CanvasViewController(state: document.state)
        controller.loadViewIfNeeded()
        let scroll = try XCTUnwrap(controller.view as? NSScrollView)
        let controllerCanvas = try XCTUnwrap((scroll.documentView as? CanvasBoardView)?.canvasView)
        fenster.contentView = scroll
        controllerCanvas.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        canvas = controllerCanvas
        canvas.lassoLayerID = bild.id

        try zieheRechteck()

        XCTAssertNotNil(document.state.document.layer(withID: bild.id)?.mask)
        XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(undo.undoActionName, "Bild ausschneiden")
        undo.undo()
        XCTAssertNil(document.state.document.layer(withID: bild.id)?.mask)
    }
}
