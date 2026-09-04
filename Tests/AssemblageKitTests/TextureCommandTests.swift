import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Textur zuweisen und entfernen (aus missing.md).
///
/// Der Dateidialog bleibt aussen vor — geprüft wird die Logik dahinter, die
/// ohne Fenster laufen muss. Genau deshalb ist `applyTexture(from:in:)` von
/// `chooseTexture(in:host:)` getrennt.
@MainActor
final class TextureCommandTests: XCTestCase {

    private var ordner: URL!

    override func setUpWithError() throws {
        ordner = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("assemblage-textur-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: ordner)
    }

    /// Eine echte PNG-Datei auf der Platte, wie sie der Dialog liefern würde.
    private func texturDatei() throws -> URL {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let bild = try XCTUnwrap(context.makeImage())
        let daten = try XCTUnwrap(NSBitmapImageRep(cgImage: bild).representation(using: .png, properties: [:]))

        let url = ordner.appendingPathComponent("korn.png")
        try daten.write(to: url)
        return url
    }

    private func dokumentMitEbene() -> (AssemblageDocument, UUID) {
        let ebene = Layer(name: "Foto", content: .shape(
            ShapeLayerContent(kind: .rectangle, size: Size(width: 40, height: 40))))
        let document = AssemblageDocument()
        document.undoManager = UndoManager()
        document.modify("Vorbereiten") { $0.layers = [ebene] }
        document.state.selectedLayerID = ebene.id
        document.undoManager?.removeAllActions()
        return (document, ebene.id)
    }

    // MARK: - Zuweisen

    func testApplyingAttachesTheTexture() throws {
        let (document, id) = dokumentMitEbene()

        XCTAssertEqual(TextureCommand.applyTexture(from: try texturDatei(), in: document.state), .applied)

        let textur = try XCTUnwrap(document.state.document.layer(withID: id)?.texture)
        XCTAssertFalse(textur.imageReference.isEmpty)
        XCTAssertEqual(textur.blendMode, .multiply)
        XCTAssertEqual(textur.opacity, 0.5, accuracy: 0.001)
        XCTAssertEqual(textur.scale, 1, accuracy: 0.001)
    }

    /// Die Datei muss tatsächlich im Paket landen, nicht nur ihr Name im
    /// Modell stehen — sonst zeigte das Dokument nach dem Sichern eine
    /// Textur, deren Bild fehlt.
    func testTheFileEndsUpInThePackage() throws {
        let (document, id) = dokumentMitEbene()
        TextureCommand.applyTexture(from: try texturDatei(), in: document.state)

        let referenz = try XCTUnwrap(document.state.document.layer(withID: id)?.texture?.imageReference)
        XCTAssertNotNil(document.state.resources.data(for: referenz))
        // Und sie darf beim Aufräumen vor dem Sichern nicht gelöscht werden.
        XCTAssertFalse(
            DocumentPackage.unreferencedFileNames(
                in: document.state.resources.fileNames,
                for: document.state.document
            ).contains(referenz)
        )
    }

    func testApplyingIsUndoable() throws {
        let (document, id) = dokumentMitEbene()
        TextureCommand.applyTexture(from: try texturDatei(), in: document.state)
        XCTAssertNotNil(document.state.document.layer(withID: id)?.texture)

        document.undoManager?.undo()
        XCTAssertNil(document.state.document.layer(withID: id)?.texture)
    }

    func testApplyingWithoutSelectionChangesNothing() throws {
        let (document, _) = dokumentMitEbene()
        document.state.selectedLayerID = nil
        let vorher = document.state.document

        XCTAssertEqual(TextureCommand.applyTexture(from: try texturDatei(), in: document.state), .noSelection)
        XCTAssertEqual(document.state.document, vorher)
    }

    /// Eine unlesbare Datei darf nicht abstürzen und nichts anfassen.
    func testUnreadableFileIsReportedNotCrashed() {
        let (document, _) = dokumentMitEbene()
        let vorher = document.state.document

        let ergebnis = TextureCommand.applyTexture(
            from: ordner.appendingPathComponent("gibtsnicht.png"), in: document.state)

        XCTAssertEqual(ergebnis, .unreadableFile)
        XCTAssertEqual(document.state.document, vorher)
    }

    func testCorruptImageIsReportedInsteadOfSilentlyAttached() throws {
        let (document, id) = dokumentMitEbene()
        let url = ordner.appendingPathComponent("kaputt.png")
        try Data("kein Bild".utf8).write(to: url)

        let ergebnis = TextureCommand.applyTexture(from: url, in: document.state)

        XCTAssertEqual(ergebnis, .unreadableFile)
        XCTAssertNil(document.state.document.layer(withID: id)?.texture)
        XCTAssertFalse(document.undoManager?.canUndo ?? true)
    }

    // MARK: - Entfernen

    func testRemovingTakesTheTextureAway() throws {
        let (document, id) = dokumentMitEbene()
        TextureCommand.applyTexture(from: try texturDatei(), in: document.state)

        XCTAssertEqual(TextureCommand.removeTexture(in: document.state), .removed)
        XCTAssertNil(document.state.document.layer(withID: id)?.texture)
    }

    /// Ohne Textur darf „entfernen" keinen Undo-Schritt erzeugen — sonst
    /// drückt man ⌘Z und nichts passiert sichtbar.
    func testRemovingNothingLeavesNoUndoStep() {
        let (document, _) = dokumentMitEbene()
        let vorher = document.state.document

        XCTAssertEqual(TextureCommand.removeTexture(in: document.state), .nothingToRemove)
        XCTAssertEqual(document.state.document, vorher)
        XCTAssertFalse(document.undoManager?.canUndo ?? true)
    }

    func testRemovingWithoutSelection() {
        let (document, _) = dokumentMitEbene()
        document.state.selectedLayerID = nil
        XCTAssertEqual(TextureCommand.removeTexture(in: document.state), .noSelection)
    }
}
