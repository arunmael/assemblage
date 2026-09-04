import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Texturen auf beiden Renderwegen (aus missing.md).
///
/// Die eine Frage, die hier zählt, ist nicht „erscheint eine Textur", sondern
/// ob sie in der Vorschau **und** im Export an derselben Stelle aufhört. Genau
/// dieses Auseinanderlaufen der beiden Ketten ist in diesem Projekt schon
/// mehrfach passiert, und es ist der Fehler, den man beim Arbeiten erst nach
/// dem Exportieren bemerkt.
@MainActor
final class TextureIntegrationTests: XCTestCase {

    // MARK: - Hilfsmittel

    /// Eine vollflächig grüne PNG-Textur im Paket.
    private func resourcesWithGreenTexture() throws -> (DocumentResources, String) {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let bild = try XCTUnwrap(context.makeImage())
        let daten = try XCTUnwrap(NSBitmapImageRep(cgImage: bild).representation(using: .png, properties: [:]))

        let ressourcen = DocumentResources()
        return (ressourcen, ressourcen.addOriginal(daten, fileExtension: "png"))
    }

    /// Eine rote Kreisform in der Mitte einer 100×100-Leinwand.
    private func documentWithCircle(texture: LayerTexture?) -> AssemblageModel.Document {
        AssemblageModel.Document(
            canvas: CanvasSize(width: 100, height: 100),
            layers: [
                Layer(
                    name: "Kreis",
                    transform: Transform2D(x: 50, y: 50),
                    texture: texture,
                    content: .shape(ShapeLayerContent(
                        kind: .ellipse,
                        size: Size(width: 60, height: 60),
                        fillColorHex: "#FF0000"
                    ))
                )
            ]
        )
    }

