import XCTest
@testable import AssemblageModel

/// Das Projektformat (7.4) ist JSON — jede Struktur muss verlustfrei
/// hin- und zurück-codierbar sein, sonst gehen beim Speichern/Laden Daten
/// verloren.
final class DocumentCodableTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func testEmptyDocumentRoundTrips() throws {
        let document = Document(preset: .instagramPost)
        XCTAssertEqual(try roundTrip(document), document)
    }

    func testDocumentWithAllLayerTypesRoundTrips() throws {
        var document = Document(preset: .a4Poster)

        let imageLayer = Layer(
            name: "Hintergrund",
            blendMode: .multiply,
            mask: LayerMask(maskImageReference: "masks/bg.png", source: .automaticForegroundInstance, isInverted: true),
            content: .image(ImageLayerContent(
                originalFileReference: "originals/bg.heic",
                cropRect: Rect(x: 0, y: 0, width: 100, height: 100),
                adjustments: ImageAdjustments(brightness: 0.2, contrast: -0.1, saturation: 0, warmth: 0.3, blurRadius: 0.5, sharpenAmount: 0)
            ))
        )
        let textLayer = Layer(name: "Titel", content: .text(TextLayerContent(string: "Assemblage", fontSize: 72, alignment: .center)))
        let shapeLayer = Layer(name: "Rahmen", content: .shape(ShapeLayerContent(kind: .roundedRectangle, cornerRadius: 12, fillColorHex: "#FF00FF")))

        try document.addLayer(imageLayer)
        try document.addLayer(textLayer)
        try document.addLayer(shapeLayer)

        let decoded = try roundTrip(document)
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.layers.count, 3)
    }

    func testDecodingUnknownLayerContentCaseFailsInsteadOfCrashing() {
        // Zukunftssicherheit: ein älteres App-Release, das einen neueren
        // Ebenentyp aus einer neueren Dokumentversion nicht kennt, muss
        // einen Decodier-Fehler werfen dürfen — nicht abstürzen (2.1).
        let json = """
        {"canvas":{"width":100,"height":100},"layers":[
            {"id":"00000000-0000-0000-0000-000000000000","name":"x","isVisible":true,"opacity":1,"blendMode":"normal","transform":{"x":0,"y":0,"scaleX":1,"scaleY":1,"rotationDegrees":0},"content":{"video":{}}}
        ]}
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(Document.self, from: json))
    }
}
