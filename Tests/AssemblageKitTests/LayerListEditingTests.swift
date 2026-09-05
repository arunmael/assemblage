import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

@MainActor
final class LayerListEditingTests: XCTestCase {

    private func ebene(_ name: String, sichtbar: Bool = true) -> Layer {
        Layer(
            name: name,
            isVisible: sichtbar,
            content: .shape(
                ShapeLayerContent(kind: .rectangle, size: Size(width: 40, height: 40))
            )
        )
    }

    private func dokument(
        mit ebenen: [Layer]
    ) -> (AssemblageDocument, LayerListEditing, UndoManager) {
        let document = AssemblageDocument()
        let undoManager = UndoManager()
        document.undoManager = undoManager
        document.modify("Test vorbereiten") { $0.layers = ebenen }
        undoManager.removeAllActions()
        return (document, LayerListEditing(state: document.state), undoManager)
    }

    func testSichtbarkeitLaesstSichAusUndWiederEinblendenUndWiderrufen() {
        let layer = ebene("Foto")
        let (document, editing, undoManager) = dokument(mit: [layer])

        editing.toggleVisibility(of: layer.id)

        XCTAssertEqual(document.state.document.layer(withID: layer.id)?.isVisible, false)
        XCTAssertEqual(undoManager.undoActionName, "Ebene ausblenden")
        undoManager.undo()
        XCTAssertEqual(document.state.document.layer(withID: layer.id)?.isVisible, true)
        XCTAssertFalse(undoManager.canUndo, "Ausblenden muss genau ein Undo-Schritt sein")

        editing.toggleVisibility(of: layer.id)
        undoManager.removeAllActions()
        editing.toggleVisibility(of: layer.id)

        XCTAssertEqual(document.state.document.layer(withID: layer.id)?.isVisible, true)
        XCTAssertEqual(undoManager.undoActionName, "Ebene einblenden")
        undoManager.undo()
        XCTAssertEqual(document.state.document.layer(withID: layer.id)?.isVisible, false)
        XCTAssertFalse(undoManager.canUndo, "Einblenden muss genau ein Undo-Schritt sein")
    }

    func testUmbenennenIstWiderrufbarUndLeererNameWirdAbgelehnt() {
        let layer = ebene("Foto")
        let (document, editing, undoManager) = dokument(mit: [layer])

        editing.rename(layer.id, to: "  Ferien  ")

        XCTAssertEqual(document.state.document.layer(withID: layer.id)?.name, "Ferien")
        XCTAssertEqual(undoManager.undoActionName, "Ebene umbenennen")
        undoManager.undo()
        XCTAssertEqual(document.state.document.layer(withID: layer.id)?.name, "Foto")
        XCTAssertFalse(undoManager.canUndo)

        editing.rename(layer.id, to: " \n\t ")

        XCTAssertEqual(document.state.document.layer(withID: layer.id)?.name, "Foto")
        XCTAssertFalse(undoManager.canUndo, "ein leerer Name darf keine Änderung registrieren")
    }

    func testLoeschenUndWiderrufenBewahrtDiePosition() {
        let unten = ebene("Unten")
        let mitte = ebene("Mitte")
        let oben = ebene("Oben")
        let (document, editing, undoManager) = dokument(mit: [unten, mitte, oben])

        editing.delete(mitte.id)

        XCTAssertEqual(document.state.document.layers.map(\.name), ["Unten", "Oben"])
        XCTAssertEqual(undoManager.undoActionName, "Ebene löschen")
        undoManager.undo()
        XCTAssertEqual(document.state.document.layers.map(\.name), ["Unten", "Mitte", "Oben"])
        XCTAssertFalse(undoManager.canUndo, "Löschen muss genau ein Undo-Schritt sein")
    }

    func testLoeschenDerAuswahlLaesstKeineVerwaisteAuswahlZurueck() {
        let layer = ebene("Ausgewählt")
        let (document, editing, _) = dokument(mit: [layer])
        document.state.selectedLayerID = layer.id

        editing.delete(layer.id)

        XCTAssertNil(document.state.selectedLayerID)
    }

    func testListenreihenfolgeIstUmgekehrtZurModellreihenfolge() {
        let (unten, mitte, oben) = (ebene("Unten"), ebene("Mitte"), ebene("Oben"))
        let (_, editing, _) = dokument(mit: [unten, mitte, oben])

        XCTAssertEqual(editing.layersInListOrder.map(\.name), ["Oben", "Mitte", "Unten"])
    }

    func testVerschiebenVonGanzObenNachGanzUntenRechnetInModellindizesUm() {
        let ebenen = [ebene("A"), ebene("B"), ebene("C"), ebene("D")]
        let (document, editing, _) = dokument(mit: ebenen)

        editing.move(fromListOffsets: IndexSet(integer: 0), toListOffset: 4)

        XCTAssertEqual(document.state.document.layers.map(\.name), ["D", "A", "B", "C"])
        XCTAssertEqual(editing.layersInListOrder.map(\.name), ["C", "B", "A", "D"])
    }

