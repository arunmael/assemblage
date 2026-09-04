import XCTest
@testable import AssemblageModel

/// Bereinigung nicht endlicher Zahlen.
///
/// Anlass war ein konkreter Fund: Ein `nan` in der Deckkraft einer Ebene
/// machte das ganze Dokument **unspeicherbar** — `JSONEncoder` wirft daran.
/// Leinwand und Export überlebten den Wert klaglos, aber der Nutzer konnte
/// seine Arbeit nicht mehr ablegen. Das ist genau der Datenverlust, den Plan
/// 2.1 ausschliesst.
final class SanitizingTests: XCTestCase {

    // MARK: - Die Gegenprobe zuerst

    /// Das Wichtigste an einer Bereinigung ist, was sie **nicht** tut. Ändert
    /// sie gültige Werte, verstellt sie bei jedem Sichern die Arbeit des
    /// Nutzers — ein weit schlimmerer Fehler als der, den sie behebt.
    func testAValidDocumentPassesThroughUnchanged() {
        let document = Document(
            canvas: CanvasSize(width: 1920, height: 1080),
            layers: [
                Layer(
                    name: "Foto",
                    isVisible: false,
                    opacity: 0.37,
                    blendMode: .overlay,
                    transform: Transform2D(x: 12.5, y: -3.25, scaleX: 2, scaleY: 0.5, rotationDegrees: 47),
                    mask: LayerMask(maskImageReference: "masks/a.png", source: .manualBrush, isInverted: true),
                    distortion: QuadDistortion(
                        topLeft: Point(x: 1, y: 2), topRight: Point(x: 3, y: 4),
                        bottomRight: Point(x: 5, y: 6), bottomLeft: Point(x: 7, y: 8)),
                    effects: LayerEffects(
                        glow: Glow(radius: 8, colorHex: "#FFEE00", intensity: 0.4),
                        shadow: Shadow(offsetX: -4, offsetY: 6, radius: 3, colorHex: "#123456", opacity: 0.9)),
                    texture: LayerTexture(imageReference: "originals/t.png", blendMode: .screen,
                                          opacity: 0.25, scale: 3),
                    content: .image(ImageLayerContent(
                        originalFileReference: "originals/a.png",
                        cropRect: Rect(x: 10, y: 20, width: 30, height: 40),
                        adjustments: ImageAdjustments(brightness: 0.2, contrast: -0.3, warmth: 0.1)))
                ),
                Layer(name: "Titel", content: .text(TextLayerContent(
                    string: "Hallo", fontName: "Georgia", fontSize: 31.5, colorHex: "#00FF00"))),
                Layer(name: "Stern", content: .shape(ShapeLayerContent(
                    kind: .star, size: Size(width: 15, height: 25),
                    cornerRadius: 4, fillColorHex: "#ABCDEF", pointCount: 7)))
            ]
        )

        XCTAssertEqual(document.sanitized(), document)
    }

    // MARK: - Was sie beheben soll

    func testNonFiniteOpacityBecomesVisibleAgain() {
        var ebene = Layer(name: "Form", content: .shape(
            ShapeLayerContent(kind: .rectangle, size: Size(width: 10, height: 10))))
        ebene.opacity = .nan

        // Sichtbar und nicht unsichtbar: Sonst hielte der Nutzer die Ebene für
        // verloren und suchte den Fehler an der falschen Stelle.
        XCTAssertEqual(ebene.sanitized().opacity, 1)
    }

    func testNonFiniteTransformFallsBackToTheIdentity() {
        let kaputt = Transform2D(x: .nan, y: .infinity, scaleX: .nan, scaleY: -.infinity, rotationDegrees: .nan)
        XCTAssertEqual(kaputt.sanitized(), .identity)
    }

    func testNonFiniteCanvasStaysUsable() {
        let document = Document(canvas: CanvasSize(width: .nan, height: .infinity), layers: [])
        let bereinigt = document.sanitized()

        // Nicht ein Punkt, sondern eine brauchbare Leinwand: Ein Dokument von
        // 1×1 wäre zwar gültig, aber der Nutzer hielte es für zerstört.
        XCTAssertEqual(bereinigt.canvas.width, 1000)
        XCTAssertEqual(bereinigt.canvas.height, 1000)
    }

