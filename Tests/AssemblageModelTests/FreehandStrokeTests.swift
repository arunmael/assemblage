import XCTest
@testable import AssemblageModel

final class FreehandStrokeTests: XCTestCase {

    func testFastGeradePunktfolgeWirdDeutlichVereinfacht() throws {
        let roh = (0..<200).map { index in
            Point(x: Double(index), y: Double(index) * 0.4 + sin(Double(index)) * 0.15)
        }

        let anker = try XCTUnwrap(FreehandStroke.path(from: roh).subpaths.first).anchors

        XCTAssertLessThan(anker.count, roh.count / 4)
    }

    func testErsterUndLetzterRohpunktBleibenExaktErhalten() throws {
        let roh = [
            Point(x: 2, y: 7), Point(x: 20, y: 30),
            Point(x: 45, y: 12), Point(x: 91, y: 70)
        ]

        let anker = try XCTUnwrap(FreehandStroke.path(from: roh).subpaths.first).anchors

        XCTAssertEqual(anker.first?.point, roh.first)
        XCTAssertEqual(anker.last?.point, roh.last)
    }

    func testEinzelpunktErgibtTupferUndLeereEingabeLeerenPfad() throws {
        let tupfer = FreehandStroke.path(from: [Point(x: 12, y: 34)])

        XCTAssertEqual(try XCTUnwrap(tupfer.subpaths.first).anchors.count, 2)
        XCTAssertTrue(FreehandStroke.path(from: []).isEmpty)
    }

    func testZuVieleRohpunkteWerdenVorherAusgeduennt() throws {
        let roh = (0..<(FreehandStroke.maxInputPoints + 1_000)).map {
            Point(x: Double($0), y: Double($0) * 0.25)
        }

        let anker = try XCTUnwrap(FreehandStroke.path(from: roh).subpaths.first).anchors

        XCTAssertLessThanOrEqual(anker.count, FreehandStroke.maxInputPoints)
    }

    func testAlleAnkerIdentischerEingabepunkteSindEndlich() throws {
        let roh = Array(repeating: Point(x: 42, y: 19), count: 100)
        let anker = try XCTUnwrap(FreehandStroke.path(from: roh).subpaths.first).anchors

        for anker in anker {
            XCTAssertTrue(anker.point.x.isFinite && anker.point.y.isFinite)
            XCTAssertTrue(anker.controlIn.x.isFinite && anker.controlIn.y.isFinite)
            XCTAssertTrue(anker.controlOut.x.isFinite && anker.controlOut.y.isFinite)
        }
    }
}
