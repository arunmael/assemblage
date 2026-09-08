import XCTest
import AppKit
@testable import AssemblageKit

/// Das Layout der schwebenden Werkzeugzeile.
@MainActor
final class ToolbarRowLayoutTests: XCTestCase {

    private func werkzeugzeile() throws -> NSView {
        let document = AssemblageDocument()
        document.makeWindowControllers()
        let windowController = try XCTUnwrap(
            document.windowControllers.first as? DocumentWindowController
        )
        let canvas = CanvasViewController(state: document.state)
        let toolbar = ToolbarController(
            state: document.state,
            canvasViewController: canvas,
            commandTarget: windowController
        )

        let row = toolbar.buildFloatingToolbarRow()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 200))
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return row
    }

    /// Alle Panels der Zeile — Werkzeuge links, Werkzeuge rechts, Suchfeld
    /// und Teilen — müssen gleich hoch sein. `NSStackView` dehnt seine
    /// Ansichten nicht von selbst; ohne ausdrückliche Höhen sähe die Zeile
    /// wieder ungleichmässig aus.
    func testAllePanelsDerZeileSindGleichHoch() throws {
        let row = try werkzeugzeile()
        let panels = row.subviews

        XCTAssertEqual(panels.count, 4, "Werkzeuge links, Werkzeuge rechts, Suchen, Teilen")

        let höhen = panels.map(\.frame.height)
        for höhe in höhen {
            // 58 pt: gibt der aktive, 30 % grössere Werkzeugknopf vor (siehe
            // `ToolbarController.activeToolScale`).
            XCTAssertEqual(höhe, 58, accuracy: 0.5, "Panelhöhen: \(höhen)")
        }
    }

    /// Die Zeile hängt rechts am Fensterrand und wächst nach links.
    func testDieZeileBleibtRechtsbündig() throws {
        let row = try werkzeugzeile()
        let host = try XCTUnwrap(row.superview)

        XCTAssertEqual(row.frame.maxX, host.bounds.maxX, accuracy: 0.5)
        XCTAssertLessThan(row.frame.minX, host.bounds.maxX)
    }

    /// Punkt 5 der UI-Sammlung: links nur noch die drei wichtigsten
    /// Werkzeuge, alles Weitere im rechten Cluster.
    func testLinkesWerkzeugPanelHatGenauDreiKnöpfe() throws {
        let row = try werkzeugzeile()
        let linkesPanel = try XCTUnwrap(row.subviews.first)

        XCTAssertEqual(buttons(in: linkesPanel).count, 3)
    }

    /// Punkt 6 der UI-Sammlung: Über beide Werkzeug-Cluster zusammen darf
    /// jedes Werkzeug nur einmal auftauchen. Vorher teilten sich „Pinsel"
    /// und „Farbe malen" ein Icon, ebenso „Bild ausschneiden" und
    /// „Freistellen" — das sah aus, als wäre dasselbe Werkzeug doppelt da.
    func testKeinWerkzeugKommtInDenClusternDoppeltVor() throws {
        let row = try werkzeugzeile()
        let cluster = Array(row.subviews.prefix(2))

        let namen = cluster
            .flatMap { buttons(in: $0) }
            .compactMap { $0.accessibilityLabel() }
            .filter { !$0.isEmpty }

        XCTAssertFalse(namen.isEmpty)
        XCTAssertEqual(
            namen.count, Set(namen).count,
            "doppelt vergeben: \(namen.sorted())"
        )
    }

    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { child in
            (child as? NSButton).map { [$0] } ?? buttons(in: child)
        }
    }
}