    private func exportPixel(
        _ document: AssemblageModel.Document,
        resources: DocumentResources,
        x: Int, y: Int
    ) throws -> (r: Int, g: Int, b: Int, a: Int) {
        let bild = try DocumentExporter.renderedImage(
            of: document, resources: resources, targetSize: CGSize(width: 100, height: 100))

        let context = try XCTUnwrap(CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(bild, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        let zeiger = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        // Pufferzeile 0 ist die oberste Bildzeile — nachgemessen, siehe
        // `TextureRenderingTests.testTextureIsNotFlippedVertically`.
        let offset = (y * 100 + x) * 4
        return (Int(zeiger[offset]), Int(zeiger[offset + 1]), Int(zeiger[offset + 2]), Int(zeiger[offset + 3]))
    }

    // MARK: - Export

    /// Ohne Textur ist die Mitte reines Rot. Das ist die Vergleichsgrundlage:
    /// Ohne sie könnte ein Test „grünlich" bestehen, obwohl der Kreis selbst
    /// falsch gezeichnet wird.
    func testUntexturedShapeStaysPure() throws {
        let (ressourcen, _) = try resourcesWithGreenTexture()
        let mitte = try exportPixel(documentWithCircle(texture: nil), resources: ressourcen, x: 50, y: 50)

        XCTAssertGreaterThan(mitte.r, 200)
        XCTAssertLessThan(mitte.g, 50)
    }

    func testTextureTintsTheShapeInExport() throws {
        let (ressourcen, referenz) = try resourcesWithGreenTexture()
        let document = documentWithCircle(texture: LayerTexture(
            imageReference: referenz, blendMode: .normal, opacity: 1, scale: 1))

        let mitte = try exportPixel(document, resources: ressourcen, x: 50, y: 50)
        XCTAssertGreaterThan(mitte.g, 200, "die Textur müsste die Mitte grün färben")
        XCTAssertLessThan(mitte.r, 50)
    }

    /// Der eigentliche Punkt: Die Textur darf nicht über die Form hinaus in
    /// den leeren Rahmen laufen. Die Ecke der Ebene liegt innerhalb ihres
    /// Rechtecks, aber ausserhalb des Kreises.
    func testTextureIsClippedToTheContentSilhouette() throws {
        let (ressourcen, referenz) = try resourcesWithGreenTexture()
        let document = documentWithCircle(texture: LayerTexture(
            imageReference: referenz, blendMode: .normal, opacity: 1, scale: 1))

        // (23,23) liegt in der Ecke des 60×60-Rahmens (20…80), aber deutlich
        // ausserhalb des einbeschriebenen Kreises.
        let ecke = try exportPixel(document, resources: ressourcen, x: 23, y: 23)
        XCTAssertLessThan(ecke.a, 20, "ausserhalb der Form müsste es durchsichtig bleiben")
    }

    /// Deckkraft null heisst: gar nicht zeichnen, nicht „durchsichtig grün".
    func testZeroOpacityLeavesTheShapeUntouched() throws {
        let (ressourcen, referenz) = try resourcesWithGreenTexture()
        let document = documentWithCircle(texture: LayerTexture(
            imageReference: referenz, blendMode: .normal, opacity: 0, scale: 1))

        let mitte = try exportPixel(document, resources: ressourcen, x: 50, y: 50)
        XCTAssertGreaterThan(mitte.r, 200)
        XCTAssertLessThan(mitte.g, 50)
    }

    /// Eine fehlende Texturdatei darf die Ebene nicht verschwinden lassen.
    func testMissingTextureFileStillDrawsTheLayer() throws {
        let document = documentWithCircle(texture: LayerTexture(
            imageReference: "originals/gibtsnicht.png", blendMode: .normal, opacity: 1, scale: 1))

        let mitte = try exportPixel(document, resources: DocumentResources(), x: 50, y: 50)
        XCTAssertGreaterThan(mitte.r, 200)
    }

    // MARK: - Bildschirm

    private func canvasLayer(for document: AssemblageModel.Document, resources: DocumentResources) throws -> CALayer {
        let view = CanvasView(document: document, images: ImageStore(resources: resources))
        view.layoutSubtreeIfNeeded()
        view.layer?.layoutIfNeeded()
        let leinwand = try XCTUnwrap(view.layer?.sublayers?.first)
        return try XCTUnwrap(leinwand.sublayers?.first)
    }

    func testCanvasGetsATextureSublayer() throws {
        let (ressourcen, referenz) = try resourcesWithGreenTexture()
        let document = documentWithCircle(texture: LayerTexture(
            imageReference: referenz, blendMode: .multiply, opacity: 0.5, scale: 1))

        let ebene = try canvasLayer(for: document, resources: ressourcen)
        let textur = try XCTUnwrap(
            ebene.sublayers?.first { $0.name == LayerRenderer.textureLayerName },
            "die Ebene müsste eine Texturschicht tragen"
        )

        XCTAssertNotNil(textur.contents)
        XCTAssertEqual(textur.opacity, 0.5, accuracy: 0.001)
        XCTAssertEqual(textur.frame.size, ebene.bounds.size)
        // Ohne Maske liefe die Textur bei einem freigestellten Motiv über
        // dessen Rand hinaus — dasselbe, was im Export der Silhouetten-
        // beschnitt verhindert.
        XCTAssertNotNil(textur.mask, "die Texturschicht müsste auf die Form beschnitten sein")
    }

    func testCanvasHasNoTextureSublayerWithoutTexture() throws {
        let (ressourcen, _) = try resourcesWithGreenTexture()
        let ebene = try canvasLayer(for: documentWithCircle(texture: nil), resources: ressourcen)

        XCTAssertNil(ebene.sublayers?.first { $0.name == LayerRenderer.textureLayerName })
    }

    /// Wird die Textur entfernt, muss die Schicht wieder verschwinden — sonst
    /// bliebe sie sichtbar, obwohl das Modell sie nicht mehr kennt.
    func testRemovingTheTextureRemovesTheSublayer() throws {
        let (ressourcen, referenz) = try resourcesWithGreenTexture()
        let mitTextur = documentWithCircle(texture: LayerTexture(
            imageReference: referenz, blendMode: .normal, opacity: 1, scale: 1))

        let view = CanvasView(document: mitTextur, images: ImageStore(resources: ressourcen))
        view.layoutSubtreeIfNeeded()
        view.layer?.layoutIfNeeded()

        view.update(to: documentWithCircle(texture: nil))
        view.layer?.layoutIfNeeded()

        let leinwand = try XCTUnwrap(view.layer?.sublayers?.first)
        let ebene = try XCTUnwrap(leinwand.sublayers?.first)
        XCTAssertNil(ebene.sublayers?.first { $0.name == LayerRenderer.textureLayerName })
    }
}
