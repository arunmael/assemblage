import XCTest
@testable import AssemblageModel

/// Tests zur Geometrie einer Ebene auf dem Canvas.
///
/// Koordinatensystem (Festlegung für die gesamte App): Ursprung **oben links**
/// der Leinwand, y wächst nach **unten** — wie in Photoshop/Figma und wie in
/// den Mockups aus `docs/mockups`. `Transform2D.x/y` bezeichnet den
/// **Mittelpunkt** der Ebene, nicht ihre obere linke Ecke; nur so bleiben
/// Rotation und Skalierung um die Bildmitte herum intuitiv (Plan 4.3
/// „Direkte Manipulation").
final class LayerGeometryTests: XCTestCase {

    // MARK: - Formebenen brauchen eine eigene Grösse

    /// Bild- und Textebenen leiten ihre Grösse aus dem Inhalt ab (Pixelmasse
    /// bzw. Textsatz). Eine Form hat keine solche natürliche Grösse — sie
    /// muss im Modell stehen, sonst ist sie nicht zeichenbar.
    func testShapeCarriesItsOwnSize() {
        let shape = ShapeLayerContent(kind: .rectangle, size: Size(width: 300, height: 200))

        XCTAssertEqual(shape.size, Size(width: 300, height: 200))
    }

    func testShapeSizeSurvivesEncodingRoundTrip() throws {
        let document = Document(
            preset: .instagramPost,
            layers: [
                Layer(
                    name: "Rahmen",
                    content: .shape(
                        ShapeLayerContent(
                            kind: .roundedRectangle,
                            size: Size(width: 120, height: 80),
                            cornerRadius: 12,
                            fillColorHex: "#FF0000"
                        )
                    )
                )
            ]
        )

        let restored = try DocumentPackage.decode(DocumentPackage.encode(document))

        XCTAssertEqual(restored, document)
    }

    // MARK: - Rahmen einer Ebene

    /// Der von der Ebene belegte Rahmen ergibt sich aus ihrer Inhaltsgrösse,
    /// der Skalierung und der Position des Mittelpunkts. Rotation bleibt
    /// bewusst aussen vor — das ist der *unrotierte* Rahmen, den der Renderer
    /// als `CALayer.bounds` setzt, bevor er die Rotation als Transform anlegt.
    func testUnrotatedFrameIsCenteredOnTransformPosition() {
        let transform = Transform2D(x: 500, y: 400)

        let frame = transform.unrotatedFrame(forContentSize: Size(width: 200, height: 100))

        XCTAssertEqual(frame, Rect(x: 400, y: 350, width: 200, height: 100))
    }

    func testUnrotatedFrameAppliesScale() {
        let transform = Transform2D(x: 0, y: 0, scaleX: 2, scaleY: 0.5)

        let frame = transform.unrotatedFrame(forContentSize: Size(width: 100, height: 100))

        XCTAssertEqual(frame, Rect(x: -100, y: -25, width: 200, height: 50))
    }

    /// Eine gespiegelte Ebene (negative Skalierung, Plan 5.5) darf keinen
    /// Rahmen mit negativer Breite erzeugen — der Renderer käme damit nicht
    /// zurecht, die Spiegelung steckt allein in der Transformationsmatrix.
    func testUnrotatedFrameStaysPositiveWhenMirrored() {
        let transform = Transform2D(x: 0, y: 0, scaleX: -2, scaleY: 1)

        let frame = transform.unrotatedFrame(forContentSize: Size(width: 100, height: 100))

        XCTAssertEqual(frame, Rect(x: -100, y: -50, width: 200, height: 100))
    }

    // MARK: - Anfangsplatzierung importierter Bilder

    /// Ein importiertes Foto soll die Leinwand füllen, ohne verzerrt oder
    /// grösser als nötig zu sein (Plan 5.1). Ein Hochformat-Foto auf einem
    /// quadratischen Canvas wird also auf die Höhe eingepasst.
    func testInitialTransformFitsContentIntoCanvas() {
        let transform = Transform2D.fitting(
            contentSize: Size(width: 2000, height: 4000),
            into: CanvasSize(width: 1080, height: 1080)
        )

        XCTAssertEqual(transform.x, 540, accuracy: 0.0001)
        XCTAssertEqual(transform.y, 540, accuracy: 0.0001)
        XCTAssertEqual(transform.scaleX, 0.27, accuracy: 0.0001)
        XCTAssertEqual(transform.scaleY, 0.27, accuracy: 0.0001)
        XCTAssertEqual(transform.rotationDegrees, 0, accuracy: 0.0001)
    }

    /// Ein Bild, das kleiner als die Leinwand ist, wird nicht hochskaliert —
    /// das würde es sichtbar unscharf machen.
    func testInitialTransformDoesNotUpscaleSmallContent() {
        let transform = Transform2D.fitting(
            contentSize: Size(width: 200, height: 100),
            into: CanvasSize(width: 1080, height: 1080)
        )

        XCTAssertEqual(transform.scaleX, 1, accuracy: 0.0001)
        XCTAssertEqual(transform.scaleY, 1, accuracy: 0.0001)
    }

    /// Ein leeres/kaputtes Bild (Grösse 0) darf keine Division durch null und
    /// damit kein NaN in der Transformation erzeugen (Plan 2.1).
    func testInitialTransformSurvivesZeroSizedContent() {
        let transform = Transform2D.fitting(
            contentSize: Size(width: 0, height: 0),
            into: CanvasSize(width: 1080, height: 1080)
        )

        XCTAssertFalse(transform.scaleX.isNaN)
        XCTAssertFalse(transform.scaleY.isNaN)
        XCTAssertEqual(transform.scaleX, 1, accuracy: 0.0001)
    }
}
