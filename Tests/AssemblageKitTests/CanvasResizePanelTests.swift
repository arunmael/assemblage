import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Der AppKit-Sheet selbst ist nicht sinnvoll automatisierbar. Diese Tests
/// decken deshalb seine Eingabegrenze und die daraus folgende Änderung am
/// echten `AssemblageDocument` ab.
@MainActor
final class CanvasResizePanelTests: XCTestCase {

    func testValidateAcceptsPointAndCommaDecimalSeparators() {
        XCTAssertEqual(
            CanvasResizePanelLogic.validate(widthText: "640.5", heightText: "480.25"),
            CanvasSize(width: 640.5, height: 480.25)
        )
        XCTAssertEqual(
            CanvasResizePanelLogic.validate(widthText: "640,5", heightText: "480,25"),
            CanvasSize(width: 640.5, height: 480.25)
        )
    }

    func testValidateRejectsInvalidAndNonPositiveValues() {
        let invalidValues = ["", "keine Zahl", "0", "-1", "NaN", "inf", "-infinity"]

        for value in invalidValues {
            XCTAssertNil(
                CanvasResizePanelLogic.validate(widthText: value, heightText: "100"),
                "\(value) dürfte keine gültige Breite ergeben"
            )
            XCTAssertNil(
                CanvasResizePanelLogic.validate(widthText: "100", heightText: value),
                "\(value) dürfte keine gültige Höhe ergeben"
            )
        }
    }

    func testResizeChangesOnlyCanvasAndKeepsLayerTransformExactly() throws {
        let originalTransform = Transform2D(
            x: 123.5,
            y: 87.25,
            scaleX: 1.4,
            scaleY: 0.8,
            rotationDegrees: 17
        )
        let layer = Layer(
            name: "Unverändert",
            transform: originalTransform,
            content: .shape(ShapeLayerContent(
                kind: .rectangle,
                size: Size(width: 80, height: 60)
            ))
        )
        let document = AssemblageDocument()
        document.modify("Vorbereiten") {
            $0.canvas = CanvasSize(width: 400, height: 300)
            $0.layers = [layer]
        }
        let newSize = try XCTUnwrap(
            CanvasResizePanelLogic.validate(widthText: "900,5", heightText: "700.25")
        )

        document.modify("Leinwandgrösse ändern") { $0.canvas = newSize }

        XCTAssertEqual(document.state.document.canvas, newSize)
        XCTAssertEqual(document.state.document.layers.first?.transform, originalTransform)
    }

    func testResizeIsUndoable() {
        let document = AssemblageDocument()
        let undoManager = UndoManager()
        document.undoManager = undoManager
        let originalSize = document.state.document.canvas
        let newSize = CanvasSize(width: 2048, height: 1536)

        document.modify("Leinwandgrösse ändern") { $0.canvas = newSize }
        XCTAssertEqual(document.state.document.canvas, newSize)
        XCTAssertEqual(undoManager.undoActionName, "Leinwandgrösse ändern")

        undoManager.undo()

        XCTAssertEqual(document.state.document.canvas, originalSize)
    }
}
