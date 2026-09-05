import XCTest
@testable import AssemblageModel

final class ShapeGeometryExtendedTests: XCTestCase {
    
    private let testSize = Size(width: 120.0, height: 90.0)
    private let tolerance = 0.001
    
    private let newTemplates: [ShapeTemplate] = [
        .diamond,
        .cross,
        .octagon,
        .rightTriangle,
        .parallelogram,
        .trapezoid,
        .crescent,
        .lightningBolt,
        .cloud,
        .shield
    ]
    
    func testNewTemplatesPointBounds() {
        // Strikte Überprüfung, dass kein Punkt die definierten Partitionsgrenzen überschreitet
        for template in newTemplates {
            let points = ShapeGeometry.outline(of: template, size: testSize)
            for point in points {
                XCTAssertGreaterThanOrEqual(point.x, -tolerance, "\(template): x-Wert \(point.x) unter dem Minimum")
                XCTAssertLessThanOrEqual(point.x, testSize.width + tolerance, "\(template): x-Wert \(point.x) über dem Maximum")
                XCTAssertGreaterThanOrEqual(point.y, -tolerance, "\(template): y-Wert \(point.y) unter dem Minimum")
                XCTAssertLessThanOrEqual(point.y, testSize.height + tolerance, "\(template): y-Wert \(point.y) über dem Maximum")
            }
        }
    }
    
    func testNewTemplatesMinimumPoints() {
        // Jede geschlossene 2D-Form benötigt mindestens ein Dreieck (3 Punkte)
        for template in newTemplates {
            let points = ShapeGeometry.outline(of: template, size: testSize)
            XCTAssertGreaterThanOrEqual(points.count, 3, "\(template) hat weniger als 3 Punkte")
        }
    }
    
    func testNewTemplatesSpan() {
        // Verhindert, dass Formen kollabieren oder das Layout-Rechteck unzureichend ausfüllen
        for template in newTemplates {
            let points = ShapeGeometry.outline(of: template, size: testSize)
            let xs = points.map { $0.x }
            let ys = points.map { $0.y }
            
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max() else {
                XCTFail("\(template) lieferte keine Punkte")
                continue
            }
            
            let spanX = maxX - minX
            let spanY = maxY - minY
            
            XCTAssertGreaterThanOrEqual(spanX, testSize.width * 0.8, "\(template) nutzt die Breite unzureichend aus")
            XCTAssertGreaterThanOrEqual(spanY, testSize.height * 0.8, "\(template) nutzt die Höhe unzureichend aus")
        }
    }
    
    func testNewTemplatesNoConsecutiveDuplicates() {
        // Verhindert redundante Zeichenoperationen und fehlerhafte Pfadsegmente
        for template in newTemplates {
            let points = ShapeGeometry.outline(of: template, size: testSize)
            for i in 0..<points.count {
                let current = points[i]
                let next = points[(i + 1) % points.count]
                
                // Der letzte Punkt darf nicht dem ersten entsprechen, da der Aufrufer schließt
                if i == points.count - 1 {
                    XCTAssertNotEqual(current, points[0], "\(template) schließt sich selbst redundant")
                } else {
                    XCTAssertNotEqual(current, next, "\(template) hat aufeinanderfolgende identische Punkte bei Index \(i)")
                }
            }
        }
    }
    
    func testTotalTemplateCount() {
        // Stellt sicher, dass alle 17 definierten Formen im System registriert sind
        XCTAssertEqual(ShapeTemplate.allCases.count, 17, "Die Gesamtanzahl der Formen entspricht nicht exakt 17")
    }
}
