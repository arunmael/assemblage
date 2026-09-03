import XCTest
@testable import AssemblageModel

/// Deckt die Ausrichtungshilfen aus Plan 5.3 ab: Kantenausrichtung, Zentrieren,
/// Leinwandbezug, gleicher Abstand — plus Determinismus und Randfälle (siehe
/// Kommentare in `AlignmentGuides.swift` zur Rangfolge).
final class AlignmentGuidesTests: XCTestCase {
    private let canvas = CanvasSize(width: 1000, height: 800)

    // MARK: - Kantenausrichtung zu anderen Ebenen

    func testSnapsLeftEdgeToLeftEdgeOfOtherLayer() {
        let other = Rect(x: 200, y: 200, width: 100, height: 100)
        // 3pt daneben — innerhalb der Fangdistanz.
        let dragged = Rect(x: 203, y: 400, width: 50, height: 50)

        let result = AlignmentGuides.snap(draggedFrame: dragged, otherFrames: [other], canvasSize: canvas, snapDistance: 8)

        XCTAssertEqual(result.offsetX, -3, accuracy: 1e-9)
        XCTAssertEqual(result.offsetY, 0, accuracy: 1e-9)
        XCTAssertTrue(result.lines.contains { $0.orientation == .vertical && abs($0.position - 200) < 1e-9 })
    }

    func testSnapsEdgeToOppositeEdgeForFlushPlacement() {
        // "Bündig anlegen": linke Kante der gezogenen Ebene an die rechte Kante der anderen.
        let other = Rect(x: 100, y: 100, width: 100, height: 100) // rechte Kante bei 200
        let dragged = Rect(x: 205, y: 300, width: 50, height: 50)

        let result = AlignmentGuides.snap(draggedFrame: dragged, otherFrames: [other], canvasSize: canvas, snapDistance: 8)

        XCTAssertEqual(result.offsetX, -5, accuracy: 1e-9)
        let snappedLeft = dragged.x + result.offsetX
        XCTAssertEqual(snappedLeft, 200, accuracy: 1e-9)
    }

    // MARK: - Zentrieren

    func testCentersOnOtherLayerInBothAxes() {
        let other = Rect(x: 100, y: 100, width: 200, height: 200) // Mitte bei (200, 200)
        let dragged = Rect(x: 185, y: 185, width: 40, height: 40) // Mitte bei (205, 205)

        let result = AlignmentGuides.snap(draggedFrame: dragged, otherFrames: [other], canvasSize: canvas, snapDistance: 8)

        XCTAssertEqual(result.offsetX, -5, accuracy: 1e-9)
        XCTAssertEqual(result.offsetY, -5, accuracy: 1e-9)
        let snappedCenterX = dragged.x + dragged.width / 2 + result.offsetX
        let snappedCenterY = dragged.y + dragged.height / 2 + result.offsetY
        XCTAssertEqual(snappedCenterX, 200, accuracy: 1e-9)
        XCTAssertEqual(snappedCenterY, 200, accuracy: 1e-9)
    }

    // MARK: - Leinwand

    func testSnapsToCanvasEdgesAndCenter() {
        // Nahe an der linken Leinwandkante (x=0) und an der senkrechten Mitte (y=400).
        let dragged = Rect(x: 4, y: 396, width: 50, height: 50)

        let result = AlignmentGuides.snap(draggedFrame: dragged, otherFrames: [], canvasSize: canvas, snapDistance: 8)

        XCTAssertEqual(result.offsetX, -4, accuracy: 1e-9)
        // Mitte der Ebene liegt bei 396+25=421, Leinwandmitte bei 400 -> Versatz -21, ausserhalb 8pt.
        // Stattdessen soll die nähere Option (obere Kante bei y=396, Distanz 396 zu 0 ist weiter weg als
        // die Leinwandmitte) NICHT einrasten, da beide ausserhalb der Fangdistanz liegen.
        XCTAssertEqual(result.offsetY, 0, accuracy: 1e-9)
    }

