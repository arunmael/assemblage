import XCTest
@testable import AssemblageModel

/// Zuschneiden pro Ebene (Plan 5.3), nicht-destruktiv: Das Original bleibt
/// unangetastet, nur der sichtbare Ausschnitt ändert sich.
///
/// Der springende Punkt ist die Ankopplung an die Transformation. Eine Ebene
/// wird über ihren Mittelpunkt platziert — und der Mittelpunkt eines
/// Ausschnitts ist ein anderer als der des ganzen Bildes. Ändert man den
/// Zuschnitt, ohne den Mittelpunkt nachzuführen, springt das Bild unter dem
/// Zeiger weg, statt dass sich nur die Kante bewegt.
final class CropTests: XCTestCase {

    private let bild = Size(width: 400, height: 300)

    private func bildebene(crop: Rect? = nil, transform: Transform2D = Transform2D(x: 200, y: 200)) -> Layer {
        Layer(
            name: "Foto",
            transform: transform,
            content: .image(ImageLayerContent(originalFileReference: "originals/a.png", cropRect: crop))
        )
    }

    private func crop(of layer: Layer) -> Rect? {
        guard case .image(let inhalt) = layer.content else { return nil }
        return inhalt.cropRect
    }

    // MARK: - Ausgangszustand

    /// Ohne Zuschnitt ist der Ausschnitt das ganze Bild — das braucht der
    /// Canvas, um beim Betreten des Zuschneiden-Modus einen Rahmen zeigen zu
    /// können.
    func testEffectiveCropOfAnUncroppedLayerIsTheWholeImage() {
        let ebene = bildebene()

        XCTAssertEqual(
            ebene.effectiveCrop(imageSize: bild),
            Rect(x: 0, y: 0, width: 400, height: 300)
        )
    }

    func testEffectiveCropReturnsTheStoredCrop() {
        let ebene = bildebene(crop: Rect(x: 50, y: 20, width: 200, height: 100))

        XCTAssertEqual(
            ebene.effectiveCrop(imageSize: bild),
            Rect(x: 50, y: 20, width: 200, height: 100)
        )
    }

    /// Eine Text- oder Formebene lässt sich nicht zuschneiden — dort gibt es
    /// kein Original, das man beschneiden könnte.
    func testNonImageLayersHaveNoCrop() {
        let text = Layer(name: "T", content: .text(TextLayerContent(string: "x")))

        XCTAssertNil(text.effectiveCrop(imageSize: bild))
    }

    // MARK: - Zuschnitt ändern

    /// Der Kern: Nach dem Beschneiden muss dieselbe Bildstelle noch an
    /// derselben Stelle der Leinwand liegen.
    func testChangingTheCropKeepsTheImageInPlace() throws {
        let ebene = bildebene()  // Mittelpunkt 200/200, Bild 400×300, Skalierung 1

        // Links 100 Punkte wegschneiden.
        let beschnitten = ebene.cropped(to: Rect(x: 100, y: 0, width: 300, height: 300), imageSize: bild)

        XCTAssertEqual(crop(of: beschnitten), Rect(x: 100, y: 0, width: 300, height: 300))
        // Der Mittelpunkt des Ausschnitts liegt im Bild 50 Punkte weiter
        // rechts als der des ganzen Bildes — also wandert die Ebene um 50
        // nach rechts, damit das Bild selbst stehen bleibt.
        XCTAssertEqual(beschnitten.transform.x, 250, accuracy: 0.001)
        XCTAssertEqual(beschnitten.transform.y, 200, accuracy: 0.001)
    }

    func testCropAdjustmentRespectsScale() {
        let ebene = bildebene(transform: Transform2D(x: 200, y: 200, scaleX: 2, scaleY: 2))

        let beschnitten = ebene.cropped(to: Rect(x: 100, y: 0, width: 300, height: 300), imageSize: bild)

        // Derselbe Versatz von 50 Bildpunkten, aber doppelt skaliert.
        XCTAssertEqual(beschnitten.transform.x, 300, accuracy: 0.001)
    }

