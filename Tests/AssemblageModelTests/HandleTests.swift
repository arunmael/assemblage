import XCTest
@testable import AssemblageModel

/// Griffpunkte zum Skalieren und Drehen (Plan 4.3: direkte Manipulation).
///
/// Die Rechnung liegt im portablen Modell, nicht im Canvas: Sie ist der
/// heikelste Teil der Interaktion — an einer gedrehten Ebene zu ziehen heisst,
/// in einem gedrehten Koordinatensystem zu rechnen — und genau so etwas will
/// man prüfen können, ohne die Maus zu bewegen.
final class HandleTests: XCTestCase {

    private let hundert = Size(width: 100, height: 100)

    private func assertNear(_ a: Point, _ b: Point, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 0.001, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 0.001, message, file: file, line: line)
    }

    // MARK: - Wo die Griffe sitzen

    func testHandlesSitOnTheEdgesAndCorners() {
        let transform = Transform2D(x: 200, y: 200)

        assertNear(transform.position(of: .topLeft, contentSize: hundert), Point(x: 150, y: 150))
        assertNear(transform.position(of: .top, contentSize: hundert), Point(x: 200, y: 150))
        assertNear(transform.position(of: .topRight, contentSize: hundert), Point(x: 250, y: 150))
        assertNear(transform.position(of: .right, contentSize: hundert), Point(x: 250, y: 200))
        assertNear(transform.position(of: .bottomRight, contentSize: hundert), Point(x: 250, y: 250))
        assertNear(transform.position(of: .bottom, contentSize: hundert), Point(x: 200, y: 250))
        assertNear(transform.position(of: .bottomLeft, contentSize: hundert), Point(x: 150, y: 250))
        assertNear(transform.position(of: .left, contentSize: hundert), Point(x: 150, y: 200))
    }

    func testHandlesRotateWithTheLayer() {
        let transform = Transform2D(x: 0, y: 0, rotationDegrees: 90)

        // Im Uhrzeigersinn: der Griff oben wandert nach rechts.
        assertNear(transform.position(of: .top, contentSize: hundert), Point(x: 50, y: 0))
    }

    /// Der Drehgriff sitzt ausserhalb der Ebene, damit er nicht mit dem
    /// Eckgriff kollidiert — bei Fingerbedienung über Sidecar wäre das sonst
    /// eine sichere Quelle für Fehltipper (Plan 2.2).
    func testRotationHandleSitsOutsideTheLayer() {
        let transform = Transform2D(x: 200, y: 200)

        let griff = transform.rotationHandlePosition(contentSize: hundert, distance: 30)

        assertNear(griff, Point(x: 200, y: 120), "30 Punkte über der Oberkante")
    }

    // MARK: - Griff unter dem Zeiger

    func testHandleUnderPointIsFound() {
        let transform = Transform2D(x: 200, y: 200)

        XCTAssertEqual(
            transform.handle(at: Point(x: 251, y: 149), contentSize: hundert, tolerance: 8),
            .topRight
        )
        XCTAssertNil(
            transform.handle(at: Point(x: 200, y: 200), contentSize: hundert, tolerance: 8),
            "in der Mitte liegt kein Griff"
        )
    }

    /// Liegen zwei Griffe dicht beieinander (sehr kleine Ebene), muss der
    /// nächstliegende gewinnen — und zwar vorhersagbar.
    func testClosestHandleWinsOnASmallLayer() {
        let transform = Transform2D(x: 200, y: 200)
        let winzig = Size(width: 10, height: 10)

        XCTAssertEqual(
            transform.handle(at: Point(x: 205, y: 195), contentSize: winzig, tolerance: 8),
            .topRight
        )
    }

    // MARK: - Skalieren

    /// Beim Ziehen an einer Ecke bleibt die **gegenüberliegende** Ecke fest.
    /// Alles andere fühlt sich falsch an: Die Ebene würde unter dem Zeiger
    /// wegrutschen.
    func testDraggingACornerKeepsTheOppositeCornerFixed() {
        let start = Transform2D(x: 200, y: 200)
        let vorher = start.position(of: .bottomRight, contentSize: hundert)

        let neu = start.resized(handle: .topLeft, draggedTo: Point(x: 100, y: 100), contentSize: hundert)

        assertNear(neu.position(of: .bottomRight, contentSize: hundert), vorher, "die feste Ecke")
        assertNear(neu.position(of: .topLeft, contentSize: hundert), Point(x: 100, y: 100), "die gezogene Ecke folgt")
    }

    func testDraggingAnEdgeChangesOnlyOneDimension() {
        let start = Transform2D(x: 200, y: 200)

        let neu = start.resized(handle: .right, draggedTo: Point(x: 300, y: 999), contentSize: hundert)

        XCTAssertEqual(neu.scaleX, 1.5, accuracy: 0.001, "Breite von 100 auf 150")
        XCTAssertEqual(neu.scaleY, 1, accuracy: 0.001, "die Höhe bleibt unberührt")
        XCTAssertEqual(neu.y, 200, accuracy: 0.001, "und der Mittelpunkt wandert nur waagrecht")
    }

    /// An einer gedrehten Ebene muss sich der Griff entlang der **gedrehten**
    /// Achse bewegen, nicht entlang der Bildschirmachse.
    func testResizingARotatedLayerWorksInItsOwnAxes() {
        let start = Transform2D(x: 200, y: 200, rotationDegrees: 90)
        let festeEcke = start.position(of: .topLeft, contentSize: hundert)

        // Der Griff unten rechts einer um 90° gedrehten Ebene liegt links unten.
        let ziel = start.position(of: .bottomRight, contentSize: hundert)
        let neu = start.resized(
            handle: .bottomRight,
            draggedTo: Point(x: ziel.x - 50, y: ziel.y),
            contentSize: hundert
        )

        assertNear(neu.position(of: .topLeft, contentSize: hundert), festeEcke, "die feste Ecke bleibt")
        XCTAssertEqual(neu.rotationDegrees, 90, accuracy: 0.001, "die Drehung bleibt unangetastet")
    }

    /// Zieht man über die feste Ecke hinaus, wird die Ebene gespiegelt statt
    /// zu verschwinden — so verhalten sich Gestaltungsprogramme.
    func testDraggingPastTheAnchorMirrorsTheLayer() {
        let start = Transform2D(x: 200, y: 200)

        let neu = start.resized(handle: .left, draggedTo: Point(x: 300, y: 200), contentSize: hundert)

        XCTAssertLessThan(neu.scaleX, 0, "gespiegelt")
        XCTAssertEqual(abs(neu.scaleX), 0.5, accuracy: 0.001)
    }

    /// Eine auf null geschrumpfte Ebene wäre nicht mehr greifbar und damit
    /// unwiederbringlich verloren.
    func testLayerCannotBeCollapsedToNothing() {
        let start = Transform2D(x: 200, y: 200)

        let neu = start.resized(handle: .right, draggedTo: Point(x: 150, y: 200), contentSize: hundert)

        XCTAssertGreaterThan(abs(neu.scaleX) * hundert.width, 0, "muss greifbar bleiben")
        XCTAssertFalse(neu.scaleX.isNaN)
    }

    /// Bei gehaltener Umschalttaste bleibt das Seitenverhältnis erhalten —
    /// bei Fotos der Normalfall, weil ein verzerrtes Gesicht selten gewollt ist.
    func testAspectRatioIsKeptWhenRequested() {
        let start = Transform2D(x: 200, y: 200)

        let neu = start.resized(
            handle: .bottomRight,
            draggedTo: Point(x: 350, y: 260),
            contentSize: hundert,
            keepingAspectRatio: true
        )

        XCTAssertEqual(abs(neu.scaleX), abs(neu.scaleY), accuracy: 0.001)
    }

    func testAspectRatioOfNonSquareContentIsKept() {
        let start = Transform2D(x: 200, y: 200)
        let breit = Size(width: 200, height: 100)

        let neu = start.resized(
            handle: .bottomRight,
            draggedTo: Point(x: 400, y: 260),
            contentSize: breit,
            keepingAspectRatio: true
        )

        XCTAssertEqual(abs(neu.scaleX), abs(neu.scaleY), accuracy: 0.001,
                       "gleiche Skalierung heisst bei nicht-quadratischem Inhalt gleiches Verhältnis")
    }

    // MARK: - Drehen

    func testRotationFollowsTheCursor() {
        let start = Transform2D(x: 200, y: 200)

        // Zeiger rechts vom Mittelpunkt: Der Drehgriff, der oben sass, ist
        // eine Vierteldrehung im Uhrzeigersinn weitergewandert.
        let neu = start.rotated(towards: Point(x: 300, y: 200))

        XCTAssertEqual(neu.rotationDegrees, 90, accuracy: 0.001)
    }

    func testRotationIsClockwiseForPositiveAngles() {
        let start = Transform2D(x: 0, y: 0)

        XCTAssertEqual(start.rotated(towards: Point(x: 0, y: -100)).rotationDegrees, 0, accuracy: 0.001)
        XCTAssertEqual(start.rotated(towards: Point(x: 0, y: 100)).rotationDegrees, 180, accuracy: 0.001)
        XCTAssertEqual(start.rotated(towards: Point(x: -100, y: 0)).rotationDegrees, -90, accuracy: 0.001)
    }

    /// Bei gehaltener Umschalttaste in Schritten drehen — sonst trifft man
    /// exakte 90° von Hand praktisch nie.
    func testRotationSnapsToStepsWhenRequested() {
        let start = Transform2D(x: 0, y: 0)

        let neu = start.rotated(towards: Point(x: 10, y: -100), snappingTo: 15)

        XCTAssertEqual(neu.rotationDegrees, 0, accuracy: 0.001)
    }

    /// Zeigt der Zeiger genau auf den Mittelpunkt, gibt es keine Richtung —
    /// das darf die Drehung nicht auf einen willkürlichen Wert springen lassen.
    func testRotationKeepsItsValueWhenCursorIsOnTheCentre() {
        let start = Transform2D(x: 200, y: 200, rotationDegrees: 37)

        let neu = start.rotated(towards: Point(x: 200, y: 200))

        XCTAssertEqual(neu.rotationDegrees, 37, accuracy: 0.001)
    }
}