    /// Ein kaputter Effekt wird abgeschaltet und nicht geraten: Ein
    /// erfundener Radius sähe aus wie eine Gestaltungsentscheidung, die der
    /// Nutzer nie getroffen hat.
    func testBrokenEffectsAreSwitchedOffRatherThanGuessed() {
        var ebene = Layer(name: "Form", content: .shape(
            ShapeLayerContent(kind: .rectangle, size: Size(width: 10, height: 10))))
        ebene.effects = LayerEffects(
            glow: Glow(radius: .infinity, intensity: .nan),
            shadow: Shadow(offsetX: .nan, offsetY: .nan, radius: .infinity, opacity: .nan))

        let effekte = ebene.sanitized().effects
        XCTAssertEqual(effekte?.glow?.radius, 0)
        XCTAssertEqual(effekte?.glow?.intensity, 0)
        XCTAssertEqual(effekte?.shadow?.opacity, 0)
    }

    func testNonFiniteDistortionCornersCollapseToTheOrigin() {
        var ebene = Layer(name: "Form", content: .shape(
            ShapeLayerContent(kind: .rectangle, size: Size(width: 10, height: 10))))
        ebene.distortion = QuadDistortion(
            topLeft: Point(x: .nan, y: .nan), topRight: Point(x: .infinity, y: 0),
            bottomRight: .zero, bottomLeft: Point(x: 0, y: -.infinity))

        let verzerrung = ebene.sanitized().distortion
        XCTAssertEqual(verzerrung?.topLeft, .zero)
        XCTAssertEqual(verzerrung?.topRight, .zero)
        XCTAssertEqual(verzerrung?.bottomLeft, .zero)
    }

    func testNonFiniteAdjustmentsBecomeNeutral() {
        let inhalt = ImageLayerContent(
            originalFileReference: "originals/a.png",
            adjustments: ImageAdjustments(brightness: .nan, contrast: .infinity, blurRadius: -.infinity))
        XCTAssertEqual(inhalt.sanitized().adjustments, .neutral)
    }

    // MARK: - Der eigentliche Zweck

    /// Der Punkt der ganzen Übung: Ein Dokument muss sich immer sichern
    /// lassen. Ohne die Bereinigung wirft `encode` hier.
    func testADocumentWithBrokenNumbersCanStillBeSaved() throws {
        var ebene = Layer(name: "Form",
                          transform: Transform2D(x: .nan, y: .infinity, scaleX: .nan),
                          content: .shape(ShapeLayerContent(
                            kind: .rectangle, size: Size(width: .nan, height: .infinity))))
        ebene.opacity = .nan
        let document = Document(canvas: CanvasSize(width: .nan, height: 600), layers: [ebene])

        let daten = try DocumentPackage.encode(document)
        let zurueck = try DocumentPackage.decode(daten)

        // Nichts geht verloren: Die Ebene ist noch da, mit Namen und Inhalt.
        XCTAssertEqual(zurueck.layers.count, 1)
        XCTAssertEqual(zurueck.layers[0].name, "Form")
        XCTAssertTrue(zurueck.canvas.width.isFinite)
        XCTAssertTrue(zurueck.layers[0].opacity.isFinite)
    }

    /// Und die Gegenprobe dazu: Ein gültiges Dokument geht durch das Sichern
    /// unverändert hindurch.
    func testSavingDoesNotAlterAValidDocument() throws {
        let document = Document(
            canvas: CanvasSize(width: 800, height: 600),
            layers: [Layer(
                name: "Form",
                transform: Transform2D(x: 100.5, y: 200.25, scaleX: 1.5, rotationDegrees: 33),
                content: .shape(ShapeLayerContent(kind: .heart, size: Size(width: 40, height: 40))))])

        XCTAssertEqual(try DocumentPackage.decode(DocumentPackage.encode(document)), document)
    }
}