    /// Bei einer gedrehten Ebene muss der Ausgleich entlang der **gedrehten**
    /// Achse laufen, sonst rutscht das Bild schräg weg.
    func testCropAdjustmentFollowsRotation() {
        let ebene = bildebene(transform: Transform2D(x: 200, y: 200, rotationDegrees: 90))

        let beschnitten = ebene.cropped(to: Rect(x: 100, y: 0, width: 300, height: 300), imageSize: bild)

        // 90° im Uhrzeigersinn: aus „nach rechts" wird „nach unten".
        XCTAssertEqual(beschnitten.transform.x, 200, accuracy: 0.001)
        XCTAssertEqual(beschnitten.transform.y, 250, accuracy: 0.001)
    }

    // MARK: - Grenzen

    /// Der Zuschnitt darf nicht über das Bild hinausreichen — dahinter sind
    /// keine Pixel, es entstünde ein durchsichtiger Rand.
    func testCropIsClampedToTheImage() {
        let ebene = bildebene()

        let beschnitten = ebene.cropped(to: Rect(x: -50, y: -50, width: 900, height: 900), imageSize: bild)

        // Geprüft wird der *wirksame* Ausschnitt: Deckt er wieder das ganze
        // Bild, wird bewusst gar keiner gespeichert (siehe
        // testFullCoverageClearsTheCrop).
        XCTAssertEqual(
            beschnitten.effectiveCrop(imageSize: bild),
            Rect(x: 0, y: 0, width: 400, height: 300)
        )
    }

    /// Ein auf null geschrumpfter Ausschnitt wäre unsichtbar und nicht mehr
    /// aufzuziehen.
    func testCropCannotCollapseToNothing() throws {
        let ebene = bildebene()

        let beschnitten = ebene.cropped(to: Rect(x: 200, y: 150, width: 0, height: 0), imageSize: bild)
        let ergebnis = try XCTUnwrap(crop(of: beschnitten))

        XCTAssertGreaterThan(ergebnis.width, 0)
        XCTAssertGreaterThan(ergebnis.height, 0)
    }

    /// Negative Ausdehnung (Griff über die gegenüberliegende Kante gezogen)
    /// wird zu einem gültigen Rechteck begradigt, statt Unsinn zu speichern.
    func testCropWithNegativeExtentIsNormalised() throws {
        let ebene = bildebene()

        let beschnitten = ebene.cropped(to: Rect(x: 300, y: 200, width: -100, height: -50), imageSize: bild)
        let ergebnis = try XCTUnwrap(crop(of: beschnitten))

        XCTAssertEqual(ergebnis, Rect(x: 200, y: 150, width: 100, height: 50))
    }

    /// Zuschnitt zurücknehmen: Deckt der Ausschnitt wieder das ganze Bild,
    /// wird gar kein Zuschnitt gespeichert — das hält die document.json
    /// schlank und macht „unbeschnitten" eindeutig erkennbar.
    func testFullCoverageClearsTheCrop() {
        let ebene = bildebene(crop: Rect(x: 50, y: 50, width: 100, height: 100))

        let zurueck = ebene.cropped(to: Rect(x: 0, y: 0, width: 400, height: 300), imageSize: bild)

        XCTAssertNil(crop(of: zurueck))
    }

    func testCroppingANonImageLayerChangesNothing() {
        let text = Layer(name: "T", content: .text(TextLayerContent(string: "x")))

        let unveraendert = text.cropped(to: Rect(x: 0, y: 0, width: 10, height: 10), imageSize: bild)

        XCTAssertEqual(unveraendert, text)
    }
}

/// Die beiden Umrechnungen, die der Zuschneiden-Modus auf dem Canvas braucht.
final class CropInteractionTests: XCTestCase {

    private let bild = Size(width: 400, height: 300)

    private func bildebene(crop: Rect? = nil, transform: Transform2D = Transform2D(x: 200, y: 200)) -> Layer {
        Layer(
            name: "Foto",
            transform: transform,
            content: .image(ImageLayerContent(originalFileReference: "originals/a.png", cropRect: crop))
        )
    }

    // MARK: - Leinwandpunkt in Bildkoordinaten

