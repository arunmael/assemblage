import XCTest
@testable import AssemblageModel

/// Trefferprüfung: Welche Ebene liegt unter dem Mauszeiger?
///
/// Reine Geometrie und deshalb hier im portablen Modell — der Canvas-Code
/// darf sich nicht selbst eine zweite, leicht abweichende Rechnung bauen.
/// Plan 4.3 verlangt direkte Manipulation; die fängt damit an, dass ein Klick
/// verlässlich die Ebene trifft, die man sieht.
final class HitTestingTests: XCTestCase {

    private let hundert = Size(width: 100, height: 100)

    // MARK: - Ohne Drehung

    func testPointInsideUnrotatedLayerHits() {
        let transform = Transform2D(x: 200, y: 200)

        XCTAssertTrue(transform.contains(Point(x: 200, y: 200), contentSize: hundert))
        XCTAssertTrue(transform.contains(Point(x: 155, y: 155), contentSize: hundert))
        XCTAssertTrue(transform.contains(Point(x: 245, y: 245), contentSize: hundert))
    }

    func testPointOutsideUnrotatedLayerMisses() {
        let transform = Transform2D(x: 200, y: 200)

        XCTAssertFalse(transform.contains(Point(x: 140, y: 200), contentSize: hundert))
        XCTAssertFalse(transform.contains(Point(x: 200, y: 260), contentSize: hundert))
    }

    /// Die Trefferfläche muss mit der Skalierung mitwachsen — sonst greift man
    /// bei einer vergrösserten Ebene ins Leere.
    func testHitAreaFollowsScale() {
        let transform = Transform2D(x: 200, y: 200, scaleX: 2, scaleY: 2)

        XCTAssertTrue(transform.contains(Point(x: 290, y: 200), contentSize: hundert))
        XCTAssertFalse(transform.contains(Point(x: 310, y: 200), contentSize: hundert))
    }

    /// Eine gespiegelte Ebene belegt dieselbe Fläche wie eine ungespiegelte —
    /// das Vorzeichen dreht nur den Inhalt.
    func testMirroredLayerCoversTheSameArea() {
        let normal = Transform2D(x: 200, y: 200, scaleX: 2, scaleY: 1)
        let gespiegelt = Transform2D(x: 200, y: 200, scaleX: -2, scaleY: 1)

        for x in stride(from: 100, through: 300, by: 10) {
            let punkt = Point(x: Double(x), y: 200)
            XCTAssertEqual(
                normal.contains(punkt, contentSize: hundert),
                gespiegelt.contains(punkt, contentSize: hundert),
                "bei x=\(x)"
            )
        }
    }

    // MARK: - Mit Drehung

    /// Der eigentliche Grund, warum das Rechnung und nicht Rechteckvergleich
    /// ist: Bei 45° liegen die Ecken des unrotierten Rahmens ausserhalb der
    /// Ebene, die Spitzen dafür weiter draussen.
    func testRotatedLayerHitsFollowTheRotation() {
        let transform = Transform2D(x: 200, y: 200, rotationDegrees: 45)

        // Die Ecke des unrotierten Rahmens liegt jetzt neben der Ebene …
        XCTAssertFalse(transform.contains(Point(x: 248, y: 248), contentSize: hundert))
        // … dafür reicht die gedrehte Ebene weiter nach rechts.
        XCTAssertTrue(transform.contains(Point(x: 265, y: 200), contentSize: hundert))
        XCTAssertFalse(transform.contains(Point(x: 275, y: 200), contentSize: hundert))
    }

    /// Positive Winkel drehen im Uhrzeigersinn (Ursprung oben links, y nach
    /// unten) — dieselbe Festlegung wie im Renderer.
    func testRotationDirectionIsClockwise() {
        // Schmaler, hoher Streifen, um 90° gedreht: liegt danach waagrecht.
        let transform = Transform2D(x: 200, y: 200, rotationDegrees: 90)
        let streifen = Size(width: 20, height: 200)

        XCTAssertTrue(transform.contains(Point(x: 280, y: 200), contentSize: streifen))
        XCTAssertFalse(transform.contains(Point(x: 200, y: 280), contentSize: streifen))
    }

