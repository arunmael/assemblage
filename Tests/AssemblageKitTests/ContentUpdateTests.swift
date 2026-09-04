import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Ändert sich der **Inhalt** einer Ebene, muss die Leinwand das zeigen.
///
/// Anlass: `update(to:)` frischte nur Layout-Eigenschaften auf — Position,
/// Deckkraft, Filter, Maske. Der Inhalt einer Schicht wurde ausschliesslich
/// beim Neuaufbau gesetzt, und ein Neuaufbau passiert nur, wenn sich die
/// Ebenen*struktur* ändert. Wer also Text umschrieb, sah auf der Leinwand
/// weiter den alten — das Löschen wirkte, als griffe es nicht.
///
/// Der Fehler blieb liegen, weil die bisherigen Tests entweder frisch
/// aufgebaute Ansichten prüften oder nur Layout-Eigenschaften veränderten.
@MainActor
final class ContentUpdateTests: XCTestCase {

    private func ansicht(_ document: AssemblageModel.Document, _ resources: DocumentResources = DocumentResources()) -> CanvasView {
        let view = CanvasView(document: document, images: ImageStore(resources: resources))
        view.layer?.layoutIfNeeded()
        return view
    }

    private func schicht(_ view: CanvasView) throws -> CALayer {
        try XCTUnwrap(view.layer?.sublayers?.first?.sublayers?.first)
    }

    // MARK: - Text

    func testChangingTextUpdatesTheCanvas() throws {
        var document = AssemblageModel.Document(
            canvas: CanvasSize(width: 400, height: 400),
            layers: [Layer(
                name: "Titel",
                transform: Transform2D(x: 200, y: 200),
                content: .text(TextLayerContent(string: "Assemblage", fontSize: 48))
            )]
        )
        let view = ansicht(document)

        guard case .text(var inhalt) = document.layers[0].content else { return XCTFail() }
        inhalt.string = "Neuer Text"
        document.layers[0].content = .text(inhalt)
        view.update(to: document)

        let text = try XCTUnwrap(schicht(view) as? CATextLayer)
        let gezeigt = (text.string as? NSAttributedString)?.string ?? text.string as? String
        XCTAssertEqual(gezeigt, "Neuer Text")
    }

    /// Der Fall, den der Nutzer gemeldet hat: Text löschen muss ihn auch von
    /// der Leinwand nehmen.
    func testClearingTextRemovesItFromTheCanvas() throws {
        var document = AssemblageModel.Document(
            canvas: CanvasSize(width: 400, height: 400),
            layers: [Layer(
                name: "Titel",
                transform: Transform2D(x: 200, y: 200),
                content: .text(TextLayerContent(string: "Assemblage", fontSize: 48))
            )]
        )
        let view = ansicht(document)

        guard case .text(var inhalt) = document.layers[0].content else { return XCTFail() }
        inhalt.string = ""
        document.layers[0].content = .text(inhalt)
        view.update(to: document)

        let text = try XCTUnwrap(schicht(view) as? CATextLayer)
        let gezeigt = (text.string as? NSAttributedString)?.string ?? text.string as? String
        XCTAssertEqual(gezeigt, "")
    }

    func testChangingFontSizeUpdatesTheCanvas() throws {
        var document = AssemblageModel.Document(
            canvas: CanvasSize(width: 400, height: 400),
            layers: [Layer(
                name: "Titel",
                transform: Transform2D(x: 200, y: 200),
                content: .text(TextLayerContent(string: "Abc", fontSize: 24))
            )]
        )
        let view = ansicht(document)
        let vorher = try schicht(view).bounds.height

        guard case .text(var inhalt) = document.layers[0].content else { return XCTFail() }
        inhalt.fontSize = 96
        document.layers[0].content = .text(inhalt)
        view.update(to: document)

        XCTAssertGreaterThan(try schicht(view).bounds.height, vorher * 2)
    }

    // MARK: - Formen

    func testChangingShapeColourUpdatesTheCanvas() throws {
        var document = AssemblageModel.Document(
            canvas: CanvasSize(width: 400, height: 400),
            layers: [Layer(
                name: "Form",
                transform: Transform2D(x: 200, y: 200),
                content: .shape(ShapeLayerContent(kind: .rectangle, size: Size(width: 100, height: 100), fillColorHex: "#FF0000"))
            )]
        )
        let view = ansicht(document)

        document.layers[0].content = .shape(ShapeLayerContent(
            kind: .rectangle, size: Size(width: 100, height: 100), fillColorHex: "#0000FF"
        ))
        view.update(to: document)

        let form = try XCTUnwrap(schicht(view) as? CAShapeLayer)
        let farbe = try XCTUnwrap(form.fillColor?.components)
        XCTAssertEqual(farbe[2], 1, accuracy: 0.01, "blau")
        XCTAssertEqual(farbe[0], 0, accuracy: 0.01, "kein rot")
    }