    func testSnapsToCanvasCenterWhenClose() {
        let dragged = Rect(x: 300, y: 397, width: 200, height: 10) // Mitte y = 402, Leinwandmitte y = 400
        let result = AlignmentGuides.snap(draggedFrame: dragged, otherFrames: [], canvasSize: canvas, snapDistance: 8)

        XCTAssertEqual(result.offsetY, -2, accuracy: 1e-9)
        XCTAssertTrue(result.lines.contains { $0.orientation == .horizontal && abs($0.position - 400) < 1e-9 })
    }

    // MARK: - Gleicher Abstand

    func testEqualSpacingBetweenTwoNeighborsInARow() {
        // Zwei Ebenen in einer Reihe (gleiche y-Ausdehnung), Lücke zwischen ihnen: x=100..300.
        let left = Rect(x: 0, y: 0, width: 100, height: 100)   // rechte Kante bei 100
        let right = Rect(x: 300, y: 0, width: 100, height: 100) // linke Kante bei 300
        // Gezogene Ebene mit Breite 50 soll die 200pt-Lücke mittig füllen: x=175
        // (Lücke 200, Ebene 50 -> je 75pt Rand links und rechts).
        let dragged = Rect(x: 178, y: 10, width: 50, height: 50)

        let result = AlignmentGuides.snap(draggedFrame: dragged, otherFrames: [left, right], canvasSize: canvas, snapDistance: 8)

        XCTAssertEqual(result.offsetX, -3, accuracy: 1e-9)
        let snappedX = dragged.x + result.offsetX
        XCTAssertEqual(snappedX, 175, accuracy: 1e-9)
        XCTAssertEqual(300 - (snappedX + 50), (snappedX - 100), accuracy: 1e-9, "Abstand links und rechts muss gleich sein")
    }

    func testEqualSpacingRequiresRowOverlap() {
        // "right" liegt weit ausserhalb der y-Ausdehnung der gezogenen Ebene -> keine Reihe,
        // Gleicher-Abstand darf nicht greifen (auch wenn die x-Rechnung sonst passen würde).
        let left = Rect(x: 0, y: 0, width: 100, height: 100)
        let right = Rect(x: 300, y: 700, width: 100, height: 50)
        let dragged = Rect(x: 128, y: 10, width: 50, height: 50)

        let result = AlignmentGuides.snap(draggedFrame: dragged, otherFrames: [left, right], canvasSize: canvas, snapDistance: 8)

        XCTAssertEqual(result.offsetX, 0, accuracy: 1e-9)
    }

    func testEqualSpacingOnlyUsesImmediateNeighbors() {
        // Drei Ebenen in einer Reihe: A (0..100), B (150..200), C (400..500).
        // Die gezogene Ebene liegt zwischen B und C — Gleicher-Abstand muss B/C verwenden,
        // nicht A/C (A wäre kein unmittelbarer Nachbar mehr, B läge sonst "verdeckt").
        let a = Rect(x: 0, y: 0, width: 100, height: 100)
        let b = Rect(x: 150, y: 0, width: 50, height: 100)
        let c = Rect(x: 400, y: 0, width: 100, height: 100)
        // Lücke B..C: 200..400, Ebene Breite 20 -> Ziel-x = 200 + (200-20)/2 = 290.
        let dragged = Rect(x: 293, y: 10, width: 20, height: 100)

        let result = AlignmentGuides.snap(draggedFrame: dragged, otherFrames: [a, b, c], canvasSize: canvas, snapDistance: 8)

        XCTAssertEqual(result.offsetX, -3, accuracy: 1e-9)
        XCTAssertTrue(result.lines.contains { $0.orientation == .vertical && abs($0.position - 200) < 1e-9 })
        XCTAssertTrue(result.lines.contains { $0.orientation == .vertical && abs($0.position - 400) < 1e-9 })
        XCTAssertFalse(result.lines.contains { $0.orientation == .vertical && abs($0.position - 100) < 1e-9 })
    }

    // MARK: - Einrasten nur in einer Achse

