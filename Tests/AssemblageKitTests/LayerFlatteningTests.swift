import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Rasterisierung von Text und Formen zu einem Bildobjekt. Die Geometrie wird
/// über Eckpunkte geprüft, weil gleiche Zahlen in `Transform2D` bei einer
/// neuen Inhaltsgrösse gerade nicht dieselbe sichtbare Ebene ergäben.
@MainActor
final class LayerFlatteningTests: XCTestCase {

    private func dokument(mit layer: Layer) -> (AssemblageDocument, UndoManager) {
        let document = AssemblageDocument()
        let undo = UndoManager()
        document.undoManager = undo
        document.modify("Vorbereiten") { $0.layers = [layer] }
        document.state.selectedLayerID = layer.id
        undo.removeAllActions()
        return (document, undo)
    }

    private func inhaltsgroesse(_ layer: Layer, resources: DocumentResources) throws -> Size {
        switch layer.content {
        case .text(let text):
            return Size(TextLayout.naturalSize(of: text))
        case .shape(let form):
            return form.size
        case .image(let bild):
            let daten = try XCTUnwrap(resources.data(for: bild.originalFileReference))
            let dekodiert = try XCTUnwrap(ImageDecoding.decode(daten))
            return Size(width: Double(dekodiert.width), height: Double(dekodiert.height))
        }
    }

    func testTextBecomesDecodablePNGOriginal() throws {
        let layer = Layer(
            name: "Titel",
            transform: Transform2D(x: 200, y: 150),
            content: .text(TextLayerContent(string: "Assemblage", fontSize: 48, colorHex: "#CC3300"))
        )
        let (document, _) = dokument(mit: layer)

        XCTAssertTrue(LayerFlattening.flattenSelected(in: document.state))

        let ergebnis = try XCTUnwrap(document.state.document.layer(withID: layer.id))
        guard case .image(let bild) = ergebnis.content else { return XCTFail("keine Bildebene") }
        XCTAssertTrue(bild.originalFileReference.hasSuffix(".png"))
        XCTAssertTrue(document.state.resources.fileNames.contains(bild.originalFileReference))
        let daten = try XCTUnwrap(document.state.resources.data(for: bild.originalFileReference))
        XCTAssertNotNil(ImageDecoding.decode(daten), "das Original im Paket muss ein dekodierbares PNG sein")
    }

    func testPositionSizeAndRotationRemainExactlyTheSame() throws {
        let layer = Layer(
            name: "Titel",
            transform: Transform2D(x: 217, y: 143, scaleX: 2.75, scaleY: 1.6, rotationDegrees: 31),
            content: .text(TextLayerContent(string: "Geometrie", fontSize: 73))
        )
        let (document, _) = dokument(mit: layer)
        let vorherGroesse = try inhaltsgroesse(layer, resources: document.state.resources)
        let vorher = layer.transform.corners(contentSize: vorherGroesse)

        XCTAssertTrue(LayerFlattening.flattenSelected(in: document.state))

        let ergebnis = try XCTUnwrap(document.state.document.layer(withID: layer.id))
        let nachherGroesse = try inhaltsgroesse(ergebnis, resources: document.state.resources)
        let nachher = ergebnis.transform.corners(contentSize: nachherGroesse)
        XCTAssertEqual(ergebnis.transform.x, layer.transform.x)
        XCTAssertEqual(ergebnis.transform.y, layer.transform.y)
        XCTAssertEqual(ergebnis.transform.rotationDegrees, layer.transform.rotationDegrees)
        for (a, b) in zip(vorher, nachher) {
            XCTAssertEqual(a.x, b.x, accuracy: 0.001)
            XCTAssertEqual(a.y, b.y, accuracy: 0.001)
        }
    }

    func testRasterResolutionIncludesLayerScale() throws {
        let text = TextLayerContent(string: "Gross", fontSize: 96)
        let layer = Layer(
            name: "Titel",
            transform: Transform2D(x: 300, y: 200, scaleX: 4, scaleY: 4),
            content: .text(text)
        )
        let (document, _) = dokument(mit: layer)
        let satzgroesse = TextLayout.naturalSize(of: text)

        XCTAssertTrue(LayerFlattening.flattenSelected(in: document.state))

        let ergebnis = try XCTUnwrap(document.state.document.layer(withID: layer.id))
        let pixel = try inhaltsgroesse(ergebnis, resources: document.state.resources)
        XCTAssertGreaterThanOrEqual(pixel.width, satzgroesse.width * 4)
        XCTAssertGreaterThanOrEqual(pixel.height, satzgroesse.height * 4)
    }

