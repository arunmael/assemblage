import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Prüft die Logik hinter dem Export-Dialog (`ExportPanelLogic`) — der
/// `NSSavePanel` selbst lässt sich nicht sinnvoll automatisiert bedienen,
/// deshalb ist die eigentliche Logik in `ExportPanel.swift` bewusst von der
/// AppKit-Darstellung getrennt (siehe Kommentar dort).
@MainActor
final class ExportPanelTests: XCTestCase {

    // MARK: - Vorgeschlagener Dateiname

    func testSuggestedFileNameStripsAssemblageExtension() {
        XCTAssertEqual(ExportPanelLogic.suggestedFileName(forDocumentDisplayName: "Ferienbilder.assemblage"), "Ferienbilder")
    }

    func testSuggestedFileNameKeepsOtherDots() {
        // Ein Punkt, der nicht zur `.assemblage`-Endung gehört, darf nicht
        // verschwinden — z. B. bei einem Namen mit Datum oder Versionsnummer.
        XCTAssertEqual(ExportPanelLogic.suggestedFileName(forDocumentDisplayName: "Reise 2024.05"), "Reise 2024.05")
    }

    func testSuggestedFileNameForUntitledDocument() {
        XCTAssertEqual(ExportPanelLogic.suggestedFileName(forDocumentDisplayName: "Ohne Titel"), "Ohne Titel")
    }

    func testSuggestedFileNameForEmptyName() {
        XCTAssertEqual(ExportPanelLogic.suggestedFileName(forDocumentDisplayName: ""), "Export")
    }

    func testSuggestedFileNameForWhitespaceOnlyName() {
        XCTAssertEqual(ExportPanelLogic.suggestedFileName(forDocumentDisplayName: "   "), "Export")
    }

    // MARK: - Format → Dateiendung/Dateityp

    func testFormatFileExtensions() {
        XCTAssertEqual(ExportFormat.png.fileExtension, "png")
        XCTAssertEqual(ExportFormat.jpeg.fileExtension, "jpg")
        XCTAssertEqual(ExportFormat.pdf.fileExtension, "pdf")
    }

    func testFormatContentTypesDiffer() {
        XCTAssertNotEqual(ExportFormat.png.contentType, ExportFormat.jpeg.contentType)
        XCTAssertEqual(ExportFormat.png.contentType, .png)
        XCTAssertEqual(ExportFormat.jpeg.contentType, .jpeg)
        XCTAssertEqual(ExportFormat.pdf.contentType, .pdf)
    }

    // MARK: - Qualität nur bei JPEG von Bedeutung

    func testOnlyJPEGSupportsQuality() {
        XCTAssertFalse(ExportFormat.png.supportsQuality)
        XCTAssertTrue(ExportFormat.jpeg.supportsQuality)
        XCTAssertFalse(ExportFormat.pdf.supportsQuality)
    }

    // MARK: - Pixelgrösse je Skalierungsfaktor

    func testPixelSizeForSquareCanvasAtEachScale() {
        let canvas = CanvasSize(width: 1080, height: 1080)
        XCTAssertEqual(ExportPanelLogic.formattedPixelSize(canvas: canvas, scale: ExportScaleOption.x1.factor), "1080 × 1080 Pixel")
        XCTAssertEqual(ExportPanelLogic.formattedPixelSize(canvas: canvas, scale: ExportScaleOption.x2.factor), "2160 × 2160 Pixel")
        XCTAssertEqual(ExportPanelLogic.formattedPixelSize(canvas: canvas, scale: ExportScaleOption.x3.factor), "3240 × 3240 Pixel")
    }

    func testPixelSizeForNonSquareCanvas() {
        // Instagram-Story-Format — Breite und Höhe müssen unabhängig
        // voneinander skaliert werden, nicht nur eine Zahl verdoppelt.
        let canvas = CanvasSize(width: 1080, height: 1920)
        XCTAssertEqual(ExportPanelLogic.formattedPixelSize(canvas: canvas, scale: ExportScaleOption.x2.factor), "2160 × 3840 Pixel")
    }

    func testPDFSizeIsLabelledInPoints() {
        let canvas = CanvasSize(width: 1080, height: 1920)
        XCTAssertEqual(
            ExportPanelLogic.formattedSize(canvas: canvas, scale: ExportScaleOption.x2.factor, format: .pdf),
            "2160 × 3840 Punkte"
        )
    }

    // MARK: - Export: Fehler beim Schreiben

    func testExportReportsErrorWhenWriteFails() async throws {
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 50, height: 50),
            layers: [
                Layer(
                    name: "Form",
                    transform: Transform2D(x: 25, y: 25),
                    content: .shape(ShapeLayerContent(kind: .rectangle, size: Size(width: 50, height: 50), fillColorHex: "#FF0000FF"))
                )
            ]
        )
        let resources = DocumentResources()

        // Ein Verzeichnis, das es nicht gibt, kann kein Schreibziel sein —
        // das Schreiben muss hier zuverlässig scheitern.
        let unwritableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("assemblage-export-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("nicht-vorhandenes-unterverzeichnis", isDirectory: true)
            .appendingPathComponent("export.png")

        do {
            try await ExportPanelLogic.performExport(
                document: document,
                resources: resources,
                format: .png,
                scale: 1,
                quality: 0.9,
                to: unwritableURL
            )
            XCTFail("Der Export in ein nicht existierendes Verzeichnis hätte fehlschlagen müssen.")
        } catch let error as ExportWriteError {
            // Erwarteter Fehlerpfad: Rendern gelingt, Schreiben scheitert.
            XCTAssertNotNil(error.errorDescription)
        } catch {
            XCTFail("Unerwarteter Fehlertyp: \(error)")
        }
    }

    func testExportSucceedsToWritableLocation() async throws {
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 20, height: 20),
            layers: [
                Layer(
                    name: "Form",
                    transform: Transform2D(x: 10, y: 10),
                    content: .shape(ShapeLayerContent(kind: .rectangle, size: Size(width: 20, height: 20), fillColorHex: "#00FF00FF"))
                )
            ]
        )
        let resources = DocumentResources()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("assemblage-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("export.png")

        try await ExportPanelLogic.performExport(
            document: document,
            resources: resources,
            format: .png,
            scale: 1,
            quality: 0.9,
            to: url
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
