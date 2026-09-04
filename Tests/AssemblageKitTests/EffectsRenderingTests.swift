import XCTest
import AppKit
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
