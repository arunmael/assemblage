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
        let size = CanvasPreset.a4Poster.size
        // DIN-A4-Seitenverhältnis: 1 : sqrt(2)
        XCTAssertEqual(size.height / size.width, 297.0 / 210.0, accuracy: 0.01)
    }

    func testCustomPresetPassesSizeThrough() {
        let custom = CanvasSize(width: 640, height: 480)
        XCTAssertEqual(CanvasPreset.custom(custom).size, custom)
    }
}
