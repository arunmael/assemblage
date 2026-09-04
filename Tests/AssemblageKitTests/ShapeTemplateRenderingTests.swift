import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Formvorlagen auf beiden Renderwegen (aus missing.md).
///
/// Solange es nur Rechteck, Ellipse und abgerundetes Rechteck gab, konnte
/// dieser Test nicht fehlschlagen: Alle drei sind senkrecht symmetrisch, eine
/// vertauschte Zeichenrichtung fällt an ihnen nicht auf. Ein Dreieck hat eine
/// Spitze — deshalb wird hier durchgehend damit geprüft.
@MainActor
final class ShapeTemplateRenderingTests: XCTestCase {

    /// Ein rotes Dreieck, Spitze oben, mittig auf 100×100.
    private func triangleDocument(kind: ShapeKind = .triangle) -> AssemblageModel.Document {
        AssemblageModel.Document(
            canvas: CanvasSize(width: 100, height: 100),
            layers: [
                Layer(
                    name: "Dreieck",
                    transform: Transform2D(x: 50, y: 50),
                    content: .shape(ShapeLayerContent(
                        kind: kind,
                        size: Size(width: 80, height: 80),
                        fillColorHex: "#FF0000"
                    ))
                )
            ]
        )
    }

    private func exportPixel(_ document: AssemblageModel.Document, x: Int, y: Int) throws -> (r: Int, a: Int) {
        let bild = try DocumentExporter.renderedImage(
            of: document, resources: DocumentResources(), targetSize: CGSize(width: 100, height: 100))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(bild, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        let z = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = (y * 100 + x) * 4
        return (Int(z[offset]), Int(z[offset + 3]))
    }

    // MARK: - Export

    /// Die Spitze zeigt nach **oben**: Oben in der Mitte ist Farbe, oben in
    /// den Ecken nicht. Genau umgekehrt unten.
    func testTriangleIsNotUpsideDownInExport() throws {
        let document = triangleDocument()

        // Kurz unter der Spitze, mittig.
        XCTAssertGreaterThan(try exportPixel(document, x: 50, y: 16).a, 200,
                             "unter der Spitze müsste Farbe sein")
        // Auf derselben Höhe am linken Rand des Rahmens — dort ist das Dreieck
        // noch schmal.
        XCTAssertLessThan(try exportPixel(document, x: 14, y: 16).a, 50,
                          "oben aussen müsste es leer sein")
        // Unten füllt die Basis die volle Breite.
        XCTAssertGreaterThan(try exportPixel(document, x: 14, y: 86).a, 200,
                             "unten aussen müsste die Basis liegen")
    }

    // MARK: - Bildschirm

    /// Die Leinwand baut den Pfad über dieselbe Stelle. Geprüft wird der Pfad
    /// selbst und nicht ein gerastertes Bild: `CALayer.render(in:)` ist bei
    /// dieser Frage kein verlässlicher Zeuge (siehe die Verziehen-Tests).
    func testCanvasUsesTheTemplatePath() throws {
        let view = CanvasView(document: triangleDocument(), images: ImageStore(resources: DocumentResources()))
        view.layoutSubtreeIfNeeded()
        view.layer?.layoutIfNeeded()

        let leinwand = try XCTUnwrap(view.layer?.sublayers?.first)
        let form = try XCTUnwrap(leinwand.sublayers?.first as? CAShapeLayer)
        let pfad = try XCTUnwrap(form.path)

        // Ein Dreieck hat drei Ecken; das Rechteck des Rahmens hätte vier und
        // eine andere Fläche.
        XCTAssertEqual(pfad.boundingBox.size, CGSize(width: 80, height: 80))
        XCTAssertFalse(pfad.contains(CGPoint(x: 2, y: 2)),
                       "die obere linke Ecke liegt ausserhalb eines Dreiecks")
        XCTAssertTrue(pfad.contains(CGPoint(x: 40, y: 70)),
                      "die untere Mitte liegt innerhalb")
    }

    /// Der Pfad muss für jede Vorlage entstehen — sonst wäre eine Form
    /// unsichtbar, ohne dass irgendetwas fehlschlüge.
    func testEveryKindProducesAPath() throws {
        for art in ShapeKind.allCases {
            let inhalt = ShapeLayerContent(kind: art, size: Size(width: 40, height: 30))
            XCTAssertNotNil(
                ShapePath.cgPath(for: inhalt, in: CGRect(x: 0, y: 0, width: 40, height: 30)),
                "\(art) liefert keinen Pfad"
            )
        }
    }

    func testEmptyRectHasNoPath() {
        let inhalt = ShapeLayerContent(kind: .star, size: Size(width: 0, height: 0))
        XCTAssertNil(ShapePath.cgPath(for: inhalt, in: .zero))
    }

    // MARK: - Rastern

    /// Beim Umwandeln in ein Objekt (aus missing.md) darf die Form nicht
    /// kippen. Bis hierher zeichnete `LayerFlattening` Formen selbst nach —
    /// bei senkrecht symmetrischen Formen unauffällig, bei einem Dreieck nicht.
    func testFlattenedTriangleKeepsItsOrientation() throws {
        let vorlage = triangleDocument()
        let document = AssemblageDocument()
        document.undoManager = UndoManager()
        document.modify("Vorbereiten") { $0 = vorlage }
        document.state.selectedLayerID = vorlage.layers[0].id

        XCTAssertTrue(LayerFlattening.flattenSelected(in: document.state))

        guard case .image = document.state.document.layers[0].content else {
            return XCTFail("nach dem Umwandeln müsste eine Bildebene stehen")
        }

        // Dieselben drei Stellen wie beim Export der Vektorform: Das Rastern
        // darf an der sichtbaren Form nichts ändern.
        let bild = try DocumentExporter.renderedImage(
            of: document.state.document,
            resources: document.state.resources,
            targetSize: CGSize(width: 100, height: 100)
        )
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(bild, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        let z = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        func deckung(x: Int, y: Int) -> Int { Int(z[(y * 100 + x) * 4 + 3]) }

        XCTAssertGreaterThan(deckung(x: 50, y: 16), 150, "unter der Spitze müsste Farbe sein")
        XCTAssertLessThan(deckung(x: 14, y: 16), 60, "oben aussen müsste es leer sein")
        XCTAssertGreaterThan(deckung(x: 14, y: 86), 150, "unten aussen müsste die Basis liegen")
    }
}
