import XCTest
import AppKit
import SwiftUI
@testable import AssemblageKit
@testable import AssemblageModel

/// Prüft, dass ein Dokumentfenster tatsächlich mit Inhalt aufgeht.
///
/// Anlass war ein leeres Fenster: `windowDidLoad()` läuft, *bevor*
/// `addWindowController(_:)` das Dokument zuweist. Der Aufbau des Inhalts
/// hing aber am Dokument und wurde deshalb nie ausgeführt — die App startete
/// mit einer dunklen, leeren Fläche. Ein Fehler, den kein Modell-Test finden
/// kann, weil an der Logik nichts falsch war.
@MainActor
final class DocumentWindowTests: XCTestCase {

    private func makeWindowController(for document: AssemblageDocument) throws -> DocumentWindowController {
        document.makeWindowControllers()
        return try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
    }

    func testWindowShowsThePanesFromThePlan() throws {
        let controller = try makeWindowController(for: AssemblageDocument())

        let split = try XCTUnwrap(
            controller.contentViewController as? NSSplitViewController,
            "das Fenster muss einen Inhalt haben — nicht nur eine leere Fläche"
        )

        // Ebenen, Werkzeuge, Canvas, Eigenschaften. Über die Typen und nicht
        // über die Anzahl: Eine Zahl sagt nicht, *welche* Spalte fehlt, und
        // bricht bei jedem Zusatz, ohne einen Fehler anzuzeigen.
        let typen = split.splitViewItems.map { ObjectIdentifier(type(of: $0.viewController)) }
        for erwartet in [ToolSidebarViewController.self, CanvasViewController.self] {
            XCTAssertTrue(typen.contains(ObjectIdentifier(erwartet)),
                          "\(erwartet) fehlt im Fenster")
        }
        XCTAssertEqual(split.splitViewItems.filter { $0.viewController is NSHostingController<LayerListView> }.count, 1)
        XCTAssertEqual(split.splitViewItems.filter { $0.viewController is NSHostingController<InspectorView> }.count, 1)
    }

    /// Der eigentliche Regressionstest: Der Inhalt muss den Zustand *dieses*
    /// Dokuments zeigen, nicht den eines leeren Ersatzdokuments.
    func testCanvasIsWiredToTheDocumentsState() throws {
        let document = AssemblageDocument()
        document.modify("Aufbauen") {
            $0.canvas = CanvasSize(width: 640, height: 480)
            try? $0.addLayer(
                Layer(name: "Probe", content: .shape(
                    ShapeLayerContent(kind: .rectangle, size: Size(width: 10, height: 10))
                ))
            )
        }

        let controller = try makeWindowController(for: document)
        let split = try XCTUnwrap(controller.contentViewController as? NSSplitViewController)
        let canvas = try XCTUnwrap(
            split.splitViewItems.compactMap { $0.viewController as? CanvasViewController }.first
        )
        _ = canvas.view  // Ansicht laden

        let scrollView = try XCTUnwrap(canvas.view as? NSScrollView)
        let canvasView = try XCTUnwrap(scrollView.documentView)

        XCTAssertEqual(canvasView.frame.size, CGSize(width: 640, height: 480),
                       "die Leinwand muss die Grösse dieses Dokuments haben")
        XCTAssertEqual(canvasView.layer?.sublayers?.first?.sublayers?.count, 1,
                       "die Ebene des Dokuments muss gerendert sein")
    }

    /// Auch ein frisch angelegtes, leeres Dokument muss ein bespielbares
    /// Fenster bekommen — sonst startet die App ins Nichts.
    func testUntitledDocumentAlsoGetsContent() throws {
        let controller = try makeWindowController(for: AssemblageDocument())
        let split = try XCTUnwrap(controller.contentViewController as? NSSplitViewController)
        let canvas = try XCTUnwrap(
            split.splitViewItems.compactMap { $0.viewController as? CanvasViewController }.first
        )

        XCTAssertNotNil(canvas.view as? NSScrollView)
    }

