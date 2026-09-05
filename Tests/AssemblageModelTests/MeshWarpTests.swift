import XCTest
@testable import AssemblageModel

/// Die Acht-Punkt-Verzerrung (aus Anpassungen.md: „8 Punkte … alle Eckpunkte
/// und alle Mitten einer Seite") baut auf den Serendipity-Q8-Formfunktionen
/// auf. Diese Tests weisen ihre beiden entscheidenden Eigenschaften direkt
/// nach, statt sie nur zu behaupten:
///
/// 1. Sie interpolieren exakt durch alle acht Stützpunkte (keine Näherung).
/// 2. Stehen alle vier Kantenmitten auf ihrem linearen Platz, reduziert sich
///    die Fläche exakt auf die bisherige, bilineare Vier-Ecken-Abbildung —
///    ein bestehendes Dokument mit reiner Eckenverzerrung sieht danach genau
///    gleich aus.
final class MeshWarpTests: XCTestCase {

    private func assertNear(_ a: Point, _ b: Point, accuracy: Double = 1e-9, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, message, file: file, line: line)
    }

    /// Referenz: dieselbe bilineare Rechnung wie die bestehende
    /// Vier-Ecken-Homographie, unabhängig von `MeshWarp` neu geschrieben,
    /// damit ein Fehler in `MeshWarp` nicht zufällig gegen sich selbst
    /// getestet wird.
    private func bilinear(xi: Double, eta: Double, halfWidth: Double, halfHeight: Double, distortion: QuadDistortion) -> Point {
        let corners: [(DistortHandle, Double, Double)] = [
            (.topLeft, -1, -1), (.topRight, 1, -1), (.bottomRight, 1, 1), (.bottomLeft, -1, 1)
        ]
        var x = 0.0
        var y = 0.0
        for (handle, hxi, heta) in corners {
            let gewicht = 0.25 * (1 + xi * hxi) * (1 + eta * heta)
            let versatz = distortion.offset(at: handle)
            x += gewicht * (hxi * halfWidth + versatz.x)
            y += gewicht * (heta * halfHeight + versatz.y)
        }
        return Point(x: x, y: y)
    }

    // MARK: - Interpolationsgenauigkeit

    /// Eine Ecke liegt exakt bei ihrer Rechteckposition plus eigenem Versatz
    /// — unverändert zur bisherigen Vier-Ecken-Logik. Eine Kantenmitte liegt
    /// exakt bei der linearen Mitte ihrer beiden (schon verschobenen)
    /// Nachbarecken plus ihrem eigenen Versatz — das ist der Vertrag aus dem
    /// Typkommentar: Versatz `.zero` heisst „auf der linearen Kante", auch
    /// wenn die Nachbarecken selbst schon verzogen sind.
    func testShapeFunctionsInterpolateExactlyThroughEveryNode() {
        let distortion = QuadDistortion(
            topLeft: Point(x: 3, y: -2),
            topRight: Point(x: -1, y: 4),
            bottomRight: Point(x: 5, y: 1),
            bottomLeft: Point(x: -2, y: -3),
            topMid: Point(x: 0, y: -8),
            rightMid: Point(x: 6, y: 0),
            bottomMid: Point(x: 1, y: 7),
            leftMid: Point(x: -4, y: 2)
        )
        let halfWidth = 50.0, halfHeight = 30.0

        func eckposition(_ ecke: DistortHandle) -> Point {
            let (xi, eta) = ecke.naturalCoordinate
            let versatz = distortion.offset(at: ecke)
            return Point(x: xi * halfWidth + versatz.x, y: eta * halfHeight + versatz.y)
        }
        let topLeft = eckposition(.topLeft)
        let topRight = eckposition(.topRight)
        let bottomRight = eckposition(.bottomRight)
        let bottomLeft = eckposition(.bottomLeft)

        let erwartungen: [DistortHandle: Point] = [
            .topLeft: topLeft, .topRight: topRight, .bottomRight: bottomRight, .bottomLeft: bottomLeft,
            .topMid: Point(
                x: (topLeft.x + topRight.x) / 2 + distortion.topMid.x,
                y: (topLeft.y + topRight.y) / 2 + distortion.topMid.y
            ),
            .rightMid: Point(
                x: (topRight.x + bottomRight.x) / 2 + distortion.rightMid.x,
                y: (topRight.y + bottomRight.y) / 2 + distortion.rightMid.y
            ),
            .bottomMid: Point(
                x: (bottomRight.x + bottomLeft.x) / 2 + distortion.bottomMid.x,
                y: (bottomRight.y + bottomLeft.y) / 2 + distortion.bottomMid.y
            ),
            .leftMid: Point(
                x: (bottomLeft.x + topLeft.x) / 2 + distortion.leftMid.x,
                y: (bottomLeft.y + topLeft.y) / 2 + distortion.leftMid.y
            )
        ]

        for handle in DistortHandle.allCases {
            let (xi, eta) = handle.naturalCoordinate
            let ergebnis = MeshWarp.position(
                xi: xi, eta: eta, halfWidth: halfWidth, halfHeight: halfHeight, distortion: distortion
            )
            assertNear(ergebnis, erwartungen[handle]!, "Knoten \(handle) muss exakt getroffen werden")
        }
    }

    // MARK: - Reduktion auf die bisherige Vier-Ecken-Abbildung

    /// Die entscheidende Kompatibilitätsgarantie: Ohne Kantenmitten-Versatz
    /// verhält sich die neue Mathematik überall auf der Fläche identisch zur
    /// alten, unabhängig nachgerechneten bilinearen Abbildung — nicht nur an
    /// den acht Knoten.
    func testReducesToTheExistingFourCornerMappingWhenMidpointsAreZero() {
        let distortion = QuadDistortion(
            topLeft: Point(x: 12, y: -7),
            topRight: Point(x: -5, y: 9),
            bottomRight: Point(x: 3, y: 4),
            bottomLeft: Point(x: -8, y: -2)
        )
        let halfWidth = 80.0, halfHeight = 45.0
        XCTAssertFalse(distortion.hasCurvedEdges)

        let stichproben: [(Double, Double)] = [
            (-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0),
            (0, 0), (0.37, -0.62), (-0.9, 0.15), (0.5, 0.5)
        ]
        for (xi, eta) in stichproben {
            let erwartet = bilinear(xi: xi, eta: eta, halfWidth: halfWidth, halfHeight: halfHeight, distortion: distortion)
            let ergebnis = MeshWarp.position(
                xi: xi, eta: eta, halfWidth: halfWidth, halfHeight: halfHeight, distortion: distortion
            )
            assertNear(ergebnis, erwartet, accuracy: 1e-9, "(ξ=\(xi), η=\(eta)) muss der bilinearen Fläche entsprechen")
        }
    }

    func testIdentityDistortionMapsToTheFlatRectangle() {
        let halfWidth = 60.0, halfHeight = 40.0
        for (xi, eta) in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0), (0.0, 0.0), (0.3, -0.8)] {
            let ergebnis = MeshWarp.position(
                xi: xi, eta: eta, halfWidth: halfWidth, halfHeight: halfHeight, distortion: .identity
            )
            assertNear(ergebnis, Point(x: xi * halfWidth, y: eta * halfHeight))
        }
    }

    // MARK: - Echte Krümmung

    /// Ein einzeln verschobener Kantenmittelpunkt darf **nur** seine eigene
    /// Kante beeinflussen — die gegenüberliegende Kante bleibt exakt gerade.
    func testMovingOneEdgeMidpointOnlyBendsItsOwnEdge() {
        let distortion = QuadDistortion(topMid: Point(x: 0, y: -20))
        XCTAssertTrue(distortion.hasCurvedEdges)
        let halfWidth = 50.0, halfHeight = 50.0

        // Obere Kante (η = -1): in der Mitte deutlich nach oben gewölbt.
        let obenMitte = MeshWarp.position(xi: 0, eta: -1, halfWidth: halfWidth, halfHeight: halfHeight, distortion: distortion)
        assertNear(obenMitte, Point(x: 0, y: -70))

        // Untere Kante (η = 1) bleibt exakt auf der unverzerrten Geraden,
        // für jedes ξ entlang der Kante.
        for xi in [-1.0, -0.5, 0.0, 0.5, 1.0] {
            let punkt = MeshWarp.position(xi: xi, eta: 1, halfWidth: halfWidth, halfHeight: halfHeight, distortion: distortion)
            assertNear(punkt, Point(x: xi * halfWidth, y: halfHeight), "untere Kante bei ξ=\(xi) muss gerade bleiben")
        }

        // Linke und rechte Kante bleiben an ihren unteren Endpunkten fix.
        let linksUnten = MeshWarp.position(xi: -1, eta: 1, halfWidth: halfWidth, halfHeight: halfHeight, distortion: distortion)
        assertNear(linksUnten, Point(x: -halfWidth, y: halfHeight))
    }

    // MARK: - Gitterzerlegung

    func testGridCornersMatchTheFourCornerNodesExactly() {
        let distortion = QuadDistortion(
            topLeft: Point(x: 4, y: -1), topRight: Point(x: -2, y: 3),
            bottomRight: Point(x: 1, y: 2), bottomLeft: Point(x: -3, y: -4)
        )
        let halfWidth = 20.0, halfHeight = 10.0
        let gitter = MeshWarp.grid(resolution: 4, halfWidth: halfWidth, halfHeight: halfHeight, distortion: distortion)

        XCTAssertEqual(gitter.count, 5, "resolution + 1 Zeilen")
        XCTAssertEqual(gitter[0].count, 5, "resolution + 1 Spalten")

        assertNear(gitter[0][0], Point(x: -halfWidth + distortion.topLeft.x, y: -halfHeight + distortion.topLeft.y))
        assertNear(gitter[0][4], Point(x: halfWidth + distortion.topRight.x, y: -halfHeight + distortion.topRight.y))
        assertNear(gitter[4][4], Point(x: halfWidth + distortion.bottomRight.x, y: halfHeight + distortion.bottomRight.y))
        assertNear(gitter[4][0], Point(x: -halfWidth + distortion.bottomLeft.x, y: halfHeight + distortion.bottomLeft.y))
    }

    func testGridWithCurvedEdgeIsMonotonicAlongTheBulgingEdge() {
        // Eine nach oben gewölbte Kante darf beim Durchlaufen von links nach
        // rechts nicht "einknicken" — y muss erst fallen (nach oben, da y
        // nach unten wächst) und dann wieder steigen, symmetrisch zur Mitte.
        let distortion = QuadDistortion(topMid: Point(x: 0, y: -30))
        let gitter = MeshWarp.grid(resolution: 8, halfWidth: 50, halfHeight: 50, distortion: distortion)
        let obereZeile = gitter[0].map(\.y)

        let mitteIndex = obereZeile.count / 2
        for i in 1...mitteIndex {
            XCTAssertLessThanOrEqual(obereZeile[i], obereZeile[i - 1], "muss zur Mitte hin weiter nach oben wölben")
        }
        for i in mitteIndex..<(obereZeile.count - 1) {
            XCTAssertGreaterThanOrEqual(obereZeile[i + 1], obereZeile[i], "muss nach der Mitte wieder absinken")
        }
    }
}