    // MARK: - Randfälle

    /// Eine Ebene ohne Ausdehnung darf keinen Treffer melden, aber auch nicht
    /// in eine Division durch null laufen.
    func testZeroSizedLayerIsNeverHit() {
        let transform = Transform2D(x: 200, y: 200)

        XCTAssertFalse(transform.contains(Point(x: 200, y: 200), contentSize: .zero))
    }

    func testZeroScaleIsNeverHit() {
        let transform = Transform2D(x: 200, y: 200, scaleX: 0, scaleY: 0)

        XCTAssertFalse(transform.contains(Point(x: 200, y: 200), contentSize: hundert))
    }

    // MARK: - Auswahl im Dokument

    /// Ein Klick wählt die **oberste** Ebene unter dem Zeiger — nicht die
    /// erste gefundene. Sonst greift man bei einer Collage immer den
    /// Hintergrund statt des Fotos darauf.
    func testTopmostLayerWins() {
        let unten = Layer(name: "Unten", transform: Transform2D(x: 200, y: 200),
                          content: .shape(ShapeLayerContent(kind: .rectangle, size: hundert)))
        let oben = Layer(name: "Oben", transform: Transform2D(x: 200, y: 200),
                         content: .shape(ShapeLayerContent(kind: .rectangle, size: hundert)))
        let document = Document(canvas: CanvasSize(width: 400, height: 400), layers: [unten, oben])

        let treffer = document.topmostLayer(at: Point(x: 200, y: 200)) { _ in self.hundert }

        XCTAssertEqual(treffer?.id, oben.id)
    }

    /// Unsichtbare Ebenen sind nicht anklickbar — man sieht sie ja nicht.
    func testHiddenLayersAreNotSelectable() {
        let versteckt = Layer(name: "Versteckt", isVisible: false, transform: Transform2D(x: 200, y: 200),
                              content: .shape(ShapeLayerContent(kind: .rectangle, size: hundert)))
        let sichtbar = Layer(name: "Sichtbar", transform: Transform2D(x: 200, y: 200),
                             content: .shape(ShapeLayerContent(kind: .rectangle, size: hundert)))
        let document = Document(canvas: CanvasSize(width: 400, height: 400), layers: [sichtbar, versteckt])

        let treffer = document.topmostLayer(at: Point(x: 200, y: 200)) { _ in self.hundert }

        XCTAssertEqual(treffer?.id, sichtbar.id)
    }

    func testClickOnEmptyCanvasSelectsNothing() {
        let document = Document(
            canvas: CanvasSize(width: 400, height: 400),
            layers: [Layer(name: "A", transform: Transform2D(x: 100, y: 100),
                           content: .shape(ShapeLayerContent(kind: .rectangle, size: hundert)))]
        )

        XCTAssertNil(document.topmostLayer(at: Point(x: 350, y: 350)) { _ in self.hundert })
    }
}

/// Die vier Eckpunkte einer Ebene auf der Leinwand — der Canvas zeichnet
/// daraus den Auswahlrahmen. Muss dieselbe Drehung annehmen wie
/// `contains(_:contentSize:)`, sonst läge der Rahmen neben der Ebene.
final class LayerCornersTests: XCTestCase {

    private let hundert = Size(width: 100, height: 100)

