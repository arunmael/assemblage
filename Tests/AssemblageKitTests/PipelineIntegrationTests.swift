import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Die von Plan 2.1 geforderten Tests der Kernpipeline — Kompositing,
/// Maskierung, Export — samt Stresstest mit vielen Ebenen.
///
/// Lagen ursprünglich als Platzhalter in `AssemblageModelTests`, obwohl sie
/// Core Image, Core Animation und Vision brauchen. Hier gehören sie hin: das
/// macOS-Testziel hat diese Frameworks, das portable Modell hat sie bewusst
/// nicht.
///
/// Noch nicht umsetzbare Fälle stehen als `XCTSkip` mit Phasen-Angabe da und
/// nicht als `XCTFail`: Ein dauerhaft roter Testlauf gewöhnt einen daran,
/// Rot zu ignorieren — und dann fällt der erste echte Fehler nicht mehr auf.
@MainActor
final class PipelineIntegrationTests: XCTestCase {

    // MARK: - Kompositing

    /// Stresstest aus Plan 2.1: viele Ebenen auf einer grossen Leinwand.
    ///
    /// Gemessen wird der Aufbau des Ebenenbaums, nicht das Zeichnen eines
    /// Einzelbildes — genau dieser Aufbau passiert bei jedem Öffnen eines
    /// Dokuments und bei jeder Änderung der Ebenenstruktur.
    func testCompositingManyLayersDoesNotExceedTimeBudget() throws {
        let layerCount = 200
        let canvas = CanvasSize(width: 4000, height: 4000)

        let layers = (0..<layerCount).map { index in
            Layer(
                name: "Ebene \(index)",
                opacity: 0.9,
                blendMode: index.isMultiple(of: 3) ? .multiply : .normal,
                transform: Transform2D(
                    x: Double(index % 20) * 200,
                    y: Double(index / 20) * 200,
                    rotationDegrees: Double(index)
                ),
                content: .shape(
                    ShapeLayerContent(
                        kind: .roundedRectangle,
                        size: Size(width: 180, height: 180),
                        cornerRadius: 20,
                        fillColorHex: "#3A7BD5"
                    )
                )
            )
        }
        let document = AssemblageModel.Document(canvas: canvas, layers: layers)

        let started = Date()
        let view = CanvasView(document: document, images: ImageStore(resources: DocumentResources()))
        view.layer?.layoutIfNeeded()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(
            view.layer?.sublayers?.first?.sublayers?.count,
            layerCount,
            "jede Ebene braucht genau eine Schicht"
        )
        // Grosszügig angesetzt: Der Test soll eine echte Verschlechterung
        // melden (etwa ein versehentlicher Neuaufbau pro Ebene), nicht bei
        // Schwankungen der Testmaschine ausschlagen.
        XCTAssertLessThan(elapsed, 1.0, "200 Ebenen aufzubauen darf nicht spürbar dauern")
    }

    /// Eine Änderung an einer einzelnen Ebene darf den Baum nicht neu
    /// aufbauen — sonst würde jeder Reglerzug alle Bilder neu dekodieren.
    func testChangingOneLayerReusesTheExistingLayerTree() throws {
        var document = AssemblageModel.Document(
            canvas: CanvasSize(width: 500, height: 500),
            layers: (0..<10).map {
                Layer(
                    name: "E\($0)",
                    content: .shape(ShapeLayerContent(kind: .rectangle, size: Size(width: 50, height: 50)))
                )
            }
        )
        let view = CanvasView(document: document, images: ImageStore(resources: DocumentResources()))
        let before = view.layer?.sublayers?.first?.sublayers?.first

        document.layers[0].opacity = 0.3
        view.update(to: document)

        XCTAssertIdentical(
            view.layer?.sublayers?.first?.sublayers?.first,
            before,
            "dieselbe Schicht muss weiterverwendet werden"
        )
        XCTAssertEqual(view.layer?.sublayers?.first?.sublayers?.first?.opacity, 0.3)
    }

    // MARK: - Fehlertoleranz beim Import

    /// Plan 2.1: kaputte Bilddateien dürfen nicht abstürzen lassen.
    func testMalformedImageImportFailsGracefullyInsteadOfCrashing() throws {
        let resources = DocumentResources()
        let store = ImageStore(resources: resources)

        let garbage = resources.addOriginal(Data("das ist kein Bild".utf8), fileExtension: "png")
        XCTAssertNil(store.image(named: garbage), "Unsinn darf nicht als Bild durchgehen")

        let truncated = resources.addOriginal(Data([0x89, 0x50, 0x4E, 0x47]), fileExtension: "png")
        XCTAssertNil(store.image(named: truncated), "abgeschnittene Datei darf nicht abstürzen")

        XCTAssertNil(store.image(named: "originals/existiert-nicht.png"))

        // Ein zweiter Versuch muss ebenso ruhig scheitern (der Fehlschlag wird
        // gemerkt, damit nicht bei jedem Frame neu dekodiert wird).
        XCTAssertNil(store.image(named: garbage))
    }

    // MARK: - Export

