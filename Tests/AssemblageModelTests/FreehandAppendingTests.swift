import XCTest
@testable import AssemblageModel

final class FreehandAppendingTests: XCTestCase {

    func testAnhaengenOhneTransformationVerschiebtVorhandenenStrichNicht() throws {
        try pruefeVorhandenenStrichBleibtLiegen(
            transform: Transform2D(x: 100, y: 80)
        )
    }

    func testAnhaengenMitDrehungUndSkalierungVerschiebtVorhandenenStrichNicht() throws {
        try pruefeVorhandenenStrichBleibtLiegen(
            transform: Transform2D(x: 100, y: 80, scaleX: 2, scaleY: 0.5, rotationDegrees: 30)
        )
    }

    func testAnhaengenAnGespiegelteEbeneVerschiebtVorhandenenStrichNicht() throws {
        try pruefeVorhandenenStrichBleibtLiegen(
            transform: Transform2D(x: 100, y: 80, scaleX: -1, scaleY: 1, rotationDegrees: 20)
        )
    }

    func testLeererPfadErgibtNormalisiertenZugAnDerRichtigenStelle() throws {
        let ebene = freihandEbene(
            transform: Transform2D(x: 200, y: 150),
            size: Size(width: 400, height: 300),
            path: VectorPath()
        )
        let zug = pfad([Point(x: 40, y: 60), Point(x: 140, y: 110)])

        let ergebnis = try XCTUnwrap(ebene.appendingFreehandStroke(canvasPath: zug))
        guard case .shape(let inhalt) = ergebnis.content else {
            return XCTFail("Das Ergebnis muss eine Formebene bleiben")
        }

        XCTAssertEqual(inhalt.path?.subpaths.count, 1)
        XCTAssertEqual(inhalt.size.width, 100, accuracy: 1e-6)
        XCTAssertEqual(inhalt.size.height, 50, accuracy: 1e-6)
        let punkte = try XCTUnwrap(inhalt.path?.subpaths.first?.anchors.map(\.point))
        XCTAssertEqual(punkte[0].x, 0, accuracy: 1e-6)
        XCTAssertEqual(punkte[0].y, 0, accuracy: 1e-6)
        XCTAssertEqual(punkte[1].x, 100, accuracy: 1e-6)
        XCTAssertEqual(punkte[1].y, 50, accuracy: 1e-6)
        XCTAssertEqual(canvasPoint(punkte[0], in: ergebnis, size: inhalt.size).x, 40, accuracy: 1e-6)
        XCTAssertEqual(canvasPoint(punkte[0], in: ergebnis, size: inhalt.size).y, 60, accuracy: 1e-6)
        XCTAssertEqual(canvasPoint(punkte[1], in: ergebnis, size: inhalt.size).x, 140, accuracy: 1e-6)
        XCTAssertEqual(canvasPoint(punkte[1], in: ergebnis, size: inhalt.size).y, 110, accuracy: 1e-6)
    }

    func testNullskalierungUndNichtEndlicheWerteErgebenNil() {
        let zug = pfad([Point(x: 0, y: 0), Point(x: 20, y: 20)])
        let nullX = freihandEbene(transform: Transform2D(scaleX: 0), path: pfad([.zero, Point(x: 10, y: 10)]))
        let unendlich = freihandEbene(
            transform: Transform2D(x: .infinity),
            path: pfad([.zero, Point(x: 10, y: 10)])
        )
        let ungueltigerZug = pfad([Point(x: .nan, y: 0), Point(x: 20, y: 20)])

        XCTAssertNil(nullX.appendingFreehandStroke(canvasPath: zug))
        XCTAssertNil(unendlich.appendingFreehandStroke(canvasPath: zug))
        XCTAssertNil(freihandEbene(path: pfad([.zero, Point(x: 10, y: 10)]))
            .appendingFreehandStroke(canvasPath: ungueltigerZug))
    }

    func testNichtFreihandEbenenErgebenNil() {
        let zug = pfad([Point(x: 0, y: 0), Point(x: 20, y: 20)])
        let ebenen = [
            Layer(name: "Text", content: .text(TextLayerContent(string: "Text"))),
            Layer(name: "Rechteck", content: .shape(ShapeLayerContent(
                kind: .rectangle, size: Size(width: 20, height: 20)
            ))),
            Layer(name: "Bild", content: .image(ImageLayerContent(originalFileReference: "bild.png")))
        ]

        for ebene in ebenen {
            XCTAssertNil(ebene.appendingFreehandStroke(canvasPath: zug))
        }
    }

    private func pruefeVorhandenenStrichBleibtLiegen(
        transform: Transform2D,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let alt = pfad([Point(x: 10, y: 20), Point(x: 70, y: 60)])
        let ebene = freihandEbene(transform: transform, size: Size(width: 80, height: 100), path: alt)
        guard case .shape(let alterInhalt) = ebene.content else { return }
        let vorher = try XCTUnwrap(alterInhalt.path?.subpaths.first?.anchors, file: file, line: line)
            .flatMap { [$0.point, $0.controlIn, $0.controlOut] }
            .map { canvasPoint($0, in: ebene, size: alterInhalt.size) }
        let zug = pfad([Point(x: 230, y: 160), Point(x: 280, y: 210)])

        let ergebnis = try XCTUnwrap(
            ebene.appendingFreehandStroke(canvasPath: zug), file: file, line: line
        )
        guard case .shape(let neuerInhalt) = ergebnis.content else {
            return XCTFail("Das Ergebnis muss eine Formebene bleiben", file: file, line: line)
        }
        let nachher = try XCTUnwrap(neuerInhalt.path?.subpaths.first?.anchors, file: file, line: line)
            .flatMap { [$0.point, $0.controlIn, $0.controlOut] }
            .map { canvasPoint($0, in: ergebnis, size: neuerInhalt.size) }

        XCTAssertEqual(neuerInhalt.path?.subpaths.count, 2, file: file, line: line)
        XCTAssertEqual(vorher.count, nachher.count, file: file, line: line)
        for (links, rechts) in zip(vorher, nachher) {
            XCTAssertEqual(links.x, rechts.x, accuracy: 1e-6, file: file, line: line)
            XCTAssertEqual(links.y, rechts.y, accuracy: 1e-6, file: file, line: line)
        }
    }

    private func freihandEbene(
        transform: Transform2D = .identity,
        size: Size = Size(width: 100, height: 100),
        path: VectorPath
    ) -> Layer {
        Layer(
            name: "Zeichnung",
            transform: transform,
            content: .shape(ShapeLayerContent(
                kind: .freehand,
                size: size,
                fillColorHex: "#00000000",
                strokeColorHex: "#112233",
                strokeWidth: 6,
                path: path
            ))
        )
    }

    private func pfad(_ punkte: [Point]) -> VectorPath {
        VectorPath(subpath: PathSubpath(anchors: punkte.map(PathAnchor.init(corner:))))
    }

    private func canvasPoint(_ point: Point, in layer: Layer, size: Size) -> Point {
        let transform = layer.transform
        return transform.pointOnCanvas(Point(
            x: (point.x - size.width / 2) * transform.scaleX,
            y: (point.y - size.height / 2) * transform.scaleY
        ))
    }
}
