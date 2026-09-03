import XCTest
import AppKit
import CoreGraphics
@testable import AssemblageKit
@testable import AssemblageModel

/// Prüft den vektorbasierten PDF-Export aus Plan 5.8. PDF-Seiten werden für
/// die Bildvergleiche bewusst wieder in eine Bitmap gerendert: So lassen sich
/// Ebenenregeln mit denselben robusten Pixelproben wie beim PNG-Export prüfen.
@MainActor
final class PDFExportTests: XCTestCase {

    private func pdfDocument(from data: Data) throws -> CGPDFDocument {
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        return try XCTUnwrap(CGPDFDocument(provider))
    }

    private func renderedPage(_ page: CGPDFPage, width: Int, height: Int) throws -> CGContext {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let mediaBox = page.getBoxRect(.mediaBox)
        context.scaleBy(x: CGFloat(width) / mediaBox.width, y: CGFloat(height) / mediaBox.height)
        context.drawPDFPage(page)
        return context
    }

    /// Liest eine Farbe in Modellkoordinaten mit Ursprung oben links.
    private func pixel(of context: CGContext, x: Int, y: Int) throws -> (r: Int, g: Int, b: Int, a: Int) {
        let data = try XCTUnwrap(context.data)
        let row = context.height - 1 - y
        let pointer = data.advanced(by: row * context.bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
        return (Int(pointer[0]), Int(pointer[1]), Int(pointer[2]), Int(pointer[3]))
    }

    private func assertRoughly(
        _ actual: (r: Int, g: Int, b: Int, a: Int),
        _ expected: (r: Int, g: Int, b: Int, a: Int),
        tolerance: Int = 24,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.r, expected.r, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(actual.g, expected.g, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(actual.b, expected.b, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(actual.a, expected.a, accuracy: tolerance, file: file, line: line)
    }

    private func rectangle(
        name: String,
        color: String,
        x: Double = 50,
        y: Double = 50,
        size: Double = 100,
        opacity: Double = 1,
        isVisible: Bool = true
    ) -> Layer {
        Layer(
            name: name,
            isVisible: isVisible,
            opacity: opacity,
            transform: Transform2D(x: x, y: y),
            content: .shape(ShapeLayerContent(
                kind: .rectangle,
                size: Size(width: size, height: size),
                fillColorHex: color
            ))
        )
    }

    func testResultIsReadableSinglePagePDF() async throws {
        let document = AssemblageModel.Document(canvas: CanvasSize(width: 120, height: 80), layers: [])
        let data = try await DocumentExporter.pdfData(
            of: document,
            resources: DocumentResources(),
            pageSize: CGSize(width: 120, height: 80)
        )

        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        XCTAssertEqual(try pdfDocument(from: data).numberOfPages, 1)
    }

    func testPageSizeUsesScaledCanvasDimensionsInPoints() async throws {
        let document = AssemblageModel.Document(canvas: CanvasSize(width: 120, height: 80), layers: [])
        let data = try await DocumentExporter.pdfData(
            of: document,
            resources: DocumentResources(),
            pageSize: DocumentExporter.targetSize(forCanvas: document.canvas, scale: 2)
        )
        let page = try XCTUnwrap(try pdfDocument(from: data).page(at: 1))

        XCTAssertEqual(page.getBoxRect(.mediaBox).width, 240, accuracy: 0.01)
        XCTAssertEqual(page.getBoxRect(.mediaBox).height, 160, accuracy: 0.01)
    }

    func testLayerOrderVisibilityAndOpacityAreApplied() async throws {
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 100, height: 100),
            layers: [
                rectangle(name: "Unten", color: "#FF0000"),
                rectangle(name: "Unsichtbar", color: "#00FF00", isVisible: false),
                rectangle(name: "Oben", color: "#0000FF", opacity: 0.5)
            ]
        )
        let data = try await DocumentExporter.pdfData(
            of: document,
            resources: DocumentResources(),
            pageSize: CGSize(width: 100, height: 100)
        )
        let page = try XCTUnwrap(try pdfDocument(from: data).page(at: 1))
        let context = try renderedPage(page, width: 100, height: 100)

        assertRoughly(try pixel(of: context, x: 50, y: 50), (128, 0, 128, 255))
    }

    func testEmptyDocumentProducesValidTransparentPDF() async throws {
        let document = AssemblageModel.Document(canvas: CanvasSize(width: 60, height: 40), layers: [])
        let data = try await DocumentExporter.pdfData(
            of: document,
            resources: DocumentResources(),
            pageSize: CGSize(width: 60, height: 40)
        )
        let pdf = try pdfDocument(from: data)
        let page = try XCTUnwrap(pdf.page(at: 1))
        let context = try renderedPage(page, width: 60, height: 40)

        XCTAssertEqual(pdf.numberOfPages, 1)
        assertRoughly(try pixel(of: context, x: 20, y: 20), (0, 0, 0, 0))
    }

    func testMissingOriginalDoesNotFailPDFExport() async throws {
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 100, height: 100),
            layers: [
                Layer(
                    name: "Fehlendes Original",
                    transform: Transform2D(x: 50, y: 50),
                    content: .image(ImageLayerContent(originalFileReference: "originals/fehlt.png"))
                )
            ]
        )

        let data = try await DocumentExporter.pdfData(
            of: document,
            resources: DocumentResources(),
            pageSize: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(try pdfDocument(from: data).numberOfPages, 1)
    }

    func testPDFAndPNGLookSubstantiallyEqual() async throws {
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 120, height: 100),
            layers: [
                rectangle(name: "Grund", color: "#D04020", x: 60, size: 100),
                rectangle(name: "Oben", color: "#2080D0", x: 70, size: 50, opacity: 0.65)
            ]
        )
        let resources = DocumentResources()
        let size = CGSize(width: 120, height: 100)
        let pdfData = try await DocumentExporter.pdfData(of: document, resources: resources, pageSize: size)
        let pngData = try await DocumentExporter.pngData(of: document, resources: resources, targetSize: size)

        let page = try XCTUnwrap(try pdfDocument(from: pdfData).page(at: 1))
        let pdfContext = try renderedPage(page, width: 120, height: 100)
        let pngImage = try XCTUnwrap(NSBitmapImageRep(data: pngData)?.cgImage)
        let pngContext = try XCTUnwrap(CGContext(
            data: nil, width: 120, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        pngContext.draw(pngImage, in: CGRect(origin: .zero, size: size))

        for (x, y) in [(10, 10), (35, 50), (60, 50), (90, 50), (119, 99)] {
            assertRoughly(
                try pixel(of: pdfContext, x: x, y: y),
                try pixel(of: pngContext, x: x, y: y),
                tolerance: 32
            )
        }
    }

    func testTextAndShapesAreNotEmbeddedAsRasterImages() async throws {
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 200, height: 100),
            layers: [
                rectangle(name: "Form", color: "#FF8000", x: 50, size: 60),
                Layer(
                    name: "Text",
                    transform: Transform2D(x: 130, y: 50),
                    content: .text(TextLayerContent(
                        string: "Vektor", fontName: "Helvetica", fontSize: 24, colorHex: "#000000"
                    ))
                )
            ]
        )
        let data = try await DocumentExporter.pdfData(
            of: document,
            resources: DocumentResources(),
            pageSize: CGSize(width: 200, height: 100)
        )

        let source = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(source.contains("/Subtype /Image"), "Formen und Text dürfen nicht als Rasterbild eingebettet werden.")
        XCTAssertFalse(source.contains("/Subtype/Image"), "Formen und Text dürfen nicht als Rasterbild eingebettet werden.")
    }
}
