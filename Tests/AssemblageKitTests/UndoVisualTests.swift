import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Widerrufen und Wiederholen müssen auf der Leinwand ankommen (aus missing.md).
///
/// Der Punkt dieses Tests ist die Betonung auf **sichtbar**. Dass das Modell
/// nach einem Undo wieder den alten Wert trägt, prüfen andere Tests längst.
/// Hier geht es um die Kette dahinter: Ändert sich `Document`, muss die
/// Beobachtung greifen und die Schicht auf dem Bildschirm nachziehen. Reisst
/// diese Kette, sieht man beim Arbeiten nichts passieren und drückt ⌘Z immer
/// weiter — der ärgerlichste denkbare Zustand.
@MainActor
final class UndoVisualTests: XCTestCase {

    private func aufbau() -> (AssemblageDocument, CanvasView, UUID) {
        let ebene = Layer(
            name: "Kreis",
            transform: Transform2D(x: 100, y: 100),
            content: .shape(ShapeLayerContent(
                kind: .ellipse, size: Size(width: 40, height: 40), fillColorHex: "#FF0000"))
        )
        let document = AssemblageDocument()
        document.undoManager = UndoManager()
        document.modify("Vorbereiten") {
            $0.canvas = CanvasSize(width: 400, height: 300)
            $0.layers = [ebene]
        }
        document.undoManager?.removeAllActions()

        let view = CanvasView(document: document.state.document, images: document.state.images)
        view.layoutSubtreeIfNeeded()
        view.layer?.layoutIfNeeded()
        return (document, view, ebene.id)
    }

    /// Die Schicht auf dem Bildschirm nach einem Modellwechsel.
    private func schicht(_ view: CanvasView, _ document: AssemblageDocument) throws -> CALayer {
        // Direkt statt über die Combine-Beobachtung: Die verschiebt bewusst
        // auf den nächsten Durchlauf und wäre im Test ein Wettlauf. Geprüft
        // wird hier, dass `update(to:)` die sichtbare Schicht nachzieht.
        view.update(to: document.state.document)
        view.layer?.layoutIfNeeded()
        let leinwand = try XCTUnwrap(view.layer?.sublayers?.first)
        return try XCTUnwrap(leinwand.sublayers?.first)
    }

    func testUndoMovesTheLayerBackOnScreen() throws {
        let (document, view, id) = aufbau()

        XCTAssertEqual(try schicht(view, document).position, CGPoint(x: 100, y: 100))

        document.modify("Verschieben") { dokument in
            try? dokument.updateLayer(id: id) { $0.transform.x = 250 }
        }
        XCTAssertEqual(try schicht(view, document).position, CGPoint(x: 250, y: 100))

        document.undoManager?.undo()
        XCTAssertEqual(try schicht(view, document).position, CGPoint(x: 100, y: 100),
                       "nach dem Widerrufen müsste die Schicht wieder links liegen")

        document.undoManager?.redo()
        XCTAssertEqual(try schicht(view, document).position, CGPoint(x: 250, y: 100),
                       "nach dem Wiederholen müsste sie wieder rechts liegen")
    }

    /// Auch ein Wechsel des Inhalts — nicht nur der Lage — muss zurückkommen.
    /// Genau hier lag der frühere Fehler, dass Textänderungen auf der Leinwand
    /// nicht ankamen.
    func testUndoRestoresContentNotJustLayout() throws {
        let ebene = Layer(
            name: "Titel",
            transform: Transform2D(x: 100, y: 100),
            content: .text(TextLayerContent(string: "Vorher", fontSize: 24))
        )
        let document = AssemblageDocument()
        document.undoManager = UndoManager()
        document.modify("Vorbereiten") {
            $0.canvas = CanvasSize(width: 400, height: 300)
            $0.layers = [ebene]
        }
        document.undoManager?.removeAllActions()

        let view = CanvasView(document: document.state.document, images: document.state.images)
        view.layoutSubtreeIfNeeded()
        view.layer?.layoutIfNeeded()

        document.modify("Text ändern") { dokument in
            try? dokument.updateLayer(id: ebene.id) { schicht in
                schicht.content = .text(TextLayerContent(string: "Nachher", fontSize: 24))
            }
        }
        let geaendert = try XCTUnwrap(try schicht(view, document) as? CATextLayer)
        XCTAssertEqual((geaendert.string as? NSAttributedString)?.string, "Nachher")

        document.undoManager?.undo()
        let zurueck = try XCTUnwrap(try schicht(view, document) as? CATextLayer)
        XCTAssertEqual((zurueck.string as? NSAttributedString)?.string, "Vorher",
                       "nach dem Widerrufen müsste wieder der alte Text stehen")
    }

    /// Eine gelöschte Ebene muss auch als Schicht verschwinden und nach dem
    /// Widerrufen wieder auftauchen.
    func testUndoOfDeletionBringsTheLayerBack() throws {
        let (document, view, id) = aufbau()

        document.modify("Löschen") { $0.layers.removeAll { $0.id == id } }
        let leinwandLeer = try XCTUnwrap({ () -> CALayer? in
            view.update(to: document.state.document)
            view.layer?.layoutIfNeeded()
            return view.layer?.sublayers?.first
        }())
        XCTAssertTrue(leinwandLeer.sublayers?.isEmpty ?? true, "die Schicht müsste weg sein")

        document.undoManager?.undo()
        XCTAssertNotNil(try schicht(view, document), "nach dem Widerrufen müsste sie wieder da sein")
    }

    // MARK: - Tastenkürzel

    /// ⌘Y wiederholt. Im Menü steht ⇧⌘Z; ⌘Y kommt über den Ansichtsbaum.
    func testCommandYRedoes() throws {
        let (document, view, id) = aufbau()

        document.modify("Verschieben") { dokument in
            try? dokument.updateLayer(id: id) { $0.transform.x = 250 }
        }
        document.undoManager?.undo()
        XCTAssertEqual(document.state.document.layers[0].transform.x, 100)

        let fenster = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        // So kommt der Canvas an denselben Undo-Manager wie im laufenden
        // Programm: über die Responder-Kette des Fensters.
        let delegat = UndoLieferant(undoManager: document.undoManager)
        fenster.delegate = delegat
        fenster.contentView = view

        let ereignis = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: fenster.windowNumber, context: nil,
            characters: "y", charactersIgnoringModifiers: "y", isARepeat: false, keyCode: 16
        ))

        XCTAssertTrue(view.performKeyEquivalent(with: ereignis), "⌘Y müsste greifen")
        XCTAssertEqual(document.state.document.layers[0].transform.x, 250)
    }

    /// Ohne etwas zu wiederholen darf ⌘Y die Taste nicht schlucken — sonst
    /// käme sie nie bei einem anderen Empfänger an.
    func testCommandYPassesThroughWithNothingToRedo() throws {
        let (document, view, _) = aufbau()
        let fenster = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        let delegat = UndoLieferant(undoManager: document.undoManager)
        fenster.delegate = delegat
        fenster.contentView = view

        let ereignis = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil,
            characters: "y", charactersIgnoringModifiers: "y", isARepeat: false, keyCode: 16
        ))
        XCTAssertFalse(view.performKeyEquivalent(with: ereignis))
    }
}

/// Liefert dem Ansichtsbaum im Test denselben Undo-Manager, den das Dokument
/// im laufenden Programm über die Responder-Kette bereitstellt.
private final class UndoLieferant: NSObject, NSWindowDelegate {
    let undoManager: UndoManager?
    init(undoManager: UndoManager?) { self.undoManager = undoManager }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undoManager }
}
