import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Der Löschen-Knopf in der Fusszeile des Ebenen-Panels.
@MainActor
final class LayerDeleteButtonTests: XCTestCase {

    private func bühne() throws -> (AssemblageDocument, NSView, NSButton) {
        let document = AssemblageDocument()
        document.makeWindowControllers()
        let windowController = try XCTUnwrap(
            document.windowControllers.first as? DocumentWindowController
        )
        let wurzel = try XCTUnwrap(windowController.window?.contentView)
        wurzel.layoutSubtreeIfNeeded()

        let knöpfe = buttons(in: wurzel).filter { $0.toolTip == "Löschen" }
        let löschen = try XCTUnwrap(knöpfe.first, "Löschen-Knopf nicht gefunden")
        return (document, wurzel, löschen)
    }

    func testDerLöschenKnopfEntferntDieAusgewählteEbene() throws {
        let (document, _, löschen) = try bühne()

        let ebene = Layer(
            name: "Weg damit",
            content: .shape(ShapeLayerContent(kind: .rectangle, size: Size(width: 40, height: 40)))
        )
        document.modify("Ebene anlegen") { _ = try? $0.addLayer(ebene) }
        document.state.selectedLayerID = ebene.id
        XCTAssertEqual(document.state.document.layers.count, 1)

        _ = löschen.target?.perform(löschen.action, with: löschen)

        XCTAssertTrue(document.state.document.layers.isEmpty,
                      "der Knopf muss die ausgewählte Ebene entfernen")
        XCTAssertEqual(document.undoManager?.undoActionName, "Ebene löschen")
    }

    /// Ohne Auswahl darf der Knopf nicht bedienbar sein — sonst sähe es aus,
    /// als täte ein Klick nichts.
    func testOhneAuswahlIstDerKnopfAbgeschaltet() throws {
        let (document, wurzel, löschen) = try bühne()
        document.state.selectedLayerID = nil
        wurzel.layoutSubtreeIfNeeded()

        XCTAssertFalse(löschen.isEnabled)
    }

    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { child in
            ((child as? NSButton).map { [$0] } ?? []) + buttons(in: child)
        }
    }
}
