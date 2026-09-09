import XCTest
import AppKit
@testable import AssemblageKit

/// Prüft am echten Fensterlayout, was das automatische Ausblenden mit den
/// Widgets macht: Ebenen, Werkzeuge und Eigenschaften fahren hinaus, Lineal,
/// Zoom und Verlauf bleiben sichtbar (Nutzer-Auftrag).
@MainActor
final class WidgetAutoHideStageTests: XCTestCase {

    private func makeStage() throws -> (DocumentStageViewController, NSView) {
        let document = AssemblageDocument()
        document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 820), display: false)
        let huelle = try XCTUnwrap(controller.contentViewController as? WindowDropZoneViewController)
        let stage = try XCTUnwrap(huelle.children.first as? DocumentStageViewController)
        window.contentView?.layoutSubtreeIfNeeded()
        return (stage, stage.view)
    }

    /// Der Zeiger mitten auf der Leinwand versteckt alles, was verschwinden darf.
    func testMouseInTheMiddleSendsThePanelsOut() throws {
        let (stage, container) = try makeStage()
        let steuerung = try XCTUnwrap(stage.autoHideController)

        steuerung.update(mouse: NSPoint(x: container.bounds.midX, y: container.bounds.midY))
        container.layoutSubtreeIfNeeded()

        let inspector = try XCTUnwrap(stage.inspectorPanel)
        XCTAssertGreaterThanOrEqual(
            inspector.frame.minX, container.bounds.maxX,
            "das Eigenschaften-Panel muss rechts aus dem Fenster gefahren sein"
        )
    }

    /// Lineal, Zoom und Verlauf bleiben stehen — sie rücken nur an den Rand.
    func testTheAlwaysVisibleWidgetsStayInside() throws {
        let (stage, container) = try makeStage()
        let steuerung = try XCTUnwrap(stage.autoHideController)

        steuerung.update(mouse: NSPoint(x: container.bounds.midX, y: container.bounds.midY))
        container.layoutSubtreeIfNeeded()

        let lineal = try XCTUnwrap(stage.horizontalRuler?.superview)
        XCTAssertTrue(
            container.bounds.contains(lineal.frame),
            "das Lineal muss sichtbar bleiben, es rückt nur an den Rand: \(lineal.frame)"
        )
    }

    /// Alle Schlösser im Ansichtsbaum, egal wie tief sie eingehängt sind.
    private func schloesser(in view: NSView) -> [NSButton] {
        var gefunden: [NSButton] = []
        if let knopf = view as? NSButton, knopf.accessibilityLabel() == "Widget offen halten" {
            gefunden.append(knopf)
        }
        for kind in view.subviews { gefunden += schloesser(in: kind) }
        return gefunden
    }

    /// Zu jedem verschwindenden Widget gehört genau ein Schloss.
    func testEveryHidingWidgetHasALock() throws {
        let (_, container) = try makeStage()

        XCTAssertEqual(
            schloesser(in: container).count, 3, "Ebenen, Werkzeuge und Eigenschaften"
        )
    }

    /// Das Schloss des Ebenen-Panels sitzt in dessen Fusszeile, direkt neben
    /// dem Mülleimer — ausserhalb des Panels war es unerreichbar, weil das
    /// Panel einfuhr, sobald der Zeiger es verliess (Nutzer-Rückmeldung).
    func testTheLayersLockSitsInsideThePanelNextToTheBin() throws {
        let (stage, container) = try makeStage()
        let steuerung = try XCTUnwrap(stage.autoHideController)
        let ebenen = try XCTUnwrap(stage.layersPanel)

        steuerung.update(mouse: NSPoint(x: 2, y: container.bounds.midY))
        container.layoutSubtreeIfNeeded()

        let schloss = try XCTUnwrap(
            schloesser(in: ebenen).first, "das Schloss muss im Ebenen-Panel hängen"
        )
        XCTAssertTrue(
            ebenen.bounds.insetBy(dx: -1, dy: -1).contains(ebenen.convert(schloss.bounds, from: schloss)),
            "und vollständig darin liegen"
        )
    }

    /// Das Schloss des Eigenschaften-Panels sitzt unten rechts in dessen Ecke,
    /// mit etwas Abstand zum Rand (Nutzer-Auftrag).
    func testTheInspectorLockSitsInItsBottomRightCorner() throws {
        let (stage, container) = try makeStage()
        let steuerung = try XCTUnwrap(stage.autoHideController)
        let inspector = try XCTUnwrap(stage.inspectorPanel)

        steuerung.update(mouse: NSPoint(x: container.bounds.maxX - 2, y: container.bounds.midY))
        container.layoutSubtreeIfNeeded()

        let schloss = try XCTUnwrap(
            schloesser(in: inspector).first, "das Schloss muss im Eigenschaften-Panel hängen"
        )
        let rahmen = inspector.convert(schloss.bounds, from: schloss)
        XCTAssertEqual(inspector.bounds.maxX - rahmen.maxX, 14, accuracy: 1, "Abstand nach rechts")
        // Der Container ist nicht geflippt: unten heisst kleines y.
        XCTAssertEqual(rahmen.minY - inspector.bounds.minY, 14, accuracy: 1, "Abstand nach unten")
    }

    /// Fährt der Zeiger auf ein Schloss, darf sich dessen Widget nicht
    /// schliessen — sonst kommt man nie hin (Nutzer-Rückmeldung zur
    /// Werkzeugleiste, deren Schloss neben ihr liegt).
    func testHoveringALockKeepsItsWidgetOut() throws {
        let (stage, container) = try makeStage()
        let steuerung = try XCTUnwrap(stage.autoHideController)
        let werkzeuge = try XCTUnwrap(stage.toolbarRowForTesting)

        // Erst an die Oberkante, damit die Werkzeugleiste herauskommt …
        steuerung.update(mouse: NSPoint(x: container.bounds.midX, y: container.bounds.maxY - 2))
        container.layoutSubtreeIfNeeded()

        let schloss = try XCTUnwrap(
            schloesser(in: container).first { $0.superview === container },
            "das Schloss der Werkzeugleiste hängt neben ihr im Container"
        )
        // … dann mitten auf ihr Schloss.
        steuerung.update(mouse: NSPoint(x: schloss.frame.midX, y: schloss.frame.midY))
        container.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            container.bounds.contains(werkzeuge.frame),
            "die Werkzeugleiste muss draussen bleiben: \(werkzeuge.frame)"
        )
    }

    /// Ein festgestelltes Widget bleibt draussen, auch wenn der Zeiger längst
    /// woanders ist (Nutzer-Auftrag: Schloss).
    func testAPinnedWidgetStaysOut() throws {
        let (stage, container) = try makeStage()
        let steuerung = try XCTUnwrap(stage.autoHideController)
        let inspector = try XCTUnwrap(stage.inspectorPanel)

        steuerung.setPinnedForTesting(edge: .right, pinned: true)
        steuerung.update(mouse: NSPoint(x: container.bounds.midX, y: container.bounds.midY))
        container.layoutSubtreeIfNeeded()

        XCTAssertLessThan(
            inspector.frame.maxX, container.bounds.maxX + 1,
            "das festgestellte Eigenschaften-Panel darf nicht hinausfahren"
        )
    }

    /// Am rechten Rand kommt das Eigenschaften-Panel zurück — und nur das.
    func testTheRightEdgeBringsTheInspectorBack() throws {
        let (stage, container) = try makeStage()
        let steuerung = try XCTUnwrap(stage.autoHideController)
        let inspector = try XCTUnwrap(stage.inspectorPanel)

        steuerung.update(mouse: NSPoint(x: container.bounds.midX, y: container.bounds.midY))
        container.layoutSubtreeIfNeeded()
        steuerung.update(mouse: NSPoint(x: container.bounds.maxX - 2, y: container.bounds.midY))
        container.layoutSubtreeIfNeeded()

        XCTAssertLessThan(
            inspector.frame.maxX, container.bounds.maxX + 1,
            "am rechten Rand muss das Eigenschaften-Panel wieder hereinfahren"
        )
    }
}
