import XCTest
@testable import AssemblageModel

/// Effekte (Leuchten, Schlagschatten) und Texturen auf einer Ebene.
///
/// Beides liegt als **optionale** Angabe neben der Ebene, wie schon die
/// Verzerrung: Die allermeisten Ebenen haben keines von beidem, und dann soll
/// weder etwas gespeichert noch gerechnet werden.
final class EffectsTests: XCTestCase {

    private let hundert = Size(width: 100, height: 100)

    private func ebene() -> Layer {
        Layer(name: "A", content: .shape(ShapeLayerContent(kind: .rectangle, size: hundert)))
    }

    // MARK: - Neutralzustand

    func testLayerHasNoEffectsByDefault() {
        XCTAssertNil(ebene().effects)
        XCTAssertNil(ebene().texture)
    }

    /// Effekte ohne Inhalt sind dasselbe wie keine Effekte — das muss
    /// erkennbar sein, damit der Renderer sie überspringen kann.
    func testEmptyEffectsAreRecognisedAsInactive() {
        XCTAssertFalse(LayerEffects().isActive)
        XCTAssertTrue(LayerEffects(glow: Glow(radius: 10)).isActive)
        XCTAssertTrue(LayerEffects(shadow: Shadow(offsetY: 4)).isActive)
    }

    /// Ein Leuchten mit Radius null leuchtet nicht — das ist kein Effekt,
    /// sondern nur Rechenaufwand.
    func testGlowWithoutRadiusIsInactive() {
        XCTAssertFalse(LayerEffects(glow: Glow(radius: 0)).isActive)
    }

    /// Ein Schatten ohne Versatz und ohne Weichzeichnung liegt exakt hinter
    /// der Ebene und ist unsichtbar.
    func testShadowWithoutOffsetOrBlurIsInactive() {
        XCTAssertFalse(LayerEffects(shadow: Shadow(offsetX: 0, offsetY: 0, radius: 0)).isActive)
    }

    // MARK: - Wertebereiche

    /// Regler können durch schnelles Ziehen kurzzeitig ausserhalb landen.
    func testValuesAreClamped() {
        let wild = LayerEffects(
            glow: Glow(radius: -5, intensity: 9),
            shadow: Shadow(radius: -3, opacity: 4)
        )
        let gezaehmt = wild.clamped()

        XCTAssertGreaterThanOrEqual(gezaehmt.glow?.radius ?? -1, 0)
        XCTAssertLessThanOrEqual(gezaehmt.glow?.intensity ?? 99, 1)
        XCTAssertGreaterThanOrEqual(gezaehmt.shadow?.radius ?? -1, 0)
        XCTAssertLessThanOrEqual(gezaehmt.shadow?.opacity ?? 99, 1)
    }

    func testTextureOpacityAndScaleAreClamped() {
        let wild = LayerTexture(imageReference: "originals/t.png", opacity: 3, scale: 0)
        let gezaehmt = wild.clamped()

        XCTAssertLessThanOrEqual(gezaehmt.opacity, 1)
        XCTAssertGreaterThan(gezaehmt.scale, 0, "Massstab null würde die Textur verschwinden lassen")
    }

    // MARK: - Speichern

    func testEffectsAndTextureSurviveEncoding() throws {
        var mit = ebene()
        mit.effects = LayerEffects(
            glow: Glow(radius: 12, colorHex: "#00FFEE", intensity: 0.8),
            shadow: Shadow(offsetX: 3, offsetY: 5, radius: 8, colorHex: "#000000", opacity: 0.5)
        )
        mit.texture = LayerTexture(
            imageReference: "originals/papier.png",
            blendMode: .multiply,
            opacity: 0.4,
            scale: 1.5
        )

        let wieder = try DocumentPackage.decode(
            DocumentPackage.encode(Document(canvas: hundert, layers: [mit]))
        )

        XCTAssertEqual(wieder.layers.first?.effects, mit.effects)
        XCTAssertEqual(wieder.layers.first?.texture, mit.texture)
    }

    /// Ältere Dokumente ohne diese Felder müssen weiter lesbar sein.
    func testOlderDocumentsWithoutEffectsStillDecode() throws {
        let json = """
        { "formatVersion": 1, "document": {
            "canvas": { "width": 100, "height": 100 },
            "layers": [{
                "id": "11111111-1111-1111-1111-111111111111", "name": "Alt",
                "content": { "text": { "_0": { "string": "x" } } }
            }]
        } }
        """
        let dokument = try DocumentPackage.decode(Data(json.utf8))

        XCTAssertNil(dokument.layers.first?.effects)
        XCTAssertNil(dokument.layers.first?.texture)
    }

    // MARK: - Texturdatei

    /// Die Texturdatei liegt im Dokumentpaket und muss beim Aufräumen als
    /// benutzt gelten — sonst wirft das nächste Sichern sie weg.
    func testTextureFileCountsAsReferenced() {
        var mit = ebene()
        mit.texture = LayerTexture(imageReference: "originals/papier.png")
        let dokument = Document(canvas: hundert, layers: [mit])

        XCTAssertTrue(dokument.referencedFileNames.contains("originals/papier.png"))
        XCTAssertTrue(
            DocumentPackage.unreferencedFileNames(in: ["originals/papier.png"], for: dokument).isEmpty
        )
    }
}
