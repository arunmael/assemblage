import XCTest
@testable import AssemblageModel

/// Farben liegen im Dokument als Hex-String (`#RRGGBB`/`#RRGGBBAA`).
/// Das Parsen ist die klassische Stelle für stille Fehler — deshalb hier
/// im portablen Modell statt im AppKit-Code, und mit Tests abgedeckt.
final class RGBATests: XCTestCase {

    func testParsesSixDigitHex() throws {
        let color = try XCTUnwrap(RGBA(hex: "#FF8000"))

        XCTAssertEqual(color.red, 1, accuracy: 0.001)
        XCTAssertEqual(color.green, 0.5019, accuracy: 0.001)
        XCTAssertEqual(color.blue, 0, accuracy: 0.001)
        XCTAssertEqual(color.alpha, 1, accuracy: 0.001)
    }

    func testParsesEightDigitHexWithAlpha() throws {
        let color = try XCTUnwrap(RGBA(hex: "#00000080"))

        XCTAssertEqual(color.alpha, 0.5019, accuracy: 0.001)
    }

    func testAcceptsHexWithoutLeadingHash() throws {
        XCTAssertEqual(RGBA(hex: "FFFFFF"), RGBA(hex: "#FFFFFF"))
    }

    func testIsCaseInsensitive() {
        XCTAssertEqual(RGBA(hex: "#aabbcc"), RGBA(hex: "#AABBCC"))
    }

    /// Ein kaputter Farbwert (etwa aus einer von Hand bearbeiteten
    /// document.json) darf nicht zum Absturz führen — der Renderer weicht
    /// dann auf eine Ersatzfarbe aus (Plan 2.1).
    func testRejectsMalformedHexInsteadOfCrashing() {
        XCTAssertNil(RGBA(hex: ""))
        XCTAssertNil(RGBA(hex: "#FFF"))
        XCTAssertNil(RGBA(hex: "#GGGGGG"))
        XCTAssertNil(RGBA(hex: "#FF00000"))
        XCTAssertNil(RGBA(hex: "Rot"))
    }

    func testHexStringRoundTrip() throws {
        let original = "#3A7BD5"
        let color = try XCTUnwrap(RGBA(hex: original))

        XCTAssertEqual(color.hexString, original)
    }

    /// Deckende Farben werden ohne Alpha-Anteil geschrieben — das hält die
    /// document.json lesbar und erzeugt keine unnötigen Unterschiede zwischen
    /// zwei gespeicherten Versionen.
    func testHexStringOmitsAlphaWhenOpaque() throws {
        XCTAssertEqual(RGBA(red: 0, green: 0, blue: 0, alpha: 1).hexString, "#000000")
        XCTAssertEqual(RGBA(red: 0, green: 0, blue: 0, alpha: 0.5).hexString, "#00000080")
    }
}
