import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Vorher/Nachher-Vergleich je Ebene (aus missing.md).
@MainActor
final class ComparisonTests: XCTestCase {

    // MARK: - Modell

    func testWithoutEditsDropsEverythingThatWasEditedIn() {
        let ebene = Layer(
            name: "Foto",
            transform: Transform2D(x: 10, y: 20, scaleX: 2, scaleY: 2, rotationDegrees: 30),
            mask: LayerMask(maskImageReference: "masks/a.png", source: .manualBrush),
            distortion: QuadDistortion(),
            effects: LayerEffects(glow: Glow(radius: 8)),
            texture: LayerTexture(imageReference: "originals/t.png"),
            content: .image(ImageLayerContent(
                originalFileReference: "originals/a.png",
                cropRect: Rect(x: 1, y: 2, width: 3, height: 4),
                adjustments: ImageAdjustments(brightness: 0.5)
            ))
        )

        let roh = ebene.withoutEdits()

        XCTAssertNil(roh.mask)
        XCTAssertNil(roh.distortion)
        XCTAssertNil(roh.effects)
        XCTAssertNil(roh.texture)
        guard case .image(let inhalt) = roh.content else { return XCTFail("Bildebene erwartet") }
        XCTAssertEqual(inhalt.adjustments, .neutral)

        // Lage, Grösse und Zuschnitt bleiben: Sonst spränge die Ebene beim
        // Vergleichen an eine andere Stelle, und man verglich zwei Bilder,
        // die gar nicht übereinanderliegen.
        XCTAssertEqual(roh.transform, ebene.transform)
        XCTAssertEqual(inhalt.cropRect, Rect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(roh.id, ebene.id)
    }

    func testHasEditsIsFalseForAPlainLayer() {
        let schlicht = Layer(name: "Form", content: .shape(
            ShapeLayerContent(kind: .rectangle, size: Size(width: 10, height: 10))))
        XCTAssertFalse(schlicht.hasEdits)
        XCTAssertEqual(schlicht.withoutEdits(), schlicht)
    }

    func testHasEditsNoticesEachKindOfEdit() {
        let grund = Layer(name: "Foto", content: .image(
            ImageLayerContent(originalFileReference: "originals/a.png")))
        XCTAssertFalse(grund.hasEdits)

        var mitMaske = grund
        mitMaske.mask = LayerMask(maskImageReference: nil, source: .manualBrush)
        XCTAssertTrue(mitMaske.hasEdits)

        var mitEffekt = grund
        mitEffekt.effects = LayerEffects(shadow: Shadow(offsetX: 4, radius: 3))
        XCTAssertTrue(mitEffekt.hasEdits)

        var mitTextur = grund
        mitTextur.texture = LayerTexture(imageReference: "originals/t.png")
        XCTAssertTrue(mitTextur.hasEdits)

        var mitAnpassung = grund
        mitAnpassung.content = .image(ImageLayerContent(
            originalFileReference: "originals/a.png",
            adjustments: ImageAdjustments(contrast: 0.3)))
        XCTAssertTrue(mitAnpassung.hasEdits)
    }

    // MARK: - Leinwand

    private func aufbau() -> (CanvasView, UUID) {
        let ebene = Layer(
            name: "Form",
            transform: Transform2D(x: 50, y: 50),
            effects: LayerEffects(shadow: Shadow(offsetX: 6, offsetY: 6, radius: 4)),
            content: .shape(ShapeLayerContent(
                kind: .rectangle, size: Size(width: 40, height: 40), fillColorHex: "#FF0000"))
        )
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 200, height: 200), layers: [ebene])
        let view = CanvasView(document: document, images: ImageStore(resources: DocumentResources()))
        view.layoutSubtreeIfNeeded()
        view.layer?.layoutIfNeeded()
        return (view, ebene.id)
    }

    private func schicht(_ view: CanvasView) throws -> CALayer {
        let leinwand = try XCTUnwrap(view.layer?.sublayers?.first)
        return try XCTUnwrap(leinwand.sublayers?.first)
    }

    func testComparisonHidesTheEffectAndRestoresIt() throws {
        let (view, id) = aufbau()
        XCTAssertGreaterThan(try schicht(view).shadowOpacity, 0, "der Schatten müsste zunächst da sein")

        view.comparisonLayerID = id
        XCTAssertEqual(try schicht(view).shadowOpacity, 0, "im Vergleich müsste der Schatten weg sein")

        view.comparisonLayerID = nil
        XCTAssertGreaterThan(try schicht(view).shadowOpacity, 0, "danach müsste er wieder da sein")
    }

    /// Der Vergleich darf die Lage nicht verändern — sonst vergliche man zwei
    /// Bilder, die nebeneinander gar nicht deckungsgleich sind.
    func testComparisonKeepsThePosition() throws {
        let (view, id) = aufbau()
        let vorher = try schicht(view).position
        view.comparisonLayerID = id
        XCTAssertEqual(try schicht(view).position, vorher)
    }

    /// Er darf am Dokument nichts ändern — kein Undo-Schritt, keine
    /// „geändert"-Markierung.
    func testComparisonDoesNotTouchTheDocument() throws {
        let (view, id) = aufbau()
        let vorher = view.documentForTesting
        view.comparisonLayerID = id
        XCTAssertEqual(view.documentForTesting, vorher)
    }
}
