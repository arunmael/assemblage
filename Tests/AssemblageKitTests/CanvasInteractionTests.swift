import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Auswählen und Verschieben auf dem Canvas — mit echten Mausereignissen.
///
/// Bewusst nicht nur die Rechenlogik: Der bisher unangenehmste Fehler im
/// Projekt (ein leeres Fenster) lag genau in solcher Verdrahtung, während
/// jeder einzelne Baustein für sich korrekt war.
@MainActor
final class CanvasInteractionTests: XCTestCase {

    /// Sammelt, was der Canvas meldet.
    private final class Protokoll: CanvasInteractionDelegate {
        var auswahl: [UUID?] = []
        var begonnen = 0
        var aenderungen: [(id: UUID, transform: Transform2D)] = []
        var beendet: [String] = []

        func canvasView(_ canvasView: CanvasView, didSelectLayerWithID id: UUID?) {
            auswahl.append(id)
        }
        func canvasViewDidBeginInteraction(_ canvasView: CanvasView) {
            begonnen += 1
        }
        func canvasView(_ canvasView: CanvasView, didChangeLayerWithID id: UUID, to transform: Transform2D) {
            aenderungen.append((id, transform))
        }
        func canvasView(_ canvasView: CanvasView, didEndInteractionNamed actionName: String) {
            beendet.append(actionName)
        }
    }

    private var fenster: NSWindow!
    private var canvas: CanvasView!
    private var protokoll: Protokoll!
    private var ebeneID: UUID!