    func testSnapsOnOneAxisOnlyWhenOtherAxisIsFarAway() {
        let other = Rect(x: 200, y: 200, width: 100, height: 100)
        let dragged = Rect(x: 203, y: 700, width: 50, height: 50) // x nah, y weit weg

        let result = AlignmentGuides.snap(draggedFrame: dragged, otherFrames: [other], canvasSize: canvas, snapDistance: 8)

        XCTAssertEqual(result.offsetX, -3, accuracy: 1e-9)
        XCTAssertEqual(result.offsetY, 0, accuracy: 1e-9)
        XCTAssertFalse(result.lines.contains { $0.orientation == .horizontal })
    }

    // MARK: - Nichts rastet ein

    func testNoSnapWhenEverythingIsFarAway() {
        let other = Rect(x: 200, y: 200, width: 100, height: 100)
        let dragged = Rect(x: 600, y: 600, width: 50, height: 50)

        let result = AlignmentGuides.snap(draggedFrame: dragged, otherFrames: [other], canvasSize: canvas, snapDistance: 8)

        XCTAssertEqual(result, .none)
    }

    func testNoSnapWithEmptyOtherLayersAndFarFromCanvasReferences() {
        let dragged = Rect(x: 450, y: 350, width: 20, height: 20)
        let result = AlignmentGuides.snap(draggedFrame: dragged, otherFrames: [], canvasSize: canvas, snapDistance: 8)
        XCTAssertEqual(result, .none)
    }

    // MARK: - Fangdistanz-Grenze

    func testSnapsExactlyAtSnapDistanceBoundary() {
        let other = Rect(x: 200, y: 200, width: 100, height: 100)
        let dragged = Rect(x: 208, y: 400, width: 50, height: 50) // exakt 8pt entfernt

        let result = AlignmentGuides.snap(draggedFrame: dragged, otherFrames: [other], canvasSize: canvas, snapDistance: 8)

        XCTAssertEqual(result.offsetX, -8, accuracy: 1e-9)
    }

    func testDoesNotSnapJustBeyondSnapDistanceBoundary() {
        let other = Rect(x: 200, y: 200, width: 100, height: 100)
        let dragged = Rect(x: 208.01, y: 400, width: 50, height: 50) // knapp über 8pt

        let result = AlignmentGuides.snap(draggedFrame: dragged, otherFrames: [other], canvasSize: canvas, snapDistance: 8)

        XCTAssertEqual(result.offsetX, 0, accuracy: 1e-9)
    }

    // MARK: - Vorhersagbarkeit bei mehreren gleich guten Kandidaten

    func testTieIsResolvedDeterministicallyRegardlessOfInputOrder() {
        // Zwei andere Ebenen liegen exakt gleich weit weg (gleicher Versatzbetrag) —
        // das Ergebnis darf nicht von der Reihenfolge im Array abhängen.
        let left = Rect(x: 100, y: 100, width: 50, height: 50)  // linke Kante bei 100
        let right = Rect(x: 300, y: 100, width: 50, height: 50) // linke Kante bei 300
        // Gezogene Ebene bei x=204: 4pt von 200 entfernt wäre nicht symmetrisch — wir bauen
        // stattdessen eine echte Gleichstand-Situation über zwei verschiedene Referenzarten:
        // linke Kante von "left" und rechte Kante von "right" beide exakt im selben Abstand.
        // Einfacher: zwei Ebenen mit identischer linker Kante ergeben zwei Kandidaten mit
        // exakt demselben Versatz und derselben Priorität (layerEdge) — Ergebnis muss trotzdem
        // gleich sein, unabhängig von der Reihenfolge.
        let duplicateA = Rect(x: 200, y: 50, width: 50, height: 50)
        let duplicateB = Rect(x: 200, y: 600, width: 50, height: 50)
        let dragged = Rect(x: 203, y: 300, width: 50, height: 50)

        let orderA = AlignmentGuides.snap(draggedFrame: dragged, otherFrames: [duplicateA, duplicateB, left, right], canvasSize: canvas, snapDistance: 8)
        let orderB = AlignmentGuides.snap(draggedFrame: dragged, otherFrames: [right, left, duplicateB, duplicateA], canvasSize: canvas, snapDistance: 8)
        let orderC = AlignmentGuides.snap(draggedFrame: dragged, otherFrames: [duplicateB, right, duplicateA, left], canvasSize: canvas, snapDistance: 8)

        XCTAssertEqual(orderA, orderB)
        XCTAssertEqual(orderA, orderC)
    }

