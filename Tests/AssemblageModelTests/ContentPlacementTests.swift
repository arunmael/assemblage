import XCTest
@testable import AssemblageModel

final class ContentPlacementTests: XCTestCase {

    func testFillSchneidetMittigUndSkaliertGleichmaessig() throws {
        let result = ContentPlacement.fill(
            contentSize: Size(width: 400, height: 200),
            frame: Rect(x: 10, y: 20, width: 100, height: 100)
        )
        XCTAssertEqual(result.cropRect, Rect(x: 100, y: 0, width: 200, height: 200))
        XCTAssertEqual(result.transform.scaleX, result.transform.scaleY, accuracy: 0.000_001)
        XCTAssertEqual(result.transform.x, 60)
        XCTAssertEqual(result.transform.y, 70)
    }

    func testStretchBehältInhaltUndSkaliertUngleich() {
        let result = ContentPlacement.stretch(
            contentSize: Size(width: 400, height: 200),
            frame: Rect(x: 10, y: 20, width: 100, height: 100)
        )
        XCTAssertNil(result.cropRect)
        XCTAssertNotEqual(result.transform.scaleX, result.transform.scaleY, accuracy: 0.000_001)
    }

    func testUngueltigeGroessenLiefernEndlicheWerte() {
        let results = [
            ContentPlacement.fill(contentSize: .zero, frame: Rect(x: 1, y: 2, width: 100, height: 100)),
            ContentPlacement.fill(contentSize: Size(width: 10, height: 10), frame: Rect(x: 1, y: 2, width: 0, height: 0)),
            ContentPlacement.stretch(contentSize: .zero, frame: Rect(x: 1, y: 2, width: 100, height: 100)),
            ContentPlacement.stretch(contentSize: Size(width: 10, height: 10), frame: Rect(x: 1, y: 2, width: 0, height: 0))
        ]
        for result in results {
            XCTAssertTrue(result.transform.x.isFinite)
            XCTAssertTrue(result.transform.y.isFinite)
            XCTAssertTrue(result.transform.scaleX.isFinite)
            XCTAssertTrue(result.transform.scaleY.isFinite)
        }
    }
}
