import XCTest
import AppKit
import CoreImage
@testable import AssemblageKit
@testable import AssemblageModel

/// Ebenenmasken (Plan 5.4) beim Rendern anwenden — auf der Leinwand und im
/// Export.
///
/// Festlegung, die hier getroffen und geprüft wird: Die Maske liegt in
/// **Bildauflösung** und deckt das ganze Original ab, genau wie der
/// Zuschnitt-Rahmen. Nur so bleiben Maske und Zuschnitt unabhängig
/// voneinander änderbar — sonst müsste jede Zuschnitt-Änderung die
/// Maskenbitmap umrechnen und verlöre dabei Pixel.
@MainActor
final class MaskRenderingTests: XCTestCase {

    private let seite = 40

    /// Maske: linke Hälfte deckend (weiss), rechte Hälfte durchsichtig
    /// (schwarz). In einer Alphamaske heisst Weiss „sichtbar".
    private func maskenPNG() throws -> Data {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: seite, height: seite, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: seite, height: seite))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: seite / 2, height: seite))
        return try XCTUnwrap(
            NSBitmapImageRep(cgImage: try XCTUnwrap(ctx.makeImage()))
                .representation(using: .png, properties: [:])
        )
    }

    private func rotesBildPNG() throws -> Data {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: seite, height: seite, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: seite, height: seite))
        return try XCTUnwrap(
            NSBitmapImageRep(cgImage: try XCTUnwrap(ctx.makeImage()))
                .representation(using: .png, properties: [:])
        )
    }

    private func dokument(
        maske: LayerMask?
    ) throws -> (AssemblageModel.Document, DocumentResources) {
        let resources = DocumentResources()
        let bildRef = resources.addOriginal(try rotesBildPNG(), fileExtension: "png")

        var verwendeteMaske = maske
        if maske != nil {
            verwendeteMaske?.maskImageReference = resources.addMask(try maskenPNG())
        }

        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: Double(seite), height: Double(seite)),
            layers: [
                Layer(
                    name: "Foto",
                    transform: Transform2D(x: Double(seite) / 2, y: Double(seite) / 2),
                    mask: verwendeteMaske,
                    content: .image(ImageLayerContent(originalFileReference: bildRef))
                )
            ]
        )
        return (document, resources)
    }

    /// Liest eine Farbe samt Alpha aus einem exportierten Bild.
    private func exportPixel(
        _ document: AssemblageModel.Document,
        _ resources: DocumentResources,
        x: Int, y: Int
    ) async throws -> (r: Int, a: Int) {
        let bild = try await DocumentExporter.image(
            of: document, resources: resources,
            targetSize: CGSize(width: seite, height: seite)
        )
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: seite, height: seite, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.draw(bild, in: CGRect(x: 0, y: 0, width: seite, height: seite))
        let daten = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        let versatz = (seite - 1 - y) * ctx.bytesPerRow + x * 4
        return (Int(daten[versatz]), Int(daten[versatz + 3]))
    }

    // MARK: - Export

    func testMaskHidesTheMaskedOutHalf() async throws {
        let (document, resources) = try dokument(maske: LayerMask(source: .manualBrush))

        let links = try await exportPixel(document, resources, x: 10, y: 20)
        let rechts = try await exportPixel(document, resources, x: 30, y: 20)

        XCTAssertGreaterThan(links.a, 200, "die weisse Maskenhälfte bleibt sichtbar")
        XCTAssertLessThan(rechts.a, 55, "die schwarze Maskenhälfte wird ausgeblendet")
    }

    /// Maske umkehren (Plan 5.4) muss genau das Gegenteil ergeben.
    func testInvertedMaskSwapsVisibility() async throws {
        let (document, resources) = try dokument(
            maske: LayerMask(source: .manualBrush, isInverted: true)
        )

        let links = try await exportPixel(document, resources, x: 10, y: 20)
        let rechts = try await exportPixel(document, resources, x: 30, y: 20)

        XCTAssertLessThan(links.a, 55)
        XCTAssertGreaterThan(rechts.a, 200)
    }

    /// Maske vorübergehend deaktivieren (Plan 5.4): Die Maske bleibt
    /// gespeichert, wirkt aber nicht.
    func testDisabledMaskHasNoEffect() async throws {
        let (document, resources) = try dokument(
            maske: LayerMask(source: .manualBrush, isEnabled: false)
        )

        let rechts = try await exportPixel(document, resources, x: 30, y: 20)

        XCTAssertGreaterThan(rechts.a, 200, "deaktiviert heisst: als wäre keine Maske da")
    }

    func testLayerWithoutMaskIsFullyVisible() async throws {
        let (document, resources) = try dokument(maske: nil)

        let rechts = try await exportPixel(document, resources, x: 30, y: 20)

        XCTAssertGreaterThan(rechts.a, 200)
    }

    /// Eine Maske, deren Bitmap noch fehlt — etwa während die Vision-Anfrage
    /// läuft —, darf die Ebene nicht verschwinden lassen (Plan 2.1).
    func testMaskWithoutBitmapLeavesTheLayerVisible() async throws {
        let resources = DocumentResources()
        let bildRef = resources.addOriginal(try rotesBildPNG(), fileExtension: "png")
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: Double(seite), height: Double(seite)),
            layers: [
                Layer(
                    name: "Foto",
                    transform: Transform2D(x: 20, y: 20),
                    mask: LayerMask(source: .automaticForegroundInstance),
                    content: .image(ImageLayerContent(originalFileReference: bildRef))
                )
            ]
        )

        let mitte = try await exportPixel(document, resources, x: 20, y: 20)

        XCTAssertGreaterThan(mitte.a, 200)
    }

    // MARK: - Leinwand

    /// Auf der Leinwand übernimmt Core Animation die Maske — geprüft wird,
    /// dass sie hängt und die richtige Ausdehnung hat.
    func testCanvasAttachesTheMaskToTheLayer() throws {
        let (document, resources) = try dokument(maske: LayerMask(source: .manualBrush))
        let ansicht = CanvasView(document: document, images: ImageStore(resources: resources))

        let schicht = try XCTUnwrap(ansicht.layer?.sublayers?.first?.sublayers?.first)
        let maske = try XCTUnwrap(schicht.mask, "ohne Maskenschicht wirkt die Maske nicht")
        XCTAssertEqual(maske.bounds.size, schicht.bounds.size, "Maske und Ebene müssen deckungsgleich sein")
    }

    func testCanvasAttachesNoMaskWhenDisabled() throws {
        let (document, resources) = try dokument(
            maske: LayerMask(source: .manualBrush, isEnabled: false)
        )
        let ansicht = CanvasView(document: document, images: ImageStore(resources: resources))

        let schicht = try XCTUnwrap(ansicht.layer?.sublayers?.first?.sublayers?.first)
        XCTAssertNil(schicht.mask)
    }
}