    /// Ein Formwechsel (Rechteck → Ellipse) muss den Pfad austauschen.
    func testChangingShapeKindUpdatesThePath() throws {
        var document = AssemblageModel.Document(
            canvas: CanvasSize(width: 400, height: 400),
            layers: [Layer(
                name: "Form",
                transform: Transform2D(x: 200, y: 200),
                content: .shape(ShapeLayerContent(kind: .rectangle, size: Size(width: 100, height: 100)))
            )]
        )
        let view = ansicht(document)
        let vorher = try XCTUnwrap((schicht(view) as? CAShapeLayer)?.path)

        document.layers[0].content = .shape(ShapeLayerContent(kind: .ellipse, size: Size(width: 100, height: 100)))
        view.update(to: document)

        let nachher = try XCTUnwrap((schicht(view) as? CAShapeLayer)?.path)
        XCTAssertNotEqual(vorher, nachher, "der Pfad muss sich geändert haben")
    }

    // MARK: - Bilder

    /// Auch ein geänderter Zuschnitt muss ankommen.
    func testChangingCropUpdatesTheCanvas() throws {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let png = try XCTUnwrap(
            NSBitmapImageRep(cgImage: try XCTUnwrap(ctx.makeImage()))
                .representation(using: .png, properties: [:])
        )
        let resources = DocumentResources()
        let referenz = resources.addOriginal(png, fileExtension: "png")

        var document = AssemblageModel.Document(
            canvas: CanvasSize(width: 400, height: 400),
            layers: [Layer(
                name: "Foto",
                transform: Transform2D(x: 200, y: 200),
                content: .image(ImageLayerContent(originalFileReference: referenz))
            )]
        )
        let view = ansicht(document, resources)

        document.layers[0].content = .image(ImageLayerContent(
            originalFileReference: referenz,
            cropRect: Rect(x: 0, y: 0, width: 50, height: 100)
        ))
        view.update(to: document)

        let schicht = try schicht(view)
        XCTAssertEqual(schicht.contentsRect.width, 0.5, accuracy: 0.01, "der Zuschnitt muss ankommen")
    }

    func testLargeImageKeepsOriginalLayerSizeAndCropGeometry() throws {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 8_192, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let png = try XCTUnwrap(
            NSBitmapImageRep(cgImage: try XCTUnwrap(ctx.makeImage()))
                .representation(using: .png, properties: [:])
        )
        let resources = DocumentResources()
        let referenz = resources.addOriginal(png, fileExtension: "png")
        let store = ImageStore(resources: resources)
        let renderer = LayerRenderer(images: store)
        let content = ImageLayerContent(originalFileReference: referenz)

        XCTAssertEqual(try XCTUnwrap(store.image(named: referenz)).width, 4_096)
        let ganzeEbene = renderer.makeLayer(for: Layer(name: "Foto", content: .image(content)))
        XCTAssertEqual(ganzeEbene.bounds.size, CGSize(width: 8_192, height: 16))

        let crop = Rect(x: 2_048, y: 4, width: 4_096, height: 8)
        let zugeschnitten = renderer.makeLayer(for: Layer(
            name: "Foto",
            content: .image(ImageLayerContent(originalFileReference: referenz, cropRect: crop))
        ))
        XCTAssertEqual(zugeschnitten.bounds.size, CGSize(width: 4_096, height: 8))
        XCTAssertEqual(zugeschnitten.contentsRect.origin.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(zugeschnitten.contentsRect.origin.y, 0.25, accuracy: 0.0001)
        XCTAssertEqual(zugeschnitten.contentsRect.width, 0.5, accuracy: 0.0001)
        XCTAssertEqual(zugeschnitten.contentsRect.height, 0.5, accuracy: 0.0001)
    }

    // MARK: - Keine unnötigen Neuaufbauten

    /// Die Gegenprobe: Eine reine Layout-Änderung darf die Schicht **nicht**
    /// austauschen — sonst würde bei jedem Reglerzug jedes Bild neu
    /// dekodiert.
    func testLayoutOnlyChangeReusesTheSameLayer() throws {
        var document = AssemblageModel.Document(
            canvas: CanvasSize(width: 400, height: 400),
            layers: [Layer(
                name: "Form",
                transform: Transform2D(x: 200, y: 200),
                content: .shape(ShapeLayerContent(kind: .rectangle, size: Size(width: 100, height: 100)))
            )]
        )
        let view = ansicht(document)
        let vorher = try schicht(view)

        document.layers[0].opacity = 0.4
        view.update(to: document)

        XCTAssertIdentical(try schicht(view), vorher)
    }
}
