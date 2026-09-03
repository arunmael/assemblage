import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Ein Ziehen auf dem Canvas erzeugt Dutzende Zwischenstände — im Undo-Stack
/// darf davon genau **einer** landen.
///
/// Sonst muss man nach dem Verschieben einer Ebene vierzigmal ⌘Z drücken, bis
/// sichtbar etwas passiert. Das ist der Grund, warum Änderungen während einer
/// Interaktion anders behandelt werden als einzelne Reglerzüge.
@MainActor
final class InteractionUndoTests: XCTestCase {

    private func dokumentMitEinerEbene() -> (AssemblageDocument, UUID, UndoManager) {
        let document = AssemblageDocument()
        let undoManager = UndoManager()
        document.undoManager = undoManager
        let layer = Layer(
            name: "Foto",
            transform: Transform2D(x: 100, y: 100),
            content: .shape(ShapeLayerContent(kind: .rectangle, size: Size(width: 50, height: 50)))
        )
        document.modify("Ebene anlegen") { try? $0.addLayer(layer) }
        undoManager.removeAllActions()
        return (document, layer.id, undoManager)
    }

    /// Verschiebt die Ebene in vielen kleinen Schritten, wie es die Maus tut.
    private func ziehe(_ document: AssemblageDocument, _ id: UUID, schritte: Int) {
        document.beginInteraction()
        for schritt in 1...schritte {
            document.modify("Ebene verschieben") {
                try? $0.updateLayer(id: id) { $0.transform.x = 100 + Double(schritt) }
            }
        }
        document.endInteraction(actionName: "Ebene verschieben")
    }

    func testWholeDragIsASingleUndoStep() {
        let (document, id, undoManager) = dokumentMitEinerEbene()

        ziehe(document, id, schritte: 40)
        XCTAssertEqual(document.state.document.layer(withID: id)?.transform.x, 140)

        undoManager.undo()

        XCTAssertEqual(
            document.state.document.layer(withID: id)?.transform.x, 100,
            "ein einziges Widerrufen muss den ganzen Zug zurücknehmen"
        )
        XCTAssertFalse(undoManager.canUndo, "und danach darf nichts mehr übrig sein")
    }

    func testRedoRestoresTheWholeDrag() {
        let (document, id, undoManager) = dokumentMitEinerEbene()

        ziehe(document, id, schritte: 10)
        undoManager.undo()
        undoManager.redo()

        XCTAssertEqual(document.state.document.layer(withID: id)?.transform.x, 110)
    }

    /// Ein Zug, der dort endet, wo er begann (versehentliches Anklicken),
    /// darf keinen Undo-Schritt hinterlassen.
    func testDragThatChangesNothingLeavesNoUndoStep() {
        let (document, id, undoManager) = dokumentMitEinerEbene()

        document.beginInteraction()
        document.modify("Ebene verschieben") {
            try? $0.updateLayer(id: id) { $0.transform.x = 180 }
        }
        document.modify("Ebene verschieben") {
            try? $0.updateLayer(id: id) { $0.transform.x = 100 }
        }
        document.endInteraction(actionName: "Ebene verschieben")

        XCTAssertFalse(undoManager.canUndo)
    }

    /// Ausserhalb einer Interaktion registriert jede Änderung für sich —
    /// die Gruppierung darf nicht auf alles abfärben.
    ///
    /// Geprüft wird bewusst die Registrierung, nicht die Anzahl der
    /// Undo-Schritte: `NSUndoManager` fasst von sich aus alles zusammen, was
    /// im selben Ereignis anfällt (`groupsByEvent`). Im Betrieb sind zwei
    /// Nutzeraktionen zwei Ereignisse; in einem synchronen Test wäre das
    /// nicht nachstellbar, ohne AppKit statt unseres Codes zu testen.
    func testChangeOutsideAnInteractionIsUndoableOnItsOwn() {
        let (document, id, undoManager) = dokumentMitEinerEbene()

        document.modify("Umbenennen") { try? $0.updateLayer(id: id) { $0.name = "A" } }

        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(document.state.document.layer(withID: id)?.name, "Foto")
    }

    /// Der Gegenpol: Solange eine Interaktion läuft, darf **nichts** im
    /// Undo-Stack landen — erst der Abschluss setzt den einen Schritt.
    func testNothingIsRegisteredWhileAnInteractionIsRunning() {
        let (document, id, undoManager) = dokumentMitEinerEbene()

        document.beginInteraction()
        for schritt in 1...5 {
            document.modify("Ebene verschieben") {
                try? $0.updateLayer(id: id) { $0.transform.x = 100 + Double(schritt) }
            }
        }

        XCTAssertTrue(document.isInteracting)
        XCTAssertFalse(undoManager.canUndo, "während des Ziehens darf noch nichts registriert sein")

        document.endInteraction(actionName: "Ebene verschieben")

        XCTAssertFalse(document.isInteracting)
        XCTAssertTrue(undoManager.canUndo, "erst der Abschluss setzt den Schritt")
    }

    /// Wird `endInteraction` vergessen oder doppelt aufgerufen, darf das den
    /// Undo-Stack nicht durcheinanderbringen.
    func testEndingAnInteractionTwiceIsHarmless() {
        let (document, id, undoManager) = dokumentMitEinerEbene()

        ziehe(document, id, schritte: 5)
        document.endInteraction(actionName: "Ebene verschieben")

        undoManager.undo()
        XCTAssertEqual(document.state.document.layer(withID: id)?.transform.x, 100)
        XCTAssertFalse(undoManager.canUndo)
    }
}
