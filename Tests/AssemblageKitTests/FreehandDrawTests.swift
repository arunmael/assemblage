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

    func testZweiterStrichMitGleichemStiftWirdAnAusgewaehlteFreihandEbeneAngehaengt() throws {
        let dokument = AssemblageDocument()
        zeichne(in: dokument, farbe: "#1D3557", breite: 6, von: 10, bis: 90)
        let id = try XCTUnwrap(dokument.state.selectedLayerID)

        zeichne(in: dokument, farbe: "#1d3557", breite: 6.0005, von: 150, bis: 230)

        XCTAssertEqual(dokument.state.document.layers.count, 1)
        XCTAssertEqual(dokument.state.selectedLayerID, id)
        guard case .shape(let inhalt) = dokument.state.document.layers[0].content else {
            return XCTFail("Der Zug muss eine Formebene bleiben")
        }
        XCTAssertEqual(inhalt.path?.subpaths.count, 2)
    }

    func testAndereFarbeOderBreiteErzeugtEineNeueEbene() {
        for (farbe, breite) in [("#FFFFFF", 6.0), ("#1D3557", 7.0)] {
            let dokument = AssemblageDocument()
            zeichne(in: dokument, farbe: "#1D3557", breite: 6, von: 10, bis: 90)

            zeichne(in: dokument, farbe: farbe, breite: breite, von: 150, bis: 230)

            XCTAssertEqual(dokument.state.document.layers.count, 2)
        }
    }

    func testErsterStrichAufLeererZeichenebeneUebernimmtStiftwerte() throws {
        let dokument = AssemblageDocument()
        let id = DrawingLayerCommand.insertEmptyLayer(
            into: dokument.state, strokeColorHex: "#000000", strokeWidth: 2
        )

        zeichne(in: dokument, farbe: "#ABCDEF", breite: 11, von: 20, bis: 120)

        XCTAssertEqual(dokument.state.document.layers.count, 1)
        XCTAssertEqual(dokument.state.selectedLayerID, id)
        guard case .shape(let inhalt) = dokument.state.document.layers[0].content else {
            return XCTFail("Die Zeichenebene muss eine Formebene bleiben")
        }
        XCTAssertEqual(inhalt.strokeColorHex, "#ABCDEF")
        XCTAssertEqual(inhalt.strokeWidth, 11)
        XCTAssertEqual(inhalt.path?.subpaths.count, 1)
    }

    func testStrichAufBildEbeneErzeugtNeueEbeneDirektDarueber() {
        let dokument = AssemblageDocument()
        let bild = Layer(name: "Bild", content: .image(ImageLayerContent(originalFileReference: "bild.png")))
        let oben = Layer(name: "Oben", content: .text(TextLayerContent(string: "Oben")))
        dokument.modify("Vorbereiten") { $0.layers = [bild, oben] }
        dokument.state.selectedLayerID = bild.id

        zeichne(in: dokument, farbe: "#1D3557", breite: 6, von: 10, bis: 90)

        XCTAssertEqual(dokument.state.document.layers.count, 3)
        XCTAssertEqual(dokument.state.document.layers[0].id, bild.id)
        XCTAssertEqual(dokument.state.document.layers[2].id, oben.id)
        XCTAssertEqual(dokument.state.document.layers[1].id, dokument.state.selectedLayerID)
    }

    private func zeichne(
        in dokument: AssemblageDocument,
        farbe: String,
        breite: Double,
        von: Double,
        bis: Double
    ) {
        FreehandDrawCommand.insert(
            rawPoints: [Point(x: von, y: 20), Point(x: bis, y: 70)],
            strokeColorHex: farbe,
            strokeWidth: breite,
            into: dokument.state
        )
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
