import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Prüft die Dokumentlogik hinter „Motiv freistellen“ ohne Menü, Sheets und
/// Vision-Modell. Die Maskenerzeugung wird als asynchrone Abhängigkeit
/// hereingereicht, weil Vision auf demselben Testbild je nach Systemversion
/// anders entscheiden darf. Damit testen diese Fälle ausschliesslich unseren
/// Vertrag: Paketressource, Dokumentänderung, Undo und Ergebnisbehandlung.
@MainActor
final class ForegroundMaskingCommandTests: XCTestCase {

    private enum TestError: Error {
        case generationFailed
    }

    private func maskPNG() throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try XCTUnwrap(context.makeImage())
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    private func imageDocument(mask: LayerMask? = nil) -> (AssemblageDocument, UUID, Data) {
        let document = AssemblageDocument()
        let original = Data("Originalbild für den Generator".utf8)
        let reference = document.state.resources.addOriginal(original, fileExtension: "png")
        let layer = Layer(
            name: "Foto",
            mask: mask,
            content: .image(ImageLayerContent(originalFileReference: reference))
        )
        document.modify("Testbild einsetzen") { _ = try? $0.addLayer(layer) }
        document.state.selectedLayerID = layer.id
        return (document, layer.id, original)
    }

    func testSuccessfulMaskingStoresAutomaticMaskInPackage() async throws {
        let (document, layerID, original) = imageDocument()
        let expectedMask = try maskPNG()

        let outcome = try await ForegroundMaskingCommandLogic.perform(in: document.state) { imageData in
            XCTAssertEqual(imageData, original)
            return .mask(expectedMask)
        }

        XCTAssertEqual(outcome, .applied)
        let mask = try XCTUnwrap(document.state.document.layer(withID: layerID)?.mask)
        XCTAssertEqual(mask.source, .automaticForegroundInstance)
        let reference = try XCTUnwrap(mask.maskImageReference)
        XCTAssertEqual(document.state.resources.data(for: reference), expectedMask)
    }

    func testSuccessfulMaskingIsOneUndoStep() async throws {
        let (document, layerID, _) = imageDocument()
        let undoManager = UndoManager()
        document.undoManager = undoManager
        undoManager.removeAllActions()

        _ = try await ForegroundMaskingCommandLogic.perform(in: document.state) { _ in
            .mask(try self.maskPNG())
        }

        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()

        XCTAssertNil(document.state.document.layer(withID: layerID)?.mask)
        XCTAssertFalse(undoManager.canUndo, "der ganze Vorgang muss genau ein Undo-Schritt sein")
    }

    func testMissingOrNonImageSelectionDoesNothing() async throws {
        let document = AssemblageDocument()
        let text = Layer(name: "Text", content: .text(TextLayerContent(string: "Hallo")))
        let shape = Layer(
            name: "Form",
            content: .shape(ShapeLayerContent(kind: .rectangle, size: Size(width: 20, height: 20)))
        )
        document.modify("Testebenen einsetzen") {
            _ = try? $0.addLayer(text)
            _ = try? $0.addLayer(shape)
        }
        let before = document.state.document
        var generationCount = 0

        for selection in [nil, text.id, shape.id] as [UUID?] {
            document.state.selectedLayerID = selection
            let outcome = try await ForegroundMaskingCommandLogic.perform(in: document.state) { _ in
                generationCount += 1
                return .mask(try self.maskPNG())
            }
            XCTAssertEqual(outcome, .notApplicable)
        }

        XCTAssertEqual(generationCount, 0)
        XCTAssertEqual(document.state.document, before)
    }

    func testNoSubjectFoundLeavesLayerUnchanged() async throws {
        let (document, _, _) = imageDocument()
        let before = document.state.document
        let resourcesBefore = Set(document.state.resources.fileNames)

        let outcome = try await ForegroundMaskingCommandLogic.perform(in: document.state) { _ in
            .noSubjectFound
        }

        XCTAssertEqual(outcome, .noSubjectFound)
        XCTAssertEqual(document.state.document, before)
        XCTAssertEqual(Set(document.state.resources.fileNames), resourcesBefore)
    }

    func testGenerationErrorLeavesDocumentUnchanged() async throws {
        let (document, _, _) = imageDocument()
        let before = document.state.document
        let resourcesBefore = Set(document.state.resources.fileNames)

        do {
            _ = try await ForegroundMaskingCommandLogic.perform(in: document.state) { _ in
                throw TestError.generationFailed
            }
            XCTFail("ein echter Fehler muss weitergereicht werden")
        } catch TestError.generationFailed {
            // Erwarteter Fehlerpfad.
        }

        XCTAssertEqual(document.state.document, before)
        XCTAssertEqual(Set(document.state.resources.fileNames), resourcesBefore)
    }

    func testExistingMaskIsReplacedAndUndoRestoresIt() async throws {
        let document = AssemblageDocument()
        let oldMaskData = try maskPNG()
        let oldReference = document.state.resources.addMask(oldMaskData)
        let oldMask = LayerMask(
            maskImageReference: oldReference,
            source: .manualBrush,
            isInverted: true,
            isEnabled: false
        )
        let layerID = UUID()
        let original = Data("Originalbild".utf8)
        let originalReference = document.state.resources.addOriginal(original, fileExtension: "png")
        let layer = Layer(
            id: layerID,
            name: "Foto",
            mask: oldMask,
            content: .image(ImageLayerContent(originalFileReference: originalReference))
        )
        document.modify("Testbild einsetzen") { _ = try? $0.addLayer(layer) }
        document.state.selectedLayerID = layerID
        let undoManager = UndoManager()
        document.undoManager = undoManager
        undoManager.removeAllActions()

        _ = try await ForegroundMaskingCommandLogic.perform(in: document.state) { _ in
            .mask(try self.maskPNG())
        }

        let replacement = try XCTUnwrap(document.state.document.layer(withID: layerID)?.mask)
        XCTAssertEqual(replacement.source, .automaticForegroundInstance)
        XCTAssertNotEqual(replacement.maskImageReference, oldReference)

        undoManager.undo()

        XCTAssertEqual(document.state.document.layer(withID: layerID)?.mask, oldMask)
        XCTAssertFalse(undoManager.canUndo, "Ersetzen und Wiederherstellen dürfen keinen zweiten Schritt bilden")
    }
}