    /// Beim Ziehen eines Zuschnitt-Griffs kommt ein Punkt auf der Leinwand
    /// herein; gebraucht wird die Stelle im Bild, auf die er zeigt.
    func testCanvasPointMapsToImagePixel() throws {
        let ebene = bildebene()  // Bild 400×300 mittig auf 200/200, Skalierung 1

        let mitte = try XCTUnwrap(ebene.imagePoint(forCanvasPoint: Point(x: 200, y: 200), imageSize: bild))
        XCTAssertEqual(mitte.x, 200, accuracy: 0.001)
        XCTAssertEqual(mitte.y, 150, accuracy: 0.001)

        let obenLinks = try XCTUnwrap(ebene.imagePoint(forCanvasPoint: Point(x: 0, y: 50), imageSize: bild))
        XCTAssertEqual(obenLinks.x, 0, accuracy: 0.001)
        XCTAssertEqual(obenLinks.y, 0, accuracy: 0.001)
    }

    func testCanvasPointMappingAccountsForScale() throws {
        let ebene = bildebene(transform: Transform2D(x: 0, y: 0, scaleX: 2, scaleY: 2))

        let punkt = try XCTUnwrap(ebene.imagePoint(forCanvasPoint: Point(x: 100, y: 0), imageSize: bild))

        XCTAssertEqual(punkt.x, 250, accuracy: 0.001, "100 Leinwandpunkte sind bei doppelter Skalierung 50 Bildpunkte")
    }

    func testCanvasPointMappingAccountsForRotation() throws {
        let ebene = bildebene(transform: Transform2D(x: 0, y: 0, rotationDegrees: 90))

        // 90° im Uhrzeigersinn: „nach unten" auf der Leinwand ist „nach
        // rechts" im Bild.
        let punkt = try XCTUnwrap(ebene.imagePoint(forCanvasPoint: Point(x: 0, y: 100), imageSize: bild))

        XCTAssertEqual(punkt.x, 300, accuracy: 0.001)
        XCTAssertEqual(punkt.y, 150, accuracy: 0.001)
    }

    /// Bei bereits beschnittener Ebene muss weiterhin auf das **ganze** Bild
    /// abgebildet werden — sonst könnte man den Zuschnitt nie wieder aufziehen.
    func testMappingUsesTheWholeImageEvenWhenCropped() throws {
        let ebene = bildebene(crop: Rect(x: 100, y: 0, width: 200, height: 300),
                              transform: Transform2D(x: 200, y: 200))

        // Mittelpunkt der Ebene ist jetzt die Mitte des Ausschnitts: Bild-x 200.
        let punkt = try XCTUnwrap(ebene.imagePoint(forCanvasPoint: Point(x: 200, y: 200), imageSize: bild))

        XCTAssertEqual(punkt.x, 200, accuracy: 0.001)
        XCTAssertEqual(punkt.y, 150, accuracy: 0.001)
    }

    func testMappingIsNilForNonImageLayers() {
        let text = Layer(name: "T", content: .text(TextLayerContent(string: "x")))

        XCTAssertNil(text.imagePoint(forCanvasPoint: .zero, imageSize: bild))
    }

    // MARK: - Kante verschieben

    func testAdjustingASingleEdge() {
        let rechteck = Rect(x: 0, y: 0, width: 100, height: 100)

        XCTAssertEqual(
            rechteck.adjusted(handle: .left, to: Point(x: 30, y: 999)),
            Rect(x: 30, y: 0, width: 70, height: 100)
        )
        XCTAssertEqual(
            rechteck.adjusted(handle: .bottom, to: Point(x: 999, y: 60)),
            Rect(x: 0, y: 0, width: 100, height: 60)
        )
    }

    func testAdjustingACornerMovesBothEdges() {
        let rechteck = Rect(x: 0, y: 0, width: 100, height: 100)

        XCTAssertEqual(
            rechteck.adjusted(handle: .topRight, to: Point(x: 80, y: 20)),
            Rect(x: 0, y: 20, width: 80, height: 80)
        )
    }

    /// Über die gegenüberliegende Kante hinausgezogen ergibt ein Rechteck mit
    /// negativer Ausdehnung — `cropped(to:)` begradigt das anschliessend.
    func testAdjustingPastTheOppositeEdgeIsAllowedAndNormalisable() {
        let rechteck = Rect(x: 0, y: 0, width: 100, height: 100)

        let gezogen = rechteck.adjusted(handle: .left, to: Point(x: 150, y: 0))

        XCTAssertEqual(gezogen.normalized, Rect(x: 100, y: 0, width: 50, height: 100))
    }
}
