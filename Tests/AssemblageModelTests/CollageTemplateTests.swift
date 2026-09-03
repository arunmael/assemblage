import XCTest
@testable import AssemblageModel

final class CollageTemplateTests: XCTestCase {

    func testKapazitaetStimmtFuerAlleVorlagen() {
        XCTAssertEqual(CollageTemplate.grid2x2.capacity, 4)
        XCTAssertEqual(CollageTemplate.grid3x3.capacity, 9)
        XCTAssertEqual(CollageTemplate.polaroidStack.capacity, 5)
        XCTAssertEqual(CollageTemplate.allCases.count, 3)
    }

    func testZweiMalZweiLiegtInVierQuadrantenOhneUeberlappung() throws {
        let canvas = CanvasSize(width: 1_000, height: 1_000)
        let frames = try (0..<4).map {
            try sichtbarerRahmen(
                XCTUnwrap(CollageTemplate.grid2x2.placement(
                    forIndex: $0,
                    contentSize: Size(width: 1_200, height: 800),
                    canvas: canvas
                )),
                contentSize: Size(width: 1_200, height: 800)
            )
        }

        XCTAssertLessThan(frames[0].x + frames[0].width / 2, canvas.width / 2)
        XCTAssertLessThan(frames[0].y + frames[0].height / 2, canvas.height / 2)
        XCTAssertGreaterThan(frames[1].x + frames[1].width / 2, canvas.width / 2)
        XCTAssertLessThan(frames[1].y + frames[1].height / 2, canvas.height / 2)
        XCTAssertLessThan(frames[2].x + frames[2].width / 2, canvas.width / 2)
        XCTAssertGreaterThan(frames[2].y + frames[2].height / 2, canvas.height / 2)
        XCTAssertGreaterThan(frames[3].x + frames[3].width / 2, canvas.width / 2)
        XCTAssertGreaterThan(frames[3].y + frames[3].height / 2, canvas.height / 2)

        for erster in frames.indices {
            for zweiter in frames.indices where zweiter > erster {
                XCTAssertFalse(ueberlappt(frames[erster], frames[zweiter]))
            }
        }
    }

    func testRasterNutztDieLeinwandBisAufKleineAbstaende() throws {
        let canvas = CanvasSize(width: 1_200, height: 900)
        let content = Size(width: 1_600, height: 1_200)
        let frames = try (0..<9).map {
            try sichtbarerRahmen(
                XCTUnwrap(CollageTemplate.grid3x3.placement(
                    forIndex: $0,
                    contentSize: content,
                    canvas: canvas
                )),
                contentSize: content
            )
        }

        let links = try XCTUnwrap(frames.map(\.x).min())
        let oben = try XCTUnwrap(frames.map(\.y).min())
        let rechts = try XCTUnwrap(frames.map { $0.x + $0.width }.max())
        let unten = try XCTUnwrap(frames.map { $0.y + $0.height }.max())

        XCTAssertLessThan(links, canvas.width * 0.03)
        XCTAssertLessThan(oben, canvas.height * 0.03)
        XCTAssertGreaterThan(rechts, canvas.width * 0.97)
        XCTAssertGreaterThan(unten, canvas.height * 0.97)
    }

    func testHochformatImQuadratischenFachWirdProportionalZugeschnitten() throws {
        let content = Size(width: 600, height: 1_200)
        let placement = try XCTUnwrap(CollageTemplate.grid2x2.placement(
            forIndex: 0,
            contentSize: content,
            canvas: CanvasSize(width: 1_000, height: 1_000)
        ))
        let crop = try XCTUnwrap(placement.cropRect)
        let scaledWidth = crop.width * abs(placement.transform.scaleX)
        let scaledHeight = crop.height * abs(placement.transform.scaleY)

        XCTAssertEqual(abs(placement.transform.scaleX), abs(placement.transform.scaleY), accuracy: 1e-12)
        XCTAssertEqual(scaledWidth / scaledHeight, 1, accuracy: 1e-12)
        XCTAssertLessThan(crop.height, content.height)
        XCTAssertEqual(crop.width, content.width, accuracy: 1e-12)
    }

    func testIndexAusserhalbDerKapazitaetErgibtNil() {
        let content = Size(width: 100, height: 100)
        let canvas = CanvasSize(width: 500, height: 500)

        for template in CollageTemplate.allCases {
            XCTAssertNil(template.placement(forIndex: -1, contentSize: content, canvas: canvas))
            XCTAssertNil(template.placement(forIndex: template.capacity, contentSize: content, canvas: canvas))
        }
    }

    func testPolaroidStapelDrehtNichtAlleBilderGleich() throws {
        let rotations = try (0..<CollageTemplate.polaroidStack.capacity).map {
            try XCTUnwrap(CollageTemplate.polaroidStack.placement(
                forIndex: $0,
                contentSize: Size(width: 1_200, height: 800),
                canvas: CanvasSize(width: 1_000, height: 800)
            )).transform.rotationDegrees
        }

        XCTAssertGreaterThan(Set(rotations).count, 1)
        XCTAssertTrue(rotations.contains(where: { $0 < 0 }))
        XCTAssertTrue(rotations.contains(where: { $0 > 0 }))
    }

    func testRasterFunktioniertAufHochformatigerLeinwand() throws {
        let canvas = CanvasSize(width: 1_080, height: 1_920)
        let content = Size(width: 4_000, height: 3_000)

        for index in 0..<9 {
            let placement = try XCTUnwrap(CollageTemplate.grid3x3.placement(
                forIndex: index,
                contentSize: content,
                canvas: canvas
            ))
            let frame = sichtbarerRahmen(placement, contentSize: content)
            XCTAssertGreaterThanOrEqual(frame.x, 0)
            XCTAssertGreaterThanOrEqual(frame.y, 0)
            XCTAssertLessThanOrEqual(frame.x + frame.width, canvas.width)
            XCTAssertLessThanOrEqual(frame.y + frame.height, canvas.height)
        }
    }

    private func sichtbarerRahmen(
        _ placement: (transform: Transform2D, cropRect: Rect?),
        contentSize: Size
    ) -> Rect {
        let size = placement.cropRect.map { Size(width: $0.width, height: $0.height) }
            ?? contentSize
        return placement.transform.unrotatedFrame(forContentSize: size)
    }

    private func ueberlappt(_ lhs: Rect, _ rhs: Rect) -> Bool {
        lhs.x < rhs.x + rhs.width
            && lhs.x + lhs.width > rhs.x
            && lhs.y < rhs.y + rhs.height
            && lhs.y + lhs.height > rhs.y
    }
}
