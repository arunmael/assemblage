import XCTest
import AppKit
@testable import AssemblageKit

/// Die aufklappende Werkzeugleiste (aus missing.md).
///
/// Geprüft wird die Mechanik, nicht das Aussehen: Breite, was sichtbar ist,
/// welche Zeile Klicks annimmt. Das sind genau die Stellen, an denen eine
/// solche Leiste kaputtgeht — zugeklappt mit sichtbaren, abgeschnittenen
/// Beschriftungen, oder ein ausgegrautes Werkzeug, das trotzdem schaltet.
@MainActor
final class ToolSidebarTests: XCTestCase {

    private func leiste() -> ToolSidebarView {
        ToolSidebarView(items: [
            ToolSidebarItem(tool: .select, title: "Auswählen", symbolName: "cursorarrow"),
            ToolSidebarItem(tool: .crop, title: "Zuschneiden", symbolName: "crop"),
            ToolSidebarItem(tool: .brush, title: "Pinsel", symbolName: "paintbrush"),
            ToolSidebarItem(tool: .distort, title: "Verziehen", symbolName: "skew")
        ])
    }

    func testStartsCollapsed() {
        let leiste = leiste()
        XCTAssertFalse(leiste.isExpanded)
        leiste.layoutSubtreeIfNeeded()
        XCTAssertEqual(leiste.fittingSize.width, ToolSidebarView.collapsedWidth, accuracy: 0.5)
    }

    func testExpandingWidensTheBar() {
        let leiste = leiste()
        leiste.setExpanded(true, animated: false)
        leiste.layoutSubtreeIfNeeded()

        XCTAssertTrue(leiste.isExpanded)
        XCTAssertEqual(leiste.fittingSize.width, ToolSidebarView.expandedWidth, accuracy: 0.5)
    }

    func testCollapsingReturnsToTheNarrowWidth() {
        let leiste = leiste()
        leiste.setExpanded(true, animated: false)
        leiste.setExpanded(false, animated: false)
        leiste.layoutSubtreeIfNeeded()

        XCTAssertFalse(leiste.isExpanded)
        XCTAssertEqual(leiste.fittingSize.width, ToolSidebarView.collapsedWidth, accuracy: 0.5)
    }

    /// Im zugeklappten Zustand dürfen keine Beschriftungen stehen — sie wären
    /// abgeschnitten.
    func testLabelsAreHiddenWhileCollapsed() {
        let leiste = leiste()
        XCTAssertTrue(leiste.labelsHiddenForTesting)

        leiste.setExpanded(true, animated: false)
        XCTAssertFalse(leiste.labelsHiddenForTesting)
    }

    /// Zugeklappt ist nur ein Symbol zu sehen. Ohne Kurzhinweis wäre nicht
    /// erkennbar, was es bedeutet.
    func testEveryRowCarriesItsTitleAsTooltip() {
        XCTAssertEqual(
            leiste().toolTipsForTesting.sorted(),
            ["Auswählen", "Pinsel", "Verziehen", "Zuschneiden"]
        )
    }

    // MARK: - Auswahl

    func testTapReportsTheTool() {
        let leiste = leiste()
        var gemeldet: [CanvasTool] = []
        leiste.onSelect = { gemeldet.append($0) }

        leiste.simulateTapForTesting(.crop)
        XCTAssertEqual(gemeldet, [.crop])
    }

    /// Die Zeile hebt sich nicht selbst hervor: Ein zweiter Klick auf dasselbe
    /// Werkzeug schaltet zurück auf Auswählen, und diese Regel kennt nur der
    /// Aufrufer.
    func testTapDoesNotChangeTheSelectionItself() {
        let leiste = leiste()
        leiste.selectedTool = .select
        leiste.simulateTapForTesting(.brush)
        XCTAssertEqual(leiste.selectedTool, .select)
    }

    /// Ein ausgegrautes Werkzeug darf nicht schalten — sonst führt die Leiste
    /// in einen Modus, den die Auswahl gar nicht zulässt.
    func testUnavailableToolsDoNotReport() {
        let leiste = leiste()
        var gemeldet: [CanvasTool] = []
        leiste.onSelect = { gemeldet.append($0) }
        leiste.availableTools = [.select]

        leiste.simulateTapForTesting(.crop)
        XCTAssertTrue(gemeldet.isEmpty)

        leiste.simulateTapForTesting(.select)
        XCTAssertEqual(gemeldet, [.select])
    }
}
