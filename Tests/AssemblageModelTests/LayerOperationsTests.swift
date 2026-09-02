import XCTest
@testable import AssemblageModel

/// Deckt die Ebenenlisten-Operationen aus 5.2 ab (Reihenfolge per Drag & Drop,
/// hinzufügen/entfernen) sowie das Prinzip aus 2.1, dass ungültige Operationen
/// einen Fehler werfen statt abzustürzen.
final class LayerOperationsTests: XCTestCase {
    private func makeShapeLayer(_ name: String) -> Layer {
        Layer(name: name, content: .shape(ShapeLayerContent(kind: .rectangle)))
    }

    func testAddLayerDefaultsToTop() throws {
        var document = Document(preset: .instagramPost)
        let first = makeShapeLayer("Erste")
        let second = makeShapeLayer("Zweite")

        try document.addLayer(first)
        try document.addLayer(second)

        XCTAssertEqual(document.layers.map(\.name), ["Erste", "Zweite"])
    }

    func testAddLayerAtInvalidIndexThrows() {
        var document = Document(preset: .instagramPost)
        XCTAssertThrowsError(try document.addLayer(makeShapeLayer("x"), at: 5)) { error in
            XCTAssertEqual(error as? DocumentError, .invalidIndex(5))
        }
    }

    func testRemoveLayerByID() throws {
        var document = Document(preset: .instagramPost)
        let layer = makeShapeLayer("Weg damit")
        try document.addLayer(layer)

        let removed = try document.removeLayer(id: layer.id)

        XCTAssertEqual(removed.id, layer.id)
        XCTAssertTrue(document.layers.isEmpty)
    }

    func testRemoveUnknownLayerThrowsInsteadOfCrashing() {
        var document = Document(preset: .instagramPost)
        let unknownID = UUID()
        XCTAssertThrowsError(try document.removeLayer(id: unknownID)) { error in
            XCTAssertEqual(error as? DocumentError, .layerNotFound(unknownID))
        }
    }

    func testMoveLayerReordersList() throws {
        var document = Document(preset: .instagramPost)
        let bottom = makeShapeLayer("Unten")
        let middle = makeShapeLayer("Mitte")
        let top = makeShapeLayer("Oben")
        try document.addLayer(bottom)
        try document.addLayer(middle)
        try document.addLayer(top)

        // "Unten" per Drag & Drop ganz nach oben ziehen.
        try document.moveLayer(id: bottom.id, toIndex: 2)

        XCTAssertEqual(document.layers.map(\.name), ["Mitte", "Oben", "Unten"])
    }

    func testMoveLayerOutOfBoundsThrows() throws {
        var document = Document(preset: .instagramPost)
        let layer = makeShapeLayer("Solo")
        try document.addLayer(layer)

        XCTAssertThrowsError(try document.moveLayer(id: layer.id, toIndex: 3)) { error in
            XCTAssertEqual(error as? DocumentError, .invalidIndex(3))
        }
    }

    func testUpdateLayerAppliesOpacityChange() throws {
        var document = Document(preset: .instagramPost)
        let layer = makeShapeLayer("Deckkraft-Test")
        try document.addLayer(layer)

        try document.updateLayer(id: layer.id) { $0.opacity = 0.5 }

        XCTAssertEqual(document.layer(withID: layer.id)?.opacity, 0.5)
    }

    func testUpdateUnknownLayerThrows() {
        var document = Document(preset: .instagramPost)
        let unknownID = UUID()
        XCTAssertThrowsError(try document.updateLayer(id: unknownID) { $0.opacity = 0 }) { error in
            XCTAssertEqual(error as? DocumentError, .layerNotFound(unknownID))
        }
    }

    func testOpacityIsClampedToValidRange() {
        let tooHigh = Layer(name: "x", opacity: 1.5, content: .shape(ShapeLayerContent(kind: .rectangle)))
        let tooLow = Layer(name: "y", opacity: -0.3, content: .shape(ShapeLayerContent(kind: .rectangle)))

        XCTAssertEqual(tooHigh.withClampedOpacity().opacity, 1)
        XCTAssertEqual(tooLow.withClampedOpacity().opacity, 0)
    }
}
