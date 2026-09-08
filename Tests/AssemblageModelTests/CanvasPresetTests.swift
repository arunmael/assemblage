import XCTest
@testable import AssemblageModel

/// Deckt die Canvas-Vorlagen aus 5.1 ab.
final class CanvasPresetTests: XCTestCase {
    func testInstagramPostIsSquare() {
        let size = CanvasPreset.instagramPost.size
        XCTAssertEqual(size.width, size.height)
    }

    func testInstagramStoryIsPortrait9x16() {
        let size = CanvasPreset.instagramStory.size
        XCTAssertEqual(size.width / size.height, 9.0 / 16.0, accuracy: 0.001)
    }

    func testA4PosterIsPortraitDIN() {
        let size = CanvasPreset.a4Portrait.size
        // DIN-A4-Seitenverhältnis: 1 : sqrt(2)
        XCTAssertEqual(size.height / size.width, 297.0 / 210.0, accuracy: 0.01)
    }

    func testCustomPresetPassesSizeThrough() {
        let custom = CanvasSize(width: 640, height: 480)
        XCTAssertEqual(CanvasPreset.custom(custom).size, custom)
    }

    /// A4 muss es in beiden Ausrichtungen geben (Nutzer-Auftrag) — und quer
    /// muss wirklich die gedrehte Hochkant-Grösse sein, nicht eine eigene.
    func testA4LandscapeIsTheRotatedPortrait() {
        let hoch = CanvasPreset.a4Portrait.size
        let quer = CanvasPreset.a4Landscape.size
        XCTAssertEqual(quer.width, hoch.height)
        XCTAssertEqual(quer.height, hoch.width)
        XCTAssertGreaterThan(quer.width, quer.height, "quer muss breiter als hoch sein")
    }

    /// Bei 300 dpi ist ein A4-Blatt 2480 × 3508 Punkte gross. Der Wert steckt
    /// in der Vorlage und darf nicht versehentlich auf 72 dpi zurückfallen.
    func testA4UsesThreeHundredDPI() {
        XCTAssertEqual(CanvasPreset.a4Portrait.size, CanvasSize(width: 2480, height: 3508))
    }

    /// Das Vorlagenmenü stellt den passenden Eintrag ein, wenn die aktuelle
    /// Leinwand einer Vorlage entspricht — und „Eigene Grösse", wenn nicht.
    func testMatchingFindsThePresetForAKnownSize() {
        XCTAssertEqual(CanvasPreset.matching(CanvasSize(width: 3508, height: 2480)), .a4Landscape)
        XCTAssertEqual(CanvasPreset.matching(CanvasSize(width: 1080, height: 1080)), .instagramPost)
        XCTAssertNil(CanvasPreset.matching(CanvasSize(width: 123, height: 456)))
    }

    /// Jede auswählbare Vorlage braucht eine Beschriftung und eine gültige
    /// Grösse — sonst stünde im Menü ein leerer oder unbrauchbarer Eintrag.
    func testEverySelectablePresetIsUsable() {
        for vorlage in CanvasPreset.selectable {
            XCTAssertFalse(vorlage.displayName.isEmpty, "\(vorlage) ohne Namen")
            XCTAssertGreaterThan(vorlage.size.width, 0, "\(vorlage) ohne Breite")
            XCTAssertGreaterThan(vorlage.size.height, 0, "\(vorlage) ohne Höhe")
        }
    }
}
