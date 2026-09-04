import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Werte, die durch die Dekodierung kommen, aber das Zeichnen umbringen können.
///
/// `DocumentFuzzTests` deckt die andere Hälfte ab: Dort geht es darum, dass
/// beschädigte Daten sauber abgewiesen werden. Hier geht es um Dokumente, die
/// **gültig dekodieren** und trotzdem Werte tragen, mit denen Core Graphics
/// oder Core Image nicht rechnen können — eine Skalierung von 1e300, eine
/// Drehung von einer Billion Grad, eine Leinwand von 1×1.
///
/// Solche Werte entstehen nicht durch Böswilligkeit, sondern durch einen
/// abgerutschten Regler, ein Dokument von einem anderen Programmstand oder
/// eine Datei, deren Zahlen halb überschrieben wurden. Plan 2.1 verlangt für
/// alle drei, dass die App weiterläuft.
@MainActor
final class PipelineRobustnessTests: XCTestCase {

    /// Ein Aufbau, der schiefgehen könnte — Name für die Fehlermeldung, plus
    /// das Dokument.
    private struct Fall {
        let name: String
        let document: AssemblageModel.Document
    }

    private func form(_ transform: Transform2D, size: Size = Size(width: 40, height: 40)) -> Layer {
        Layer(name: "Form", transform: transform,
              content: .shape(ShapeLayerContent(kind: .rectangle, size: size, fillColorHex: "#FF0000")))
    }

    private func faelle() -> [Fall] {
        let leinwand = CanvasSize(width: 200, height: 150)

        func doc(_ layers: [Layer], canvas: CanvasSize = CanvasSize(width: 200, height: 150)) -> AssemblageModel.Document {
            AssemblageModel.Document(canvas: canvas, layers: layers)
        }

        var ebeneOhneDeckkraft = form(Transform2D(x: 100, y: 75))
        ebeneOhneDeckkraft.opacity = .nan

        var ebeneUnendlicheDeckkraft = form(Transform2D(x: 100, y: 75))
        ebeneUnendlicheDeckkraft.opacity = .infinity

        var verzerrtEntartet = form(Transform2D(x: 100, y: 75))
        verzerrtEntartet.distortion = QuadDistortion(
            topLeft: .zero, topRight: .zero, bottomRight: .zero, bottomLeft: .zero)

        var maskeFehlt = Layer(
            name: "Foto", transform: Transform2D(x: 100, y: 75),
            content: .image(ImageLayerContent(originalFileReference: "originals/fehlt.png")))
        maskeFehlt.mask = LayerMask(maskImageReference: "masks/fehlt.png", source: .manualBrush)

        var texturFehlt = form(Transform2D(x: 100, y: 75))
        texturFehlt.texture = LayerTexture(imageReference: "originals/fehlt.png")

        var riesigerEffekt = form(Transform2D(x: 100, y: 75))
        riesigerEffekt.effects = LayerEffects(
            glow: Glow(radius: 1e9, intensity: 1),
            shadow: Shadow(offsetX: 1e9, offsetY: -1e9, radius: 1e9, opacity: 1))

        return [
            Fall(name: "Skalierung null", document: doc([form(Transform2D(x: 100, y: 75, scaleX: 0, scaleY: 0))])),
            Fall(name: "Skalierung negativ", document: doc([form(Transform2D(x: 100, y: 75, scaleX: -3, scaleY: -3))])),
            Fall(name: "Skalierung riesig", document: doc([form(Transform2D(x: 100, y: 75, scaleX: 1e300, scaleY: 1e300))])),
            Fall(name: "Drehung eine Billion Grad", document: doc([form(Transform2D(x: 100, y: 75, rotationDegrees: 1e12))])),
            Fall(name: "Position weit ausserhalb", document: doc([form(Transform2D(x: 1e12, y: -1e12))])),
            Fall(name: "Formgrösse null", document: doc([form(Transform2D(x: 100, y: 75), size: Size(width: 0, height: 0))])),
            Fall(name: "Formgrösse negativ", document: doc([form(Transform2D(x: 100, y: 75), size: Size(width: -50, height: -50))])),
            Fall(name: "Leinwand 1×1", document: doc([form(Transform2D(x: 0, y: 0))], canvas: CanvasSize(width: 1, height: 1))),
            Fall(name: "Leinwand null", document: doc([form(Transform2D(x: 0, y: 0))], canvas: CanvasSize(width: 0, height: 0))),
            Fall(name: "Deckkraft NaN", document: doc([ebeneOhneDeckkraft])),
            Fall(name: "Deckkraft unendlich", document: doc([ebeneUnendlicheDeckkraft])),
            Fall(name: "Verzerrung entartet", document: doc([verzerrtEntartet])),
            Fall(name: "Maske fehlt", document: doc([maskeFehlt])),
            Fall(name: "Textur fehlt", document: doc([texturFehlt])),
            Fall(name: "Effekt mit Radius 1e9", document: doc([riesigerEffekt])),
            Fall(name: "Zuschnitt ausserhalb des Bildes", document: doc([Layer(
                name: "Foto", transform: Transform2D(x: 100, y: 75),
                content: .image(ImageLayerContent(
                    originalFileReference: "originals/fehlt.png",
                    cropRect: Rect(x: -5000, y: -5000, width: 99999, height: 99999))))])),
            Fall(name: "Text mit 200 000 Zeichen", document: doc([Layer(
                name: "Text", transform: Transform2D(x: 100, y: 75),
                content: .text(TextLayerContent(string: String(repeating: "M", count: 200_000))))])),
            Fall(name: "Schriftgrad null", document: doc([Layer(
                name: "Text", transform: Transform2D(x: 100, y: 75),
                content: .text(TextLayerContent(string: "x", fontSize: 0)))])),
            Fall(name: "Schrift gibt es nicht", document: doc([Layer(
                name: "Text", transform: Transform2D(x: 100, y: 75),
                content: .text(TextLayerContent(string: "x", fontName: "GibtEsNichtXYZ")))])),
            Fall(name: "Farbe kein Hexwert", document: doc([Layer(
                name: "Form", transform: Transform2D(x: 100, y: 75),
                content: .shape(ShapeLayerContent(
                    kind: .star, size: Size(width: 40, height: 40), fillColorHex: "kein hexwert")))])),
            Fall(name: "Stern mit null Zacken", document: doc([Layer(
                name: "Form", transform: Transform2D(x: 100, y: 75),
                content: .shape(ShapeLayerContent(
                    kind: .star, size: Size(width: 40, height: 40), pointCount: 0)))])),
            Fall(name: "leeres Dokument", document: doc([], canvas: leinwand))
        ]
    }

