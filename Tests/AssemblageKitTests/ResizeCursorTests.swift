import XCTest
@testable import AssemblageKit
@testable import AssemblageModel

/// Der Mauszeiger über einem Grössen-Griff (aus Anpassungen.md).
final class ResizeCursorTests: XCTestCase {

    // MARK: - Ungedreht: Achse folgt direkt dem Griff

    func testEdgeHandlesWithoutRotation() {
        XCTAssertEqual(ResizeCursor.axis(for: .left, layerRotationDegrees: 0), .horizontal)
        XCTAssertEqual(ResizeCursor.axis(for: .right, layerRotationDegrees: 0), .horizontal)
        XCTAssertEqual(ResizeCursor.axis(for: .top, layerRotationDegrees: 0), .vertical)
        XCTAssertEqual(ResizeCursor.axis(for: .bottom, layerRotationDegrees: 0), .vertical)
    }

    /// Oben-links/unten-rechts ⟍, oben-rechts/unten-links ⟋ — die beiden
    /// Diagonalen dürfen nicht vertauscht sein, sonst zeigt der Zeiger in die
    /// falsche Richtung.
    func testCornerHandlesWithoutRotation() {
        XCTAssertEqual(ResizeCursor.axis(for: .topLeft, layerRotationDegrees: 0), .topLeftBottomRight)
        XCTAssertEqual(ResizeCursor.axis(for: .bottomRight, layerRotationDegrees: 0), .topLeftBottomRight)
        XCTAssertEqual(ResizeCursor.axis(for: .topRight, layerRotationDegrees: 0), .topRightBottomLeft)
        XCTAssertEqual(ResizeCursor.axis(for: .bottomLeft, layerRotationDegrees: 0), .topRightBottomLeft)
    }

    // MARK: - Gedreht: der Zeiger folgt der sichtbaren Richtung

    /// Eine um 90° gedrehte Ebene: Ihr linker/rechter Griff liegt jetzt dort,
    /// wo vorher oben/unten war — der Zeiger muss der Drehung folgen, nicht
    /// dem ungedrehten Modell.
    func test90DegreeRotationSwapsHorizontalAndVertical() {
        XCTAssertEqual(ResizeCursor.axis(for: .left, layerRotationDegrees: 90), .vertical)
        XCTAssertEqual(ResizeCursor.axis(for: .top, layerRotationDegrees: 90), .horizontal)
    }

    /// Eine volle Umdrehung darf am Ergebnis nichts ändern.
    func test360DegreeRotationIsTheIdentity() {
        for griff in ResizeHandle.allCases {
            XCTAssertEqual(
                ResizeCursor.axis(for: griff, layerRotationDegrees: 360),
                ResizeCursor.axis(for: griff, layerRotationDegrees: 0),
                "\(griff)"
            )
        }
    }

    /// Eine Drehung um 45° dreht eine Kante genau auf eine Diagonale.
    func test45DegreeRotationTurnsAnEdgeIntoADiagonal() {
        let achse = ResizeCursor.axis(for: .right, layerRotationDegrees: 45)
        XCTAssertTrue(achse == .topLeftBottomRight || achse == .topRightBottomLeft)
    }

    /// Negative Winkel (Linksdrehung) müssen genauso funktionieren wie
    /// positive.
    func testNegativeRotationWorks() {
        XCTAssertEqual(ResizeCursor.axis(for: .left, layerRotationDegrees: -90), .vertical)
    }

    // MARK: - Zeiger selbst

    /// Für waagrecht/senkrecht gibt es eingebaute System-Zeiger — sie zu
    /// benutzen statt eigene zu zeichnen, hält den Zeiger konsistent mit dem
    /// Rest von macOS.
    func testHorizontalAndVerticalUseSystemCursors() {
        XCTAssertEqual(ResizeCursor.cursor(for: .horizontal), NSCursor.resizeLeftRight)
        XCTAssertEqual(ResizeCursor.cursor(for: .vertical), NSCursor.resizeUpDown)
    }

    /// Für die Diagonalen gibt es kein öffentliches System-Symbol — es muss
    /// trotzdem einen gültigen, benutzbaren Zeiger geben.
    func testDiagonalCursorsAreValidAndDistinct() {
        let a = ResizeCursor.cursor(for: .topLeftBottomRight)
        let b = ResizeCursor.cursor(for: .topRightBottomLeft)
        XCTAssertEqual(a.image.size.width, a.image.size.height, "der Zeiger muss quadratisch sein")
        XCTAssertGreaterThan(a.image.size.width, 0)
        XCTAssertNotEqual(a, b, "die beiden Diagonalen müssen sich unterscheiden")
    }
}
