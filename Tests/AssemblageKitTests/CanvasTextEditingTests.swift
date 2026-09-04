import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Direkte Textbearbeitung auf der Leinwand, geprüft mit denselben echten
/// Mausereignissen wie der Zuschneiden-Modus. So fällt insbesondere auf,
/// wenn der bestehende Doppelklick für Bilder versehentlich Text übernimmt.
@MainActor
final class CanvasTextEditingTests: XCTestCase {

    private final class Protokoll: CanvasInteractionDelegate {
        let document: AssemblageDocument
        var abgeschlosseneTexte: [String] = []

        init(document: AssemblageDocument) { self.document = document }

        func canvasView(_ canvasView: CanvasView, didSelectLayerWithID id: UUID?) {
            document.state.selectedLayerID = id
        }
        func canvasViewDidBeginInteraction(_ canvasView: CanvasView) {}
        func canvasView(_ canvasView: CanvasView, didChangeLayerWithID id: UUID, to transform: Transform2D) {}
        func canvasView(_ canvasView: CanvasView, didEndInteractionNamed actionName: String) {}
        func canvasView(_ canvasView: CanvasView, didReceiveDropFrom pasteboard: NSPasteboard) {}
        func canvasView(_ canvasView: CanvasView, didChangeCropOfLayerWithID id: UUID, to crop: Rect) {}
        func canvasView(_ canvasView: CanvasView, didPaintMaskForLayerWithID id: UUID, pngData: Data) {}

        func canvasView(_ canvasView: CanvasView, didFinishEditingTextOfLayerWithID id: UUID, text: String) {
            abgeschlosseneTexte.append(text)
            document.modify("Text bearbeiten") {
                try? $0.updateLayer(id: id) { ebene in
                    guard case .text(var inhalt) = ebene.content else { return }
                    inhalt.string = text
                    ebene.content = .text(inhalt)
                }
            }
        }
    }

    private final class Tastenprotokoll: CanvasKeyboardCommandDelegate {
        var befehle: [KeyboardCommand] = []
        func canvasView(_ canvasView: CanvasView, perform command: KeyboardCommand) -> Bool {
            befehle.append(command)
            return true
        }
    }

    private var document: AssemblageDocument!
    private var fenster: NSWindow!
    private var canvas: CanvasView!
    private var protokoll: Protokoll!
    private var textID: UUID!
    private var bildID: UUID!

