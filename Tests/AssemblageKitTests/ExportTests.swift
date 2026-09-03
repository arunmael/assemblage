import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Prüft den Export (Plan 5.8: PNG mit Transparenz, JPEG) — im Stil von
/// `CanvasRenderingTests`: Pixelfarben lesen statt Screenshots vergleichen,
/// damit die Prüfung bei jedem `swift test` mitläuft.
@MainActor
final class ExportTests: XCTestCase {

    // MARK: - Hilfsmittel

    private func rgbaContext(from image: CGImage) throws -> CGContext {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context
    }

    /// Liest eine Farbe in **Bild**koordinaten (Ursprung oben links), damit
    /// Testfälle so gelesen werden können, wie das Modell denkt.
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
        tolerance: Int = 12,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.r, expected.r, accuracy: tolerance, message + " (r)", file: file, line: line)
        XCTAssertEqual(actual.g, expected.g, accuracy: tolerance, message + " (g)", file: file, line: line)
        XCTAssertEqual(actual.b, expected.b, accuracy: tolerance, message + " (b)", file: file, line: line)
        XCTAssertEqual(actual.a, expected.a, accuracy: tolerance, message + " (a)", file: file, line: line)
    }

    private func rectangleLayer(
        name: String = "Form",
        hex: String,
        x: Double,
        y: Double,
        size: Double = 100,
        opacity: Double = 1,
        blendMode: BlendMode = .normal,
        transform: Transform2D? = nil
    ) -> Layer {
        Layer(
            name: name,
            opacity: opacity,
            blendMode: blendMode,
            transform: transform ?? Transform2D(x: x, y: y),
            content: .shape(ShapeLayerContent(kind: .rectangle, size: Size(width: size, height: size), fillColorHex: hex))
        )
    }

    private func makeTestImage(reference resources: DocumentResources, topColor: (CGFloat, CGFloat, CGFloat), bottomColor: (CGFloat, CGFloat, CGFloat), width: Int = 100, height: Int = 100) throws -> String {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // CGContext zeichnet von unten links — untere Hälfte zuerst.
        context.setFillColor(CGColor(srgbRed: bottomColor.0, green: bottomColor.1, blue: bottomColor.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(CGColor(srgbRed: topColor.0, green: topColor.1, blue: topColor.2, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))

        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
        return resources.addOriginal(png, fileExtension: "png")
    }

    // MARK: - Zielgrösse

    func testExportHonoursArbitraryTargetSize() async throws {
        let document = AssemblageModel.Document(canvas: CanvasSize(width: 400, height: 400), layers: [])
        let image = try await DocumentExporter.image(of: document, resources: DocumentResources(), targetSize: CGSize(width: 777, height: 321))
        XCTAssertEqual(image.width, 777)
        XCTAssertEqual(image.height, 321)
    }

    func testExportScaleFactorHelperMultipliesCanvasSize() {
        let canvas = CanvasSize(width: 1080, height: 1080)
        let size = DocumentExporter.targetSize(forCanvas: canvas, scale: 2)
        XCTAssertEqual(size, CGSize(width: 2160, height: 2160))
    }

    // MARK: - Leeres Dokument

    /// Ein Dokument ohne Ebenen darf den Export nicht scheitern lassen —
    /// es ergibt schlicht ein leeres (durchsichtiges) Bild.
    func testEmptyDocumentProducesTransparentImageInsteadOfError() async throws {
        let document = AssemblageModel.Document(canvas: CanvasSize(width: 100, height: 100), layers: [])
        let image = try await DocumentExporter.image(of: document, resources: DocumentResources(), targetSize: CGSize(width: 100, height: 100))
        let context = try rgbaContext(from: image)
        assertRoughly(try pixel(of: context, x: 50, y: 50), (0, 0, 0, 0), "kein Inhalt heisst durchsichtig, nicht weiss")
    }

    // MARK: - Transparenz PNG vs. weisser Grund JPEG

    func testPNGBackgroundIsTransparentWhereUnpainted() async throws {
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 200, height: 200),
            layers: [rectangleLayer(hex: "#FF0000", x: 100, y: 100, size: 40)]
        )
        let data = try await DocumentExporter.pngData(of: document, resources: DocumentResources(), targetSize: CGSize(width: 200, height: 200))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        let image = try XCTUnwrap(rep.cgImage)
        let context = try rgbaContext(from: image)

        assertRoughly(try pixel(of: context, x: 10, y: 10), (0, 0, 0, 0), "PNG: unbemalte Fläche ist durchsichtig")
    }

    func testJPEGBackgroundIsWhiteWhereUnpainted() async throws {
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 200, height: 200),
            layers: [rectangleLayer(hex: "#FF0000", x: 100, y: 100, size: 40)]
        )
        let data = try await DocumentExporter.jpegData(of: document, resources: DocumentResources(), targetSize: CGSize(width: 200, height: 200))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        let image = try XCTUnwrap(rep.cgImage)
        let context = try rgbaContext(from: image)

        assertRoughly(try pixel(of: context, x: 10, y: 10), (255, 255, 255, 255), "JPEG: unbemalte Fläche ist weiss, nicht durchsichtig")
    }

    // MARK: - Deckkraft

    func testOpacityIsAppliedAsAlphaOnTransparentPNG() async throws {
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 200, height: 200),
            layers: [rectangleLayer(hex: "#000000", x: 100, y: 100, opacity: 0.5)]
        )
        let image = try await DocumentExporter.image(of: document, resources: DocumentResources(), targetSize: CGSize(width: 200, height: 200))
        let context = try rgbaContext(from: image)

        assertRoughly(try pixel(of: context, x: 100, y: 100), (0, 0, 0, 128), "50% Deckkraft ohne Hintergrund ergibt halbdurchsichtiges Schwarz")
    }

    // MARK: - Ebenenreihenfolge & Sichtbarkeit (Grundfälle liegen in PipelineIntegrationTests)

    // MARK: - Zuschnitt

    func testCropRectShowsOnlyTheCroppedPortion() async throws {
        let resources = DocumentResources()
        let reference = try makeTestImage(reference: resources, topColor: (1, 0, 0), bottomColor: (0, 0, 1), width: 100, height: 100)

        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 200, height: 200),
            layers: [
                Layer(
                    name: "Zugeschnitten",
                    transform: Transform2D(x: 100, y: 100),
                    content: .image(ImageLayerContent(
                        originalFileReference: reference,
                        // Nur die obere (rote) Hälfte des Originals.
                        cropRect: Rect(x: 0, y: 0, width: 100, height: 50)
                    ))
                )
            ]
        )

        let image = try await DocumentExporter.image(of: document, resources: resources, targetSize: CGSize(width: 200, height: 200))
        let context = try rgbaContext(from: image)

        // Die Ebene ist jetzt 100×50 gross, zentriert bei (100,100): 50…150 × 75…125.
        assertRoughly(try pixel(of: context, x: 100, y: 100), (255, 0, 0, 255), "der Zuschnitt zeigt nur den roten Teil")
        assertRoughly(try pixel(of: context, x: 100, y: 60), (0, 0, 0, 0), "ausserhalb des Zuschnitts bleibt es leer")
    }

    // MARK: - Fehlende Originaldatei

    /// Plan 2.1: eine fehlende Originaldatei darf den Export nicht scheitern
    /// lassen.
    func testMissingOriginalDoesNotFailTheExport() async throws {
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 200, height: 200),
            layers: [
                Layer(
                    name: "Kaputt",
                    transform: Transform2D(x: 100, y: 100),
                    content: .image(ImageLayerContent(originalFileReference: "originals/existiert-nicht.png"))
                )
            ]
        )

        let image = try await DocumentExporter.image(of: document, resources: DocumentResources(), targetSize: CGSize(width: 200, height: 200))
        XCTAssertEqual(image.width, 200, "der Export darf trotz fehlendem Original nicht scheitern")
    }

    // MARK: - Drehung & Spiegelung

    /// Eine 90°-Drehung im Uhrzeigersinn muss „oben" nach „rechts" bringen —
    /// dieselbe Konvention wie beim Bildschirm-Canvas.
    func testRotationMovesTopToTheRight() async throws {
        let resources = DocumentResources()
        let reference = try makeTestImage(reference: resources, topColor: (1, 0, 0), bottomColor: (0, 0, 1))

        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 200, height: 200),
            layers: [
                Layer(
                    name: "Gedreht",
                    transform: Transform2D(x: 100, y: 100, rotationDegrees: 90),
                    content: .image(ImageLayerContent(originalFileReference: reference))
                )
            ]
        )

        let image = try await DocumentExporter.image(of: document, resources: resources, targetSize: CGSize(width: 200, height: 200))
        let context = try rgbaContext(from: image)

        assertRoughly(try pixel(of: context, x: 140, y: 100), (255, 0, 0, 255), "nach 90 Grad im Uhrzeigersinn liegt oben jetzt rechts")
        assertRoughly(try pixel(of: context, x: 60, y: 100), (0, 0, 255, 255), "und unten liegt jetzt links")
    }

    func testMirroredLayerFlipsHorizontally() async throws {
        let resources = DocumentResources()
        // Testbild: linke Hälfte rot, rechte Hälfte blau (per Rotation um 90° aus dem oben/unten-Bild simuliert reicht nicht — eigenes Bild bauen).
        let width = 100, height = 100
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
        let reference = resources.addOriginal(png, fileExtension: "png")

        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 200, height: 200),
            layers: [
                Layer(
                    name: "Gespiegelt",
                    transform: Transform2D(x: 100, y: 100, scaleX: -1, scaleY: 1),
                    content: .image(ImageLayerContent(originalFileReference: reference))
                )
            ]
        )

        let image = try await DocumentExporter.image(of: document, resources: resources, targetSize: CGSize(width: 200, height: 200))
        let readContext = try rgbaContext(from: image)

        assertRoughly(try pixel(of: readContext, x: 60, y: 100), (0, 0, 255, 255), "gespiegelt: links ist jetzt blau")
        assertRoughly(try pixel(of: readContext, x: 140, y: 100), (255, 0, 0, 255), "gespiegelt: rechts ist jetzt rot")
    }

    // MARK: - Blend-Modi

    /// Prüft alle sechs Blend-Modi gegen die Standardformel, statt gegen von
    /// Hand ausgerechnete Zahlen — so testet der Fall wirklich die
    /// `CGBlendMode`-Zuordnung und nicht nur eine Abschrift ihres Ergebnisses.
    func testAllSixBlendModesMatchTheStandardFormula() async throws {
        // Bewusst keine reinen Farben: bei 0/1 fallen mehrere Blend-Formeln
        // zusammen und würden einen falschen `CGBlendMode` nicht auffangen.
        let bottom = (r: 0.75, g: 0.30, b: 0.10)
        let top = (r: 0.20, g: 0.60, b: 0.85)

        for mode in [BlendMode.normal, .multiply, .screen, .overlay, .lighten, .darken] {
            let document = AssemblageModel.Document(
                canvas: CanvasSize(width: 100, height: 100),
                layers: [
                    rectangleLayer(name: "Unten", hex: RGBA(red: bottom.r, green: bottom.g, blue: bottom.b).hexString, x: 50, y: 50, size: 100),
                    rectangleLayer(name: "Oben", hex: RGBA(red: top.r, green: top.g, blue: top.b).hexString, x: 50, y: 50, size: 100, blendMode: mode)
                ]
            )

            let image = try await DocumentExporter.image(of: document, resources: DocumentResources(), targetSize: CGSize(width: 100, height: 100))
            let context = try rgbaContext(from: image)
            let actual = try pixel(of: context, x: 50, y: 50)

            let expected = standardBlend(mode, top: top, bottom: bottom)
            assertRoughly(
                (actual.r, actual.g, actual.b, actual.a),
                (expected.r, expected.g, expected.b, 255),
                "Blend-Modus \(mode) muss der Standardformel entsprechen",
                tolerance: 6
            )
        }
    }

    /// Referenzformeln für separierbare Blend-Modi (opake Ebenen, ohne
    /// zusätzliche Deckkraft) — dieselben, die Core Graphics für
    /// `CGBlendMode` verwendet.
    private func standardBlend(_ mode: BlendMode, top: (r: Double, g: Double, b: Double), bottom: (r: Double, g: Double, b: Double)) -> (r: Int, g: Int, b: Int) {
        func channel(_ t: Double, _ b: Double) -> Double {
            switch mode {
            case .normal: return t
            case .multiply: return t * b
            case .screen: return 1 - (1 - t) * (1 - b)
            case .darken: return min(t, b)
            case .lighten: return max(t, b)
            case .overlay: return b < 0.5 ? 2 * t * b : 1 - 2 * (1 - t) * (1 - b)
            }
        }
        func byte(_ value: Double) -> Int { Int((value.clamped(to: 0...1) * 255).rounded()) }
        return (byte(channel(top.r, bottom.r)), byte(channel(top.g, bottom.g)), byte(channel(top.b, bottom.b)))
    }

    // MARK: - Übereinstimmung mit dem Bildschirm-Canvas

    /// Der wichtigste Test: Export und Bildschirm-Canvas dürfen nicht
    /// auseinanderlaufen — geprüft an einem Blend-Modus und einer gedrehten
    /// Ebene, mit grosszügiger Toleranz, weil es zwei unabhängige
    /// Rendering-Pfade sind (Core Animation vs. direktes `CGContext`-Zeichnen).
    func testExportMatchesOnScreenCanvasForBlendModeAndRotation() async throws {
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 300, height: 300),
            layers: [
                rectangleLayer(name: "Unten", hex: "#C04820", x: 150, y: 150, size: 300),
                Layer(
                    name: "Gedreht & multipliziert",
                    blendMode: .multiply,
                    transform: Transform2D(x: 150, y: 150, rotationDegrees: 30),
                    content: .shape(ShapeLayerContent(kind: .rectangle, size: Size(width: 120, height: 60), fillColorHex: "#3080C0"))
                )
            ]
        )
        let resources = DocumentResources()

        // Weg 1: Bildschirm-Canvas (Core Animation).
        let canvasView = CanvasView(document: document, images: ImageStore(resources: resources))
        canvasView.layoutSubtreeIfNeeded()
        canvasView.layer?.layoutIfNeeded()
        let canvasContext = try XCTUnwrap(CGContext(
            data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Weisser Grund, exakt wie `canvasLayer.backgroundColor` — sonst
        // vergleicht der Test Transparenz gegen Weiss statt Pfad gegen Pfad.
        canvasContext.setFillColor(NSColor.white.cgColor)
        canvasContext.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        let canvasLayer = try XCTUnwrap(canvasView.layer?.sublayers?.first)
        canvasLayer.render(in: canvasContext)

        // Weg 2: Export, auf denselben weissen Grund gezeichnet.
        let exportedImage = try await DocumentExporter.image(of: document, resources: resources, targetSize: CGSize(width: 300, height: 300))
        let exportContext = try XCTUnwrap(CGContext(
            data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        exportContext.setFillColor(NSColor.white.cgColor)
        exportContext.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        exportContext.draw(exportedImage, in: CGRect(x: 0, y: 0, width: 300, height: 300))

        for (x, y) in [(150, 150), (110, 130), (190, 170), (30, 30)] {
            let fromCanvas = try pixel(of: canvasContext, x: x, y: y)
            let fromExport = try pixel(of: exportContext, x: x, y: y)
            assertRoughly(
                fromCanvas, fromExport,
                "Export und Canvas müssen bei (\(x),\(y)) übereinstimmen",
                tolerance: 40
            )
        }
    }
}
