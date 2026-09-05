import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// „Malebene einfügen" (aus Anpassungen.md: „sollte auf einer eigenen Ebene
/// sein").
@MainActor
final class PaintLayerCommandTests: XCTestCase {

    private func aufbau(width: Double = 400, height: Double = 300) -> AssemblageDocument {
        let document = AssemblageDocument()
        document.undoManager = UndoManager()
        document.modify("Vorbereiten") { $0.canvas = CanvasSize(width: width, height: height) }
        document.undoManager?.removeAllActions()
        return document
    }

    func testInsertsATransparentImageLayerCoveringTheCanvas() throws {
        let document = aufbau()

        XCTAssertTrue(PaintLayerCommand.insertBlankLayer(into: document.state))

        let ebene = try XCTUnwrap(document.state.document.layers.first)
        guard case .image(let inhalt) = ebene.content else {
            return XCTFail("es müsste eine Bildebene entstanden sein")
        }
        XCTAssertEqual(document.state.selectedLayerID, ebene.id, "die neue Ebene müsste ausgewählt sein")

        let daten = try XCTUnwrap(document.state.resources.data(for: inhalt.originalFileReference))
        let bild = try XCTUnwrap(NSBitmapImageRep(data: daten))
        XCTAssertEqual(bild.pixelsWide, 400)
        XCTAssertEqual(bild.pixelsHigh, 300)

        // Vollständig durchsichtig — sonst wäre es keine leere Fläche zum
        // Anfangen, sondern eine gefüllte.
        let mitte = try XCTUnwrap(bild.colorAt(x: 200, y: 150))
        XCTAssertEqual(mitte.alphaComponent, 0, accuracy: 0.01)
    }

    /// Das Einfügen ist ein Undo-Schritt wie jedes andere Einfügen.
    func testInsertionIsUndoable() throws {
        let document = aufbau()
        PaintLayerCommand.insertBlankLayer(into: document.state)
        XCTAssertEqual(document.state.document.layers.count, 1)

        document.undoManager?.undo()
        XCTAssertTrue(document.state.document.layers.isEmpty)
    }

    /// Eine Leinwand ohne sinnvolle Grösse darf keine Datei anlegen und
    /// keinen Absturz auslösen.
    func testDoesNothingForAnEmptyCanvas() {
        let document = aufbau(width: 0, height: 0)
        XCTAssertFalse(PaintLayerCommand.insertBlankLayer(into: document.state))
        XCTAssertTrue(document.state.document.layers.isEmpty)
    }
}
