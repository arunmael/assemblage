import XCTest
import AppKit
@testable import AssemblageKit

final class WindowPlacementTests: XCTestCase {

    /// Beim Start soll das Fenster den ganzen nutzbaren Bildschirm einnehmen
    /// (Nutzer-Auftrag) — nicht Vollbild, sondern genau `visibleFrame`, damit
    /// Menüleiste und Dock erreichbar bleiben.
    func testFillsTheVisibleScreenArea() {
        let sichtbar = NSRect(x: 0, y: 60, width: 1920, height: 1020)
        XCTAssertEqual(
            WindowPlacement.initialFrame(visibleFrame: sichtbar,
                                         minimumSize: NSSize(width: 880, height: 520)),
            sichtbar
        )
    }

    /// Ein Bildschirm, der kleiner als die Mindestgrösse des Fensters ist,
    /// darf kein zu kleines Fenster erzwingen — sonst kippt das Layout.
    func testNeverSmallerThanTheMinimumSize() {
        let winzig = NSRect(x: 10, y: 10, width: 400, height: 300)
        let rahmen = WindowPlacement.initialFrame(visibleFrame: winzig,
                                                  minimumSize: NSSize(width: 880, height: 520))
        XCTAssertEqual(rahmen.width, 880)
        XCTAssertEqual(rahmen.height, 520)
        XCTAssertEqual(rahmen.origin, winzig.origin)
    }

    /// Ein unbrauchbarer Bildschirmrahmen (kein Bildschirm angeschlossen,
    /// kaputte Werte) darf keinen NaN-Rahmen erzeugen.
    func testInvalidScreenFrameFallsBackToTheMinimumSize() {
        let kaputt = NSRect(x: CGFloat.nan, y: 0, width: CGFloat.infinity, height: 0)
        let rahmen = WindowPlacement.initialFrame(visibleFrame: kaputt,
                                                  minimumSize: NSSize(width: 880, height: 520))
        XCTAssertEqual(rahmen, NSRect(x: 0, y: 0, width: 880, height: 520))
    }
}