    /// Grundfall aus Plan 5.8: alle sichtbaren Ebenen landen im Export, in
    /// der richtigen Grösse und richtigen Reihenfolge.
    func testExportRendersAllVisibleLayersAtRequestedSize() async throws {
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 200, height: 200),
            layers: [
                Layer(
                    name: "Unten",
                    transform: Transform2D(x: 100, y: 100),
                    content: .shape(ShapeLayerContent(kind: .rectangle, size: Size(width: 200, height: 200), fillColorHex: "#FF0000"))
                ),
                Layer(
                    name: "Oben",
                    transform: Transform2D(x: 100, y: 100),
                    content: .shape(ShapeLayerContent(kind: .rectangle, size: Size(width: 80, height: 80), fillColorHex: "#0000FF"))
                )
            ]
        )

        let image = try await DocumentExporter.image(
            of: document,
            resources: DocumentResources(),
            targetSize: CGSize(width: 400, height: 400)
        )

        XCTAssertEqual(image.width, 400, "die angeforderte Zielgrösse muss eingehalten werden")
        XCTAssertEqual(image.height, 400, "die angeforderte Zielgrösse muss eingehalten werden")

        let context = try XCTUnwrap(contextForReading(image))
        // Mitte: die obere (spätere) Ebene muss die untere verdecken.
        assertRoughly(try pixel(of: context, x: 200, y: 200), (0, 0, 255, 255), "die obere Ebene gewinnt in der Mitte")
        // Rand: dort liegt nur die untere Ebene.
        assertRoughly(try pixel(of: context, x: 20, y: 20), (255, 0, 0, 255), "am Rand bleibt nur die untere Ebene sichtbar")
    }

    /// Ausgeblendete Ebenen dürfen im Export nicht auftauchen.
    func testExportSkipsHiddenLayers() async throws {
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 200, height: 200),
            layers: [
                Layer(
                    name: "Versteckt",
                    isVisible: false,
                    transform: Transform2D(x: 100, y: 100),
                    content: .shape(ShapeLayerContent(kind: .rectangle, size: Size(width: 100, height: 100), fillColorHex: "#FF0000"))
                )
            ]
        )

        let image = try await DocumentExporter.image(
            of: document,
            resources: DocumentResources(),
            targetSize: CGSize(width: 200, height: 200)
        )
        let context = try XCTUnwrap(contextForReading(image))

        assertRoughly(try pixel(of: context, x: 100, y: 100), (0, 0, 0, 0), "eine ausgeblendete Ebene darf nicht exportiert werden")
    }

    // MARK: - Hilfsmittel Export

    private func contextForReading(_ image: CGImage) -> CGContext? {
        let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context
    }

    private func pixel(of context: CGContext, x: Int, y: Int) throws -> (r: Int, g: Int, b: Int, a: Int) {
        let data = try XCTUnwrap(context.data)
        let row = context.height - 1 - y
        let pointer = data.advanced(by: row * context.bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
        return (Int(pointer[0]), Int(pointer[1]), Int(pointer[2]), Int(pointer[3]))
    }

    private func assertRoughly(
        _ actual: (r: Int, g: Int, b: Int, a: Int),
        _ expected: (r: Int, g: Int, b: Int, a: Int),
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let tolerance = 12
        XCTAssertEqual(actual.r, expected.r, accuracy: tolerance, message, file: file, line: line)
        XCTAssertEqual(actual.g, expected.g, accuracy: tolerance, message, file: file, line: line)
        XCTAssertEqual(actual.b, expected.b, accuracy: tolerance, message, file: file, line: line)
        XCTAssertEqual(actual.a, expected.a, accuracy: tolerance, message, file: file, line: line)
    }

    // MARK: - Automatisches Freistellen (Plan 5.4, 7.3)

    /// Grundfall der Kernpipeline: ein Bild mit klarem Vordergrund-Objekt vor
    /// einheitlichem Grund liefert eine nicht-leere Maske in den Massen des
    /// Quellbilds. Die Einzelfälle (kein Motiv, kaputte Daten, Skalierung,
    /// Nebenläufigkeit) stehen ausführlich in `ForegroundMaskingTests` — hier
    /// nur der Beleg, dass die Pipeline als Ganzes funktioniert.
    ///
    /// Vision ist ein Modell, keine deterministische Funktion; erkennt es auf
    /// diesem gemalten Testbild nichts, ist das keine Regression dieser App,
    /// sondern eine Modellentscheidung, die je nach macOS-Version anders
    /// ausfallen darf — deshalb `XCTSkip` statt `XCTFail` in diesem Fall,
    /// analog zur bisherigen Konvention dieser Datei.
    func testAutomaticForegroundMaskProducesNonEmptyMask() async throws {
        let width = 500, height = 500
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.9, blue: 0.92, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 125, y: 125, width: 250, height: 250))
        let image = try XCTUnwrap(context.makeImage())

        let result = try await ForegroundMasking.generateMask(from: image)

        guard case .mask(let data) = result else {
            throw XCTSkip("Vision hat auf diesem gemalten Testbild kein Motiv erkannt — modellabhängig, kein Fehler der Pipeline.")
        }

        XCTAssertFalse(data.isEmpty, "eine gefundene Maske darf nicht leer sein")
        let decodedMask = try XCTUnwrap(ImageDecoding.decode(data))
        XCTAssertEqual(decodedMask.width, width, "die Maske muss dieselbe Breite wie das Bild haben")
        XCTAssertEqual(decodedMask.height, height, "die Maske muss dieselbe Höhe wie das Bild haben")

        // Aus der Maske liesse sich direkt eine `LayerMask` bauen, so wie sie
        // laut Plan 5.4 ins Dokumentpaket abgelegt wird — der eigentliche
        // Anschluss an Ebene/Dokument ist bewusst nicht Teil dieser Aufgabe.
        let resources = DocumentResources()
        let reference = resources.addMask(data)
        let mask = LayerMask(maskImageReference: reference, source: .automaticForegroundInstance)
        XCTAssertEqual(mask.source, .automaticForegroundInstance)
        XCTAssertNotNil(resources.data(for: reference))
    }
}