    func testCenterPriorityWinsOverEdgeAtEqualDistance() {
        // Ebene A: gleicher Versatz über Kantenausrichtung wie Ebene B über Zentrieren ->
        // laut Rangfolge gewinnt Zentrieren (layerCenter) vor Kantenausrichtung (layerEdge).
        let edgeMatch = Rect(x: 205, y: 0, width: 100, height: 100)   // linke Kante bei 205
        let dragged = Rect(x: 200, y: 300, width: 40, height: 40)     // linke Kante 200, Mitte 220

        // "edgeMatch" ergibt offset = 205-200 = 5 (linke Kante an linke Kante).
        // "centeredOther" hat Mitte 215, dragged-Mitte ist 220 -> offset = -5. Gleicher Betrag (5),
        // aber verschiedene Kategorie -> laut Rangfolge gewinnt Zentrieren vor Kantenausrichtung.
        let centeredOther = Rect(x: 170, y: 500, width: 90, height: 100) // Mitte bei 215 -> offset -5
        let result = AlignmentGuides.snap(draggedFrame: dragged, otherFrames: [edgeMatch, centeredOther], canvasSize: canvas, snapDistance: 8)

        // Beide Kandidaten haben |offset| = 5 -> Zentrieren gewinnt laut Rangfolge.
        XCTAssertEqual(result.offsetX, -5, accuracy: 1e-9)
        let snappedCenter = dragged.x + dragged.width / 2 + result.offsetX
        XCTAssertEqual(snappedCenter, centeredOther.x + centeredOther.width / 2, accuracy: 1e-9)
    }

    // MARK: - Randfälle

    func testZeroSizeOtherLayerDoesNotCrashAndCanStillMatch() {
        let point = Rect(x: 200, y: 200, width: 0, height: 0)
        let dragged = Rect(x: 203, y: 500, width: 50, height: 50)

        let result = AlignmentGuides.snap(draggedFrame: dragged, otherFrames: [point], canvasSize: canvas, snapDistance: 8)

        XCTAssertEqual(result.offsetX, -3, accuracy: 1e-9)
    }

    func testZeroSizeDraggedLayerDoesNotCrash() {
        let other = Rect(x: 200, y: 200, width: 100, height: 100)
        let dragged = Rect(x: 203, y: 500, width: 0, height: 0)

        let result = AlignmentGuides.snap(draggedFrame: dragged, otherFrames: [other], canvasSize: canvas, snapDistance: 8)

        XCTAssertEqual(result.offsetX, -3, accuracy: 1e-9)
    }

    func testManyLayersDoesNotCrashAndStillFindsClosestMatch() {
        var others: [Rect] = []
        for i in 0..<500 {
            others.append(Rect(x: Double(i) * 3, y: Double(i) * 2, width: 10, height: 10))
        }
        // Eine Ebene, die exakt an x=200 (linke Kante von "others[?]" mit x=200... nicht garantiert,
        // wir fügen gezielt eine passende Referenz hinzu) andocken soll.
        others.append(Rect(x: 5000, y: 5000, width: 40, height: 40))
        let dragged = Rect(x: 5003, y: 5100, width: 50, height: 50)

        let result = AlignmentGuides.snap(draggedFrame: dragged, otherFrames: others, canvasSize: canvas, snapDistance: 8)

        XCTAssertEqual(result.offsetX, -3, accuracy: 1e-9)
    }

    // MARK: - Linien passen zur eingerasteten Position

