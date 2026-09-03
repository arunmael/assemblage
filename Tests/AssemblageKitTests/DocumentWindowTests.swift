import XCTest
import AppKit
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

    func testWindowShowsTheThreePanesFromThePlan() throws {
        let controller = try makeWindowController(for: AssemblageDocument())

        let split = try XCTUnwrap(
            controller.contentViewController as? NSSplitViewController,
            "das Fenster muss einen Inhalt haben — nicht nur eine leere Fläche"
        )
        // Ebenen, Canvas, Eigenschaften (Plan 8).
        XCTAssertEqual(split.splitViewItems.count, 3)
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
            split.splitViewItems[1].viewController as? CanvasViewController
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
        let canvas = try XCTUnwrap(split.splitViewItems[1].viewController as? CanvasViewController)

        XCTAssertNotNil(canvas.view as? NSScrollView)
    }
}
