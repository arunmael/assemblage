import XCTest
@testable import AssemblageModel

/// Freies Verziehen einer Ebene: die vier Ecken lassen sich unabhängig
/// voneinander bewegen.
///
/// `Transform2D` kann das nicht und soll es auch nicht können — es beschreibt
/// Position, Skalierung und Drehung, also eine Ähnlichkeitsabbildung. Ein
/// verzogenes Viereck ist etwas anderes: eine projektive Abbildung. Beides zu
/// vermischen würde jede bestehende Rechnung verkomplizieren, deshalb liegt
/// die Verzerrung als eigene, **optionale** Angabe daneben. Ebenen ohne sie
/// verhalten sich exakt wie bisher.
final class DistortionTests: XCTestCase {

    private let hundert = Size(width: 100, height: 100)

    private func assertNear(_ a: Point, _ b: Point, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 0.001, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 0.001, message, file: file, line: line)
    }

    // MARK: - Neutralzustand

    /// Ohne Versatz muss das Ergebnis exakt dem unverzerrten Rahmen
    /// entsprechen — sonst würde allein das Einschalten des Werkzeugs die
    /// Ebene verschieben.
    func testIdentityDistortionMatchesTheUndistortedCorners() {
        let transform = Transform2D(x: 200, y: 200)
        let ohne = transform.corners(contentSize: hundert)
        let mit = transform.corners(contentSize: hundert, distortion: .identity)

        for (a, b) in zip(ohne, mit) { assertNear(a, b) }
    }

    func testIdentityIsRecognisedAsSuch() {
        XCTAssertTrue(QuadDistortion.identity.isIdentity)
        XCTAssertFalse(QuadDistortion(topLeft: Point(x: 1, y: 0)).isIdentity)
    }

    /// Eine Ebene ohne Verzerrung soll gar keine speichern — das hält die
    /// document.json schlank und macht „unverzerrt" eindeutig erkennbar.
    func testLayerWithoutDistortionStoresNone() throws {
        let ebene = Layer(name: "A", content: .shape(ShapeLayerContent(kind: .rectangle, size: hundert)))
        XCTAssertNil(ebene.distortion)

        let wieder = try DocumentPackage.decode(
            DocumentPackage.encode(Document(canvas: hundert, layers: [ebene]))
        )
        XCTAssertNil(wieder.layers.first?.distortion)
    }

    func testDistortionSurvivesEncoding() throws {
        var ebene = Layer(name: "A", content: .shape(ShapeLayerContent(kind: .rectangle, size: hundert)))
        ebene.distortion = QuadDistortion(
            topLeft: Point(x: 5, y: -3),
            topRight: Point(x: -2, y: 8),
            bottomRight: Point(x: 1, y: 1),
            bottomLeft: Point(x: 0, y: -4)
        )

        let wieder = try DocumentPackage.decode(
            DocumentPackage.encode(Document(canvas: hundert, layers: [ebene]))
        )
        XCTAssertEqual(wieder.layers.first?.distortion, ebene.distortion)
    }

    // MARK: - Ecken verschieben

    /// Der Versatz gilt im **ungedrehten** Koordinatensystem der Ebene, damit
    /// sich das Ziehen an einer gedrehten Ebene entlang ihrer eigenen Achsen
    /// anfühlt — dieselbe Festlegung wie beim Skalieren.
    func testMovingOneCornerLeavesTheOthersInPlace() {
        let transform = Transform2D(x: 200, y: 200)
        let verzerrt = QuadDistortion(topLeft: Point(x: -20, y: -30))

        let ecken = transform.corners(contentSize: hundert, distortion: verzerrt)

        assertNear(ecken[0], Point(x: 130, y: 120), "die gezogene Ecke")
        assertNear(ecken[1], Point(x: 250, y: 150), "oben rechts bleibt")
        assertNear(ecken[2], Point(x: 250, y: 250), "unten rechts bleibt")
        assertNear(ecken[3], Point(x: 150, y: 250), "unten links bleibt")
    }

    func testDistortionFollowsScale() {
        let transform = Transform2D(x: 0, y: 0, scaleX: 2, scaleY: 2)
        let verzerrt = QuadDistortion(topLeft: Point(x: -10, y: 0))

        let ecken = transform.corners(contentSize: hundert, distortion: verzerrt)

        // Ohne Verzerrung läge die Ecke bei -100; der Versatz ist im
        // Inhaltsmass angegeben und wird mitskaliert.
        assertNear(ecken[0], Point(x: -120, y: -100))
    }

    func testDistortionFollowsRotation() {
        let transform = Transform2D(x: 0, y: 0, rotationDegrees: 90)
        let verzerrt = QuadDistortion(topLeft: Point(x: 0, y: -10))

        let ecken = transform.corners(contentSize: hundert, distortion: verzerrt)

        // 90° im Uhrzeigersinn: „nach oben" im Ebenensystem zeigt auf der
        // Leinwand nach rechts.
        assertNear(ecken[0], Point(x: 60, y: -50))
    }

    // MARK: - Trefferprüfung

    /// Eine verzogene Ebene muss dort getroffen werden, wo sie liegt — nicht
    /// dort, wo ihr ursprüngliches Rechteck war.
    func testHitTestingFollowsTheDistortedQuad() {
        let transform = Transform2D(x: 200, y: 200)
        // Obere Kante stark nach innen gezogen: ein Trapez.
        let verzerrt = QuadDistortion(
            topLeft: Point(x: 40, y: 0),
            topRight: Point(x: -40, y: 0)
        )

        XCTAssertTrue(transform.contains(Point(x: 200, y: 160), contentSize: hundert, distortion: verzerrt),
                      "in der Mitte der schmalen Oberkante")
        XCTAssertFalse(transform.contains(Point(x: 160, y: 155), contentSize: hundert, distortion: verzerrt),
                       "links davon liegt jetzt nichts mehr")
        XCTAssertTrue(transform.contains(Point(x: 160, y: 240), contentSize: hundert, distortion: verzerrt),
                      "unten ist die Ebene noch breit")
    }

    /// Ohne Verzerrung muss die Trefferprüfung genau das Alte tun.
    func testHitTestingWithoutDistortionIsUnchanged() {
        let transform = Transform2D(x: 200, y: 200, rotationDegrees: 30)

        for x in stride(from: 120.0, through: 280.0, by: 8) {
            for y in stride(from: 120.0, through: 280.0, by: 8) {
                let punkt = Point(x: x, y: y)
                XCTAssertEqual(
                    transform.contains(punkt, contentSize: hundert),
                    transform.contains(punkt, contentSize: hundert, distortion: .identity),
                    "bei \(x)/\(y)"
                )
            }
        }
    }

    /// Ein zu einem überschlagenen Viereck gezogener Umriss darf die
    /// Trefferprüfung nicht in eine Endlosschleife oder NaN treiben.
    func testSelfCrossingQuadDoesNotBreakHitTesting() {
        let transform = Transform2D(x: 200, y: 200)
        let ueberschlagen = QuadDistortion(
            topLeft: Point(x: 200, y: 200),
            bottomRight: Point(x: -200, y: -200)
        )

        // Kein Absturz, kein Hänger — welches Ergebnis herauskommt, ist bei
        // einem überschlagenen Viereck nicht sinnvoll festzulegen.
        _ = transform.contains(Point(x: 200, y: 200), contentSize: hundert, distortion: ueberschlagen)
    }

    // MARK: - Begrenzung

    /// Die Umschliessende einer verzogenen Ebene muss das Viereck umfassen —
    /// die Ausrichtungshilfen rechnen damit.
    func testBoundingFrameCoversTheDistortedQuad() {
        let transform = Transform2D(x: 200, y: 200)
        let verzerrt = QuadDistortion(topLeft: Point(x: -50, y: -50))

        let rahmen = transform.boundingFrame(contentSize: hundert, distortion: verzerrt)

        XCTAssertEqual(rahmen.x, 100, accuracy: 0.001)
        XCTAssertEqual(rahmen.y, 100, accuracy: 0.001)
        XCTAssertEqual(rahmen.width, 150, accuracy: 0.001)
        XCTAssertEqual(rahmen.height, 150, accuracy: 0.001)
    }
}
