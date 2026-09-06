import XCTest
@testable import AssemblageModel

final class ShapeTemplateConsistencyTests: XCTestCase {

    func testVorlagenUndFormartenHabenIdentischeRohwerte() throws {
        for template in ShapeTemplate.allCases {
            let kind = try XCTUnwrap(
                ShapeKind(rawValue: template.rawValue),
                "Für \(template.rawValue) fehlt ein ShapeKind"
            )
            XCTAssertEqual(kind.template, template)
        }

        XCTAssertEqual(
            Set(ShapeKind.allCases.compactMap { $0.template?.rawValue }),
            Set(ShapeTemplate.allCases.map(\.rawValue))
        )
    }

    func testJedeVorlageLiefertGueltigePunkteImZielrechteck() {
        let size = Size(width: 100, height: 100)

        for template in ShapeTemplate.allCases {
            let points = ShapeGeometry.outline(of: template, size: size)
            XCTAssertGreaterThanOrEqual(points.count, 3, "\(template)")
            for point in points {
                XCTAssertTrue(point.x.isFinite && point.y.isFinite, "\(template): \(point)")
                XCTAssertTrue((0...100).contains(point.x), "\(template): x=\(point.x)")
                XCTAssertTrue((0...100).contains(point.y), "\(template): y=\(point.y)")
            }
        }
    }
}
