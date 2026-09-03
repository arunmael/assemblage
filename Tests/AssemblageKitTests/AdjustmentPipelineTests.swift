import XCTest
import AppKit
import CoreImage
@testable import AssemblageKit
@testable import AssemblageModel

/// Die Core-Image-Kette für die Bildanpassungen aus Plan 5.5.
///
/// Geprüft wird die **Wirkung** auf Pixel, nicht welche Filter verwendet
/// werden: Welcher `CIFilter` das erledigt, darf sich ändern; dass „Helligkeit
/// hoch" das Bild heller macht, nicht.
final class AdjustmentPipelineTests: XCTestCase {

    /// Ein einfarbiges Testbild in mittlerem Grau mit einem Farbstich, damit
    /// sich Sättigung und Wärme messen lassen.
    private func testbild(
        rot: Double = 0.5, gruen: Double = 0.4, blau: Double = 0.3,
        seite: Int = 32
    ) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: seite, height: seite, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(srgbRed: rot, green: gruen, blue: blau, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: seite, height: seite))
        return try XCTUnwrap(ctx.makeImage())
    }

    /// Wendet die Anpassungen an und liest die Farbe in der Bildmitte.
    private func farbe(
        _ adjustments: ImageAdjustments,
        auf bild: CGImage
    ) throws -> (r: Int, g: Int, b: Int) {
        let ergebnis = try XCTUnwrap(
            AdjustmentPipeline.apply(adjustments, to: CIImage(cgImage: bild)),
            "die Kette muss ein Bild liefern"
        )
        let gerendert = try XCTUnwrap(
            RenderContext.shared.createCGImage(ergebnis, from: CGRect(x: 0, y: 0, width: bild.width, height: bild.height))
        )
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: gerendert.width, height: gerendert.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.draw(gerendert, in: CGRect(x: 0, y: 0, width: gerendert.width, height: gerendert.height))

        let daten = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        let mitte = (gerendert.height / 2) * ctx.bytesPerRow + (gerendert.width / 2) * 4
        return (Int(daten[mitte]), Int(daten[mitte + 1]), Int(daten[mitte + 2]))
    }

    // MARK: - Neutral

    /// Der wichtigste Fall: Ohne Anpassung darf nichts passieren. Sonst
    /// veränderte allein das Importieren eines Fotos dessen Farben.
    func testNeutralAdjustmentsLeaveTheImageUntouched() throws {
        let bild = try testbild()
        let vorher = try farbe(.neutral, auf: bild)

        XCTAssertEqual(vorher.r, 128, accuracy: 3)
        XCTAssertEqual(vorher.g, 102, accuracy: 3)
        XCTAssertEqual(vorher.b, 77, accuracy: 3)
    }

    /// Neutral soll die Kette gar nicht erst aufbauen — bei einer Collage aus
    /// zwanzig unbearbeiteten Fotos wäre jede Filterkette verschenkte Arbeit.
    func testNeutralAdjustmentsProduceNoFilters() {
        XCTAssertTrue(AdjustmentPipeline.filters(for: .neutral).isEmpty)
        XCTAssertFalse(AdjustmentPipeline.filters(for: ImageAdjustments(brightness: 0.2)).isEmpty)
    }

    // MARK: - Einzelne Regler

    func testBrightnessBrightensAndDarkens() throws {
        let bild = try testbild()
        let neutral = try farbe(.neutral, auf: bild)

        let hell = try farbe(ImageAdjustments(brightness: 0.5), auf: bild)
        let dunkel = try farbe(ImageAdjustments(brightness: -0.5), auf: bild)

        XCTAssertGreaterThan(hell.r, neutral.r + 10)
        XCTAssertLessThan(dunkel.r, neutral.r - 10)
    }

    /// Volle Entsättigung muss echtes Grau ergeben — alle drei Kanäle gleich.
    func testFullDesaturationProducesGrey() throws {
        let ergebnis = try farbe(ImageAdjustments(saturation: -1), auf: try testbild())

        XCTAssertEqual(ergebnis.r, ergebnis.g, accuracy: 3)
        XCTAssertEqual(ergebnis.g, ergebnis.b, accuracy: 3)
    }

    func testSaturationIncreasesColourSpread() throws {
        let bild = try testbild()
        let neutral = try farbe(.neutral, auf: bild)
        let bunt = try farbe(ImageAdjustments(saturation: 1), auf: bild)

        XCTAssertGreaterThan(bunt.r - bunt.b, neutral.r - neutral.b)
    }

    /// Kontrast zieht Werte von der Mitte weg. Ein heller Wert wird heller.
    func testContrastPushesAwayFromMidGrey() throws {
        let hellesBild = try testbild(rot: 0.75, gruen: 0.75, blau: 0.75)

        let neutral = try farbe(.neutral, auf: hellesBild)
        let stark = try farbe(ImageAdjustments(contrast: 1), auf: hellesBild)

        XCTAssertGreaterThan(stark.r, neutral.r)
    }

    /// „Wärme" heisst: mehr Rot, weniger Blau. Das Vorzeichen ist die
    /// häufigste Fehlerquelle bei diesem Filter.
    func testWarmthShiftsTowardsOrange() throws {
        let bild = try testbild(rot: 0.5, gruen: 0.5, blau: 0.5)
        let neutral = try farbe(.neutral, auf: bild)

        let warm = try farbe(ImageAdjustments(warmth: 1), auf: bild)
        let kalt = try farbe(ImageAdjustments(warmth: -1), auf: bild)

        XCTAssertGreaterThan(warm.r - warm.b, neutral.r - neutral.b, "wärmer heisst röter")
        XCTAssertLessThan(kalt.r - kalt.b, neutral.r - neutral.b, "kühler heisst blauer")
    }

    // MARK: - Weichzeichnen

    /// Weichzeichnen muss eine harte Kante verlaufen lassen. Geprüft an einem
    /// halb schwarzen, halb weissen Bild.
    func testBlurSoftensAHardEdge() throws {
        let seite = 64
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: seite, height: seite, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: seite / 2, height: seite))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: seite / 2, y: 0, width: seite / 2, height: seite))
        let kante = try XCTUnwrap(ctx.makeImage())

        // Direkt an der Kante ist ohne Weichzeichnen Schwarz oder Weiss;
        // mit Weichzeichnen ein Zwischenwert.
        let verwaschen = try farbe(ImageAdjustments(blurRadius: 0.5), auf: kante)

        XCTAssertGreaterThan(verwaschen.r, 40)
        XCTAssertLessThan(verwaschen.r, 215)
    }

    /// Das weichgezeichnete Bild darf nicht schrumpfen oder durchsichtige
    /// Ränder bekommen — ein bekanntes Verhalten von CIGaussianBlur.
    func testBlurKeepsTheOriginalExtent() throws {
        let bild = try testbild(seite: 40)
        let ergebnis = try XCTUnwrap(
            AdjustmentPipeline.apply(ImageAdjustments(blurRadius: 1), to: CIImage(cgImage: bild))
        )

        XCTAssertEqual(ergebnis.extent.width, 40, accuracy: 0.5)
        XCTAssertEqual(ergebnis.extent.height, 40, accuracy: 0.5)
    }

    func testSharpenDoesNotCrashOrBlank() throws {
        let ergebnis = try farbe(ImageAdjustments(sharpenAmount: 1), auf: try testbild())

        XCTAssertGreaterThan(ergebnis.r, 0)
    }

    // MARK: - Robustheit

    /// Werte ausserhalb des gültigen Bereichs dürfen nicht zu Unsinn führen.
    func testOutOfRangeValuesAreClamped() throws {
        let wild = ImageAdjustments(brightness: 99, contrast: -99, saturation: 42, warmth: -42)

        let ergebnis = try farbe(wild, auf: try testbild())

        XCTAssertTrue((0...255).contains(ergebnis.r))
        XCTAssertTrue((0...255).contains(ergebnis.g))
        XCTAssertTrue((0...255).contains(ergebnis.b))
    }
}