    func testZoomMenuDisablesCommandsAtMagnificationLimits() throws {
        let controller = try makeWindowController(for: AssemblageDocument())
        let split = try XCTUnwrap(controller.contentViewController as? NSSplitViewController)
        let canvas = try XCTUnwrap(
            split.splitViewItems.compactMap { $0.viewController as? CanvasViewController }.first
        )

        for _ in 0..<20 { canvas.zoomIn() }
        XCTAssertFalse(controller.validateMenuItem(NSMenuItem(
            title: "Einzoomen",
            action: #selector(DocumentWindowController.zoomIn(_:)),
            keyEquivalent: ""
        )))

        for _ in 0..<40 { canvas.zoomOut() }
        XCTAssertFalse(controller.validateMenuItem(NSMenuItem(
            title: "Auszoomen",
            action: #selector(DocumentWindowController.zoomOut(_:)),
            keyEquivalent: ""
        )))
    }
}

/// Das Dokumentfenster darf nicht auf nichts zusammenfallen können.
///
/// Anlass war ein Fenster, das als 860 × **42** Punkte grosser Streifen
/// startete — nur die Titelleiste. Es meldete sich als sichtbar, war aber
/// leer, und weil `setFrameAutosaveName` diesen Zustand speichert, kam die
/// App bei jedem weiteren Start so wieder hoch. Ein Fehler, den man nicht
/// mehr los wird, ohne Voreinstellungen von Hand zu löschen — genau das darf
/// nach Plan 2.1 nicht passieren.
@MainActor
final class WindowMinimumSizeTests: XCTestCase {

    private func fenster() throws -> NSWindow {
        let document = AssemblageDocument()
        document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowControllers.first)
        return try XCTUnwrap(controller.window)
    }

    /// Die Mindestgrösse muss die drei Bereiche aus Plan 8 überhaupt
    /// unterbringen können: Ebenen, Leinwand, Eigenschaften.
    func testWindowHasAUsableMinimumSize() throws {
        let w = try fenster()

        XCTAssertGreaterThanOrEqual(w.contentMinSize.width, 640)
        XCTAssertGreaterThanOrEqual(w.contentMinSize.height, 400)
    }

    /// Der entscheidende Fall, genau so aufgetreten: In den Voreinstellungen
    /// steht ein zusammengefallener Rahmen aus einer früheren Sitzung. Beim
    /// Start muss er korrigiert werden — sonst kommt die App dauerhaft leer
    /// hoch und erholt sich ohne Eingriff von Hand nicht mehr.
    func testCollapsedSavedFrameIsCorrectedOnLaunch() throws {
        let schluessel = "NSWindow Frame AssemblageDocumentWindow"
        let vorher = UserDefaults.standard.string(forKey: schluessel)
        defer {
            if let vorher {
                UserDefaults.standard.set(vorher, forKey: schluessel)
            } else {
                UserDefaults.standard.removeObject(forKey: schluessel)
            }
        }

        // Der tatsächlich vorgefundene Wert: 860 breit, 42 hoch.
        UserDefaults.standard.set("0 810 860 42 0 0 1470 923 ", forKey: schluessel)

        let w = try fenster()

        XCTAssertGreaterThanOrEqual(
            w.frame.height, w.contentMinSize.height,
            "ein zusammengefallen gesicherter Rahmen muss sich wieder aufrichten"
        )
        XCTAssertGreaterThanOrEqual(w.frame.width, w.contentMinSize.width)
    }
}

/// ⌘Z am Fenstercontroller.
///
/// Anlass: Der Befehl schliesst seit Neuestem zuerst eine laufende
/// Tastenwiederholung ab, damit ⌘Z direkt nach einer Pfeilbewegung wirkt.
/// Dieser Eingriff sitzt aber im Weg jedes anderen Widerrufens — auch dessen
/// beim Tippen in ein Textfeld, das denselben Undo-Manager benutzt.
@MainActor
final class UndoCommandRoutingTests: XCTestCase {

    private func fenster(mitEbene ebene: Layer) throws -> (AssemblageDocument, DocumentWindowController) {
        let document = AssemblageDocument()
        document.undoManager = UndoManager()
        document.modify("Vorbereiten") {
            $0.canvas = CanvasSize(width: 400, height: 300)
            $0.layers = [ebene]
        }
        document.state.selectedLayerID = ebene.id
        document.undoManager?.removeAllActions()

        let controller = DocumentWindowController()
        document.addWindowController(controller)
        return (document, controller)
    }

    private var formebene: Layer {
        Layer(name: "Form", transform: Transform2D(x: 100, y: 100),
              content: .shape(ShapeLayerContent(
                kind: .rectangle, size: Size(width: 20, height: 20))))
    }

