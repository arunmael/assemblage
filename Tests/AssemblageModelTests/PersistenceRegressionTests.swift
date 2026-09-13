import XCTest
@testable import AssemblageModel

final class PersistenceRegressionTests: XCTestCase {
    func testNonFiniteColorComponentsDoNotCrashHexConversion() {
        let color = RGBA(red: .nan, green: .infinity, blue: -.infinity, alpha: .nan)
        XCTAssertEqual(color.hexString, "#00000000")
    }

    func testSavingPreservesAllDistortionHandles() throws {
        let distortion = QuadDistortion(
            topMid: Point(x: 1, y: 2), rightMid: Point(x: 3, y: 4),
            bottomMid: Point(x: 5, y: 6), leftMid: Point(x: 7, y: 8))
        let document = Document(preset: .instagramPost, layers: [Layer(
            name: "Verzogen", distortion: distortion,
            content: .shape(ShapeLayerContent(kind: .rectangle, size: Size(width: 30, height: 40))))])
        XCTAssertEqual(try DocumentPackage.decode(DocumentPackage.encode(document)), document)
    }

    func testBrokenFreehandPathAndStrokeCanStillBeSaved() throws {
        let path = VectorPath(subpath: PathSubpath(anchors: [
            PathAnchor(point: Point(x: .nan, y: 2), controlIn: Point(x: .infinity, y: 3),
                       controlOut: Point(x: 4, y: -.infinity))
        ], isClosed: true))
        let document = Document(preset: .instagramPost, layers: [Layer(
            name: "Pfad", content: .shape(ShapeLayerContent(
                kind: .freehand, size: Size(width: 30, height: 40),
                strokeWidth: .infinity, path: path)))])
        let restored = try DocumentPackage.decode(DocumentPackage.encode(document))
        guard case .shape(let shape) = restored.layers[0].content else { return XCTFail() }
        XCTAssertEqual(shape.path?.subpaths.first?.anchors.first?.point, Point(x: 0, y: 2))
        XCTAssertEqual(shape.path?.subpaths.first?.anchors.first?.controlIn, Point(x: 0, y: 3))
        XCTAssertEqual(shape.path?.subpaths.first?.anchors.first?.controlOut, Point(x: 4, y: 0))
        XCTAssertEqual(shape.path?.subpaths.first?.isClosed, true)
        XCTAssertEqual(shape.strokeWidth, 0)
    }
}
