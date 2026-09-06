import XCTest
@testable import AssemblageKit
@testable import AssemblageModel

@MainActor
final class ImageInShapeTests: XCTestCase {

    private let imageSize = Size(width: 1_600, height: 900)

    func testCoverUebernimmtFormrahmenUndEntferntForm() throws {
        let (document, imageID, shapeID, oldImage, oldShape) = makeDocument()
        let expectedFrame = oldShape.transform.unrotatedFrame(forContentSize: shapeContent(oldShape).size)

        ImageInShapeCommand.apply(
            imageLayerID: imageID, shapeLayerID: shapeID, fit: .cover, to: document.state
        ) { _ in self.imageSize }

        let image = try XCTUnwrap(document.state.document.layer(withID: imageID))
        let content = imageContent(image)
        XCTAssertEqual(content.clipShape, shapeContent(oldShape).kind)
        let visibleSize = content.cropRect.map { Size(width: $0.width, height: $0.height) } ?? imageSize
        XCTAssertEqual(image.transform.unrotatedFrame(forContentSize: visibleSize), expectedFrame)
        XCTAssertNil(document.state.document.layer(withID: shapeID))
        XCTAssertNotEqual(image, oldImage)
    }

    func testCoverSchneidetZuUndSkaliertGleichmaessig() throws {
        let (document, imageID, shapeID, _, _) = makeDocument()
        ImageInShapeCommand.apply(
            imageLayerID: imageID, shapeLayerID: shapeID, fit: .cover, to: document.state
        ) { _ in self.imageSize }

        let image = try XCTUnwrap(document.state.document.layer(withID: imageID))
        XCTAssertNotNil(imageContent(image).cropRect)
        XCTAssertEqual(image.transform.scaleX, image.transform.scaleY, accuracy: 0.000_001)
    }

    func testStretchBehältGanzesBildUndSkaliertUngleich() throws {
        let (document, imageID, shapeID, _, _) = makeDocument()
        ImageInShapeCommand.apply(
            imageLayerID: imageID, shapeLayerID: shapeID, fit: .stretch, to: document.state
        ) { _ in self.imageSize }

        let image = try XCTUnwrap(document.state.document.layer(withID: imageID))
        XCTAssertNil(imageContent(image).cropRect)
        XCTAssertNotEqual(image.transform.scaleX, image.transform.scaleY, accuracy: 0.000_001)
    }

    func testFormstrichWirdZumBildrahmen() throws {
        let (document, imageID, shapeID, _, _) = makeDocument()
        ImageInShapeCommand.apply(
            imageLayerID: imageID, shapeLayerID: shapeID, fit: .cover, to: document.state
        ) { _ in self.imageSize }

        let content = imageContent(try XCTUnwrap(document.state.document.layer(withID: imageID)))
        XCTAssertEqual(content.borderWidth, 7)
        XCTAssertEqual(content.borderColorHex, "#123456")
    }

    func testEinsetzenIstEinUndoSchritt() throws {
        let (document, imageID, shapeID, oldImage, oldShape) = makeDocument()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        document.undoManager = undoManager

        undoManager.beginUndoGrouping()
        ImageInShapeCommand.apply(
            imageLayerID: imageID, shapeLayerID: shapeID, fit: .cover, to: document.state
        ) { _ in self.imageSize }
        undoManager.endUndoGrouping()

        undoManager.undo()
        XCTAssertEqual(document.state.document.layer(withID: imageID), oldImage)
        XCTAssertEqual(document.state.document.layer(withID: shapeID), oldShape)
    }

    func testZuschnittAufhebenIstWiderrufbar() throws {
        let (document, imageID, _, _, _) = makeDocument(clipShape: .heart)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        document.undoManager = undoManager

        undoManager.beginUndoGrouping()
        ImageInShapeCommand.removeClipShape(from: imageID, in: document.state)
        undoManager.endUndoGrouping()
        XCTAssertNil(imageContent(try XCTUnwrap(document.state.document.layer(withID: imageID))).clipShape)

        undoManager.undo()
        XCTAssertEqual(imageContent(try XCTUnwrap(document.state.document.layer(withID: imageID))).clipShape, .heart)
    }

    func testCanApplyLehntGleicheIDUndFalscheTypenAb() {
        let (document, imageID, shapeID, _, _) = makeDocument()
        XCTAssertTrue(ImageInShapeCommand.canApply(imageLayerID: imageID, shapeLayerID: shapeID, in: document.state.document))
        XCTAssertFalse(ImageInShapeCommand.canApply(imageLayerID: imageID, shapeLayerID: imageID, in: document.state.document))
        XCTAssertFalse(ImageInShapeCommand.canApply(imageLayerID: shapeID, shapeLayerID: imageID, in: document.state.document))
    }

    private func makeDocument(
        clipShape: ShapeKind? = nil
    ) -> (AssemblageDocument, UUID, UUID, Layer, Layer) {
        let document = AssemblageDocument()
        let image = Layer(
            name: "Bild",
            transform: Transform2D(x: 80, y: 70, scaleX: 0.5, scaleY: 0.5),
            content: .image(ImageLayerContent(originalFileReference: "originals/test.png", clipShape: clipShape))
        )
        let shape = Layer(
            name: "Form",
            transform: Transform2D(x: 420, y: 310, scaleX: 1.5, scaleY: 0.75, rotationDegrees: 12),
            content: .shape(ShapeLayerContent(
                kind: .ellipse,
                size: Size(width: 300, height: 300),
                strokeColorHex: "#123456",
                strokeWidth: 7
            ))
        )
        document.modify("Testebenen einsetzen") {
            _ = try? $0.addLayer(image)
            _ = try? $0.addLayer(shape)
        }
        return (document, image.id, shape.id, image, shape)
    }

    private func imageContent(_ layer: Layer) -> ImageLayerContent {
        guard case .image(let content) = layer.content else { XCTFail("Bildebene erwartet"); return ImageLayerContent(originalFileReference: "") }
        return content
    }

    private func shapeContent(_ layer: Layer) -> ShapeLayerContent {
        guard case .shape(let content) = layer.content else { XCTFail("Formebene erwartet"); return ShapeLayerContent(kind: .rectangle, size: .zero) }
        return content
    }
}
