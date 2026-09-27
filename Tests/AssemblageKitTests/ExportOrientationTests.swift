import XCTest
import AppKit
import ImageIO
@testable import AssemblageKit
@testable import AssemblageModel

/// Der Export muss aufrecht stehen — für jeden Zeichenweg.
///
/// Anlass: Fotos standen im Export auf dem Kopf. `drawImage` spiegelte sie in
/// der falschen Annahme, Core Graphics zeichne ein `CGImage` verkehrt; die
/// Wege über Schatten/Leuchten und Verzerrung spiegelten dann alles noch
/// einmal, womit dort Fotos richtig, Formen und Masken aber falsch standen.
/// Die Tests bestätigten das, weil sie Exportbilder mit `height - 1 - y`
/// auslasen — eine Umrechnung, die nur für `CALayer.render(in:)` stimmt.
///
/// Geprüft wird darum gegen die Leinwand als Wahrheit, mit der jeweils
/// richtigen Auslesung: Pufferzeile 0 ist beim Exportbild die oberste Zeile,
/// beim Leinwandbild aus `render(in:)` die unterste (nachgemessen: ein
/// Dreieck mit Spitze oben kommt dort mit der Spitze unten im Puffer an).
@MainActor
final class ExportOrientationTests: XCTestCase {

    // MARK: - Hilfsmittel