    override func setUpWithError() throws {
        let ebene = Layer(
            name: "Foto",
            transform: Transform2D(x: 200, y: 200),
            content: .shape(ShapeLayerContent(kind: .rectangle, size: Size(width: 100, height: 100)))
        )
        ebeneID = ebene.id

        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 400, height: 400),
            layers: [ebene]
        )

        canvas = CanvasView(document: document, images: ImageStore(resources: DocumentResources()))
        protokoll = Protokoll()
        canvas.interactionDelegate = protokoll

        // Ereignisse brauchen ein Fenster: `convert(_:from: nil)` rechnet
        // gegen dessen Koordinaten.
        fenster = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        fenster.contentView?.addSubview(canvas)
        canvas.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    }

    /// Baut ein Mausereignis für einen Punkt in **Leinwand**koordinaten
    /// (Ursprung oben links) — so, wie die Tests denken.
    private func ereignis(_ typ: NSEvent.EventType, atCanvasX x: Double, y: Double) throws -> NSEvent {
        let inView = NSPoint(x: x, y: Double(canvas.bounds.height) - y)
        let inWindow = canvas.convert(inView, to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: typ, location: inWindow, modifierFlags: [], timestamp: 0,
            windowNumber: fenster.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    // MARK: - Auswahl

    func testClickSelectsTheLayerUnderTheCursor() throws {
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 200, y: 200))

        XCTAssertEqual(protokoll.auswahl, [ebeneID])
        XCTAssertEqual(canvas.selectedLayerID, ebeneID)
    }

    func testClickOnEmptyCanvasClearsTheSelection() throws {
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 200, y: 200))
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 380, y: 380))

        XCTAssertEqual(protokoll.auswahl, [ebeneID, nil])
        XCTAssertNil(canvas.selectedLayerID)
    }

    /// Die Umrechnung Ansicht → Leinwand muss stimmen: Die Ansicht rechnet von
    /// unten links, die Leinwand von oben links. Ein Vorzeichenfehler hier
    /// würde Klicks am oberen Rand am unteren landen lassen.
    func testHitTestingUsesCanvasCoordinatesNotViewCoordinates() throws {
        let obenLinks = AssemblageModel.Document(
            canvas: CanvasSize(width: 400, height: 400),
            layers: [Layer(
                name: "Oben links",
                transform: Transform2D(x: 60, y: 60),
                content: .shape(ShapeLayerContent(kind: .rectangle, size: Size(width: 80, height: 80)))
            )]
        )
        canvas.update(to: obenLinks)

        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 60, y: 60))
        XCTAssertNotNil(canvas.selectedLayerID, "der Klick oben links muss treffen")

        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 60, y: 340))
        XCTAssertNil(canvas.selectedLayerID, "unten links liegt nichts")
    }

    // MARK: - Ziehen

    func testDraggingMovesTheLayerByTheCursorOffset() throws {
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 200, y: 200))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: 260, y: 230))
        canvas.mouseUp(with: try ereignis(.leftMouseUp, atCanvasX: 260, y: 230))

        let letzte = try XCTUnwrap(protokoll.aenderungen.last)
        XCTAssertEqual(letzte.id, ebeneID)
        XCTAssertEqual(letzte.transform.x, 260, accuracy: 0.001)
        XCTAssertEqual(letzte.transform.y, 230, accuracy: 0.001)
        XCTAssertEqual(protokoll.begonnen, 1, "genau eine Undo-Klammer")
        XCTAssertEqual(protokoll.beendet, ["Ebene verschieben"])
    }

    /// Der Versatz wird gegen den Startpunkt gerechnet, nicht Schritt für
    /// Schritt aufaddiert — sonst summieren sich Rundungsfehler über hundert
    /// Mausmeldungen sichtbar auf.
    func testManySmallDragStepsEndUpExactlyAtTheCursor() throws {
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 200, y: 200))
        for schritt in 1...100 {
            canvas.mouseDragged(with: try ereignis(
                .leftMouseDragged, atCanvasX: 200 + Double(schritt) * 0.5, y: 200
            ))
        }
        canvas.mouseUp(with: try ereignis(.leftMouseUp, atCanvasX: 250, y: 200))

        let letzte = try XCTUnwrap(protokoll.aenderungen.last)
        XCTAssertEqual(letzte.transform.x, 250, accuracy: 0.001)
    }

    /// Ein Klick mit leichtem Wackeln darf die Ebene nicht verschieben —
    /// sonst verrutscht beim blossen Auswählen alles um einen Punkt.
    func testTinyWobbleDoesNotCountAsADrag() throws {
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 200, y: 200))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: 201, y: 201))
        canvas.mouseUp(with: try ereignis(.leftMouseUp, atCanvasX: 201, y: 201))

        XCTAssertTrue(protokoll.aenderungen.isEmpty)
        XCTAssertEqual(protokoll.begonnen, 0, "keine Undo-Klammer für einen Klick")
        XCTAssertTrue(protokoll.beendet.isEmpty)
    }

    func testDraggingOnEmptyCanvasMovesNothing() throws {
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 380, y: 380))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: 300, y: 300))
        canvas.mouseUp(with: try ereignis(.leftMouseUp, atCanvasX: 300, y: 300))

        XCTAssertTrue(protokoll.aenderungen.isEmpty)
        XCTAssertEqual(protokoll.begonnen, 0)
    }

    // MARK: - Auswahlrahmen

    func testSelectionOutlineAppearsAndDisappears() throws {
        let overlay = try XCTUnwrap(canvas.layer?.sublayers?.last)
        let rahmen = try XCTUnwrap(overlay.sublayers?.first as? CAShapeLayer)

        XCTAssertNil(rahmen.path, "ohne Auswahl kein Rahmen")

        canvas.selectedLayerID = ebeneID
        let pfad = try XCTUnwrap(rahmen.path, "mit Auswahl ein Rahmen")
        XCTAssertEqual(pfad.boundingBox.width, 100, accuracy: 0.5)
        XCTAssertEqual(pfad.boundingBox.height, 100, accuracy: 0.5)

        canvas.selectedLayerID = nil
        XCTAssertNil(rahmen.path)
    }

    /// Der Rahmen muss beim Zoomen gleich dick wirken — sonst ist er bei
    /// 8-fachem Zoom ein Balken und bei 10 % unsichtbar.
    func testOutlineWidthCompensatesForZoom() throws {
        let overlay = try XCTUnwrap(canvas.layer?.sublayers?.last)
        let rahmen = try XCTUnwrap(overlay.sublayers?.first as? CAShapeLayer)
        canvas.selectedLayerID = ebeneID

        canvas.zoomScale = 1
        let beiEins = rahmen.lineWidth
        canvas.zoomScale = 4
        let beiVier = rahmen.lineWidth

        XCTAssertEqual(beiVier, beiEins / 4, accuracy: 0.001)
    }

    // MARK: - Griffe

    /// Ein Griff muss auch dann greifen, wenn er ausserhalb der Ebene liegt —
    /// beim Drehgriff ist das immer so. Ohne Vorrang vor der Trefferprüfung
    /// der Ebene wäre er unerreichbar.
    func testHandlesTakePrecedenceOverTheLayerBeneath() throws {
        canvas.selectedLayerID = ebeneID

        // Ecke oben links der Ebene (Mittelpunkt 200/200, Grösse 100).
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 150, y: 150))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: 100, y: 100))
        canvas.mouseUp(with: try ereignis(.leftMouseUp, atCanvasX: 100, y: 100))

        XCTAssertEqual(protokoll.beendet, ["Ebene skalieren"], "kein Verschieben, sondern Skalieren")

        let letzte = try XCTUnwrap(protokoll.aenderungen.last)
        // Gegenüberliegende Ecke bleibt bei 250/250, gezogene Ecke bei 100/100
        // ergibt eine Ebene von 150 Punkten Kantenlänge.
        XCTAssertEqual(abs(letzte.transform.scaleX), 1.5, accuracy: 0.001)
        XCTAssertEqual(letzte.transform.x, 175, accuracy: 0.001, "der Mittelpunkt wandert mit")
    }

    /// Der Drehgriff sitzt ausserhalb der Ebene und muss trotzdem greifen.
    func testRotationHandleIsReachableOutsideTheLayer() throws {
        canvas.selectedLayerID = ebeneID

        // Oberkante bei y=150, Drehgriff 28 Punkte darüber.
        let griffY = 150.0 - CanvasView.rotationHandleDistance
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 200, y: griffY))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: 300, y: 200))
        canvas.mouseUp(with: try ereignis(.leftMouseUp, atCanvasX: 300, y: 200))

        XCTAssertEqual(protokoll.beendet, ["Ebene drehen"])
        let letzte = try XCTUnwrap(protokoll.aenderungen.last)
        XCTAssertEqual(letzte.transform.rotationDegrees, 90, accuracy: 0.001)
    }

    /// Ohne Auswahl gibt es keine Griffe — ein Klick dort, wo bei ausgewählter
    /// Ebene ein Griff sässe, darf nichts skalieren.
    func testNoHandlesWithoutASelection() throws {
        canvas.selectedLayerID = nil

        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 150, y: 150))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: 100, y: 100))
        canvas.mouseUp(with: try ereignis(.leftMouseUp, atCanvasX: 100, y: 100))

        XCTAssertNotEqual(protokoll.beendet.first, "Ebene skalieren")
    }

    /// Das Ziehen eines Griffs darf die Auswahl nicht ändern — sonst verlöre
    /// man mitten im Skalieren die Ebene, an der man gerade arbeitet.
    func testDraggingAHandleKeepsTheSelection() throws {
        canvas.selectedLayerID = ebeneID
        protokoll.auswahl.removeAll()

        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 250, y: 200))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: 300, y: 200))
        canvas.mouseUp(with: try ereignis(.leftMouseUp, atCanvasX: 300, y: 200))

        XCTAssertTrue(protokoll.auswahl.isEmpty, "keine neue Auswahlmeldung")
        XCTAssertEqual(canvas.selectedLayerID, ebeneID)
    }

    /// Die Fangbereiche der Griffe müssen mit dem Zoom mitgehen: Bei
    /// vierfacher Vergrösserung ist ein Bildschirmpunkt nur ein Viertel
    /// Leinwandpunkt, der Fangbereich in Leinwandkoordinaten also kleiner.
    func testHandleHitAreaShrinksWithZoom() throws {
        canvas.selectedLayerID = ebeneID
        canvas.zoomScale = 8

        // 9 Leinwandpunkte neben der Ecke: bei Zoom 1 im Fangbereich,
        // bei Zoom 8 (Fangbereich 11/8 ≈ 1,4 Punkte) deutlich ausserhalb.
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 159, y: 159))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: 120, y: 120))
        canvas.mouseUp(with: try ereignis(.leftMouseUp, atCanvasX: 120, y: 120))

        XCTAssertEqual(protokoll.beendet, ["Ebene verschieben"], "kein Griff, also verschieben")
    }

    /// Griffe müssen gezeichnet werden, sobald etwas ausgewählt ist.
    func testHandlesAreDrawnForTheSelection() throws {
        let overlay = try XCTUnwrap(canvas.layer?.sublayers?.last)
        let griffe = try XCTUnwrap(overlay.sublayers?.last as? CAShapeLayer)

        XCTAssertNil(griffe.path, "ohne Auswahl keine Griffe")

        canvas.selectedLayerID = ebeneID
        let pfad = try XCTUnwrap(griffe.path)
        // Acht Skaliergriffe plus Drehgriff plus Verbindungsstrich reichen
        // über die Ebene hinaus nach oben.
        XCTAssertLessThan(
            pfad.boundingBox.minY, 150,
            "der Drehgriff liegt oberhalb der Ebene"
        )
    }

    // MARK: - Ausrichtungshilfen

    private var linienSchicht: CAShapeLayer {
        get throws {
            let overlay = try XCTUnwrap(canvas.layer?.sublayers?.last)
            // Reihenfolge im Overlay: Rahmen, Linien, Griffe.
            return try XCTUnwrap(overlay.sublayers?[1] as? CAShapeLayer)
        }
    }

    /// Beim Ziehen nahe der Leinwandmitte muss die Ebene einrasten — das ist
    /// der häufigste Fall überhaupt (Plan 5.3: „Zentrieren").
    func testDraggingNearTheCanvasCentreSnapsToIt() throws {
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 200, y: 200))
        // Ziel 3 Punkte neben der Leinwandmitte (200/200 bei 400×400).
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: 203, y: 197))

        let letzte = try XCTUnwrap(protokoll.aenderungen.last)
        XCTAssertEqual(letzte.transform.x, 200, accuracy: 0.001, "waagrecht eingerastet")
        XCTAssertEqual(letzte.transform.y, 200, accuracy: 0.001, "senkrecht eingerastet")
        XCTAssertNotNil(try linienSchicht.path, "und die Hilfslinien sind sichtbar")
    }

    /// Weit weg von allem darf nichts einrasten — sonst kann man eine Ebene
    /// nicht mehr frei platzieren.
    func testDraggingFarFromAnyGuideDoesNotSnap() throws {
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 200, y: 200))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: 137, y: 262))

        let letzte = try XCTUnwrap(protokoll.aenderungen.last)
        XCTAssertEqual(letzte.transform.x, 137, accuracy: 0.001)
        XCTAssertEqual(letzte.transform.y, 262, accuracy: 0.001)
        XCTAssertNil(try linienSchicht.path, "und keine Linien ohne Einrasten")
    }

    /// Nach dem Loslassen dürfen keine Linien stehen bleiben — sie sind eine
    /// Hilfe während des Ziehens, danach nur noch Striche ohne Bezug.
    func testGuidesDisappearWhenTheDragEnds() throws {
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 200, y: 200))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: 203, y: 197))
        XCTAssertNotNil(try linienSchicht.path)

        canvas.mouseUp(with: try ereignis(.leftMouseUp, atCanvasX: 203, y: 197))
        XCTAssertNil(try linienSchicht.path)
    }

    /// Beim Skalieren wird nicht eingerastet: Die Ebene würde unter dem Griff
    /// wegspringen, statt der Bewegung zu folgen.
    func testResizingDoesNotSnap() throws {
        canvas.selectedLayerID = ebeneID

        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 250, y: 200))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: 303, y: 200))

        XCTAssertNil(try linienSchicht.path)
    }

    /// Die Fangdistanz wird in Bildschirmpunkten gemessen: Wer hineinzoomt,
    /// arbeitet feiner und will nicht aus grosser Entfernung eingefangen werden.
    func testSnapDistanceShrinksWhenZoomedIn() throws {
        canvas.zoomScale = 8

        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 200, y: 200))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: 205, y: 200))

        let letzte = try XCTUnwrap(protokoll.aenderungen.last)
        XCTAssertEqual(
            letzte.transform.x, 205, accuracy: 0.001,
            "5 Punkte sind bei 8-fachem Zoom deutlich mehr als die Fangdistanz"
        )
    }
}