    /// Der Canvas muss jeden Fall aufbauen können. Ein Absturz hier heisst:
    /// Das Dokument lässt sich nicht einmal öffnen.
    func testCanvasSurvivesEveryCase() {
        for fall in faelle() {
            let view = CanvasView(
                document: fall.document,
                images: ImageStore(resources: DocumentResources()))
            view.layoutSubtreeIfNeeded()
            view.layer?.layoutIfNeeded()

            // Auch ein Auffrischen darf nicht scheitern — das ist der Weg,
            // den jede Änderung nimmt.
            view.update(to: fall.document)
            XCTAssertNotNil(view.layer, fall.name)
        }
    }

    /// Der Export muss jeden Fall zu Ende bringen oder einen sauberen Fehler
    /// melden. Was er nicht darf: abstürzen oder hängenbleiben.
    func testExportSurvivesEveryCase() async {
        for fall in faelle() {
            do {
                let bild = try await DocumentExporter.image(
                    of: fall.document,
                    resources: DocumentResources(),
                    targetSize: CGSize(width: 120, height: 90))
                XCTAssertEqual(bild.width, 120, fall.name)
            } catch let fehler as DocumentExporter.ExportError {
                // Ein gemeldeter Fehler ist ein gültiges Ergebnis; er muss nur
                // etwas sagen, das man einem Benutzer zeigen kann.
                XCTAssertNotNil(fehler.errorDescription, fall.name)
            } catch {
                XCTFail("\(fall.name): unerwarteter Fehler \(error)")
            }
        }
    }

    /// Dieselben Fälle durch das Dokumentformat und wieder zurück: Was sich
    /// zeichnen lässt, muss sich auch sichern und wieder öffnen lassen.
    func testEveryCaseSurvivesARoundTrip() throws {
        for fall in faelle() {
            let daten = try DocumentPackage.encode(fall.document)
            let zurueck = try DocumentPackage.decode(daten)
            XCTAssertEqual(zurueck.layers.count, fall.document.layers.count, fall.name)
        }
    }

    /// Trefferprüfung und Auswahlrahmen laufen bei jeder Mausbewegung. Eine
    /// entartete Geometrie darf dort nicht in eine Endlosschleife oder eine
    /// nicht umkehrbare Matrix laufen.
    func testHitTestingSurvivesEveryCase() {
        for fall in faelle() {
            for punkt in [Point(x: 0, y: 0), Point(x: 100, y: 75), Point(x: 1e9, y: -1e9)] {
                _ = fall.document.topmostLayer(at: punkt) { ebene in
                    switch ebene.content {
                    case .shape(let form): return form.size
                    case .text: return Size(width: 100, height: 20)
                    case .image: return Size(width: 320, height: 320)
                    }
                }
            }
        }
    }
}
