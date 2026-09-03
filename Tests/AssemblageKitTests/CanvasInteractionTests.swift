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
        var bewegungen: [(id: UUID, mitte: Point)] = []
        var beendet: [String] = []

        func canvasView(_ canvasView: CanvasView, didSelectLayerWithID id: UUID?) {
            auswahl.append(id)
        }
        func canvasViewDidBeginInteraction(_ canvasView: CanvasView) {
            begonnen += 1
        }
        func canvasView(_ canvasView: CanvasView, didMoveLayerWithID id: UUID, toCentre centre: Point) {
            bewegungen.append((id, centre))
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

        let letzte = try XCTUnwrap(protokoll.bewegungen.last)
        XCTAssertEqual(letzte.id, ebeneID)
        XCTAssertEqual(letzte.mitte.x, 260, accuracy: 0.001)
        XCTAssertEqual(letzte.mitte.y, 230, accuracy: 0.001)
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

        let letzte = try XCTUnwrap(protokoll.bewegungen.last)
        XCTAssertEqual(letzte.mitte.x, 250, accuracy: 0.001)
    }

    /// Ein Klick mit leichtem Wackeln darf die Ebene nicht verschieben —
    /// sonst verrutscht beim blossen Auswählen alles um einen Punkt.
    func testTinyWobbleDoesNotCountAsADrag() throws {
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 200, y: 200))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: 201, y: 201))
        canvas.mouseUp(with: try ereignis(.leftMouseUp, atCanvasX: 201, y: 201))

        XCTAssertTrue(protokoll.bewegungen.isEmpty)
        XCTAssertEqual(protokoll.begonnen, 0, "keine Undo-Klammer für einen Klick")
        XCTAssertTrue(protokoll.beendet.isEmpty)
    }

    func testDraggingOnEmptyCanvasMovesNothing() throws {
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 380, y: 380))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: 300, y: 300))
        canvas.mouseUp(with: try ereignis(.leftMouseUp, atCanvasX: 300, y: 300))

        XCTAssertTrue(protokoll.bewegungen.isEmpty)
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
}
