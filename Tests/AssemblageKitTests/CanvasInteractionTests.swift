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
        var wuerfe = 0
        func canvasView(_ canvasView: CanvasView, didReceiveDropFrom pasteboard: NSPasteboard) {
            wuerfe += 1
        }
        var zuschnitte: [(id: UUID, crop: Rect)] = []
        var striche = 0
        func canvasView(_ canvasView: CanvasView, didPaintMaskForLayerWithID id: UUID, pngData: Data) {
            striche += 1
        }
        func canvasView(_ canvasView: CanvasView, didChangeCropOfLayerWithID id: UUID, to crop: Rect) {
            zuschnitte.append((id, crop))
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
        let rahmen = canvas.selectionOutlineLayerForTesting

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
        let rahmen = canvas.selectionOutlineLayerForTesting
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
        let griffe = canvas.handleLayerForTesting

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

    private var linienSchicht: CAShapeLayer { canvas.guideLayerForTesting }

    /// Beim Ziehen nahe der Leinwandmitte muss die Ebene einrasten — das ist
    /// der häufigste Fall überhaupt (Plan 5.3: „Zentrieren").
    func testDraggingNearTheCanvasCentreSnapsToIt() throws {
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 200, y: 200))
        // Ziel 3 Punkte neben der Leinwandmitte (200/200 bei 400×400).
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: 203, y: 197))

        let letzte = try XCTUnwrap(protokoll.aenderungen.last)
        XCTAssertEqual(letzte.transform.x, 200, accuracy: 0.001, "waagrecht eingerastet")
        XCTAssertEqual(letzte.transform.y, 200, accuracy: 0.001, "senkrecht eingerastet")
        XCTAssertNotNil(linienSchicht.path, "und die Hilfslinien sind sichtbar")
    }

    /// Weit weg von allem darf nichts einrasten — sonst kann man eine Ebene
    /// nicht mehr frei platzieren.
    func testDraggingFarFromAnyGuideDoesNotSnap() throws {
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 200, y: 200))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: 137, y: 262))

        let letzte = try XCTUnwrap(protokoll.aenderungen.last)
        XCTAssertEqual(letzte.transform.x, 137, accuracy: 0.001)
        XCTAssertEqual(letzte.transform.y, 262, accuracy: 0.001)
        XCTAssertNil(linienSchicht.path, "und keine Linien ohne Einrasten")
    }

    /// Nach dem Loslassen dürfen keine Linien stehen bleiben — sie sind eine
    /// Hilfe während des Ziehens, danach nur noch Striche ohne Bezug.
    func testGuidesDisappearWhenTheDragEnds() throws {
        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 200, y: 200))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: 203, y: 197))
        XCTAssertNotNil(linienSchicht.path)

        canvas.mouseUp(with: try ereignis(.leftMouseUp, atCanvasX: 203, y: 197))
        XCTAssertNil(linienSchicht.path)
    }

    /// Beim Skalieren wird nicht eingerastet: Die Ebene würde unter dem Griff
    /// wegspringen, statt der Bewegung zu folgen.
    func testResizingDoesNotSnap() throws {
        canvas.selectedLayerID = ebeneID

        canvas.mouseDown(with: try ereignis(.leftMouseDown, atCanvasX: 250, y: 200))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, atCanvasX: 303, y: 200))

        XCTAssertNil(linienSchicht.path)
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

    // MARK: - Bilder auf die Leinwand ziehen

    private final class Wurf: NSObject, NSDraggingInfo {
        let board: NSPasteboard
        init(board: NSPasteboard) { self.board = board }

        var draggingPasteboard: NSPasteboard { board }
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation: NSPoint { .zero }
        var draggedImageLocation: NSPoint { .zero }
        // Veraltete Anforderung des Protokolls; wird von unserem Code nicht
        // gelesen, muss aber vorhanden sein.
        var draggedImage: NSImage? { nil }
        var draggingSequenceNumber: Int { 0 }
        var draggingSource: Any? { nil }
        var animatesToDestination: Bool { get { false } set {} }
        var numberOfValidItemsForDrop: Int { get { 1 } set {} }
        var draggingFormation: NSDraggingFormation { get { .default } set {} }
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        func enumerateDraggingItems(
            options: NSDraggingItemEnumerationOptions,
            for view: NSView?,
            classes: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey: Any],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}
        func resetSpringLoading() {}
    }

    private func wurfMit(dateien namen: [String]) throws -> Wurf {
        let ordner = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Wurf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        let urls = try namen.map { name -> URL in
            let url = ordner.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            return url
        }
        let board = NSPasteboard(name: NSPasteboard.Name(rawValue: "Wurf-\(UUID().uuidString)"))
        board.clearContents()
        board.writeObjects(urls as [NSURL])
        return Wurf(board: board)
    }

    /// Bereitschaft nur melden, wenn wirklich etwas Brauchbares dabei ist —
    /// sonst zeigt der Finder ein Pluszeichen und der Wurf verpufft.
    func testCanvasAcceptsImagesAndRefusesOtherFiles() throws {
        XCTAssertEqual(canvas.draggingEntered(try wurfMit(dateien: ["foto.png"])), .copy)
        XCTAssertEqual(canvas.draggingEntered(try wurfMit(dateien: ["text.pdf"])), [])
    }

    func testDroppingImagesReachesTheDelegate() throws {
        let angenommen = canvas.performDragOperation(try wurfMit(dateien: ["a.png", "b.jpg"]))

        XCTAssertTrue(angenommen)
        XCTAssertEqual(protokoll.wuerfe, 1, "der Wurf wird als Ganzes gemeldet, nicht je Datei")
    }

    /// Ein Wurf ohne Bilder darf nicht angenommen werden — sonst meldet die
    /// App Erfolg für etwas, das sie gar nicht verarbeitet hat.
    func testDroppingUnsupportedFilesIsRefused() throws {
        let angenommen = canvas.performDragOperation(try wurfMit(dateien: ["text.pdf"]))

        XCTAssertFalse(angenommen)
        XCTAssertEqual(protokoll.wuerfe, 0)
    }
}

