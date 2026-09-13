import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

@MainActor
final class LayerInsertionTests: XCTestCase {

    func testIndexLiegtDirektUeberDerAuswahlOderOhneAuswahlGanzOben() {
        let document = AssemblageDocument()
        let unten = textEbene("Unten")
        let mitte = textEbene("Mitte")
        let oben = textEbene("Oben")
        document.modify("Vorbereiten") { $0.layers = [unten, mitte, oben] }

        document.state.selectedLayerID = mitte.id
        XCTAssertEqual(LayerInsertion.indexAboveSelection(in: document.state), 2)

        document.state.selectedLayerID = nil
        XCTAssertNil(LayerInsertion.indexAboveSelection(in: document.state))

        document.state.selectedLayerID = UUID()
        XCTAssertNil(LayerInsertion.indexAboveSelection(in: document.state))
    }

    func testTextFormUndLeereEbeneLandenDirektUeberDerAuswahl() throws {
        for einfuegen in [
            { (state: DocumentState) in LayerCreation.insert(.text, into: state) },
            { (state: DocumentState) in LayerCreation.insert(.ellipse, into: state) },
            { (state: DocumentState) in
                _ = DrawingLayerCommand.insertEmptyLayer(
                    into: state, strokeColorHex: "#1D3557", strokeWidth: 6
                )
            }
        ] {
            let document = dokumentMitDreiEbenen()
            let ausgewaehlt = document.state.document.layers[1]
            let bisherOben = document.state.document.layers[2]
            document.state.selectedLayerID = ausgewaehlt.id

            einfuegen(document.state)

            XCTAssertEqual(document.state.document.layers.count, 4)
            XCTAssertEqual(document.state.document.layers[1].id, ausgewaehlt.id)
            XCTAssertEqual(document.state.document.layers[2].id, document.state.selectedLayerID)
            XCTAssertEqual(document.state.document.layers[3].id, bisherOben.id)
        }
    }

    func testOhneAuswahlLandenNeueEbenenGanzOben() {
        let document = dokumentMitDreiEbenen()
        document.state.selectedLayerID = nil

        LayerCreation.insert(.rectangle, into: document.state)

        XCTAssertEqual(document.state.document.layers.last?.id, document.state.selectedLayerID)
    }

    func testMehrereBilderBleibenZusammenhaengendUndInReihenfolgeUeberDerAuswahl() throws {
        let document = dokumentMitDreiEbenen()
        let ausgewaehlt = document.state.document.layers[1]
        let bisherOben = document.state.document.layers[2]
        document.state.selectedLayerID = ausgewaehlt.id
        let bilder = ["eins", "zwei", "drei"].map { name in
            Layer(name: name, content: .image(ImageLayerContent(originalFileReference: "\(name).png")))
        }

        ImageDropCommand.insertImportedLayers(bilder, into: document.state)

        let layers = document.state.document.layers
        XCTAssertEqual(layers.count, 6)
        guard layers.count == 6 else { return }
        XCTAssertEqual(layers[1].id, ausgewaehlt.id)
        XCTAssertEqual(layers[5].id, bisherOben.id)
        let namen = layers[2...4].map(\.name)
        XCTAssertEqual(namen, ["eins", "zwei", "drei"])
        XCTAssertEqual(document.state.selectedLayerID, layers[4].id)
    }

    func testLeereZeichenebeneKannExportiertWerden() async throws {
        let document = AssemblageDocument()
        document.modify("Leinwand") { $0.canvas = CanvasSize(width: 80, height: 60) }
        let id = DrawingLayerCommand.insertEmptyLayer(
            into: document.state, strokeColorHex: "#123456", strokeWidth: 7
        )

        XCTAssertNotNil(id)
        let bild = try await DocumentExporter.image(
            of: document.state.document,
            resources: document.state.resources,
            targetSize: CGSize(width: 80, height: 60)
        )
        XCTAssertEqual(bild.width, 80)
        XCTAssertEqual(bild.height, 60)
    }

    func testLeereZeichenebeneHatLeerenPfadLeinwandgroesseUndUndoNamen() throws {
        let document = AssemblageDocument()
        let undoManager = UndoManager()
        document.undoManager = undoManager
        document.modify("Leinwand") { $0.canvas = CanvasSize(width: 320, height: 180) }
        undoManager.removeAllActions()

        let id = DrawingLayerCommand.insertEmptyLayer(
            into: document.state, strokeColorHex: "#AABBCC", strokeWidth: 9
        )

        let ebene = try XCTUnwrap(id.flatMap { document.state.document.layer(withID: $0) })
        guard case .shape(let inhalt) = ebene.content else {
            return XCTFail("Die leere Zeichenebene muss eine Formebene sein")
        }
        XCTAssertEqual(ebene.name, "Zeichnung")
        XCTAssertEqual(ebene.transform.x, 160, accuracy: 1e-6)
        XCTAssertEqual(ebene.transform.y, 90, accuracy: 1e-6)
        XCTAssertEqual(inhalt.kind, .freehand)
        XCTAssertEqual(inhalt.size, Size(width: 320, height: 180))
        XCTAssertEqual(inhalt.fillColorHex, "#00000000")
        XCTAssertEqual(inhalt.strokeColorHex, "#AABBCC")
        XCTAssertEqual(inhalt.strokeWidth, 9)
        XCTAssertEqual(inhalt.path, VectorPath())
        XCTAssertEqual(undoManager.undoActionName, "Leere Ebene einfügen")
    }

    private func dokumentMitDreiEbenen() -> AssemblageDocument {
        let document = AssemblageDocument()
        document.modify("Vorbereiten") {
            $0.layers = [textEbene("Unten"), textEbene("Mitte"), textEbene("Oben")]
        }
        return document
    }

    private func textEbene(_ name: String) -> Layer {
        Layer(name: name, content: .text(TextLayerContent(string: name)))
    }

}
