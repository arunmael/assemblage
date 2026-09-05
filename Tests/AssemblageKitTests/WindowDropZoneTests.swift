import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Eine Datei überall im Fenster loslassen können, nicht nur auf der
/// Leinwand (aus Anpassungen.md).
@MainActor
final class WindowDropZoneTests: XCTestCase {

    /// Baut ein Pasteboard mit einer Bilddatei, wie ein echter Finder-Wurf
    /// es liefern würde.
    private func wurfMitBild() throws -> NSPasteboard {
        let ordner = FileManager.default.temporaryDirectory
            .appendingPathComponent("assemblage-dropzone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        let url = ordner.appendingPathComponent("foto.png")

        let context = try XCTUnwrap(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bild = try XCTUnwrap(context.makeImage())
        let daten = try XCTUnwrap(NSBitmapImageRep(cgImage: bild).representation(using: .png, properties: [:]))
        try daten.write(to: url)

        let board = NSPasteboard(name: .init("assemblage-dropzone-test"))
        board.clearContents()
        board.writeObjects([url as NSURL])
        return board
    }

    // MARK: - Reine Ablagefläche

    func testDropZoneAcceptsAnImageFile() throws {
        let zone = WindowDropZoneView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var empfangen: NSPasteboard?
        zone.onDrop = { empfangen = $0 }

        let board = try wurfMitBild()
        let ergebnis = zone.performDragOperation(FakeDraggingInfo(pasteboard: board))

        XCTAssertTrue(ergebnis)
        XCTAssertNotNil(empfangen)
    }

    func testDropZoneRejectsUnsupportedFiles() throws {
        let zone = WindowDropZoneView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var wurdeGerufen = false
        zone.onDrop = { _ in wurdeGerufen = true }

        let board = NSPasteboard(name: .init("assemblage-dropzone-reject-test"))
        board.clearContents()
        board.setString("kein Bild", forType: .string)

        let ergebnis = zone.performDragOperation(FakeDraggingInfo(pasteboard: board))

        XCTAssertFalse(ergebnis)
        XCTAssertFalse(wurdeGerufen)
    }

    // MARK: - Einbettung um den Fensterinhalt

    /// Der eigentliche Punkt: Der Split View muss als Kind erhalten bleiben
    /// und weiterhin die volle Fläche einnehmen — die Ablagefläche darf ihn
    /// nur umschliessen, nicht ersetzen.
    func testEmbeddingKeepsTheChildAsTheOnlyContent() throws {
        let split = NSSplitViewController()
        let huelle = WindowDropZoneViewController(embedding: split)
        _ = huelle.view // löst loadView() aus

        XCTAssertEqual(huelle.children.count, 1)
        XCTAssertTrue(huelle.children.first === split)
        XCTAssertTrue(huelle.view.subviews.contains(split.view))
    }

    /// Ein über dem Fenstercontroller ausgelöster Wurf muss dieselbe
    /// Ebene ergeben wie einer direkt auf dem Canvas — die Stelle im Fenster
    /// darf keinen Unterschied machen.
    func testWindowLevelDropInsertsALayerJustLikeTheCanvasDoes() throws {
        let document = AssemblageDocument()
        document.undoManager = UndoManager()
        let board = try wurfMitBild()

        ImageDropCommand.handle(pasteboard: board, state: document.state, presentingWindow: nil)

        XCTAssertEqual(document.state.document.layers.count, 1)
        guard case .image = document.state.document.layers.first?.content else {
            return XCTFail("es müsste eine Bildebene entstanden sein")
        }
        XCTAssertNotNil(document.state.selectedLayerID, "das eingesetzte Bild müsste ausgewählt sein")
    }
}

/// Ein minimales `NSDraggingInfo` für Tests — echte Instanzen entstehen nur
/// während eines laufenden System-Drags. Derselbe Aufbau wie `Wurf` in
/// `CanvasInteractionTests.swift`.
private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let board: NSPasteboard
    init(pasteboard: NSPasteboard) { self.board = pasteboard }

    var draggingPasteboard: NSPasteboard { board }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingSource: Any? { nil }
    var animatesToDestination: Bool { get { false } set {} }
    var numberOfValidItemsForDrop: Int { get { 1 } set {} }
    var draggingFormation: NSDraggingFormation { get { .default } set {} }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}
