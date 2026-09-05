import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Bedienung des Verziehen-Modus mit echten AppKit-Mausereignissen.
@MainActor
final class DistortModeTests: XCTestCase {

    private final class Protokoll: CanvasInteractionDelegate {
        var verzerrungen: [(UUID, QuadDistortion?)] = []
        var transformationen: [Transform2D] = []
        var begonnen = 0
        var beendet: [String] = []
        func canvasView(_ canvasView: CanvasView, didSelectLayerWithID id: UUID?) {}
        func canvasViewDidBeginInteraction(_ canvasView: CanvasView) { begonnen += 1 }
        func canvasView(_ canvasView: CanvasView, didChangeLayerWithID id: UUID, to transform: Transform2D) { transformationen.append(transform) }
        func canvasView(_ canvasView: CanvasView, didChangeDistortionOfLayerWithID id: UUID, to distortion: QuadDistortion?) { verzerrungen.append((id, distortion)) }
        func canvasView(_ canvasView: CanvasView, didEndInteractionNamed actionName: String) { beendet.append(actionName) }
        func canvasView(_ canvasView: CanvasView, didReceiveDropFrom pasteboard: NSPasteboard) {}
        func canvasView(_ canvasView: CanvasView, didChangeCropOfLayerWithID id: UUID, to crop: Rect) {}
        func canvasView(_ canvasView: CanvasView, didPaintMaskForLayerWithID id: UUID, pngData: Data) {}
    }

    private var window: NSWindow!
    private var canvas: CanvasView!
    private var log: Protokoll!
    private var layer: Layer!

    override func setUp() {
        layer = Layer(
            name: "Form", transform: Transform2D(x: 200, y: 200),
            content: .shape(ShapeLayerContent(kind: .rectangle, size: Size(width: 100, height: 100)))
        )
        canvas = CanvasView(
            document: AssemblageModel.Document(canvas: CanvasSize(width: 400, height: 400), layers: [layer]),
            images: ImageStore(resources: DocumentResources())
        )
        canvas.selectedLayerID = layer.id
        canvas.distortingLayerID = layer.id
        log = Protokoll()
        canvas.interactionDelegate = log
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(canvas)
        canvas.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    }