    private func assertNear(_ a: Point, _ b: Point, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 0.001, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 0.001, message, file: file, line: line)
    }

    func testUnrotatedCornersMatchTheFrame() {
        let ecken = Transform2D(x: 200, y: 200).corners(contentSize: hundert)

        XCTAssertEqual(ecken.count, 4)
        assertNear(ecken[0], Point(x: 150, y: 150), "oben links")
        assertNear(ecken[1], Point(x: 250, y: 150), "oben rechts")
        assertNear(ecken[2], Point(x: 250, y: 250), "unten rechts")
        assertNear(ecken[3], Point(x: 150, y: 250), "unten links")
    }

    func testCornersFollowScale() {
        let ecken = Transform2D(x: 0, y: 0, scaleX: 2, scaleY: 0.5).corners(contentSize: hundert)

        assertNear(ecken[0], Point(x: -100, y: -25))
        assertNear(ecken[2], Point(x: 100, y: 25))
    }

    /// 90° im Uhrzeigersinn: Die Ecke oben links wandert nach oben rechts.
    func testCornersRotateClockwise() {
        let ecken = Transform2D(x: 0, y: 0, rotationDegrees: 90).corners(contentSize: hundert)

        assertNear(ecken[0], Point(x: 50, y: -50), "oben links landet oben rechts")
        assertNear(ecken[1], Point(x: 50, y: 50))
    }

    /// Der Zusammenhang, auf den es ankommt: Was innerhalb der Ecken liegt,
    /// muss auch die Trefferprüfung bestehen — sonst zeigt der Auswahlrahmen
    /// woanders hin, als der Klick trifft.
    func testCornersAgreeWithHitTesting() {
        let transform = Transform2D(x: 300, y: 200, scaleX: 1.5, scaleY: 0.8, rotationDegrees: 37)
        let ecken = transform.corners(contentSize: hundert)
        let mitte = Point(
            x: ecken.map(\.x).reduce(0, +) / 4,
            y: ecken.map(\.y).reduce(0, +) / 4
        )

        assertNear(mitte, Point(x: 300, y: 200), "der Schwerpunkt der Ecken ist der Mittelpunkt")

        for ecke in ecken {
            // Knapp innerhalb jeder Ecke, Richtung Mitte.
            let innen = Point(
                x: ecke.x + (mitte.x - ecke.x) * 0.02,
                y: ecke.y + (mitte.y - ecke.y) * 0.02
            )
            XCTAssertTrue(transform.contains(innen, contentSize: hundert), "knapp innerhalb einer Ecke")

            let aussen = Point(
                x: ecke.x - (mitte.x - ecke.x) * 0.02,
                y: ecke.y - (mitte.y - ecke.y) * 0.02
            )
            XCTAssertFalse(transform.contains(aussen, contentSize: hundert), "knapp ausserhalb einer Ecke")
        }
    }
}

/// Die achsenparallele Umschliessende einer Ebene.
///
/// Genau das erwarten die Ausrichtungshilfen: Sie rechnen mit `Rect` und
/// kennen keine Drehung (siehe Kopfkommentar in `AlignmentGuides.swift`).
final class BoundingFrameTests: XCTestCase {

    private let hundert = Size(width: 100, height: 100)

    func testUnrotatedBoundingFrameIsTheLayerItself() {
        let rahmen = Transform2D(x: 200, y: 200).boundingFrame(contentSize: hundert)

        XCTAssertEqual(rahmen, Rect(x: 150, y: 150, width: 100, height: 100))
    }

    /// Bei 45° wächst die Umschliessende auf das Wurzel-Zwei-fache — das ist
    /// der ganze Grund, warum es diese Funktion gibt.
    func testRotatedLayerHasALargerBoundingFrame() {
        let rahmen = Transform2D(x: 200, y: 200, rotationDegrees: 45).boundingFrame(contentSize: hundert)

        XCTAssertEqual(rahmen.width, 141.42, accuracy: 0.01)
        XCTAssertEqual(rahmen.height, 141.42, accuracy: 0.01)
        XCTAssertEqual(rahmen.x + rahmen.width / 2, 200, accuracy: 0.001, "bleibt mittig")
    }

    func testBoundingFrameFollowsScale() {
        let rahmen = Transform2D(x: 0, y: 0, scaleX: 2, scaleY: 0.5).boundingFrame(contentSize: hundert)

        XCTAssertEqual(rahmen.width, 200, accuracy: 0.001)
        XCTAssertEqual(rahmen.height, 50, accuracy: 0.001)
    }

    /// Eine 90°-Drehung vertauscht Breite und Höhe.
    func testNinetyDegreesSwapsWidthAndHeight() {
        let rahmen = Transform2D(x: 0, y: 0, rotationDegrees: 90)
            .boundingFrame(contentSize: Size(width: 200, height: 100))

        XCTAssertEqual(rahmen.width, 100, accuracy: 0.001)
        XCTAssertEqual(rahmen.height, 200, accuracy: 0.001)
    }
}
