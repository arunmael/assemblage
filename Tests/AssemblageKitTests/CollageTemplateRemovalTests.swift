import XCTest
@testable import AssemblageKit
@testable import AssemblageModel

@MainActor
final class CollageTemplateRemovalTests: XCTestCase {

    func testAufhebenEntferntDenZuschnittAllerBetroffenenBilder() throws {
        let document = dokumentMitBildern(4)
        let bildgroesse = Size(width: 1_600, height: 1_200)

        CollageTemplateCommand.apply(.grid2x2, to: document.state) { _ in bildgroesse }
        XCTAssertTrue(document.state.document.layers.allSatisfy { layer in
            guard case .image(let content) = layer.content else { return true }
            return content.cropRect != nil
        })

        CollageTemplateCommand.removeTemplate(from: document.state) { _ in bildgroesse }

        for layer in document.state.document.layers {
            guard case .image(let content) = layer.content else { continue }
            XCTAssertNil(content.cropRect)
        }
    }

    /// In der App liegen Anwenden und Aufheben in getrennten Ereignissen und
    /// damit in getrennten Undo-Gruppen. Der Test muss das nachstellen:
    /// `groupsByEvent` fasst sonst beide Befehle zu einer Gruppe zusammen,
    /// weil zwischen ihnen keine Runloop-Runde vergeht — ein Widerrufen
    /// nähme dann auch das Raster selbst zurück.
    func testAufhebenIstEinEinzelnerUndoSchrittDerDasRasterWiederherstellt() {
        let document = dokumentMitBildern(4)
        let undoManager = UndoManager()
        document.undoManager = undoManager
        undoManager.groupsByEvent = false
        let bildgroesse = Size(width: 1_600, height: 1_200)

        undoManager.beginUndoGrouping()
        CollageTemplateCommand.apply(.grid2x2, to: document.state) { _ in bildgroesse }
        undoManager.endUndoGrouping()
        let rasterzustand = document.state.document

        undoManager.beginUndoGrouping()
        CollageTemplateCommand.removeTemplate(from: document.state) { _ in bildgroesse }
        undoManager.endUndoGrouping()

        XCTAssertNotEqual(document.state.document, rasterzustand,
                          "Aufheben muss das Dokument überhaupt verändern")
        XCTAssertEqual(undoManager.undoActionName, "Raster aufheben")

        undoManager.undo()
        XCTAssertEqual(document.state.document, rasterzustand,
                       "ein Widerrufen stellt genau das Raster wieder her")
    }

    private func dokumentMitBildern(_ anzahl: Int) -> AssemblageDocument {
        let document = AssemblageDocument()
        document.modify("Testbilder einsetzen") { zustand in
            for index in 0..<anzahl {
                let layer = Layer(
                    name: "Bild \(index)",
                    content: .image(ImageLayerContent(
                        originalFileReference: "originals/bild-\(index).png"
                    ))
                )
                _ = try? zustand.addLayer(layer)
            }
        }
        return document
    }
}