    private func event(_ type: NSEvent.EventType, x: Double, y: Double, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let point = NSPoint(x: x, y: Double(canvas.bounds.height) - y)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: canvas.convert(point, to: nil), modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    func testDraggingCornerChangesOnlyThatCorner() throws {
        canvas.mouseDown(with: try event(.leftMouseDown, x: 150, y: 150))
        canvas.mouseDragged(with: try event(.leftMouseDragged, x: 170, y: 165))
        canvas.mouseUp(with: try event(.leftMouseUp, x: 170, y: 165))

        let distortion = try XCTUnwrap(log.verzerrungen.last?.1)
        XCTAssertEqual(distortion.topLeft, Point(x: 20, y: 15))
        XCTAssertEqual(distortion.topRight, .zero)
        XCTAssertEqual(distortion.bottomRight, .zero)
        XCTAssertEqual(distortion.bottomLeft, .zero)
        XCTAssertEqual(distortion.topMid, .zero)
        XCTAssertEqual(distortion.rightMid, .zero)
        XCTAssertEqual(distortion.bottomMid, .zero)
        XCTAssertEqual(distortion.leftMid, .zero)
        XCTAssertFalse(distortion.hasCurvedEdges)
        XCTAssertEqual(log.beendet, ["Ebene verziehen"])
    }

    func testAllEightDistortHandlesCanBeHit() throws {
        let positions: [(DistortHandle, Point)] = [
            (.topLeft, Point(x: 150, y: 150)),
            (.topRight, Point(x: 250, y: 150)),
            (.bottomRight, Point(x: 250, y: 250)),
            (.bottomLeft, Point(x: 150, y: 250)),
            (.topMid, Point(x: 200, y: 150)),
            (.rightMid, Point(x: 250, y: 200)),
            (.bottomMid, Point(x: 200, y: 250)),
            (.leftMid, Point(x: 150, y: 200))
        ]

        for (handle, position) in positions {
            log.verzerrungen.removeAll()
            canvas.mouseDown(with: try event(.leftMouseDown, x: position.x, y: position.y))
            canvas.mouseDragged(with: try event(.leftMouseDragged, x: position.x + 12, y: position.y + 7))
            canvas.mouseUp(with: try event(.leftMouseUp, x: position.x + 12, y: position.y + 7))

            let distortion = try XCTUnwrap(log.verzerrungen.last?.1, "Griff \(handle) muss getroffen werden")
            for candidate in DistortHandle.allCases {
                XCTAssertEqual(
                    distortion.offset(at: candidate),
                    candidate == handle ? Point(x: 12, y: 7) : .zero,
                    "Ziehen an \(handle) darf \(candidate) nicht fälschlich ändern"
                )
            }
        }
    }

    func testDraggingEdgeMidpointCreatesCurvedDistortionAndChangesOnlyThatMidpoint() throws {
        canvas.mouseDown(with: try event(.leftMouseDown, x: 200, y: 150))
        canvas.mouseDragged(with: try event(.leftMouseDragged, x: 208, y: 132))
        canvas.mouseUp(with: try event(.leftMouseUp, x: 208, y: 132))

        let distortion = try XCTUnwrap(log.verzerrungen.last?.1)
        XCTAssertTrue(distortion.hasCurvedEdges)
        XCTAssertEqual(distortion.topMid, Point(x: 8, y: -18))
        for handle in DistortHandle.allCases where handle != .topMid {
            XCTAssertEqual(distortion.offset(at: handle), .zero, "nur die obere Kantenmitte darf sich ändern")
        }
    }

    func testOptionDraggingCornerMovesAllCorners() throws {
        canvas.mouseDown(with: try event(.leftMouseDown, x: 150, y: 150, modifiers: .option))
        canvas.mouseDragged(with: try event(.leftMouseDragged, x: 170, y: 165, modifiers: .option))
        canvas.mouseUp(with: try event(.leftMouseUp, x: 170, y: 165, modifiers: .option))

        let distortion = try XCTUnwrap(log.verzerrungen.last?.1)
        for corner in [distortion.topLeft, distortion.topRight, distortion.bottomRight, distortion.bottomLeft] {
            XCTAssertEqual(corner, Point(x: 20, y: 15))
        }
        for midpoint in [distortion.topMid, distortion.rightMid, distortion.bottomMid, distortion.leftMid] {
            XCTAssertEqual(midpoint, Point(x: 20, y: 15))
        }
    }

    func testDistortModeDrawsFourSquareCornersAndFourRoundMidpoints() throws {
        let path = try XCTUnwrap(canvas.handleLayerForTesting.path)
        var closedSubpaths = 0
        var curves = 0
        path.applyWithBlock { element in
            switch element.pointee.type {
            case .closeSubpath: closedSubpaths += 1
            case .addCurveToPoint: curves += 1
            default: break
            }
        }

        XCTAssertEqual(closedSubpaths, 8, "vier Eck- und vier Kantenmittengriffe")
        XCTAssertGreaterThan(curves, 0, "die Kantenmittengriffe müssen rund statt quadratisch sein")
    }

    func testOneDragOpensAndClosesOneUndoInteraction() throws {
        canvas.mouseDown(with: try event(.leftMouseDown, x: 150, y: 150))
        canvas.mouseDragged(with: try event(.leftMouseDragged, x: 160, y: 155))
        canvas.mouseDragged(with: try event(.leftMouseDragged, x: 170, y: 160))
        canvas.mouseUp(with: try event(.leftMouseUp, x: 170, y: 160))

        XCTAssertEqual(log.begonnen, 1)
        XCTAssertEqual(log.beendet, ["Ebene verziehen"])
    }

    func testEscapeLeavesDistortMode() {
        canvas.cancelOperation(nil)
        XCTAssertNil(canvas.distortingLayerID)
    }

    func testModesExcludeEachOther() {
        canvas.croppingLayerID = layer.id
        XCTAssertNil(canvas.distortingLayerID)
        canvas.distortingLayerID = layer.id
        XCTAssertNil(canvas.croppingLayerID)
        XCTAssertNil(canvas.brushLayerID)
    }

    func testOutsideDistortModeSameDragMovesLayerAsBefore() throws {
        canvas.distortingLayerID = nil
        canvas.mouseDown(with: try event(.leftMouseDown, x: 200, y: 200))
        canvas.mouseDragged(with: try event(.leftMouseDragged, x: 220, y: 215))
        canvas.mouseUp(with: try event(.leftMouseUp, x: 220, y: 215))

        XCTAssertTrue(log.verzerrungen.isEmpty)
        XCTAssertEqual(log.transformationen.last?.x, 220)
        XCTAssertEqual(log.transformationen.last?.y, 215)
        XCTAssertEqual(log.beendet, ["Ebene verschieben"])
    }

    func testDistortToolIsAvailableForEveryLayerKind() {
        let image = Layer(name: "Bild", content: .image(ImageLayerContent(originalFileReference: "x")))
        let text = Layer(name: "Text", content: .text(TextLayerContent(string: "x")))
        XCTAssertTrue(ToolSelection.isAvailable(.distort, forSelected: image))
        XCTAssertTrue(ToolSelection.isAvailable(.distort, forSelected: text))
        XCTAssertTrue(ToolSelection.isAvailable(.distort, forSelected: layer))
        XCTAssertFalse(ToolSelection.isAvailable(.distort, forSelected: nil))
    }

    func testDraggingEdgeMidpointIsOneUndoStepAndUndoRestoresDistortion() throws {
        let document = AssemblageDocument()
        let undo = UndoManager()
        document.undoManager = undo
        document.modify("Ebene anlegen") { _ = try? $0.addLayer(layer) }
        undo.removeAllActions()

        final class UndoDelegate: CanvasInteractionDelegate {
            let document: AssemblageDocument
            init(_ document: AssemblageDocument) { self.document = document }
            func canvasView(_ canvasView: CanvasView, didSelectLayerWithID id: UUID?) {}
            func canvasViewDidBeginInteraction(_ canvasView: CanvasView) { document.beginInteraction() }
            func canvasView(_ canvasView: CanvasView, didChangeLayerWithID id: UUID, to transform: Transform2D) {}
            func canvasView(_ canvasView: CanvasView, didChangeDistortionOfLayerWithID id: UUID, to distortion: QuadDistortion?) {
                document.modify("Ebene verziehen") { try? $0.updateLayer(id: id) { $0.distortion = distortion } }
            }
            func canvasView(_ canvasView: CanvasView, didEndInteractionNamed actionName: String) { document.endInteraction(actionName: actionName) }
            func canvasView(_ canvasView: CanvasView, didReceiveDropFrom pasteboard: NSPasteboard) {}
            func canvasView(_ canvasView: CanvasView, didChangeCropOfLayerWithID id: UUID, to crop: Rect) {}
            func canvasView(_ canvasView: CanvasView, didPaintMaskForLayerWithID id: UUID, pngData: Data) {}
        }
        let delegate = UndoDelegate(document)
        canvas.interactionDelegate = delegate

        canvas.mouseDown(with: try event(.leftMouseDown, x: 250, y: 200))
        canvas.mouseDragged(with: try event(.leftMouseDragged, x: 265, y: 210))
        canvas.mouseDragged(with: try event(.leftMouseDragged, x: 275, y: 215))
        canvas.mouseUp(with: try event(.leftMouseUp, x: 275, y: 215))

        XCTAssertEqual(undo.undoActionName, "Ebene verziehen")
        let distortion = try XCTUnwrap(document.state.document.layer(withID: layer.id)?.distortion)
        XCTAssertEqual(distortion.rightMid, Point(x: 25, y: 15))
        XCTAssertTrue(distortion.hasCurvedEdges)
        undo.undo()
        XCTAssertNil(document.state.document.layer(withID: layer.id)?.distortion)
        XCTAssertFalse(undo.canUndo, "der ganze Zug muss genau ein Schritt sein")
    }

    func testResetSetsNilAndUndoRestoresPreviousDistortion() throws {
        let document = AssemblageDocument()
        let undo = UndoManager()
        document.undoManager = undo
        document.modify("Ebene anlegen") { _ = try? $0.addLayer(layer) }
        document.state.selectedLayerID = layer.id
        document.modify("Vorbereiten") {
            try? $0.updateLayer(id: self.layer.id) {
                $0.distortion = QuadDistortion(topMid: Point(x: 10, y: 5))
            }
        }
        undo.removeAllActions()

        DistortionCommands.resetSelected(in: document.state)

        XCTAssertNil(document.state.selectedLayer?.distortion)
        XCTAssertEqual(undo.undoActionName, "Verzerrung zurücksetzen")
        undo.undo()
        XCTAssertEqual(document.state.selectedLayer?.distortion?.topMid, Point(x: 10, y: 5))
        XCTAssertTrue(document.state.selectedLayer?.distortion?.hasCurvedEdges == true)
    }
}
