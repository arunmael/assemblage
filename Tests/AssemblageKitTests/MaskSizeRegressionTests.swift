import XCTest
import AppKit
@testable import AssemblageKit
import AssemblageModel

final class MaskSizeRegressionTests: XCTestCase {
    func testUnrepresentableCropDimensionsAreRejected() {
        let layer = Layer(name: "Formbild", content: .image(ImageLayerContent(
            originalFileReference: "originals/test.png", clipShape: .ellipse)))
        for width in [Double.infinity, Double.greatestFiniteMagnitude] {
            XCTAssertNil(MaskRendering.grayMaskImage(
                for: layer, cropRect: Rect(x: 0, y: 0, width: width, height: 40),
                resources: DocumentResources()))
        }
    }

    func testInfiniteDisplaySizeIsRejected() {
        let layer = Layer(name: "Formbild", content: .image(ImageLayerContent(
            originalFileReference: "originals/test.png", clipShape: .ellipse)))
        XCTAssertNil(MaskRendering.grayMaskImage(
            for: layer, cropRect: nil, resources: DocumentResources(),
            displayedSize: CGSize(width: CGFloat.infinity, height: 40)))
    }
}
