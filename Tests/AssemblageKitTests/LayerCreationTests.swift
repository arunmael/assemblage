import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

@MainActor
final class LayerCreationTests: XCTestCase {

    private let canvas = CanvasSize(width: 1_080, height: 1_080)

    func testAlleArtenErzeugenDenPassendenInhaltstyp() {
        let text = LayerCreation.makeLayer(.text, canvas: canvas, existingLayers: [])
        let rectangle = LayerCreation.makeLayer(.rectangle, canvas: canvas, existingLayers: [])
        let rounded = LayerCreation.makeLayer(.roundedRectangle, canvas: canvas, existingLayers: [])
        let ellipse = LayerCreation.makeLayer(.ellipse, canvas: canvas, existingLayers: [])

        guard case .text = text.content else { return XCTFail("Text muss eine Textebene erzeugen") }
        guard case .shape(let rectangleContent) = rectangle.content else {
            return XCTFail("Rechteck muss eine Formebene erzeugen")
        }
        guard case .shape(let roundedContent) = rounded.content else {
            return XCTFail("Abgerundetes Rechteck muss eine Formebene erzeugen")
        }
        guard case .shape(let ellipseContent) = ellipse.content else {
            return XCTFail("Ellipse muss eine Formebene erzeugen")
        }

        XCTAssertEqual(rectangleContent.kind, .rectangle)
        XCTAssertEqual(roundedContent.kind, .roundedRectangle)
        XCTAssertEqual(ellipseContent.kind, .ellipse)
    }

    func testNeueTextebeneHatSichtbarenPlatzhaltertext() {
        let layer = LayerCreation.makeLayer(.text, canvas: canvas, existingLayers: [])
        guard case .text(let content) = layer.content else {
            return XCTFail("Text muss eine Textebene erzeugen")
        }

        XCTAssertFalse(content.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertGreaterThan(layer.opacity, 0)
    }

    func testFormgroesseWaechstMitDerLeinwand() {
        let small = LayerCreation.makeLayer(
            .rectangle,
            canvas: CanvasSize(width: 400, height: 300),
            existingLayers: []
        )
        let large = LayerCreation.makeLayer(
            .rectangle,
            canvas: CanvasSize(width: 2_480, height: 3_508),
            existingLayers: []
        )

        guard case .shape(let smallContent) = small.content,
              case .shape(let largeContent) = large.content
        else { return XCTFail("Beide Ebenen müssen Formen sein") }

        XCTAssertGreaterThan(largeContent.size.width, smallContent.size.width * 3)
        XCTAssertGreaterThan(largeContent.size.height, smallContent.size.height * 3)
    }

    func testEinsetzenLegtEbeneZuoberstAbUndWaehltSieAus() {
        let document = AssemblageDocument()
        let existing = Layer(name: "Bestehend", content: .text(TextLayerContent(string: "Alt")))
        document.modify("Testebene einsetzen") { _ = try? $0.addLayer(existing) }

        LayerCreation.insert(.ellipse, into: document.state)

        XCTAssertEqual(document.state.document.layers.count, 2)
        XCTAssertEqual(document.state.document.layers.last?.id, document.state.selectedLayerID)
        guard case .shape(let content) = document.state.document.layers.last?.content else {
            return XCTFail("Zuoberst muss die neue Ellipse liegen")
        }
        XCTAssertEqual(content.kind, .ellipse)
    }

    func testZweiNacheinanderEingesetzteEbenenLiegenNichtDeckungsgleich() {
        let document = AssemblageDocument()

        LayerCreation.insert(.rectangle, into: document.state)
        LayerCreation.insert(.rectangle, into: document.state)

        XCTAssertEqual(document.state.document.layers.count, 2)
        XCTAssertNotEqual(
            document.state.document.layers[0].transform,
            document.state.document.layers[1].transform
        )
    }

    func testEinsetzenIstGenauEinUndoSchrittUndEntferntDieEbeneVollstaendig() {
        let document = AssemblageDocument()
        let undoManager = UndoManager()
        document.undoManager = undoManager
        undoManager.removeAllActions()

        LayerCreation.insert(.text, into: document.state)

        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertTrue(document.state.document.layers.isEmpty)
        XCTAssertNil(document.state.selectedLayerID)
        XCTAssertFalse(undoManager.canUndo, "Einsetzen darf nur einen Undo-Schritt erzeugen")
    }

    func testUndoSchrittHatEinenSprechendenNamen() {
        let document = AssemblageDocument()
        let undoManager = UndoManager()
        document.undoManager = undoManager
        undoManager.removeAllActions()

        LayerCreation.insert(.roundedRectangle, into: document.state)

        XCTAssertEqual(undoManager.undoActionName, "Abgerundetes Rechteck einfügen")
    }

    func testNeueFormIstAufWeissemGrundSichtbar() {
        for kind in [NewLayerKind.rectangle, .roundedRectangle, .ellipse] {
            let layer = LayerCreation.makeLayer(kind, canvas: canvas, existingLayers: [])
            guard case .shape(let content) = layer.content else {
                return XCTFail("\(kind) muss eine Formebene erzeugen")
            }

            XCTAssertGreaterThan(layer.opacity, 0)
            XCTAssertNotEqual(content.fillColorHex.uppercased(), "#FFFFFF")
            XCTAssertGreaterThan(content.size.width, 0)
            XCTAssertGreaterThan(content.size.height, 0)
        }
    }
}