    override func setUpWithError() throws {
        let kontext = try XCTUnwrap(CGContext(
            data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        kontext.setFillColor(NSColor.red.cgColor)
        kontext.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let png = try XCTUnwrap(
            NSBitmapImageRep(cgImage: try XCTUnwrap(kontext.makeImage()))
                .representation(using: .png, properties: [:])
        )

        document = AssemblageDocument()
        document.undoManager = UndoManager()
        let referenz = document.state.resources.addOriginal(png, fileExtension: "png")
        let text = Layer(
            name: "Titel",
            transform: Transform2D(x: 160, y: 120, scaleX: 1.5, scaleY: 1.5),
            content: .text(TextLayerContent(
                string: "Assemblage", fontName: "Helvetica", fontSize: 32,
                colorHex: "#336699", alignment: .center
            ))
        )
        let bild = Layer(
            name: "Bild",
            transform: Transform2D(x: 320, y: 300),
            content: .image(ImageLayerContent(originalFileReference: referenz))
        )
        textID = text.id
        bildID = bild.id
        document.modify("Vorbereiten") { $0.layers = [text, bild] }
        document.undoManager?.removeAllActions()

        canvas = CanvasView(document: document.state.document, images: document.state.images)
        protokoll = Protokoll(document: document)
        canvas.interactionDelegate = protokoll
        fenster = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        fenster.contentView = canvas
        canvas.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        fenster.makeKeyAndOrderFront(nil)
    }

    override func tearDown() {
        fenster?.orderOut(nil)
    }

    private func mausereignis(
        _ typ: NSEvent.EventType,
        atCanvasX x: Double,
        y: Double,
        klicks: Int = 1
    ) throws -> NSEvent {
        let inView = NSPoint(x: x, y: Double(canvas.bounds.height) - y)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: typ, location: canvas.convert(inView, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: fenster.windowNumber, context: nil,
            eventNumber: 0, clickCount: klicks, pressure: 1
        ))
    }

    private func doppelklickAufText() throws {
        canvas.mouseDown(with: try mausereignis(.leftMouseDown, atCanvasX: 160, y: 120, klicks: 2))
    }

    func testDoubleClickOnTextLayerOpensMatchingEditorAndHidesRenderedLayer() throws {
        try doppelklickAufText()

        let editor = try XCTUnwrap(canvas.textEditorForTesting)
        XCTAssertEqual(editor.string, "Assemblage")
        XCTAssertEqual(editor.font?.fontName, "Helvetica")
        XCTAssertEqual(try XCTUnwrap(editor.font).pointSize, 48, accuracy: 0.01, "die Ebenenskalierung gilt auch für die Eingabeschrift")
        let farbe = try XCTUnwrap(editor.textColor?.usingColorSpace(NSColorSpace.sRGB))
        XCTAssertEqual(farbe.redComponent, 0.2, accuracy: 0.01)
        XCTAssertTrue(canvas.isRenderedLayerHiddenForTesting(textID), "Text darf nicht doppelt erscheinen")
        XCTAssertIdentical(fenster.firstResponder, editor)
    }

    func testDoubleClickOnImageDoesNotOpenEditorAndStillEntersCropMode() throws {
        canvas.mouseDown(with: try mausereignis(.leftMouseDown, atCanvasX: 320, y: 300, klicks: 2))

        XCTAssertNil(canvas.textEditorForTesting)
        XCTAssertEqual(canvas.croppingLayerID, bildID)
    }

    func testEscapeDiscardsText() throws {
        try doppelklickAufText()
        canvas.textEditorForTesting?.string = "Verworfen"

        canvas.cancelOperation(nil)

        XCTAssertNil(canvas.textEditorForTesting)
        XCTAssertTrue(protokoll.abgeschlosseneTexte.isEmpty)
        guard case .text(let inhalt) = document.state.document.layer(withID: textID)?.content else {
            return XCTFail("Textebene fehlt")
        }
        XCTAssertEqual(inhalt.string, "Assemblage")
        XCTAssertFalse(canvas.isRenderedLayerHiddenForTesting(textID))
    }

    func testReturnCommitsAsExactlyOneUndoStep() throws {
        try doppelklickAufText()
        let editor = try XCTUnwrap(canvas.textEditorForTesting)
        editor.string = "Neuer Titel"

        XCTAssertTrue(canvas.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))

        guard case .text(let neu) = document.state.document.layer(withID: textID)?.content else {
            return XCTFail("Textebene fehlt")
        }
        XCTAssertEqual(neu.string, "Neuer Titel")
        XCTAssertEqual(document.undoManager?.undoActionName, "Text bearbeiten")
        document.undoManager?.undo()
        guard case .text(let alt) = document.state.document.layer(withID: textID)?.content else {
            return XCTFail("Textebene fehlt nach Widerrufen")
        }
        XCTAssertEqual(alt.string, "Assemblage")
        XCTAssertFalse(document.undoManager?.canUndo ?? true, "die ganze Bearbeitung ist genau ein Schritt")
    }

    func testToolKeysDoNotFireWhileCanvasEditorIsFirstResponder() throws {
        let tasten = Tastenprotokoll()
        canvas.keyboardCommandDelegate = tasten
        try doppelklickAufText()
        XCTAssertNotNil(canvas.textEditorForTesting)

        let ereignis = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: fenster.windowNumber, context: nil,
            characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11
        ))
        canvas.keyDown(with: ereignis)

        XCTAssertTrue(tasten.befehle.isEmpty, "b darf beim Tippen nicht das Pinselwerkzeug wählen")
    }

    func testDoubleClickOnEmptyCanvasCommitsOpenEditor() throws {
        try doppelklickAufText()
        canvas.textEditorForTesting?.string = "Abgeschlossen"

        canvas.mouseDown(with: try mausereignis(.leftMouseDown, atCanvasX: 20, y: 20, klicks: 2))

        XCTAssertNil(canvas.textEditorForTesting)
        XCTAssertEqual(protokoll.abgeschlosseneTexte, ["Abgeschlossen"])
    }

    func testDistortedTextDoesNotOpenAnEditor() throws {
        document.modify("Verziehen") {
            try? $0.updateLayer(id: self.textID) {
                $0.distortion = QuadDistortion(topLeft: Point(x: 8, y: 4))
            }
        }
        canvas.update(to: document.state.document)

        try doppelklickAufText()

        XCTAssertNil(canvas.textEditorForTesting, "ein rechteckiges Feld kann eine projektive Verzerrung nicht ehrlich abbilden")
    }

    func testDeletingEditedLayerClosesEditorWithoutCommitting() throws {
        try doppelklickAufText()
        canvas.textEditorForTesting?.string = "Darf nicht zurückbleiben"
        document.modify("Ebene löschen") { _ = try? $0.removeLayer(id: self.textID) }

        canvas.update(to: document.state.document)

        XCTAssertNil(canvas.textEditorForTesting)
        XCTAssertTrue(protokoll.abgeschlosseneTexte.isEmpty)
    }
}
