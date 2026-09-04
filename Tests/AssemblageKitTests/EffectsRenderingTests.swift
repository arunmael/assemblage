import XCTest
import AppKit
import CoreImage
@testable import AssemblageKit
@testable import AssemblageModel

/// Leuchten und Schlagschatten beim Rendern (aus missing.md).
///
/// Beide zeichnen **ausserhalb** der Ebene — daran erkennt man sie, und daran
/// lassen sie sich prüfen. Der Schatten muss dorthin fallen, wohin sein
/// Versatz zeigt; ein vertauschtes Vorzeichen fällt hier auf, weil y nach
/// unten wächst.
@MainActor
final class EffectsRenderingTests: XCTestCase {

    private let seite = 200

    private func dokument(effects: LayerEffects?) -> AssemblageModel.Document {
        AssemblageModel.Document(
            canvas: CanvasSize(width: Double(seite), height: Double(seite)),
            layers: [
                Layer(
                    name: "Form",
                    transform: Transform2D(x: 100, y: 100),
                    effects: effects,
                    content: .shape(ShapeLayerContent(
                        kind: .rectangle,
                        size: Size(width: 60, height: 60),
                        fillColorHex: "#000000"
                    ))
                )
            ]
        )
    }

    /// Liest Alpha aus einem Export.
    private func exportAlpha(_ document: AssemblageModel.Document, x: Int, y: Int) async throws -> Int {
        let bild = try await DocumentExporter.image(
            of: document, resources: DocumentResources(),
            targetSize: CGSize(width: seite, height: seite)
        )
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: seite, height: seite, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.draw(bild, in: CGRect(x: 0, y: 0, width: seite, height: seite))
        let daten = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        return Int(daten[(seite - 1 - y) * ctx.bytesPerRow + x * 4 + 3])
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let daten = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: daten, count: image.height * ctx.bytesPerRow))
    }

    // MARK: - Nichts eingestellt, nichts verändert

    /// Der wichtigste Fall: Ohne Effekte muss alles exakt bleiben, wie es war.
    func testNoEffectsLeavesTheExportUnchanged() async throws {
        let ohne = try await exportAlpha(dokument(effects: nil), x: 100, y: 40)
        let leer = try await exportAlpha(dokument(effects: LayerEffects()), x: 100, y: 40)

        XCTAssertEqual(ohne, 0, "40 Punkte über der Form ist nichts")
        XCTAssertEqual(leer, 0, "leere Effekte sind wie keine")
    }

    /// Ein Effekt mit Radius null ist keiner.
    func testZeroRadiusChangesNothing() async throws {
        let mitNull = LayerEffects(glow: Glow(radius: 0, intensity: 1))
        let alpha = try await exportAlpha(dokument(effects: mitNull), x: 100, y: 40)
        XCTAssertEqual(alpha, 0)
    }

    // MARK: - Schlagschatten

    /// Der Schatten fällt dorthin, wohin sein Versatz zeigt — und nicht auf
    /// die Gegenseite. y wächst nach unten, ein positiver Versatz heisst also
    /// „nach unten".
    func testShadowFallsWhereTheOffsetPoints() async throws {
        let doc = dokument(effects: LayerEffects(
            shadow: Shadow(offsetX: 0, offsetY: 20, radius: 4, colorHex: "#000000", opacity: 1)
        ))

        // Form reicht von y=70 bis y=130. Der Schatten liegt 20 tiefer.
        let unten = try await exportAlpha(doc, x: 100, y: 145)
        let oben = try await exportAlpha(doc, x: 100, y: 55)

        XCTAssertGreaterThan(unten, 60, "unter der Form muss der Schatten liegen")
        XCTAssertLessThan(oben, 30, "über der Form nicht")
    }

    func testHorizontalShadowOffset() async throws {
        let doc = dokument(effects: LayerEffects(
            shadow: Shadow(offsetX: 20, offsetY: 0, radius: 4, opacity: 1)
        ))

        let rechts = try await exportAlpha(doc, x: 145, y: 100)
        let links = try await exportAlpha(doc, x: 55, y: 100)
        XCTAssertGreaterThan(rechts, 60, "rechts")
        XCTAssertLessThan(links, 30, "links nicht")
    }

    // MARK: - Leuchten

    /// Ein Leuchten legt sich rings um die Ebene, auf allen Seiten.
    func testGlowSurroundsTheLayerOnAllSides() async throws {
        let doc = dokument(effects: LayerEffects(
            glow: Glow(radius: 12, colorHex: "#FFFFFF", intensity: 1)
        ))

        for (x, y, seiteName) in [(100, 62, "oben"), (100, 138, "unten"),
                                  (62, 100, "links"), (138, 100, "rechts")] {
            let alpha = try await exportAlpha(doc, x: x, y: y)
            XCTAssertGreaterThan(alpha, 20, "das Leuchten fehlt \(seiteName)")
        }
    }

    /// Leuchten und Schatten zusammen müssen beide erscheinen — ein Effekt
    /// darf den anderen nicht verdrängen.
    func testGlowAndShadowTogether() async throws {
        let doc = dokument(effects: LayerEffects(
            glow: Glow(radius: 12, colorHex: "#FFFFFF", intensity: 1),
            shadow: Shadow(offsetX: 0, offsetY: 25, radius: 4, opacity: 1)
        ))

        let leuchten = try await exportAlpha(doc, x: 62, y: 100)
        let schatten = try await exportAlpha(doc, x: 100, y: 150)
        XCTAssertGreaterThan(leuchten, 20, "Leuchten links")
        XCTAssertGreaterThan(schatten, 60, "Schatten unten")
    }

    // MARK: - Export-Zwischenfläche

    func testEffectSurfaceIsLimitedToLayerBoundsAndEffectReach() throws {
        let layer = Layer(
            name: "Ecke",
            transform: Transform2D(x: 28, y: 24, rotationDegrees: 18),
            distortion: QuadDistortion(topRight: Point(x: 7, y: 3)),
            effects: LayerEffects(
                glow: Glow(radius: 10, intensity: 0.8),
                shadow: Shadow(offsetX: 12, offsetY: 8, radius: 6, opacity: 0.7)
            ),
            content: .shape(ShapeLayerContent(
                kind: .rectangle,
                size: Size(width: 40, height: 30),
                fillColorHex: "#204080"
            ))
        )

        let rect = try XCTUnwrap(DocumentExporter.effectSurfaceRect(
            for: layer,
            effects: try XCTUnwrap(layer.effects),
            contentSize: CGSize(width: 40, height: 30),
            canvasHeight: 400,
            targetSize: CGSize(width: 400, height: 400),
            exportScale: CGSize(width: 1, height: 1)
        ))

        XCTAssertEqual(rect, CGRect(x: 0, y: 325, width: 88, height: 75))
        XCTAssertLessThan(rect.width * rect.height, 400 * 400 / 10)
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertLessThanOrEqual(rect.maxX, 400)
        XCTAssertLessThanOrEqual(rect.maxY, 400)
    }

    /// Vergleicht den begrenzten mit dem ganzflächigen Weg.
    ///
    /// Bewusst **nicht** byteweise gleich. Auf echter Hardware weicht der
    /// Effektsaum um genau eine 8-Bit-Stufe ab — auf GPU und Software-Renderer
    /// gleichermassen, weil der Weichzeichner von Core Image auf einer
    /// kleineren Fläche minimal anders auswertet. Ohne echte GPU (etwa in
    /// einem Sandkasten) tritt das nicht auf, was die Sache anfangs verschleiert
    /// hat.
    ///
    /// Das ist eine bewusste Abwägung und keine aufgeweichte Zusicherung: Eine
    /// Stufe von 255 liegt unterhalb dessen, was sichtbar ist, und unterhalb
    /// dessen, was ein JPEG davon übrig lässt. Dafür sinkt der Spitzenspeicher
    /// beim Export etwa um das Zehnfache.
    ///
    /// Streng bleibt dagegen die **Lage**: Ein verschobener oder gespiegelter
    /// Effekt wiche um weit mehr als eine Stufe ab, und an weit mehr Pixeln.
    /// Genau dafür ist dieser Test da.
    /// `expectsSoftEdge` sagt, ob im Ergebnis überhaupt ein weicher Saum
    /// vorkommen kann. Bei einer Ebene, die die Leinwand vollständig bedeckt,
    /// liegt der Effekt ausserhalb und jedes Pixel ist deckend — dort wäre die
    /// Gegenprobe auf einen Saum schlicht falsch.
    private func assertBoundedMatchesFullCanvas(
        _ document: AssemblageModel.Document,
        targetSize: CGSize,
        expectsSoftEdge: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let resources = DocumentResources()
        // Software-Renderer, damit das Ergebnis nicht vom Gerät abhängt.
        let ctx = CIContext(options: [.useSoftwareRenderer: true])

        let referenz = try pixels(DocumentExporter.renderedImage(
            of: document, resources: resources, targetSize: targetSize,
            effectSurfaceMode: .fullCanvas, effectRenderContext: ctx))
        let gemessen = try pixels(DocumentExporter.renderedImage(
            of: document, resources: resources, targetSize: targetSize,
            effectSurfaceMode: .bounded, effectRenderContext: ctx))

        XCTAssertEqual(gemessen.count, referenz.count, file: file, line: line)

        // Gegenprobe: Ohne sie bestünde der Vergleich auch zwischen zwei
        // vollständig leeren Bildern.
        let deckung = stride(from: 3, to: referenz.count, by: 4)
        XCTAssertTrue(deckung.contains { referenz[$0] == 255 },
                      "die Vorlage müsste deckende Pixel enthalten", file: file, line: line)
        if expectsSoftEdge {
            XCTAssertTrue(deckung.contains { (1..<255).contains(referenz[$0]) },
                          "die Vorlage müsste einen weichen Saum enthalten", file: file, line: line)
        }

        var groessteAbweichung = 0
        var abweichendePixel = 0
        for i in stride(from: 0, to: referenz.count, by: 4) {
            var punkt = 0
            for k in 0..<4 {
                punkt = max(punkt, abs(Int(referenz[i + k]) - Int(gemessen[i + k])))
            }
            if punkt > 0 { abweichendePixel += 1 }
            groessteAbweichung = max(groessteAbweichung, punkt)
        }

        XCTAssertLessThanOrEqual(groessteAbweichung, 1,
            "mehr als eine Stufe wäre kein Rundungsrest, sondern ein Lagefehler",
            file: file, line: line)
        XCTAssertLessThan(abweichendePixel, referenz.count / 4 / 20,
            "die Abweichung darf nur den Saum betreffen, nicht die Fläche",
            file: file, line: line)
    }

    /// Ebene an der **oberen linken** Ecke, gedreht und ungleich skaliert,
    /// mit Leuchten und versetztem Schatten.
    func testBoundedEffectSurfaceMatchesPreviousFullCanvasRenderingAtCorner() throws {
        let layer = Layer(
            name: "Eckebene",
            transform: Transform2D(x: 31, y: 29, scaleX: 1.15, scaleY: 0.9, rotationDegrees: 17),
            effects: LayerEffects(
                glow: Glow(radius: 9, colorHex: "#FFD080", intensity: 0.75),
                shadow: Shadow(offsetX: 11, offsetY: 7, radius: 5, colorHex: "#102040", opacity: 0.65)),
            content: .shape(ShapeLayerContent(
                kind: .ellipse, size: Size(width: 42, height: 34), fillColorHex: "#3050A0")))

        try assertBoundedMatchesFullCanvas(
            AssemblageModel.Document(canvas: CanvasSize(width: 240, height: 240), layers: [layer]),
            targetSize: CGSize(width: 480, height: 480))
    }

    /// Dieselbe Prüfung an der **unteren rechten** Ecke, und mit einem
    /// Schattenversatz, der aus der Leinwand hinausweist.
    ///
    /// Nicht überflüssig neben dem Test darüber: Dieses Projekt hat mehrfach
    /// Fehler gehabt, die sich nur in einer der beiden y-Richtungen zeigten
    /// (Bilder, Text, Verziehen, Formen). Eine Zwischenfläche, deren Lage aus
    /// einer y-Umrechnung stammt, ist genau derselbe Fall — ein
    /// Vorzeichenfehler bliebe oben links unsichtbar.
    /// Dieselbe Prüfung an der **unteren rechten** Ecke, mit einem
    /// Schattenversatz, der aus der Leinwand hinausweist.
    ///
    /// Nicht überflüssig neben dem Test darüber: Dieses Projekt hat mehrfach
    /// Fehler gehabt, die sich nur in einer der beiden y-Richtungen zeigten
    /// (Bilder, Text, Verziehen, Formen). Eine Zwischenfläche, deren Lage aus
    /// einer y-Umrechnung stammt, ist genau derselbe Fall — ein
    /// Vorzeichenfehler bliebe oben links unsichtbar.
    func testBoundedEffectSurfaceAlsoMatchesAtTheOppositeCorner() throws {
        let layer = Layer(
            name: "Gegenecke",
            transform: Transform2D(x: 212, y: 208, scaleX: 0.85, scaleY: 1.2, rotationDegrees: -23),
            effects: LayerEffects(
                glow: Glow(radius: 7, colorHex: "#80FFC0", intensity: 0.9),
                shadow: Shadow(offsetX: 14, offsetY: 12, radius: 6, colorHex: "#201000", opacity: 0.7)),
            content: .shape(ShapeLayerContent(
                kind: .rectangle, size: Size(width: 38, height: 46), fillColorHex: "#A03050")))

        try assertBoundedMatchesFullCanvas(
            AssemblageModel.Document(canvas: CanvasSize(width: 240, height: 240), layers: [layer]),
            targetSize: CGSize(width: 480, height: 480))
    }

    /// Eine Ebene, die grösser als die Leinwand ist, darf durch die Begrenzung
    /// nicht beschnitten werden.
    /// Eine Ebene, die grösser als die Leinwand ist, darf durch die Begrenzung
    /// nicht beschnitten werden.
    func testBoundedEffectSurfaceMatchesForALayerLargerThanTheCanvas() throws {
        let layer = Layer(
            name: "Übergross",
            transform: Transform2D(x: 120, y: 120, scaleX: 3, scaleY: 3),
            effects: LayerEffects(shadow: Shadow(offsetX: -20, offsetY: -18, radius: 10, opacity: 0.8)),
            content: .shape(ShapeLayerContent(
                kind: .ellipse, size: Size(width: 200, height: 200), fillColorHex: "#3060A0")))

        // Die Ebene bedeckt die Leinwand vollständig; der Schatten fällt
        // vollständig ausserhalb. Es gibt hier deshalb keinen weichen Saum —
        // geprüft wird stattdessen, dass die Begrenzung nichts abschneidet.
        try assertBoundedMatchesFullCanvas(
            AssemblageModel.Document(canvas: CanvasSize(width: 240, height: 240), layers: [layer]),
            targetSize: CGSize(width: 240, height: 240),
            expectsSoftEdge: false)
    }

    // MARK: - Leinwand

    /// Auf der Leinwand übernimmt Core Animation die Effekte. Geprüft wird,
    /// dass sie an der Schicht hängen — `CALayer.render(in:)` gibt Schatten
    /// ebenso wenig wieder wie Filter, ein Pixelvergleich ginge also ins Leere.
    func testCanvasAttachesShadowToTheLayer() throws {
        let doc = dokument(effects: LayerEffects(
            shadow: Shadow(offsetX: 3, offsetY: 5, radius: 8, opacity: 0.6)
        ))
        let ansicht = CanvasView(document: doc, images: ImageStore(resources: DocumentResources()))
        let schicht = try XCTUnwrap(ansicht.layer?.sublayers?.first?.sublayers?.first)

        XCTAssertEqual(schicht.shadowOpacity, 0.6, accuracy: 0.01)
        XCTAssertEqual(schicht.shadowRadius, 8, accuracy: 0.01)
        XCTAssertEqual(schicht.shadowOffset.width, 3, accuracy: 0.01)
        XCTAssertEqual(schicht.shadowOffset.height, 5, accuracy: 0.01)
    }

    func testCanvasAttachesNoShadowWithoutEffects() throws {
        let ansicht = CanvasView(
            document: dokument(effects: nil),
            images: ImageStore(resources: DocumentResources())
        )
        let schicht = try XCTUnwrap(ansicht.layer?.sublayers?.first?.sublayers?.first)

        XCTAssertEqual(schicht.shadowOpacity, 0, "ohne Effekte kein Schatten")
    }

    /// Wird ein Effekt zurückgenommen, muss er auch von der Schicht
    /// verschwinden.
    func testCanvasRemovesTheShadowWhenEffectsAreCleared() throws {
        var doc = dokument(effects: LayerEffects(shadow: Shadow(offsetY: 5, radius: 4, opacity: 0.8)))
        let ansicht = CanvasView(document: doc, images: ImageStore(resources: DocumentResources()))

        doc.layers[0].effects = nil
        ansicht.update(to: doc)

        let schicht = try XCTUnwrap(ansicht.layer?.sublayers?.first?.sublayers?.first)
        XCTAssertEqual(schicht.shadowOpacity, 0)
    }
}
