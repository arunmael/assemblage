import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Prüft den kompletten Weg Dokument → Paket auf der Platte → Dokument
/// (Plan 7.4). Die reine Formatlogik liegt in `AssemblageModelTests`; hier
/// geht es um die `FileWrapper`-Anbindung, die `NSDocument` tatsächlich nutzt.
@MainActor
final class DocumentIOTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AssemblageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func packageURL(_ name: String) -> URL {
        scratch.appendingPathComponent("\(name).\(AssemblageDocument.fileExtension)")
    }

    private func pngData(_ side: Int = 8) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try XCTUnwrap(
            NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
                .representation(using: .png, properties: [:])
        )
    }

    /// Schreibt ein Dokument auf die Platte und liest es in ein frisches
    /// `AssemblageDocument` zurück.
    private func roundTrip(_ document: AssemblageDocument, named name: String) throws -> AssemblageDocument {
        let url = packageURL(name)
        try document.write(to: url, ofType: AssemblageDocument.fileType, for: .saveOperation, originalContentsURL: nil)

        let reopened = AssemblageDocument()
        try reopened.read(from: FileWrapper(url: url), ofType: AssemblageDocument.fileType)
        return reopened
    }

    // MARK: - Runde durch die Platte

    func testDocumentSurvivesSaveAndOpen() throws {
        let document = AssemblageDocument()
        document.modify("Aufbauen") {
            $0.canvas = CanvasSize(width: 800, height: 600)
            try? $0.addLayer(
                Layer(
                    name: "Titel",
                    opacity: 0.4,
                    blendMode: .multiply,
                    content: .text(TextLayerContent(string: "Hallo"))
                )
            )
        }

        let reopened = try roundTrip(document, named: "Runde")

        XCTAssertEqual(reopened.state.document, document.state.document)
    }

    func testOriginalImageIsStoredInsideThePackage() throws {
        let document = AssemblageDocument()
        let reference = document.state.resources.addOriginal(try pngData(), fileExtension: "png")
        document.modify("Bild einsetzen") {
            try? $0.addLayer(
                Layer(name: "Foto", content: .image(ImageLayerContent(originalFileReference: reference)))
            )
        }

        let reopened = try roundTrip(document, named: "MitBild")

        XCTAssertNotNil(
            reopened.state.resources.data(for: reference),
            "das Original muss im Paket liegen — sonst ist das Dokument nach dem Verschieben kaputt"
        )
        XCTAssertNotNil(
            reopened.state.images.image(named: reference),
            "und es muss sich auch wieder dekodieren lassen"
        )
    }

    /// Plan 2.1: Pakete dürfen nicht endlos wachsen. Das Original einer
    /// gelöschten Ebene muss beim nächsten Sichern verschwinden.
    func testDeletedLayersOriginalIsDroppedOnSave() throws {
        let document = AssemblageDocument()
        let reference = document.state.resources.addOriginal(try pngData(), fileExtension: "png")
        let layer = Layer(name: "Foto", content: .image(ImageLayerContent(originalFileReference: reference)))
        document.modify("Bild einsetzen") { try? $0.addLayer(layer) }
        document.modify("Ebene löschen") { try? $0.removeLayer(id: layer.id) }

        let reopened = try roundTrip(document, named: "Aufgeraeumt")

        XCTAssertNil(reopened.state.resources.data(for: reference))
    }

    // MARK: - Fehlerfälle statt Abstürze (Plan 2.1)

    func testOpeningPackageWithoutDocumentJSONThrows() throws {
        let url = packageURL("Kaputt")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("nichts".utf8).write(to: url.appendingPathComponent("egal.txt"))

        XCTAssertThrowsError(
            try AssemblageDocument().read(from: FileWrapper(url: url), ofType: AssemblageDocument.fileType)
        )
    }

    func testOpeningPackageWithMissingOriginalNamesTheMissingFile() throws {
        let document = AssemblageDocument()
        document.modify("Bild einsetzen") {
            try? $0.addLayer(
                Layer(
                    name: "Foto",
                    content: .image(ImageLayerContent(originalFileReference: "originals/weg.png"))
                )
            )
        }
        let url = packageURL("Unvollstaendig")
        try document.write(to: url, ofType: AssemblageDocument.fileType, for: .saveOperation, originalContentsURL: nil)

        XCTAssertThrowsError(
            try AssemblageDocument().read(from: FileWrapper(url: url), ofType: AssemblageDocument.fileType)
        ) { error in
            XCTAssertEqual(
                error as? DocumentPackageError,
                .missingReferencedFiles(["originals/weg.png"])
            )
        }
    }

    // MARK: - Widerrufen

    func testUndoRestoresThePreviousDocument() throws {
        let document = AssemblageDocument()
        let undoManager = UndoManager()
        document.undoManager = undoManager
        let before = document.state.document

        document.modify("Ebene hinzufügen") {
            try? $0.addLayer(Layer(name: "Neu", content: .text(TextLayerContent(string: "x"))))
        }
        XCTAssertEqual(document.state.document.layers.count, 1)

        undoManager.undo()

        XCTAssertEqual(document.state.document, before)

        undoManager.redo()

        XCTAssertEqual(document.state.document.layers.count, 1, "Wiederholen muss die Änderung zurückbringen")
    }

    /// Ein Regler, der auf demselben Wert stehen bleibt, darf keinen leeren
    /// Undo-Schritt erzeugen — sonst muss man dreimal ⌘Z drücken, bis sich
    /// sichtbar etwas tut.
    func testUnchangedModificationRegistersNoUndoStep() throws {
        let document = AssemblageDocument()
        let undoManager = UndoManager()
        document.undoManager = undoManager

        document.modify("Nichts tun") { _ in }

        XCTAssertFalse(undoManager.canUndo)
    }
}
