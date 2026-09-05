import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Der Teilen-Knopf (aus Anpassungen.md).
///
/// `NSSharingServicePicker` selbst lässt sich nicht automatisiert prüfen —
/// er öffnet ein echtes System-Menü. Geprüft wird deshalb, was ihm übergeben
/// wird: ein Bild in Leinwandgrösse.
@MainActor
final class ShareCommandTests: XCTestCase {

    func testRendersAtCanvasSize() async throws {
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 320, height: 240),
            layers: [Layer(
                name: "Form",
                transform: Transform2D(x: 160, y: 120),
                content: .shape(ShapeLayerContent(
                    kind: .ellipse, size: Size(width: 100, height: 100), fillColorHex: "#3050A0"))
            )]
        )

        let bild = try await ShareCommand.renderedImage(of: document, resources: DocumentResources())

        XCTAssertEqual(bild.size.width, 320, accuracy: 0.5)
        XCTAssertEqual(bild.size.height, 240, accuracy: 0.5)
    }

    /// Ein leeres Dokument darf nicht scheitern — sonst könnte man ein neu
    /// angelegtes, noch unbearbeitetes Dokument nicht einmal teilen.
    func testRendersAnEmptyDocumentWithoutThrowing() async throws {
        let document = AssemblageModel.Document(canvas: CanvasSize(width: 100, height: 100), layers: [])
        let bild = try await ShareCommand.renderedImage(of: document, resources: DocumentResources())
        XCTAssertEqual(bild.size.width, 100, accuracy: 0.5)
    }
}
