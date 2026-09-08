import XCTest
import AppKit
@testable import AssemblageKit

/// Die Regel, welche Fensterkante der Zeiger weckt — nach dem Vorbild des
/// macOS-Docks (Nutzer-Auftrag). Rein rechnerisch prüfbar, deshalb ohne
/// Fenster und ohne echte Mausbewegung.
final class WidgetAutoHideTests: XCTestCase {

    private let flaeche = NSRect(x: 0, y: 0, width: 1000, height: 800)

    private func kanten(
        _ punkt: NSPoint,
        flipped: Bool = false,
        widgets: [(edge: WidgetAutoHideController.Edge, frame: NSRect)] = []
    ) -> Set<WidgetAutoHideController.Edge> {
        WidgetAutoHideController.revealedEdges(
            mouse: punkt, in: flaeche, flipped: flipped, widgets: widgets
        )
    }

    func testMitteWecktNichts() {
        XCTAssertTrue(kanten(NSPoint(x: 500, y: 400)).isEmpty)
    }

    func testJedeKanteWecktNurSichSelbst() {
        XCTAssertEqual(kanten(NSPoint(x: 5, y: 400)), [.left])
        XCTAssertEqual(kanten(NSPoint(x: 995, y: 400)), [.right])
        // Ungeflippt liegt oben bei den grossen y-Werten.
        XCTAssertEqual(kanten(NSPoint(x: 500, y: 795)), [.top])
        XCTAssertEqual(kanten(NSPoint(x: 500, y: 5)), [.bottom])
    }

    /// In einer geflippten Ansicht dreht sich oben und unten um. Ohne diese
    /// Unterscheidung führe die Werkzeugleiste heraus, wenn man die Zoomleiste
    /// unten ansteuert.
    func testGeflippteAnsichtDrehtObenUndUnten() {
        XCTAssertEqual(kanten(NSPoint(x: 500, y: 5), flipped: true), [.top])
        XCTAssertEqual(kanten(NSPoint(x: 500, y: 795), flipped: true), [.bottom])
    }

    func testEckeWecktBeideKanten() {
        XCTAssertEqual(kanten(NSPoint(x: 5, y: 5)), [.left, .bottom])
    }

    /// Sobald ein Panel draussen ist, muss es wach bleiben, solange der Zeiger
    /// darauf steht — sonst führe es wieder hinaus, kaum dass man es benutzen
    /// will.
    func testZeigerAufAusgefahrenemWidgetHaeltDieKanteWach() {
        let panel = NSRect(x: 24, y: 24, width: 248, height: 752)
        XCTAssertEqual(
            kanten(NSPoint(x: 150, y: 400), widgets: [(.left, panel)]),
            [.left],
            "der Zeiger steht mitten auf dem Ebenen-Panel"
        )
    }

    func testZeigerNebenDemWidgetWecktNichts() {
        let panel = NSRect(x: 24, y: 24, width: 248, height: 752)
        XCTAssertTrue(kanten(NSPoint(x: 600, y: 400), widgets: [(.left, panel)]).isEmpty)
    }
}
