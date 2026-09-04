import XCTest
@testable import AssemblageModel

final class ShapeGeometryTests: XCTestCase {

    private let testSize = Size(width: 100.0, height: 80.0)
    private let tolerance = 0.001

    func testPointsAreWithinBounds() {
        for template in ShapeTemplate.allCases {
            let points = ShapeGeometry.outline(of: template, size: testSize)
            XCTAssertFalse(points.isEmpty, "Vorlage \(template) lieferte keine Punkte.")

            for point in points {
                XCTAssertGreaterThanOrEqual(point.x, -tolerance, "X-Wert \(point.x) von \(template) liegt ausserhalb der linken Grenze.")
                XCTAssertLessThanOrEqual(point.x, testSize.width + tolerance, "X-Wert \(point.x) von \(template) liegt ausserhalb der rechten Grenze.")
                XCTAssertGreaterThanOrEqual(point.y, -tolerance, "Y-Wert \(point.y) von \(template) liegt ausserhalb der oberen Grenze.")
                XCTAssertLessThanOrEqual(point.y, testSize.height + tolerance, "Y-Wert \(point.y) von \(template) liegt ausserhalb der unteren Grenze.")
            }
        }
    }

    func testHasAtLeastThreePoints() {
        for template in ShapeTemplate.allCases {
            let points = ShapeGeometry.outline(of: template, size: testSize)
            XCTAssertGreaterThanOrEqual(points.count, 3, "Vorlage \(template) hat weniger als 3 Punkte.")
        }
    }

    func testExploitsRectangleBounds() {
        for template in ShapeTemplate.allCases {
            let points = ShapeGeometry.outline(of: template, size: testSize)
            let xs = points.map { $0.x }
            let ys = points.map { $0.y }

            let minX = xs.min() ?? 0.0
            let maxX = xs.max() ?? 0.0
            let minY = ys.min() ?? 0.0
            let maxY = ys.max() ?? 0.0

            let spanX = maxX - minX
            let spanY = maxY - minY

            XCTAssertGreaterThanOrEqual(spanX, testSize.width * 0.8, "Vorlage \(template) nutzt die Breite nicht ausreichend aus.")
            XCTAssertGreaterThanOrEqual(spanY, testSize.height * 0.8, "Vorlage \(template) nutzt die Höhe nicht ausreichend aus.")
        }
    }

    func testZeroOrNegativeSizeReturnsEmpty() {
        let zeroSize = Size(width: 0.0, height: 80.0)
        let negativeSize = Size(width: 100.0, height: -10.0)

        for template in ShapeTemplate.allCases {
            XCTAssertTrue(ShapeGeometry.outline(of: template, size: zeroSize).isEmpty)
            XCTAssertTrue(ShapeGeometry.outline(of: template, size: negativeSize).isEmpty)
        }
    }

    func testExactPointCountsForPolygons() {
        XCTAssertEqual(ShapeGeometry.outline(of: .triangle, size: testSize).count, 3)
        XCTAssertEqual(ShapeGeometry.outline(of: .pentagon, size: testSize).count, 5)
        XCTAssertEqual(ShapeGeometry.outline(of: .hexagon, size: testSize).count, 6)
    }

    func testStarPointCountLimits() {
        XCTAssertEqual(ShapeGeometry.outline(of: .star, size: testSize).count, 10)
        XCTAssertEqual(ShapeGeometry.outline(of: .star, size: testSize, pointCount: 8).count, 16)
        XCTAssertEqual(ShapeGeometry.outline(of: .star, size: testSize, pointCount: 1).count, 6)
        XCTAssertEqual(ShapeGeometry.outline(of: .star, size: testSize, pointCount: 100).count, 40)
    }

    func testHeartPointCount() {
        let points = ShapeGeometry.outline(of: .heart, size: testSize)
        XCTAssertGreaterThanOrEqual(points.count, 40)
    }

    func testNoConsecutiveDuplicatePoints() {
        for template in ShapeTemplate.allCases {
            let points = ShapeGeometry.outline(of: template, size: testSize)
            guard points.count > 1 else { continue }

            for i in 0..<(points.count - 1) {
                let current = points[i]
                let next = points[i + 1]
                XCTAssertNotEqual(current, next, "Vorlage \(template) hat identische aufeinanderfolgende Punkte an Index \(i).")
            }

            // Schliessung des Pfades darf den Startpunkt nicht explizit duplizieren
            if let first = points.first, let last = points.last {
                XCTAssertNotEqual(first, last, "Vorlage \(template) wiederholt den Startpunkt am Ende.")
            }
        }
    }
}
