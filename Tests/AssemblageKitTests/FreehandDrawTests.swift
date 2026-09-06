import XCTest
@testable import AssemblageKit
@testable import AssemblageModel

@MainActor
final class FreehandDrawTests: XCTestCase {

    func testInsertLegtGenauEineFreihandEbeneMitStricheinstellungenAn() throws {
        let dokument = AssemblageDocument()

        FreehandDrawCommand.insert(
            rawPoints: [Point(x: 10, y: 20), Point(x: 110, y: 70)],
            strokeColorHex: "#1D3557",
            strokeWidth: 8,
            into: dokument.state
        )

        let ebene = try XCTUnwrap(dokument.state.document.layers.only)
        guard case .shape(let inhalt) = ebene.content else {
            return XCTFail("Der Zug muss eine Formebene erzeugen")
        }
        XCTAssertEqual(inhalt.kind, .freehand)
        XCTAssertNotNil(inhalt.path)
        XCTAssertEqual(inhalt.strokeWidth, 8)
        XCTAssertEqual(inhalt.strokeColorHex, "#1D3557")
        XCTAssertEqual(dokument.state.selectedLayerID, ebene.id)
    }

    func testEbeneDecktDenHuellenrahmenDerEingabepunkteAb() throws {
        let dokument = AssemblageDocument()
        let punkte = [Point(x: 30, y: 45), Point(x: 230, y: 145)]

        FreehandDrawCommand.insert(
            rawPoints: punkte, strokeColorHex: "#123456", strokeWidth: 6,
            into: dokument.state
        )

        let ebene = try XCTUnwrap(dokument.state.document.layers.only)
        guard case .shape(let inhalt) = ebene.content else {
            return XCTFail("Der Zug muss eine Formebene erzeugen")
        }
        XCTAssertEqual(ebene.transform.x, 130, accuracy: 1)
        XCTAssertEqual(ebene.transform.y, 95, accuracy: 1)
        XCTAssertEqual(inhalt.size.width, 200, accuracy: 1)
        XCTAssertEqual(inhalt.size.height, 100, accuracy: 1)
    }

    func testLeerePunktlisteFuegtKeineEbeneEin() {
        let dokument = AssemblageDocument()

        FreehandDrawCommand.insert(
            rawPoints: [], strokeColorHex: "#000000", strokeWidth: 6,
            into: dokument.state
        )

        XCTAssertTrue(dokument.state.document.layers.isEmpty)
    }

    func testSenkrechterStrichHatMindestensStrichbreiteAlsEbenenbreite() throws {
        let dokument = AssemblageDocument()

        FreehandDrawCommand.insert(
            rawPoints: [Point(x: 80, y: 20), Point(x: 80, y: 220)],
            strokeColorHex: "#000000", strokeWidth: 12,
            into: dokument.state
        )

        let ebene = try XCTUnwrap(dokument.state.document.layers.only)
        guard case .shape(let inhalt) = ebene.content else {
            return XCTFail("Der Zug muss eine Formebene erzeugen")
        }
        XCTAssertGreaterThanOrEqual(inhalt.size.width, 12)
        XCTAssertEqual(ebene.transform.x, 80, accuracy: 0.001)
    }

    func testZeichnenIstEinBenannterUndoSchritt() {
        let dokument = AssemblageDocument()
        let undoManager = UndoManager()
        dokument.undoManager = undoManager
        undoManager.groupsByEvent = false

        undoManager.beginUndoGrouping()
        FreehandDrawCommand.insert(
            rawPoints: [Point(x: 10, y: 10), Point(x: 90, y: 50)],
            strokeColorHex: "#1D3557", strokeWidth: 6,
            into: dokument.state
        )
        undoManager.endUndoGrouping()

        XCTAssertEqual(dokument.state.document.layers.count, 1)
        XCTAssertEqual(undoManager.undoActionName, "Freihand zeichnen")
        undoManager.undo()
        XCTAssertTrue(dokument.state.document.layers.isEmpty)
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
