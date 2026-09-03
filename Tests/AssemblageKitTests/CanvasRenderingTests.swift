import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Prüft, dass der Core-Animation-Canvas Ebenen tatsächlich dort und so
/// zeichnet, wie das Modell es beschreibt.
///
/// Headless statt per Screenshot: So läuft die Prüfung bei jedem `swift test`
/// mit, statt einmalig von Hand am Bildschirm. Plan 2.1 verlangt
/// „automatisierte Tests für die Kernpipeline (Kompositing, Maskierung,
/// Export)" — das hier ist der Anfang davon.
@MainActor
final class CanvasRenderingTests: XCTestCase {

    // MARK: - Hilfsmittel

    /// Rendert die Leinwand eines Dokuments in eine Bitmap.
    private func render(_ document: AssemblageModel.Document, resources: DocumentResources = DocumentResources()) throws -> CGContext {
        let view = CanvasView(document: document, images: ImageStore(resources: resources))
        // Layout erzwingen: ohne das haben die Schichten noch keine Rahmen.
        view.layoutSubtreeIfNeeded()
        view.layer?.layoutIfNeeded()

        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: Int(document.canvas.width),
            height: Int(document.canvas.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))

        let canvasLayer = try XCTUnwrap(view.layer?.sublayers?.first)
        canvasLayer.render(in: context)
        return context
    }

    /// Liest eine Farbe an einer Stelle der Leinwand — in **Leinwand**-
    /// koordinaten (Ursprung oben links), damit die Testfälle so gelesen
    /// werden können, wie das Modell denkt.
    private func color(of context: CGContext, atCanvasX x: Int, y: Int) throws -> (r: Int, g: Int, b: Int) {
        let data = try XCTUnwrap(context.data)
        // CGContext-Ursprung liegt unten links, deshalb hier umrechnen.
        let row = context.height - 1 - y
        let pixel = data.advanced(by: row * context.bytesPerRow + x * 4)
            .assumingMemoryBound(to: UInt8.self)
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    private func assertRoughly(
        _ actual: (r: Int, g: Int, b: Int),
        _ expected: (r: Int, g: Int, b: Int),
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Grosszügige Toleranz: Kantenglättung und Farbraumumrechnung
        // verschieben einzelne Werte, das ist kein Fehler.
        let tolerance = 12
        XCTAssertEqual(actual.r, expected.r, accuracy: tolerance, message, file: file, line: line)
        XCTAssertEqual(actual.g, expected.g, accuracy: tolerance, message, file: file, line: line)
        XCTAssertEqual(actual.b, expected.b, accuracy: tolerance, message, file: file, line: line)
    }

    /// Die unbemalte Leinwand ist weiss, nicht durchsichtig — sie ist das
    /// Blatt Papier, auf dem die Collage entsteht.
    private let leereLeinwand = (r: 255, g: 255, b: 255)

    private func shapeLayer(
        name: String,
        hex: String,
        x: Double,
        y: Double,
        size: Double = 100,
        isVisible: Bool = true,
        opacity: Double = 1
    ) -> Layer {
        Layer(
            name: name,
            isVisible: isVisible,
            opacity: opacity,
            transform: Transform2D(x: x, y: y),
            content: .shape(
                ShapeLayerContent(
                    kind: .rectangle,
                    size: Size(width: size, height: size),
                    fillColorHex: hex
                )
            )
        )
    }

    // MARK: - Koordinatensystem

    /// Der entscheidende Test für Phase 0: Eine Ebene bei y = 100 muss **oben**
    /// landen, nicht unten. Ohne `isGeometryFlipped` auf der Leinwand-Schicht
    /// stünde die ganze Collage auf dem Kopf — und zwar spiegelverkehrt zur
    /// Ebenenliste, was beim Bauen einer Collage sofort unbrauchbar wäre.
    func testLayerAtSmallYIsRenderedNearTheTop() throws {
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 400, height: 400),
            layers: [shapeLayer(name: "Oben", hex: "#FF0000", x: 200, y: 60)]
        )

        let context = try render(document)

        assertRoughly(try color(of: context, atCanvasX: 200, y: 60), (255, 0, 0), "y=60 muss oben liegen")
        assertRoughly(try color(of: context, atCanvasX: 200, y: 340), leereLeinwand, "unten muss leer bleiben")
    }

    /// `Transform2D.x/y` bezeichnet den Mittelpunkt, nicht die obere linke Ecke.
    func testTransformPositionIsTheLayerCentre() throws {
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 400, height: 400),
            layers: [shapeLayer(name: "Mitte", hex: "#00FF00", x: 200, y: 200, size: 100)]
        )

        let context = try render(document)

        // Die Form reicht von 150 bis 250 in beiden Richtungen.
        assertRoughly(try color(of: context, atCanvasX: 200, y: 155), (0, 255, 0), "obere Kante")
        assertRoughly(try color(of: context, atCanvasX: 200, y: 245), (0, 255, 0), "untere Kante")
        assertRoughly(try color(of: context, atCanvasX: 200, y: 140), leereLeinwand, "knapp darüber ist leer")
    }

    // MARK: - Skalierung

    /// Skalierung muss für *alle* Ebenentypen wirken, nicht nur für Bilder.
    ///
    /// Anlass: Der Pfad einer `CAShapeLayer` skaliert nicht mit ihren
    /// `bounds` — eine Hintergrundfläche mit Skalierung 2,7 blieb dadurch in
    /// Originalgrösse und liess die Leinwand halb leer. Bei Text wäre es
    /// genauso: `CATextLayer` setzt in `fontSize`, nicht auf Bounds-Grösse.
    func testScaledShapeCoversTheScaledArea() throws {
        // 100×100 bei doppelter Skalierung um (200,200) → belegt 100…300.
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 400, height: 400),
            layers: [
                Layer(
                    name: "Gross",
                    transform: Transform2D(x: 200, y: 200, scaleX: 2, scaleY: 2),
                    content: .shape(
                        ShapeLayerContent(
                            kind: .rectangle,
                            size: Size(width: 100, height: 100),
                            fillColorHex: "#FF0000"
                        )
                    )
                )
            ]
        )

        let context = try render(document)

        assertRoughly(try color(of: context, atCanvasX: 200, y: 110), (255, 0, 0), "obere Kante bei y=100")
        assertRoughly(try color(of: context, atCanvasX: 110, y: 200), (255, 0, 0), "linke Kante bei x=100")
        assertRoughly(try color(of: context, atCanvasX: 200, y: 290), (255, 0, 0), "untere Kante bei y=300")
        assertRoughly(try color(of: context, atCanvasX: 200, y: 80), leereLeinwand, "darüber bleibt leer")
    }

    /// Eine Textebene muss ebenfalls mitwachsen.
    func testScaledTextCoversMoreThanUnscaledText() throws {
        func breiteDerSchrift(scale: Double) throws -> Int {
            let document = AssemblageModel.Document(
                canvas: CanvasSize(width: 400, height: 400),
                layers: [
                    Layer(
                        name: "T",
                        transform: Transform2D(x: 200, y: 200, scaleX: scale, scaleY: scale),
                        content: .text(
                            TextLayerContent(string: "MMM", fontSize: 40, colorHex: "#000000")
                        )
                    )
                ]
            )
            let context = try render(document)
            // Bemalte Spalten auf der Mittelzeile zählen.
            return try (0..<400).filter { x in
                try color(of: context, atCanvasX: x, y: 200) != leereLeinwand
            }.count
        }

        let einfach = try breiteDerSchrift(scale: 1)
        let doppelt = try breiteDerSchrift(scale: 2)

        XCTAssertGreaterThan(einfach, 0, "der Text muss überhaupt erscheinen")
        XCTAssertGreaterThan(doppelt, einfach * 3 / 2, "doppelt skaliert muss deutlich breiter sein")
    }

    /// Spiegeln (negative Skalierung, Plan 5.5) muss das Bild kippen, nicht
    /// die Ebene verschwinden lassen.
    func testMirroredLayerIsStillDrawnInPlace() throws {
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 400, height: 400),
            layers: [
                Layer(
                    name: "Gespiegelt",
                    transform: Transform2D(x: 200, y: 200, scaleX: -2, scaleY: 2),
                    content: .shape(
                        ShapeLayerContent(
                            kind: .rectangle,
                            size: Size(width: 100, height: 100),
                            fillColorHex: "#0000FF"
                        )
                    )
                )
            ]
        )

        let context = try render(document)

        assertRoughly(try color(of: context, atCanvasX: 200, y: 200), (0, 0, 255), "die Ebene bleibt sichtbar")
        assertRoughly(try color(of: context, atCanvasX: 110, y: 200), (0, 0, 255), "und behält ihre Ausdehnung")
    }

    // MARK: - Ebenenreihenfolge & Sichtbarkeit

    /// Index 0 liegt zuunterst — die spätere Ebene muss die frühere verdecken.
    func testLaterLayersCoverEarlierOnes() throws {
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 400, height: 400),
            layers: [
                shapeLayer(name: "Unten", hex: "#FF0000", x: 200, y: 200, size: 200),
                shapeLayer(name: "Oben", hex: "#0000FF", x: 200, y: 200, size: 100)
            ]
        )

        let context = try render(document)

        assertRoughly(try color(of: context, atCanvasX: 200, y: 200), (0, 0, 255), "die obere Ebene gewinnt")
        assertRoughly(try color(of: context, atCanvasX: 200, y: 130), (255, 0, 0), "daneben bleibt die untere sichtbar")
    }

    func testHiddenLayersAreNotRendered() throws {
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 400, height: 400),
            layers: [shapeLayer(name: "Versteckt", hex: "#FF0000", x: 200, y: 200, isVisible: false)]
        )

        let context = try render(document)

        assertRoughly(try color(of: context, atCanvasX: 200, y: 200), leereLeinwand, "ausgeblendet heisst unsichtbar")
    }

    /// Halbe Deckkraft muss die Leinwand darunter zur Hälfte durchscheinen
    /// lassen: Schwarz auf Weiss ergibt Grau.
    func testOpacityIsApplied() throws {
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 400, height: 400),
            layers: [shapeLayer(name: "Halb", hex: "#000000", x: 200, y: 200, opacity: 0.5)]
        )

        let context = try render(document)

        assertRoughly(try color(of: context, atCanvasX: 200, y: 200), (128, 128, 128), "50 % Deckkraft")
    }

    // MARK: - Bilder

    /// Ein Foto darf nicht vertikal gespiegelt ankommen — der klassische
    /// Fehler bei `isGeometryFlipped`, weil dessen Wirkung auf `contents`
    /// leicht mit der auf die Unterschichten verwechselt wird.
    func testImageIsNotFlippedVertically() throws {
        // Testbild: obere Hälfte rot, untere Hälfte blau.
        let width = 100, height = 100
        let imageContext = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // CGContext zeichnet von unten links.
        imageContext.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        imageContext.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        imageContext.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        imageContext.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))

        let png = try XCTUnwrap(
            NSBitmapImageRep(cgImage: try XCTUnwrap(imageContext.makeImage()))
                .representation(using: .png, properties: [:])
        )

        let resources = DocumentResources()
        let reference = resources.addOriginal(png, fileExtension: "png")

        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 200, height: 200),
            layers: [
                Layer(
                    name: "Foto",
                    transform: Transform2D(x: 100, y: 100),
                    content: .image(ImageLayerContent(originalFileReference: reference))
                )
            ]
        )

        let context = try render(document, resources: resources)

        assertRoughly(try color(of: context, atCanvasX: 100, y: 75), (255, 0, 0), "obere Bildhälfte ist rot")
        assertRoughly(try color(of: context, atCanvasX: 100, y: 125), (0, 0, 255), "untere Bildhälfte ist blau")
    }

    /// Fehlt das Original, muss ein sichtbarer Platzhalter erscheinen statt
    /// eines Absturzes oder einer unauffindbaren leeren Ebene (Plan 2.1).
    func testMissingImageRendersPlaceholderInsteadOfCrashing() throws {
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 400, height: 400),
            layers: [
                Layer(
                    name: "Kaputt",
                    transform: Transform2D(x: 200, y: 200),
                    content: .image(ImageLayerContent(originalFileReference: "originals/gibtsnicht.png"))
                )
            ]
        )

        let context = try render(document)
        let centre = try color(of: context, atCanvasX: 200, y: 200)

        XCTAssertNotEqual(
            centre.r + centre.g + centre.b,
            leereLeinwand.r + leereLeinwand.g + leereLeinwand.b,
            "der Platzhalter muss sich von der leeren Leinwand abheben"
        )
    }
}