    func testVerschiebenVonGanzUntenNachGanzObenRechnetInModellindizesUm() {
        let ebenen = [ebene("A"), ebene("B"), ebene("C"), ebene("D")]
        let (document, editing, _) = dokument(mit: ebenen)

        editing.move(fromListOffsets: IndexSet(integer: 3), toListOffset: 0)

        XCTAssertEqual(document.state.document.layers.map(\.name), ["B", "C", "D", "A"])
        XCTAssertEqual(editing.layersInListOrder.map(\.name), ["A", "D", "C", "B"])
    }

    func testVerschiebenInDerMitteRechnetRichtungUndZielKorrektUm() {
        let ebenen = [ebene("A"), ebene("B"), ebene("C"), ebene("D"), ebene("E")]
        let (document, editing, _) = dokument(mit: ebenen)

        // Liste vorher: E, D, C, B, A. D wird hinter B abgelegt.
        editing.move(fromListOffsets: IndexSet(integer: 1), toListOffset: 4)

        XCTAssertEqual(document.state.document.layers.map(\.name), ["A", "D", "B", "C", "E"])
        XCTAssertEqual(editing.layersInListOrder.map(\.name), ["E", "C", "B", "D", "A"])
    }

    func testVerschiebenIstEinUndoSchrittUndVollstaendigWiderrufbar() {
        let ebenen = [ebene("A"), ebene("B"), ebene("C"), ebene("D")]
        let (document, editing, undoManager) = dokument(mit: ebenen)

        editing.move(fromListOffsets: IndexSet(integer: 1), toListOffset: 4)

        XCTAssertEqual(undoManager.undoActionName, "Reihenfolge ändern")
        undoManager.undo()
        XCTAssertEqual(document.state.document.layers.map(\.name), ["A", "B", "C", "D"])
        XCTAssertFalse(undoManager.canUndo, "Umsortieren muss genau ein Undo-Schritt sein")
    }

    func testUnbekannteIDIstFuerAlleOperationenWirkungslos() {
        let layer = ebene("Foto")
        let (document, editing, undoManager) = dokument(mit: [layer])
        let vorher = document.state.document
        let unbekannt = UUID()

        editing.toggleVisibility(of: unbekannt)
        editing.rename(unbekannt, to: "Anders")
        editing.delete(unbekannt)

        XCTAssertEqual(document.state.document, vorher)
        XCTAssertFalse(undoManager.canUndo)
    }
}

// MARK: - Duplizieren (aus Anpassungen 2)

extension LayerListEditingTests {

    func testDuplicateInsertsACopyDirectlyAboveTheOriginal() {
        let unten = ebene("Unten")
        let original = ebene("Original")
        let oben = ebene("Oben")
        let (document, editing, _) = dokument(mit: [unten, original, oben])

        let neueID = try? XCTUnwrap(editing.duplicate(original.id))

        XCTAssertEqual(document.state.document.layers.count, 4)
        // Modellreihenfolge: unten, Original, Kopie, oben — die Kopie sitzt
        // direkt über dem Original.
        XCTAssertEqual(document.state.document.layers.map(\.name), ["Unten", "Original", "Original Kopie", "Oben"])
        XCTAssertEqual(document.state.selectedLayerID, neueID, "die Kopie müsste ausgewählt sein")
    }

    /// Ein Feld verändert, alle anderen bleiben — sonst wäre es kein Duplikat.
    func testDuplicatePreservesEveryFieldExceptIdentityAndPosition() {
        var original = ebene("Original")
        original.opacity = 0.42
        original.blendMode = .multiply
        original.isVisible = false
        original.transform = Transform2D(x: 50, y: 60, scaleX: 2, rotationDegrees: 30)
        let (document, editing, _) = dokument(mit: [original])

        editing.duplicate(original.id)
        let kopie = try? XCTUnwrap(document.state.document.layers.last)

        XCTAssertNotEqual(kopie?.id, original.id, "die Kopie braucht eine eigene Identität")
        XCTAssertEqual(kopie?.opacity, 0.42)
        XCTAssertEqual(kopie?.blendMode, .multiply)
        XCTAssertEqual(kopie?.isVisible, false)
        XCTAssertEqual(kopie?.transform.scaleX, 2)
        XCTAssertEqual(kopie?.transform.rotationDegrees, 30)
        // Nur die Position ist bewusst leicht versetzt.
        XCTAssertEqual(kopie?.transform.x, 60)
        XCTAssertEqual(kopie?.transform.y, 70)
    }

    func testDuplicateIsUndoable() {
        let original = ebene("Original")
        let (document, editing, undoManager) = dokument(mit: [original])

        editing.duplicate(original.id)
        XCTAssertEqual(document.state.document.layers.count, 2)

        undoManager.undo()
        XCTAssertEqual(document.state.document.layers.count, 1)
    }

    func testDuplicateOfAnUnknownLayerDoesNothing() {
        let (document, editing, _) = dokument(mit: [ebene("Einzige")])
        XCTAssertNil(editing.duplicate(UUID()))
        XCTAssertEqual(document.state.document.layers.count, 1)
    }
}