/// Der Mauszeiger über einem Grössen-Griff (aus Anpassungen.md).
@MainActor
final class CanvasCursorTests: XCTestCase {

    private var fenster: NSWindow!
    private var canvas: CanvasView!

    private func aufbau(rotationDegrees: Double = 0) -> UUID {
        let ebene = Layer(
            name: "Foto",
            transform: Transform2D(x: 200, y: 200, rotationDegrees: rotationDegrees),
            content: .shape(ShapeLayerContent(kind: .rectangle, size: Size(width: 100, height: 100)))
        )
        let document = AssemblageModel.Document(canvas: CanvasSize(width: 400, height: 400), layers: [ebene])
        canvas = CanvasView(document: document, images: ImageStore(resources: DocumentResources()))
        canvas.selectedLayerID = ebene.id

        fenster = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        fenster.contentView?.addSubview(canvas)
        canvas.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        return ebene.id
    }

    private func bewegen(atCanvasX x: Double, y: Double) throws {
        let inView = NSPoint(x: x, y: Double(canvas.bounds.height) - y)
        let inWindow = canvas.convert(inView, to: nil)
        let ereignis = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved, location: inWindow, modifierFlags: [], timestamp: 0,
            windowNumber: fenster.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0
        ))
        canvas.mouseMoved(with: ereignis)
    }

    /// Bewegt die Maus genau auf die Bildschirmposition eines Griffs — auch
    /// nach einer Drehung, statt eine Koordinate zu erraten.
    private func bewegen(auf griff: ResizeHandle, transform: Transform2D) throws {
        let punkt = transform.position(of: griff, contentSize: Size(width: 100, height: 100))
        try bewegen(atCanvasX: punkt.x, y: punkt.y)
    }

    func testCursorOverAnEdgeHandleIsResizeLeftRight() throws {
        _ = aufbau()
        // Der Rahmen ist 100×100, mittig bei (200,200) — der linke Griff
        // liegt also bei x=150, y=200.
        try bewegen(atCanvasX: 150, y: 200)
        XCTAssertEqual(NSCursor.current, NSCursor.resizeLeftRight)
    }

    func testCursorOverATopOrBottomHandleIsResizeUpDown() throws {
        _ = aufbau()
        try bewegen(atCanvasX: 200, y: 150)
        XCTAssertEqual(NSCursor.current, NSCursor.resizeUpDown)
    }

    /// Die Ecke und ihr gegenüberliegender Griff müssen denselben Zeiger
    /// zeigen — dieselbe Achse, nur das andere Ende.
    func testCornerHandlesShareTheirDiagonalCursor() throws {
        _ = aufbau()
        try bewegen(atCanvasX: 150, y: 150)
        let obenLinks = NSCursor.current

        try bewegen(atCanvasX: 250, y: 250)
        let untenRechts = NSCursor.current

        XCTAssertEqual(obenLinks, untenRechts)
        XCTAssertNotEqual(obenLinks, NSCursor.resizeLeftRight)
        XCTAssertNotEqual(obenLinks, NSCursor.resizeUpDown)
    }

    /// Gegenprobe: Die andere Diagonale muss sich vom ersten Zeiger
    /// unterscheiden — sonst könnten beide „Diagonal"-Fälle zufällig auf
    /// denselben (falschen) Zeiger abgebildet worden sein.
    func testTheTwoDiagonalsAreDifferentCursors() throws {
        _ = aufbau()
        try bewegen(atCanvasX: 150, y: 150)
        let obenLinksUntenRechts = NSCursor.current

        try bewegen(atCanvasX: 250, y: 150)
        let obenRechtsUntenLinks = NSCursor.current

        XCTAssertNotEqual(obenLinksUntenRechts, obenRechtsUntenLinks)
    }

    /// Ausserhalb jedes Griffs bleibt es beim gewöhnlichen Pfeil.
    func testCursorAwayFromAnyHandleIsTheArrow() throws {
        _ = aufbau()
        try bewegen(atCanvasX: 200, y: 200)
        XCTAssertEqual(NSCursor.current, NSCursor.arrow)
    }

    /// Eine gedrehte Ebene: Der linke Griff liegt jetzt an anderer
    /// Bildschirmstelle, aber der Zeiger muss ihr folgen und darf nicht mehr
    /// der ungedrehte „links/rechts"-Zeiger sein.
    func testRotatedLayerGetsARotatedCursor() throws {
        let transform = Transform2D(x: 200, y: 200, rotationDegrees: 90)
        _ = aufbau(rotationDegrees: 90)

        // Der linke Griff liegt nach 90° Drehung an anderer Bildschirmstelle,
        // seine Achse bleibt aber dieselbe „linke/rechte" wie ungedreht — nur
        // sichtbar um 90° gekippt, und damit senkrecht statt waagrecht.
        try bewegen(auf: .left, transform: transform)
        XCTAssertEqual(NSCursor.current, NSCursor.resizeUpDown)
    }
}
