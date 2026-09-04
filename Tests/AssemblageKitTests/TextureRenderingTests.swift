import XCTest
import CoreGraphics
import AppKit
import AssemblageModel
@testable import AssemblageKit

/// Kachelung von Texturen.
///
/// Die beiden interessanten Fragen sind hier nicht „kommt ein Bild heraus",
/// sondern: Wiederholt sich das Muster tatsächlich, und liegt es richtig
/// herum? Beides sind Fehler, die man auf einem gleichmässigen Korn nie
/// bemerkt und auf einem gerichteten Muster sofort. Die Tests arbeiten deshalb
/// mit absichtlich unsymmetrischen Vorlagen.
final class TextureRenderingTests: XCTestCase {

    // MARK: - Helfer

    /// Zeichnet in Core-Graphics-Koordinaten: Ursprung unten links.
    private func makeImage(width: Int, height: Int, draw: (CGContext) -> Void) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        draw(context)
        return try XCTUnwrap(context.makeImage())
    }

    /// Legt das Bild als PNG im Paket ab und liefert Ressourcen samt Referenz.
    private func resources(with image: CGImage) throws -> (DocumentResources, String) {
        let rep = NSBitmapImageRep(cgImage: image)
        let daten = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let ressourcen = DocumentResources()
        return (ressourcen, ressourcen.addOriginal(daten, fileExtension: "png"))
    }

    /// Liest ein Pixel in **Ansichts**koordinaten: (0,0) ist oben links.
    private func pixel(of image: CGImage, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let breite = image.width
        let hoehe = image.height
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: breite,
            height: hoehe,
            bitsPerComponent: 8,
            bytesPerRow: breite * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(breite), height: CGFloat(hoehe)))
        let zeiger = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        // Zeile 0 des Puffers ist die **oberste** Bildzeile: `draw` legt ein
        // CGImage in einem ungeflippten Kontext so ab.
        let offset = (y * breite + x) * 4
        return (zeiger[offset], zeiger[offset + 1], zeiger[offset + 2], zeiger[offset + 3])
    }

    private func texture(_ reference: String, scale: Double = 1) -> LayerTexture {
        LayerTexture(imageReference: reference, blendMode: .normal, opacity: 1, scale: scale)
    }

    // MARK: - Kachelgrösse

    func testTileSizeFollowsScale() throws {
        let bild = try makeImage(width: 10, height: 20) { _ in }
        XCTAssertEqual(TextureRendering.tileSize(of: bild, scale: 2), CGSize(width: 20, height: 40))
        XCTAssertEqual(TextureRendering.tileSize(of: bild, scale: 0.5), CGSize(width: 5, height: 10))
    }

    /// Eine Kachel der Grösse null würde die Kachelschleife nie beenden.
    func testTileSizeNeverCollapsesToZero() throws {
        let bild = try makeImage(width: 10, height: 10) { _ in }
        let winzig = TextureRendering.tileSize(of: bild, scale: 0.000_01)
        XCTAssertEqual(winzig.width, 1)
        XCTAssertEqual(winzig.height, 1)
    }

    // MARK: - Grösse und Fehlerfälle

    func testEmptySizeYieldsNoImage() throws {
        let bild = try makeImage(width: 4, height: 4) { _ in }
        let (ressourcen, referenz) = try resources(with: bild)

        XCTAssertNil(TextureRendering.tiledImage(
            for: texture(referenz), size: CGSize(width: 0, height: 10), resources: ressourcen))
        XCTAssertNil(TextureRendering.tiledImage(
            for: texture(referenz), size: CGSize(width: 10, height: -3), resources: ressourcen))
    }

    func testNonFiniteSizeYieldsNoImageInsteadOfTrappingDuringIntegerConversion() throws {
        let bild = try makeImage(width: 4, height: 4) { _ in }
        let (ressourcen, referenz) = try resources(with: bild)

        XCTAssertNil(TextureRendering.tiledImage(
            for: texture(referenz),
            size: CGSize(width: CGFloat.infinity, height: 10),
            resources: ressourcen
        ))
    }

    func testMissingFileYieldsNoImage() {
        XCTAssertNil(TextureRendering.tiledImage(
            for: texture("originals/gibtsnicht.png"),
            size: CGSize(width: 10, height: 10),
            resources: DocumentResources()
        ))
    }

    func testResultHasRequestedSize() throws {
        let bild = try makeImage(width: 8, height: 8) { _ in }
        let (ressourcen, referenz) = try resources(with: bild)

        let ergebnis = try XCTUnwrap(TextureRendering.tiledImage(
            for: texture(referenz), size: CGSize(width: 35, height: 42), resources: ressourcen))

        XCTAssertEqual(ergebnis.width, 35)
        XCTAssertEqual(ergebnis.height, 42)
    }

    // MARK: - Das Muster wiederholt sich

    func testPatternRepeats() throws {
        // 2×2, nur die Ecke oben links rot. In CG-Koordinaten liegt „oben"
        // bei y = 1.
        let bild = try makeImage(width: 2, height: 2) { context in
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 1, width: 1, height: 1))
        }
        let (ressourcen, referenz) = try resources(with: bild)

        let gekachelt = try XCTUnwrap(TextureRendering.tiledImage(
            for: texture(referenz), size: CGSize(width: 4, height: 4), resources: ressourcen))

        // Vier Kacheln, jede mit ihrem roten Punkt oben links.
        for (x, y) in [(0, 0), (2, 0), (0, 2), (2, 2)] {
            let punkt = try pixel(of: gekachelt, x: x, y: y)
            XCTAssertEqual(punkt.r, 255, "Kachelecke (\(x),\(y)) müsste rot sein")
            XCTAssertEqual(punkt.a, 255, "Kachelecke (\(x),\(y)) müsste deckend sein")
        }

        // Gegenprobe: Die übrigen Stellen der Kachel bleiben durchsichtig.
        // Ohne sie würde auch eine vollflächig rote Textur den Test bestehen.
        for (x, y) in [(1, 0), (0, 1), (1, 1), (3, 3)] {
            XCTAssertEqual(try pixel(of: gekachelt, x: x, y: y).a, 0,
                           "Stelle (\(x),\(y)) müsste durchsichtig sein")
        }
    }

    /// Der Massstab verkleinert die Kacheln, statt die Textur zu stauchen.
    func testScaleChangesTileCountNotStretch() throws {
        let bild = try makeImage(width: 4, height: 4) { context in
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 3, width: 1, height: 1))
        }
        let (ressourcen, referenz) = try resources(with: bild)

        // Massstab 0.5 halbiert die Kachel auf 2×2 — auf 4×4 also vier Kacheln
        // statt einer, und damit rote Punkte auch bei (2,0) und (0,2).
        let gekachelt = try XCTUnwrap(TextureRendering.tiledImage(
            for: texture(referenz, scale: 0.5), size: CGSize(width: 4, height: 4), resources: ressourcen))

        // Nicht auf volles Rot prüfen: Beim Verkleinern mischt Core Graphics
        // den roten Punkt mit seiner durchsichtigen Umgebung. Entscheidend ist,
        // dass an diesen Stellen überhaupt Rot auftaucht — also dass die Kachel
        // sich wiederholt hat.
        for (x, y) in [(0, 0), (2, 0), (0, 2)] {
            let punkt = try pixel(of: gekachelt, x: x, y: y)
            XCTAssertGreaterThan(punkt.r, punkt.g, "Kachelecke (\(x),\(y)) müsste rötlich sein")
            XCTAssertGreaterThan(punkt.r, punkt.b, "Kachelecke (\(x),\(y)) müsste rötlich sein")
        }

        // Gegenprobe: In der Mitte einer Kachel bleibt es durchsichtig — sonst
        // wäre die Textur bloss auf die ganze Fläche gestreckt worden.
        XCTAssertEqual(try pixel(of: gekachelt, x: 1, y: 1).a, 0)
    }

    // MARK: - Ausrichtung

    /// Die Textur darf nicht auf dem Kopf stehen. Auf einem gleichmässigen Korn
    /// fiele das nie auf, auf einer Papierkante sofort.
    func testTextureIsNotFlippedVertically() throws {
        let bild = try makeImage(width: 2, height: 2) { context in
            // In CG-Koordinaten ist y = 1 die obere Zeile.
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 1, width: 2, height: 1))
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
        }
        let (ressourcen, referenz) = try resources(with: bild)

        let gekachelt = try XCTUnwrap(TextureRendering.tiledImage(
            for: texture(referenz), size: CGSize(width: 2, height: 2), resources: ressourcen))

        let oben = try pixel(of: gekachelt, x: 0, y: 0)
        let unten = try pixel(of: gekachelt, x: 0, y: 1)
        XCTAssertEqual(oben.r, 255, "oben müsste rot sein")
        XCTAssertEqual(oben.b, 0)
        XCTAssertEqual(unten.b, 255, "unten müsste blau sein")
        XCTAssertEqual(unten.r, 0)
    }

    // MARK: - Notbremse

    /// Eine winzige Textur auf einer grossen Fläche darf nicht Millionen
    /// Zeichenbefehle auslösen.
    func testAbsurdTileCountFallsBackToStretching() throws {
        let bild = try makeImage(width: 1, height: 1) { context in
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let (ressourcen, referenz) = try resources(with: bild)

        // 400 × 400 = 160 000 Kacheln, über der Grenze.
        let ergebnis = try XCTUnwrap(TextureRendering.tiledImage(
            for: texture(referenz, scale: 1), size: CGSize(width: 400, height: 400), resources: ressourcen))

        XCTAssertEqual(ergebnis.width, 400)
        // Gestreckt oder gekachelt: Das Ergebnis ist bei einer einfarbigen
        // Vorlage dasselbe — geprüft wird, dass es überhaupt zurückkommt und
        // der Aufruf nicht hängenbleibt.
        XCTAssertEqual(try pixel(of: ergebnis, x: 200, y: 200).r, 255)
    }
}