    private func png(width: Int = 200, height: Int = 100, orientation: Int? = nil, _ zeichne: (CGContext) -> Void) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        zeichne(context)
        let data = NSMutableData()
        let ziel = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        var eigenschaften: [CFString: Any] = [:]
        if let orientation { eigenschaften[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(ziel, try XCTUnwrap(context.makeImage()), eigenschaften as CFDictionary)
        CGImageDestinationFinalize(ziel)
        return data as Data
    }

    /// Obere Hälfte rot, untere blau (in Core Graphics liegt y = 50…100 oben).
    private func rotOben(_ context: CGContext) {
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height / 2))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: context.height / 2, width: context.width, height: context.height / 2))
    }

    /// Maske: oben weiss (sichtbar), unten schwarz (ausgeblendet).
    private func weissOben(_ context: CGContext) {
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 50))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 50, width: 200, height: 50))
    }

    /// Farbe an einer Stelle in Modellkoordinaten (y von oben) — R, B oder W.
    private func farbe(_ image: CGImage, x: Double, y: Double, ausLeinwand: Bool) throws -> Character {
        let w = image.width, h = image.height
        let context = try XCTUnwrap(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let zeile = ausLeinwand ? h - 1 - Int(y * Double(h)) : Int(y * Double(h))
        let p = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            .advanced(by: zeile * w * 4 + Int(x * Double(w)) * 4)
        let (r, g, b) = (Int(p[0]), Int(p[1]), Int(p[2]))
        if r > 150, g < 110, b < 110 { return "R" }
        if b > 150, r < 110 { return "B" }
        if r > 200, g > 200, b > 200 { return "W" }
        return "?"
    }

    /// Mitte oben/unten und links oben/unten — genug, um Kopfstand und
    /// Spiegelung einer Dreiecksspitze zu erkennen.
    private func signatur(_ image: CGImage, ausLeinwand: Bool) throws -> String {
        var ergebnis = ""
        for (x, y) in [(0.5, 0.25), (0.5, 0.75), (0.2, 0.15), (0.2, 0.85)] {
            ergebnis.append(try farbe(image, x: x, y: y, ausLeinwand: ausLeinwand))
        }
        return ergebnis
    }

    private func leinwand(_ document: AssemblageModel.Document, _ resources: DocumentResources) throws -> CGImage {
        let view = CanvasView(document: document, images: ImageStore(resources: resources))
        view.layer?.layoutIfNeeded()
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        try XCTUnwrap(view.layer?.sublayers?.first).render(in: context)
        return try XCTUnwrap(context.makeImage())
    }

    // MARK: - Tests

    func testEveryDrawingPathMatchesTheCanvas() throws {
        let resources = DocumentResources()
        let foto = resources.addOriginal(try png(rotOben), fileExtension: "png")
        let exif180 = resources.addOriginal(try png(orientation: 3, rotOben), fileExtension: "png")
        let maske = resources.addMask(try png(weissOben))

        func bild(_ referenz: String) -> Layer {
            Layer(name: "Foto", transform: Transform2D(x: 100, y: 50),
                  content: .image(ImageLayerContent(originalFileReference: referenz)))
        }
        func dreieck() -> Layer {
            Layer(name: "Dreieck", transform: Transform2D(x: 100, y: 50),
                  content: .shape(ShapeLayerContent(kind: .triangle, size: Size(width: 200, height: 100), fillColorHex: "#FF0000")))
        }
        let schatten = LayerEffects(shadow: Shadow(offsetX: 1, offsetY: 1, radius: 1, opacity: 0.2))
        let ecke = QuadDistortion(topLeft: Point(x: 1, y: 0))
        let kruemmung = QuadDistortion(topMid: Point(x: 0, y: -1))

        var varianten: [(String, Layer, String)] = []
        // (Name, Ebene, erwartete Signatur im Export)
        varianten.append(("Foto", bild(foto), "RBRB"))
        varianten.append(("Foto mit EXIF-Drehung", bild(exif180), "BRBR"))
        var ebene = bild(foto); ebene.mask = LayerMask(maskImageReference: maske, source: .manualBrush)
        varianten.append(("Foto mit Maske", ebene, "RWRW"))
        ebene.effects = schatten
        varianten.append(("Foto mit Maske und Schatten", ebene, "RWRW"))
        ebene = bild(foto); ebene.effects = schatten
        varianten.append(("Foto mit Schatten", ebene, "RBRB"))
        ebene = bild(foto); ebene.distortion = ecke
        varianten.append(("Foto verzerrt", ebene, "RBRB"))
        ebene.mask = LayerMask(maskImageReference: maske, source: .manualBrush)
        varianten.append(("Foto verzerrt mit Maske", ebene, "RWRW"))
        ebene = bild(foto); ebene.distortion = kruemmung
        varianten.append(("Foto gekrümmt", ebene, "RBRB"))
        varianten.append(("Dreieck", dreieck(), "RRWR"))
        ebene = dreieck(); ebene.effects = schatten
        varianten.append(("Dreieck mit Schatten", ebene, "RRWR"))
        ebene = dreieck(); ebene.distortion = ecke
        varianten.append(("Dreieck verzerrt", ebene, "RRWR"))
        ebene = dreieck(); ebene.distortion = kruemmung
        varianten.append(("Dreieck gekrümmt", ebene, "RRWR"))

        for (name, layer, erwartet) in varianten {
            let document = AssemblageModel.Document(canvas: CanvasSize(width: 200, height: 100), layers: [layer])
            let export = try DocumentExporter.renderedImage(
                of: document, resources: resources, targetSize: CGSize(width: 200, height: 100))
            XCTAssertEqual(try signatur(export, ausLeinwand: false), erwartet, "\(name): Export")
            XCTAssertEqual(try signatur(try leinwand(document, resources), ausLeinwand: true), erwartet, "\(name): Leinwand")
        }
    }

    /// Verkleinert dekodiert (Foto im Export kleiner als das Original) muss
    /// dasselbe Bild entstehen wie aus dem vollen Original — auch mit
    /// Zuschnitt, dessen Koordinaten dabei mitskaliert werden.
    func testDownsampledExportMatchesFullResolutionExport() throws {
        let resources = DocumentResources()
        let foto = resources.addOriginal(try png(width: 2000, height: 1000) { context in
            rotOben(context)
            // Ein grünes Feld rechts oben, damit ein falsch skalierter
            // Zuschnitt auffällt.
            context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
            context.fill(CGRect(x: 1500, y: 750, width: 500, height: 250))
        }, fileExtension: "png")
        var inhalt = ImageLayerContent(originalFileReference: foto)
        inhalt.cropRect = Rect(x: 1000, y: 0, width: 1000, height: 500)
        var ebene = Layer(name: "Foto", transform: Transform2D(x: 100, y: 50), content: .image(inhalt))
        ebene.transform.scaleX = 0.2
        ebene.transform.scaleY = 0.2
        let document = AssemblageModel.Document(canvas: CanvasSize(width: 200, height: 100), layers: [ebene])
        let groesse = CGSize(width: 200, height: 100)

        let verkleinert = try DocumentExporter.renderedImage(of: document, resources: resources, targetSize: groesse)
        let voll = try DocumentExporter.OutputResolution.$limitsImageDecoding.withValue(false) {
            try DocumentExporter.renderedImage(of: document, resources: resources, targetSize: groesse)
        }

        func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [Int] {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 200, height: 100))
            let p = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self).advanced(by: y * 800 + x * 4)
            return [Int(p[0]), Int(p[1]), Int(p[2])]
        }
        // Grün rechts oben, Rot links oben, Blau unten — in beiden gleich.
        for (x, y) in [(150, 25), (50, 25), (100, 75)] {
            let a = try pixel(verkleinert, x, y), b = try pixel(voll, x, y)
            for (u, v) in zip(a, b) {
                XCTAssertEqual(u, v, accuracy: 8, "Abweichung bei (\(x), \(y)): \(a) gegen \(b)")
            }
        }
        XCTAssertEqual(try pixel(verkleinert, 150, 25), [0, 255, 0], "rechts oben liegt das grüne Feld")
    }
}