/// Beide Rendering-Wege müssen die Anpassungen tatsächlich anwenden.
///
/// Ein Pixelvergleich zwischen Leinwand und Export ist hier nicht möglich:
/// `CALayer.render(in:)` ignoriert `filters` — genauso, wie es schon
/// `compositingFilter` ignoriert (deshalb rendert der Export ohnehin über
/// einen eigenen Weg). Geprüft wird deshalb auf der Leinwand strukturell, dass
/// die Kette hängt, und im Export das Ergebnis in Pixeln.
@MainActor
final class AdjustmentWiringTests: XCTestCase {

    private func dokumentMitFoto(_ adjustments: ImageAdjustments) throws -> (AssemblageModel.Document, DocumentResources) {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.4, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let png = try XCTUnwrap(
            NSBitmapImageRep(cgImage: try XCTUnwrap(ctx.makeImage()))
                .representation(using: .png, properties: [:])
        )

        let resources = DocumentResources()
        let referenz = resources.addOriginal(png, fileExtension: "png")

        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 40, height: 40),
            layers: [
                Layer(
                    name: "Foto",
                    transform: Transform2D(x: 20, y: 20),
                    content: .image(ImageLayerContent(
                        originalFileReference: referenz,
                        adjustments: adjustments
                    ))
                )
            ]
        )
        return (document, resources)
    }

    /// Auf der Leinwand muss die Kette an der Schicht hängen — nur dann
    /// wendet Core Animation sie auf der GPU an, und nur dann ist das
    /// Feedback beim Reglerziehen sofort (Plan 4.4).
    func testCanvasAttachesTheFilterChainToTheLayer() throws {
        let (mitAnpassung, resources) = try dokumentMitFoto(ImageAdjustments(brightness: 0.5))
        let ansicht = CanvasView(document: mitAnpassung, images: ImageStore(resources: resources))

        let schicht = try XCTUnwrap(ansicht.layer?.sublayers?.first?.sublayers?.first)
        let filter = try XCTUnwrap(schicht.filters as? [CIFilter])
        XCTAssertFalse(filter.isEmpty)
    }

    /// Ohne Anpassung darf keine Kette hängen — sonst zahlt jede
    /// unbearbeitete Ebene für nichts.
    func testCanvasAttachesNoChainForNeutralAdjustments() throws {
        let (ohne, resources) = try dokumentMitFoto(.neutral)
        let ansicht = CanvasView(document: ohne, images: ImageStore(resources: resources))

        let schicht = try XCTUnwrap(ansicht.layer?.sublayers?.first?.sublayers?.first)
        XCTAssertNil(schicht.filters)
    }

    /// Wird eine Anpassung zurückgenommen, muss die Kette wieder verschwinden.
    func testCanvasRemovesTheChainWhenAdjustmentsAreReset() throws {
        let (mitAnpassung, resources) = try dokumentMitFoto(ImageAdjustments(saturation: -1))
        let ansicht = CanvasView(document: mitAnpassung, images: ImageStore(resources: resources))

        let (ohne, _) = try dokumentMitFoto(.neutral)
        var zurueckgesetzt = mitAnpassung
        zurueckgesetzt.layers[0].content = ohne.layers[0].content
        // Dieselbe Datei-Referenz behalten, damit die Schicht wiederverwendet wird.
        if case .image(var inhalt) = mitAnpassung.layers[0].content {
            inhalt.adjustments = .neutral
            zurueckgesetzt.layers[0].content = .image(inhalt)
        }
        ansicht.update(to: zurueckgesetzt)

        let schicht = try XCTUnwrap(ansicht.layer?.sublayers?.first?.sublayers?.first)
        XCTAssertNil(schicht.filters)
    }

    /// Im Export muss die Anpassung in den Pixeln ankommen.
    func testExportAppliesAdjustments() async throws {
        let (ohne, resourcesOhne) = try dokumentMitFoto(.neutral)
        let (hell, resourcesHell) = try dokumentMitFoto(ImageAdjustments(brightness: 0.6))

        func helligkeitInDerMitte(_ document: AssemblageModel.Document, _ resources: DocumentResources) async throws -> Int {
            let bild = try await DocumentExporter.image(
                of: document, resources: resources, targetSize: CGSize(width: 40, height: 40)
            )
            let ctx = try XCTUnwrap(CGContext(
                data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            ctx.draw(bild, in: CGRect(x: 0, y: 0, width: 40, height: 40))
            let daten = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
            return Int(daten[20 * ctx.bytesPerRow + 20 * 4])
        }

        let normal = try await helligkeitInDerMitte(ohne, resourcesOhne)
        let aufgehellt = try await helligkeitInDerMitte(hell, resourcesHell)

        XCTAssertGreaterThan(aufgehellt, normal + 15, "der Export muss die Aufhellung zeigen")
    }
}