    func testUndoRevertsAnOrdinaryChange() throws {
        let (document, controller) = try fenster(mitEbene: formebene)
        let id = try XCTUnwrap(document.state.selectedLayerID)

        document.modify("Verschieben") { try? $0.updateLayer(id: id) { $0.transform.x = 250 } }
        XCTAssertEqual(document.state.document.layers[0].transform.x, 250)

        controller.undo(nil)
        XCTAssertEqual(document.state.document.layers[0].transform.x, 100)
    }

    /// Der eigentliche Punkt: Eine Pfeilbewegung wartet kurz auf einen
    /// Folgedruck. Ohne den Abschluss davor liefe ⌘Z ins Leere — man drückt
    /// und nichts passiert.
    func testUndoWorksImmediatelyAfterANudge() throws {
        let (document, controller) = try fenster(mitEbene: formebene)
        let id = try XCTUnwrap(document.state.selectedLayerID)

        document.modifyCoalescing("Ebene bewegen", targetID: id) {
            try? $0.updateLayer(id: id) { $0.transform.x += 10 }
        }
        XCTAssertEqual(document.state.document.layers[0].transform.x, 110)

        controller.undo(nil)
        XCTAssertEqual(document.state.document.layers[0].transform.x, 100,
                       "⌘Z direkt nach einer Pfeilbewegung müsste sie zurücknehmen")
    }

    /// Widerrufen darf nicht angeboten werden, wenn es nichts zu widerrufen
    /// gibt — aber sehr wohl, solange eine Tastenwiederholung noch offen ist.
    func testUndoIsOfferedOnlyWhenThereIsSomething() throws {
        let (document, controller) = try fenster(mitEbene: formebene)
        let id = try XCTUnwrap(document.state.selectedLayerID)

        let eintrag = NSMenuItem(title: "Widerrufen",
                                 action: #selector(DocumentWindowController.undo(_:)),
                                 keyEquivalent: "z")
        XCTAssertFalse(controller.validateMenuItem(eintrag), "frisch geöffnet gibt es nichts")

        document.modifyCoalescing("Ebene bewegen", targetID: id) {
            try? $0.updateLayer(id: id) { $0.transform.x += 5 }
        }
        XCTAssertTrue(controller.validateMenuItem(eintrag),
                      "eine noch offene Tastenwiederholung zählt bereits")
    }

    /// Ein zweites Widerrufen nach dem ersten darf nicht doppelt zurückgehen,
    /// nur weil der Abschluss der Wiederholung dazwischenliegt.
    func testTwoUndoStepsGoBackOneAtATime() throws {
        let (document, controller) = try fenster(mitEbene: formebene)
        let id = try XCTUnwrap(document.state.selectedLayerID)

        // Ohne das hier ist der Test wertlos: `NSUndoManager` fasst mit
        // `groupsByEvent` alles zusammen, was innerhalb **eines** Ereignisses
        // registriert wird — und eine synchrone Testmethode ist genau ein
        // solches Ereignis. Beide Änderungen landeten sonst in einem Schritt,
        // und ein einziges Widerrufen ginge scheinbar zweimal zurück.
        // Dieselbe Falle hat dieses Projekt schon zweimal getroffen.
        // Ohne das hier wäre der Test wertlos, und ohne die ausdrückliche
        // Gruppierung darunter liefe er in einen Zustandsfehler: `NSUndoManager`
        // fasst mit `groupsByEvent` alles zusammen, was innerhalb **eines**
        // Ereignisses registriert wird — und eine synchrone Testmethode ist
        // genau ein solches Ereignis. Beide Änderungen landeten sonst in einem
        // Schritt, und ein einziges Widerrufen ginge scheinbar zweimal zurück.
        // Dieselbe Falle hat dieses Projekt schon zweimal getroffen.
        let undo = try XCTUnwrap(document.undoManager)
        undo.groupsByEvent = false

        undo.beginUndoGrouping()
        document.modify("Erste") { try? $0.updateLayer(id: id) { $0.transform.x = 150 } }
        undo.endUndoGrouping()

        undo.beginUndoGrouping()
        document.modify("Zweite") { try? $0.updateLayer(id: id) { $0.transform.x = 200 } }
        undo.endUndoGrouping()

        controller.undo(nil)
        XCTAssertEqual(document.state.document.layers[0].transform.x, 150)
        controller.undo(nil)
        XCTAssertEqual(document.state.document.layers[0].transform.x, 100)
    }
}
