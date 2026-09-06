import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

@MainActor
final class UndoTimelineTests: XCTestCase {

    private func timeline() -> UndoTimelineView {
        let timeline = UndoTimelineView(frame: NSRect(x: 0, y: 0, width: 140, height: 28))
        timeline.setDepths(undo: 4, redo: 4)
        return timeline
    }

    func testHorizontalPositionMapsToHistoryDepth() {
        let timeline = timeline()

        XCTAssertEqual(timeline.depth(atX: 1), 0)
        XCTAssertEqual(timeline.depth(atX: 70), 4)
        XCTAssertEqual(timeline.depth(atX: 139), 8)
    }

    func testPointerReportsOnlyActualGridChanges() {
        let timeline = timeline()
        var reportedDepths: [Int] = []
        timeline.onSelectDepth = { reportedDepths.append($0) }

        for x in [1, 2, 9, 10, 11, 26, 27] as [CGFloat] {
            timeline.handlePointer(atX: x)
        }

        XCTAssertEqual(reportedDepths, [0, 1, 2])
    }

    /// Der Controller muss das Wiederholen selbst empfangen; über ein
    /// nil-Ziel hing es bisher davon ab, welcher Responder gerade aktiv war.
    func testDocumentWindowControllerRedoRestoresTheUndoneState() throws {
        let document = AssemblageDocument()
        document.undoManager = UndoManager()
        let layer = Layer(
            name: "Form",
            transform: Transform2D(x: 100, y: 100),
            content: .shape(ShapeLayerContent(
                kind: .rectangle,
                size: Size(width: 20, height: 20)
            ))
        )
        document.modify("Vorbereiten") { $0.layers = [layer] }
        document.undoManager?.removeAllActions()

        let controller = DocumentWindowController()
        document.addWindowController(controller)
        let undoManager = try XCTUnwrap(document.undoManager)
        undoManager.groupsByEvent = false

        undoManager.beginUndoGrouping()
        document.modify("Erste Änderung") {
            try? $0.updateLayer(id: layer.id) { $0.transform.x = 150 }
        }
        undoManager.endUndoGrouping()

        undoManager.beginUndoGrouping()
        document.modify("Zweite Änderung") {
            try? $0.updateLayer(id: layer.id) { $0.transform.x = 200 }
        }
        undoManager.endUndoGrouping()

        controller.undo(nil)
        XCTAssertEqual(document.state.document.layer(withID: layer.id)?.transform.x, 150)

        controller.redo(nil)
        XCTAssertEqual(document.state.document.layer(withID: layer.id)?.transform.x, 200)
    }

    /// Die Grundlage dafür, dass `ToolbarController.jumpInTimeline(to:)` keinen
    /// eigenen Zählerstand mitführt: `DocumentState` folgt den Undo-Benach-
    /// richtigungen synchron und ist deshalb auch mitten in einer engen
    /// Sprungschleife — ohne Runloop-Durchlauf dazwischen — nach jedem
    /// einzelnen Schritt aktuell. Fiele das weg, liefe ein Timeline-Drag auf
    /// einem veralteten Ausgangspunkt und spränge zu weit.
    func testHistoryDepthStaysExactAcrossATightUndoRedoLoop() throws {
        let document = AssemblageDocument()
        document.undoManager = UndoManager()
        let layer = Layer(
            name: "Form",
            transform: Transform2D(x: 100, y: 100),
            content: .shape(ShapeLayerContent(
                kind: .rectangle,
                size: Size(width: 20, height: 20)
            ))
        )
        document.modify("Vorbereiten") { $0.layers = [layer] }
        document.undoManager?.removeAllActions()

        let controller = DocumentWindowController()
        document.addWindowController(controller)
        let undoManager = try XCTUnwrap(document.undoManager)
        undoManager.groupsByEvent = false

        for x in [140.0, 180.0, 220.0] {
            undoManager.beginUndoGrouping()
            document.modify("Änderung") {
                try? $0.updateLayer(id: layer.id) { $0.transform.x = x }
            }
            undoManager.endUndoGrouping()
        }
        XCTAssertEqual(document.state.undoDepth, 3)

        // Kein Runloop-Durchlauf zwischen den Schritten — genau wie beim Drag.
        for erwartet in [2, 1, 0] {
            controller.undo(nil)
            XCTAssertEqual(document.state.undoDepth, erwartet)
            XCTAssertEqual(document.state.redoDepth, 3 - erwartet)
        }
        for erwartet in [1, 2, 3] {
            controller.redo(nil)
            XCTAssertEqual(document.state.undoDepth, erwartet)
            XCTAssertEqual(document.state.redoDepth, 3 - erwartet)
        }
    }
}
