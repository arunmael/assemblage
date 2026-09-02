import XCTest
@testable import AssemblageModel

/// Felder mit einem neutralen Vorgabewert müssen fehlen dürfen.
///
/// Warum das wichtig ist: Ohne diese Toleranz verlangt Codable *jeden*
/// Schlüssel. Ein in Version 2 ergänztes Feld — sagen wir ein Schlagschatten —
/// würde dann jedes in Version 1 gesicherte Dokument unlesbar machen, obwohl
/// dessen Daten vollständig sind. Genau das verbietet Plan 2.1
/// („kein Datenverlust").
///
/// Umgekehrt bleiben Felder ohne sinnvollen Ersatzwert (Ebenen-ID, Dateiname
/// des Originals, Leinwandgrösse) weiterhin Pflicht — fehlen die, ist das
/// Dokument wirklich beschädigt und darf nicht stillschweigend „repariert"
/// werden.
final class DecodingToleranceTests: XCTestCase {

    private func decode(_ json: String) throws -> Document {
        try DocumentPackage.decode(Data(json.utf8))
    }

    // MARK: - Vorgabewerte greifen

    func testLayerDecodesWithOnlyRequiredFields() throws {
        let document = try decode("""
        { "formatVersion": 1, "document": {
            "canvas": { "width": 100, "height": 100 },
            "layers": [{
                "id": "11111111-1111-1111-1111-111111111111",
                "name": "Nackt",
                "content": { "shape": { "_0": {
                    "kind": "rectangle",
                    "size": { "width": 10, "height": 10 }
                } } }
            }]
        } }
        """)

        let layer = try XCTUnwrap(document.layers.first)
        XCTAssertTrue(layer.isVisible)
        XCTAssertEqual(layer.opacity, 1)
        XCTAssertEqual(layer.blendMode, .normal)
        XCTAssertEqual(layer.transform, .identity)
        XCTAssertNil(layer.mask)
    }

    func testImageContentDecodesWithoutAdjustments() throws {
        let document = try decode("""
        { "formatVersion": 1, "document": {
            "canvas": { "width": 100, "height": 100 },
            "layers": [{
                "id": "11111111-1111-1111-1111-111111111111",
                "name": "Foto",
                "content": { "image": { "_0": { "originalFileReference": "originals/a.png" } } }
            }]
        } }
        """)

        guard case .image(let content) = try XCTUnwrap(document.layers.first).content else {
            return XCTFail("Bildebene erwartet")
        }
        XCTAssertEqual(content.adjustments, .neutral)
        XCTAssertNil(content.cropRect)
    }

    func testTextAndShapeContentUseDefaults() throws {
        let document = try decode("""
        { "formatVersion": 1, "document": {
            "canvas": { "width": 100, "height": 100 },
            "layers": [
                { "id": "11111111-1111-1111-1111-111111111111", "name": "T",
                  "content": { "text": { "_0": { "string": "Hallo" } } } },
                { "id": "22222222-2222-2222-2222-222222222222", "name": "F",
                  "content": { "shape": { "_0": { "kind": "ellipse",
                    "size": { "width": 5, "height": 5 } } } } }
            ]
        } }
        """)

        guard case .text(let text) = document.layers[0].content,
              case .shape(let shape) = document.layers[1].content
        else { return XCTFail("Text- und Formebene erwartet") }

        XCTAssertEqual(text.fontName, "Helvetica")
        XCTAssertEqual(text.fontSize, 48)
        XCTAssertEqual(text.alignment, .left)
        XCTAssertEqual(shape.cornerRadius, 0)
        XCTAssertEqual(shape.fillColorHex, "#FFFFFF")
    }

    func testDocumentWithoutLayersDecodesAsEmpty() throws {
        let document = try decode("""
        { "formatVersion": 1, "document": { "canvas": { "width": 100, "height": 100 } } }
        """)

        XCTAssertTrue(document.layers.isEmpty)
    }

    func testMaskDecodesWithDefaults() throws {
        let document = try decode("""
        { "formatVersion": 1, "document": {
            "canvas": { "width": 100, "height": 100 },
            "layers": [{
                "id": "11111111-1111-1111-1111-111111111111", "name": "M",
                "mask": { "source": "manualBrush" },
                "content": { "text": { "_0": { "string": "x" } } }
            }]
        } }
        """)

        let mask = try XCTUnwrap(document.layers.first?.mask)
        XCTAssertNil(mask.maskImageReference)
        XCTAssertFalse(mask.isInverted)
        XCTAssertTrue(mask.isEnabled)
    }

    // MARK: - Pflichtfelder bleiben Pflicht

    /// Ohne ID lässt sich eine Ebene nicht auswählen, nicht widerrufen und
    /// nicht ihrer Maske zuordnen — dafür gibt es keinen sinnvollen Ersatz.
    func testLayerWithoutIDIsRejected() {
        XCTAssertThrowsError(try decode("""
        { "formatVersion": 1, "document": {
            "canvas": { "width": 100, "height": 100 },
            "layers": [{ "name": "Ohne ID",
                "content": { "text": { "_0": { "string": "x" } } } }]
        } }
        """))
    }

    func testImageWithoutFileReferenceIsRejected() {
        XCTAssertThrowsError(try decode("""
        { "formatVersion": 1, "document": {
            "canvas": { "width": 100, "height": 100 },
            "layers": [{ "id": "11111111-1111-1111-1111-111111111111", "name": "F",
                "content": { "image": { "_0": {} } } }]
        } }
        """))
    }

    func testDocumentWithoutCanvasIsRejected() {
        XCTAssertThrowsError(try decode("""
        { "formatVersion": 1, "document": { "layers": [] } }
        """))
    }

    // MARK: - Vollständige Dokumente bleiben unverändert

    /// Die Toleranz darf nicht dazu führen, dass gesetzte Werte verlorengehen.
    func testFullyPopulatedDocumentStillRoundTrips() throws {
        let original = Document(
            canvas: CanvasSize(width: 640, height: 480),
            layers: [
                Layer(
                    name: "Alles gesetzt",
                    isVisible: false,
                    opacity: 0.25,
                    blendMode: .overlay,
                    transform: Transform2D(x: 1, y: 2, scaleX: 3, scaleY: 4, rotationDegrees: 5),
                    mask: LayerMask(
                        maskImageReference: "masks/m.png",
                        source: .automaticForegroundInstance,
                        isInverted: true,
                        isEnabled: false
                    ),
                    content: .image(
                        ImageLayerContent(
                            originalFileReference: "originals/a.png",
                            cropRect: Rect(x: 1, y: 2, width: 3, height: 4),
                            adjustments: ImageAdjustments(brightness: 0.5, warmth: -0.2)
                        )
                    )
                )
            ]
        )

        XCTAssertEqual(try DocumentPackage.decode(DocumentPackage.encode(original)), original)
    }
}