    func testReportedLineMatchesSnappedEdge() {
        let other = Rect(x: 200, y: 200, width: 100, height: 100)
        let dragged = Rect(x: 206, y: 400, width: 50, height: 50)

        let result = AlignmentGuides.snap(draggedFrame: dragged, otherFrames: [other], canvasSize: canvas, snapDistance: 8)

        guard let line = result.lines.first(where: { $0.orientation == .vertical }) else {
            return XCTFail("Erwartete eine senkrechte Linie")
        }
        let snappedLeft = dragged.x + result.offsetX
        XCTAssertEqual(line.position, snappedLeft, accuracy: 1e-9)
        // Linie muss beide Ebenen verbinden (y-Ausdehnung), nicht über die ganze Leinwand laufen.
        XCTAssertEqual(line.start, 200, accuracy: 1e-9)
        XCTAssertEqual(line.end, 450, accuracy: 1e-9)
        XCTAssertLessThan(line.end - line.start, canvas.height)
    }
}

/// Die Leinwand ist keine Ebene, an die man etwas „anlegt".
///
/// Zwischen zwei Ebenen ist „linke Kante an rechte Kante" sinnvoll — man legt
/// sie bündig aneinander. Bei der Leinwand hiesse dasselbe: die Ebene rastet
/// vollständig **ausserhalb** der Leinwand ein. Das ist nie gemeint, und es
/// passiert genau dann, wenn man eine Ebene an den Rand schiebt.
final class CanvasEdgeSnappingTests: XCTestCase {

    private let leinwand = CanvasSize(width: 1000, height: 1000)

    func testLayerDoesNotSnapOffTheRightCanvasEdge() {
        // Linke Kante 4 Punkte hinter der rechten Leinwandkante.
        let gezogen = Rect(x: 1004, y: 400, width: 100, height: 100)

        let ergebnis = AlignmentGuides.snap(
            draggedFrame: gezogen, otherFrames: [], canvasSize: leinwand
        )

        XCTAssertEqual(ergebnis.offsetX, 0, "die Ebene darf nicht neben die Leinwand rasten")
    }

    func testLayerDoesNotSnapOffTheLeftCanvasEdge() {
        // Rechte Kante 4 Punkte vor der linken Leinwandkante.
        let gezogen = Rect(x: -104, y: 400, width: 100, height: 100)

        let ergebnis = AlignmentGuides.snap(
            draggedFrame: gezogen, otherFrames: [], canvasSize: leinwand
        )

        XCTAssertEqual(ergebnis.offsetX, 0)
    }

    func testLayerDoesNotSnapOffTheBottomCanvasEdge() {
        let gezogen = Rect(x: 400, y: 1004, width: 100, height: 100)

        let ergebnis = AlignmentGuides.snap(
            draggedFrame: gezogen, otherFrames: [], canvasSize: leinwand
        )

        XCTAssertEqual(ergebnis.offsetY, 0)
    }

    /// Das Einrasten an der *gleichen* Kante muss weiter funktionieren —
    /// bündig am Leinwandrand ausrichten ist der Normalfall.
    func testLayerStillSnapsFlushToTheCanvasEdge() {
        let gezogen = Rect(x: 896, y: 400, width: 100, height: 100)  // rechte Kante bei 996

        let ergebnis = AlignmentGuides.snap(
            draggedFrame: gezogen, otherFrames: [], canvasSize: leinwand
        )

        XCTAssertEqual(ergebnis.offsetX, 4, accuracy: 0.001, "rechte Kante rastet auf 1000")
    }

    /// Und zwischen zwei Ebenen bleibt „bündig anlegen" richtig — dort ist die
    /// gegenüberliegende Kante genau das, was man will.
    func testLayersStillSnapFlushAgainstEachOther() {
        let gezogen = Rect(x: 504, y: 400, width: 100, height: 100)
        let andere = Rect(x: 300, y: 400, width: 200, height: 100)  // rechte Kante bei 500

        let ergebnis = AlignmentGuides.snap(
            draggedFrame: gezogen, otherFrames: [andere], canvasSize: leinwand
        )

        XCTAssertEqual(ergebnis.offsetX, -4, accuracy: 0.001, "linke Kante rastet an rechte Kante der anderen")
    }
}
