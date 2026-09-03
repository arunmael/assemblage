import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

@MainActor
final class InspectorTests: XCTestCase {

    private func dokumentMitEbene(
        content: LayerContent = .shape(
            ShapeLayerContent(kind: .rectangle, size: Size(width: 100, height: 80))
        )
    ) -> (AssemblageDocument, InspectorEditing, UUID, UndoManager) {
        let document = AssemblageDocument()
        let undoManager = UndoManager()
        document.undoManager = undoManager
        let layer = Layer(name: "Ebene", opacity: 0.5, content: content)
        document.modify("Ebene anlegen") { _ = try? $0.addLayer(layer) }
        document.state.selectedLayerID = layer.id
        undoManager.removeAllActions()
        return (document, InspectorEditing(state: document.state), layer.id, undoManager)
    }

    func testEinReglerzugErzeugtGenauEinenUndoSchritt() {
        let (document, editing, id, undoManager) = dokumentMitEbene()

        editing.beginEditing()
        for schritt in 1...40 {
            editing.updateSelectedLayer(actionName: "Deckkraft ändern") {
                $0.opacity = Double(schritt) / 100
            }
        }
        editing.endEditing(actionName: "Deckkraft ändern")

        XCTAssertEqual(document.state.document.layer(withID: id)?.opacity, 0.4)
        undoManager.undo()
        XCTAssertEqual(document.state.document.layer(withID: id)?.opacity, 0.5)
        XCTAssertFalse(undoManager.canUndo, "ein einziges Widerrufen muss den ganzen Reglerzug zurücknehmen")
    }

    func testWährendReglerzugNochKeinUndoSchrittVorhandenIst() {
        let (document, editing, _, undoManager) = dokumentMitEbene()

        editing.beginEditing()
        editing.updateSelectedLayer(actionName: "Deckkraft ändern") { $0.opacity = 0.7 }

        XCTAssertTrue(document.isInteracting)
        XCTAssertFalse(undoManager.canUndo)

        editing.endEditing(actionName: "Deckkraft ändern")
        XCTAssertFalse(document.isInteracting)
        XCTAssertTrue(undoManager.canUndo)
    }

    func testReglerzugZumAusgangswertKeinenUndoSchrittErzeugt() {
        let (document, editing, id, undoManager) = dokumentMitEbene()

        editing.beginEditing()
        editing.updateSelectedLayer(actionName: "Deckkraft ändern") { $0.opacity = 0.9 }
        XCTAssertEqual(document.state.document.layer(withID: id)?.opacity, 0.9)
        editing.updateSelectedLayer(actionName: "Deckkraft ändern") { $0.opacity = 0.5 }
        editing.endEditing(actionName: "Deckkraft ändern")

        XCTAssertEqual(document.state.document.layer(withID: id)?.opacity, 0.5)
        XCTAssertFalse(undoManager.canUndo)
    }

    func testDeckkraftUndBildanpassungenBegrenztGespeichertWerden() {
        let bild = ImageLayerContent(originalFileReference: "originals/foto.jpg")
        let (document, editing, id, _) = dokumentMitEbene(content: .image(bild))

        editing.updateSelectedLayer(actionName: "Werte ändern") { layer in
            layer.opacity = 1.5
            guard case .image(var content) = layer.content else { return }
            content.adjustments = ImageAdjustments(
                brightness: 1.8,
                contrast: -1.4,
                saturation: 3,
                warmth: -2,
                blurRadius: -0.3,
                sharpenAmount: 1.7
            )
            layer.content = .image(content)
        }

        guard let layer = document.state.document.layer(withID: id),
              case .image(let content) = layer.content else {
            return XCTFail("Bildebene fehlt")
        }
        XCTAssertEqual(layer.opacity, 1)
        XCTAssertEqual(content.adjustments.brightness, 1)
        XCTAssertEqual(content.adjustments.contrast, -1)
        XCTAssertEqual(content.adjustments.saturation, 1)
        XCTAssertEqual(content.adjustments.warmth, -1)
        XCTAssertEqual(content.adjustments.blurRadius, 0)
        XCTAssertEqual(content.adjustments.sharpenAmount, 1)

        editing.updateSelectedLayer(actionName: "Deckkraft ändern") { $0.opacity = -0.3 }
        XCTAssertEqual(document.state.document.layer(withID: id)?.opacity, 0)
    }

    func testGelöschteAuswahlNichtGeändertWird() {
        let (document, editing, id, undoManager) = dokumentMitEbene()
        document.modify("Ebene löschen") { _ = try? $0.removeLayer(id: id) }
        undoManager.removeAllActions()

        editing.updateSelectedLayer(actionName: "Umbenennen") { $0.name = "Nicht mehr da" }

        XCTAssertNil(document.state.document.layer(withID: id))
        XCTAssertFalse(undoManager.canUndo)
    }

    func testOhneAuswahlNichtsGeändertWird() {
        let (document, editing, id, undoManager) = dokumentMitEbene()
        document.state.selectedLayerID = nil

        editing.updateSelectedLayer(actionName: "Umbenennen") { $0.name = "Ungewollt" }

        XCTAssertEqual(document.state.document.layer(withID: id)?.name, "Ebene")
        XCTAssertFalse(undoManager.canUndo)
    }

    func testBildanpassungenZurückgesetztWerden() {
        let bild = ImageLayerContent(
            originalFileReference: "originals/foto.jpg",
            adjustments: ImageAdjustments(brightness: 0.5, blurRadius: 0.4)
        )
        let (document, editing, id, undoManager) = dokumentMitEbene(content: .image(bild))

        editing.resetAdjustments()

        guard let layer = document.state.document.layer(withID: id),
              case .image(let content) = layer.content else {
            return XCTFail("Bildebene fehlt")
        }
        XCTAssertEqual(content.adjustments, .neutral)
        XCTAssertTrue(undoManager.canUndo)
    }

    func testZahleneingabenAusgewertetWerden() {
        XCTAssertEqual(InspectorEditing.number(from: "12.5"), 12.5)
        XCTAssertEqual(InspectorEditing.number(from: "12,5"), 12.5)
        XCTAssertEqual(InspectorEditing.number(from: "  12.5  "), 12.5)
        XCTAssertNil(InspectorEditing.number(from: "Buchstaben"))
        XCTAssertNil(InspectorEditing.number(from: ""))
        XCTAssertNil(InspectorEditing.number(from: "   "))
    }

    func testBlendModusUndNameGemeinsamWiderrufbarSind() {
        let (document, editing, id, undoManager) = dokumentMitEbene()

        editing.beginEditing()
        editing.updateSelectedLayer(actionName: "Ebene ändern") {
            $0.name = "Hintergrund"
            $0.blendMode = .multiply
        }
        editing.endEditing(actionName: "Ebene ändern")

        XCTAssertEqual(document.state.document.layer(withID: id)?.name, "Hintergrund")
        XCTAssertEqual(document.state.document.layer(withID: id)?.blendMode, .multiply)
        undoManager.undo()
        XCTAssertEqual(document.state.document.layer(withID: id)?.name, "Ebene")
        XCTAssertEqual(document.state.document.layer(withID: id)?.blendMode, .normal)
        XCTAssertFalse(undoManager.canUndo)
    }
}
