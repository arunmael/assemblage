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

    /// Zu jedem verschwindenden Widget gehört ein Schloss, und es steht neben
    /// dem Widget statt darauf — sonst verdeckte es dessen Inhalt.
    func testEveryHidingWidgetHasALockBesideIt() throws {
        let (stage, container) = try makeStage()
        let steuerung = try XCTUnwrap(stage.autoHideController)
        let inspector = try XCTUnwrap(stage.inspectorPanel)

        steuerung.update(mouse: NSPoint(x: container.bounds.maxX - 2, y: container.bounds.midY))
        container.layoutSubtreeIfNeeded()

        let schloesser = container.subviews.compactMap { $0 as? NSButton }
            .filter { $0.accessibilityLabel() == "Widget offen halten" }
        XCTAssertEqual(schloesser.count, 3, "Ebenen, Werkzeuge und Eigenschaften")

        let amInspector = try XCTUnwrap(
            schloesser.first { $0.frame.maxX <= inspector.frame.minX + 1 },
            "das Schloss des Eigenschaften-Panels muss links davon liegen: \(schloesser.map(\.frame))"
        )
        XCTAssertFalse(
            amInspector.frame.intersects(inspector.frame),
            "das Schloss darf das Widget nicht überlappen"
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