    func testRasterizedTextLooksLikeTheEditableOriginal() throws {
        let layer = Layer(
            name: "Titel",
            transform: Transform2D(x: 200, y: 180, scaleX: 2, scaleY: 2),
            content: .text(TextLayerContent(string: "Aa", fontSize: 64, colorHex: "#CC3300"))
        )
        let (document, _) = dokument(mit: layer)
        document.modify("Leinwand") { $0.canvas = CanvasSize(width: 400, height: 360) }
        document.undoManager?.removeAllActions()
        let ziel = CGSize(width: 400, height: 360)
        let vorher = try DocumentExporter.renderedImage(
            of: document.state.document,
            resources: document.state.resources,
            targetSize: ziel
        )

        XCTAssertTrue(LayerFlattening.flattenSelected(in: document.state))
        let nachher = try DocumentExporter.renderedImage(
            of: document.state.document,
            resources: document.state.resources,
            targetSize: ziel
        )
        let anzahl = vorher.width * vorher.height * 4
        let vorherKontext = try rgbaContext(vorher)
        let nachherKontext = try rgbaContext(nachher)
        let a = try XCTUnwrap(vorherKontext.data).assumingMemoryBound(to: UInt8.self)
        let b = try XCTUnwrap(nachherKontext.data).assumingMemoryBound(to: UInt8.self)
        var abweichung = 0
        for index in 0..<anzahl where abs(Int(a[index]) - Int(b[index])) > 24 {
            abweichung += 1
        }
        XCTAssertLessThan(
            abweichung,
            anzahl / 200,
            "Rasterbild und bearbeitbarer Text dürfen sich nur an Antialiasing-Kanten unterscheiden"
        )
    }

    private func rgbaContext(_ image: CGImage) throws -> CGContext {
        let kontext = try XCTUnwrap(CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        kontext.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return kontext
    }

    func testMaskOpacityBlendModeAndDistortionSurvive() throws {
        let resources = DocumentResources()
        let maskenreferenz = resources.addMask(Data([1, 2, 3]))
        let maske = LayerMask(
            maskImageReference: maskenreferenz,
            source: .manualBrush,
            isInverted: true,
            isEnabled: false
        )
        let verzerrung = QuadDistortion(
            topLeft: Point(x: 4, y: 7),
            bottomRight: Point(x: -3, y: 9)
        )
        let layer = Layer(
            name: "Form",
            opacity: 0.42,
            blendMode: .multiply,
            transform: Transform2D(x: 200, y: 200, scaleX: 1.8, scaleY: 2.2),
            mask: maske,
            distortion: verzerrung,
            content: .shape(ShapeLayerContent(
                kind: .roundedRectangle,
                size: Size(width: 180, height: 90),
                cornerRadius: 18,
                fillColorHex: "#3366CC"
            ))
        )
        let document = AssemblageDocument()
        document.modify("Vorbereiten") { $0.layers = [layer] }
        document.state.selectedLayerID = layer.id

        XCTAssertTrue(LayerFlattening.flattenSelected(in: document.state))

        let ergebnis = try XCTUnwrap(document.state.document.layer(withID: layer.id))
        guard case .image = ergebnis.content else { return XCTFail("Form wurde nicht gerastert") }
        XCTAssertEqual(ergebnis.mask, maske)
        XCTAssertEqual(ergebnis.opacity, 0.42)
        XCTAssertEqual(ergebnis.blendMode, .multiply)
        XCTAssertEqual(ergebnis.distortion, verzerrung)
    }

    func testUndoRestoresEditableTextInOneStep() throws {
        let inhalt = TextLayerContent(
            string: "Weiter bearbeitbar", fontName: "Helvetica", fontSize: 64,
            colorHex: "#123456", alignment: .right
        )
        let layer = Layer(name: "Titel", content: .text(inhalt))
        let (document, undo) = dokument(mit: layer)

        XCTAssertTrue(LayerFlattening.flattenSelected(in: document.state))
        XCTAssertEqual(undo.undoActionName, "In Objekt umwandeln")
        undo.undo()

        let wiederhergestellt = try XCTUnwrap(document.state.document.layer(withID: layer.id))
        XCTAssertEqual(wiederhergestellt.content, .text(inhalt))
        XCTAssertFalse(undo.canUndo, "die Umwandlung ist genau ein Undo-Schritt")
    }

    func testImageLayerDoesNothing() throws {
        let resources = DocumentResources()
        let referenz = resources.addOriginal(Data([1, 2, 3]), fileExtension: "png")
        let layer = Layer(name: "Schon ein Bild", content: .image(ImageLayerContent(originalFileReference: referenz)))
        let (document, undo) = dokument(mit: layer)
        let dateienVorher = document.state.resources.fileNames
        let vorher = document.state.document

        XCTAssertFalse(LayerFlattening.flattenSelected(in: document.state))

        XCTAssertEqual(document.state.document, vorher)
        XCTAssertEqual(document.state.resources.fileNames, dateienVorher)
        XCTAssertFalse(undo.canUndo)
    }

    func testTextAndShapeAreEligibleButImagesAreNot() {
        XCTAssertTrue(LayerFlattening.canFlatten(.text(TextLayerContent(string: "Text"))))
        XCTAssertTrue(LayerFlattening.canFlatten(.shape(ShapeLayerContent(
            kind: .ellipse, size: Size(width: 20, height: 30)
        ))))
        XCTAssertFalse(LayerFlattening.canFlatten(.image(ImageLayerContent(originalFileReference: "x.png"))))
    }
}
