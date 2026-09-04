import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

@MainActor
final class LayerOrderCommandsTests: XCTestCase {

    private final class Tastaturziel: CanvasKeyboardCommandDelegate {
        let state: DocumentState
        var empfangen: [KeyboardCommand] = []

        init(state: DocumentState) {
            self.state = state
        }

        func canvasView(_ canvasView: CanvasView, perform command: KeyboardCommand) -> Bool {
            empfangen.append(command)
            KeyboardCommands.perform(command, in: state)
            return true
        }
    }

    private func ebene(_ name: String, x: Double = 0) -> Layer {
        Layer(
            name: name,
            transform: Transform2D(x: x, y: 20),
            content: .shape(
                ShapeLayerContent(kind: .rectangle, size: Size(width: 40, height: 40))
            )
        )
    }

    private func dokument(
        mit ebenen: [Layer],
        auswahl: UUID?
    ) -> (AssemblageDocument, LayerListEditing, UndoManager) {
        let document = AssemblageDocument()
        let undoManager = UndoManager()
        document.undoManager = undoManager
        document.modify("Test vorbereiten") { $0.layers = ebenen }
        document.state.selectedLayerID = auswahl
        undoManager.removeAllActions()
        return (document, LayerListEditing(state: document.state), undoManager)
    }

    func testEinePositionNachObenBedeutetEinenHoeherenModellindex() {
        let ebenen = [ebene("A"), ebene("B"), ebene("C"), ebene("D")]
        let (document, editing, _) = dokument(mit: ebenen, auswahl: ebenen[1].id)

        editing.moveSelected(.up)

        XCTAssertEqual(document.state.document.layers.map(\.name), ["A", "C", "B", "D"])
    }

    func testEinePositionNachUntenBedeutetEinenTieferenModellindex() {
        let ebenen = [ebene("A"), ebene("B"), ebene("C"), ebene("D")]
        let (document, editing, _) = dokument(mit: ebenen, auswahl: ebenen[2].id)

        editing.moveSelected(.down)

        XCTAssertEqual(document.state.document.layers.map(\.name), ["A", "C", "B", "D"])
    }

    func testGanzNachObenUndGanzNachUntenVerwendenDieEndenDesModells() {
        let ebenen = [ebene("A"), ebene("B"), ebene("C"), ebene("D")]
        let (nachOben, obenEditing, _) = dokument(mit: ebenen, auswahl: ebenen[1].id)
        let (nachUnten, untenEditing, _) = dokument(mit: ebenen, auswahl: ebenen[2].id)

        obenEditing.moveSelected(.toTop)
        untenEditing.moveSelected(.toBottom)

        XCTAssertEqual(nachOben.state.document.layers.map(\.name), ["A", "C", "D", "B"])
        XCTAssertEqual(nachUnten.state.document.layers.map(\.name), ["C", "A", "B", "D"])
    }

    func testGrenzenSindWirkungslosUndStuerzenNichtAb() {
        let ebenen = [ebene("Unten"), ebene("Mitte"), ebene("Oben")]
        let (oben, obenEditing, obenUndo) = dokument(mit: ebenen, auswahl: ebenen[2].id)
        let (unten, untenEditing, untenUndo) = dokument(mit: ebenen, auswahl: ebenen[0].id)

        obenEditing.moveSelected(.up)
        untenEditing.moveSelected(.down)

        XCTAssertEqual(oben.state.document.layers, ebenen)
        XCTAssertEqual(unten.state.document.layers, ebenen)
        XCTAssertFalse(obenUndo.canUndo)
        XCTAssertFalse(untenUndo.canUndo)
    }

    func testJederReihenfolgebefehlIstEinUndoSchrittUndVollstaendigWiderrufbar() {
        let faelle: [(LayerOrderCommand, Int, String)] = [
            (.up, 1, "Ebene nach oben"),
            (.down, 2, "Ebene nach unten"),
            (.toTop, 1, "Ebene ganz nach oben"),
            (.toBottom, 2, "Ebene ganz nach unten")
        ]

        for (command, selectedIndex, actionName) in faelle {
            let ebenen = [ebene("A"), ebene("B"), ebene("C"), ebene("D")]
            let (document, editing, undoManager) = dokument(
                mit: ebenen,
                auswahl: ebenen[selectedIndex].id
            )

            editing.moveSelected(command)

            XCTAssertEqual(undoManager.undoActionName, actionName)
            undoManager.undo()
            XCTAssertEqual(document.state.document.layers, ebenen)
            XCTAssertFalse(undoManager.canUndo, "\(actionName) muss genau ein Undo-Schritt sein")
        }
    }

    func testOhneAuswahlPassiertBeiKeinemReihenfolgebefehlEtwas() {
        let ebenen = [ebene("A"), ebene("B"), ebene("C")]
        let (document, editing, undoManager) = dokument(mit: ebenen, auswahl: nil)

        for command in LayerOrderCommand.allCases {
            editing.moveSelected(command)
        }

        XCTAssertEqual(document.state.document.layers, ebenen)
        XCTAssertFalse(undoManager.canUndo)
    }

    func testPfeiltasteAmCanvasVerschiebtDieAusgewaehlteEbene() throws {
        let layer = ebene("Foto", x: 50)
        let (document, _, _) = dokument(mit: [layer], auswahl: layer.id)
        let canvas = CanvasView(document: document.state.document, images: document.state.images)
        let ziel = Tastaturziel(state: document.state)
        canvas.keyboardCommandDelegate = ziel
        let fenster = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        fenster.contentView?.addSubview(canvas)

        canvas.keyDown(with: try tastenEreignis("\u{F703}", keyCode: 124, window: fenster))

        XCTAssertEqual(document.state.document.layer(withID: layer.id)?.transform.x, 51)
        XCTAssertEqual(ziel.empfangen, [.nudge(dx: 1, dy: 0)])
    }

    func testNichtBelegteTasteAmCanvasAendertNichts() throws {
        let layer = ebene("Foto", x: 50)
        let (document, _, _) = dokument(mit: [layer], auswahl: layer.id)
        let canvas = CanvasView(document: document.state.document, images: document.state.images)
        let ziel = Tastaturziel(state: document.state)
        canvas.keyboardCommandDelegate = ziel
        let fenster = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        fenster.contentView?.addSubview(canvas)

        canvas.keyDown(with: try tastenEreignis("k", keyCode: 40, window: fenster))

        XCTAssertEqual(document.state.document.layer(withID: layer.id)?.transform.x, 50)
        XCTAssertTrue(ziel.empfangen.isEmpty)
    }

    func testFeldeditorImSelbenFensterBlockiertCanvasBefehle() throws {
        let layer = ebene("Foto", x: 50)
        let (document, _, _) = dokument(mit: [layer], auswahl: layer.id)
        let canvas = CanvasView(document: document.state.document, images: document.state.images)
        let ziel = Tastaturziel(state: document.state)
        canvas.keyboardCommandDelegate = ziel
        let fenster = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        fenster.contentView?.addSubview(canvas)
        fenster.contentView?.addSubview(textView)
        XCTAssertTrue(fenster.makeFirstResponder(textView))

        canvas.keyDown(with: try tastenEreignis("b", keyCode: 11, window: fenster))

        XCTAssertTrue(ziel.empfangen.isEmpty)
    }

    func testWerkzeugtasteAmCanvasErreichtDasZustaendigeZiel() throws {
        let layer = ebene("Foto")
        let (document, _, _) = dokument(mit: [layer], auswahl: layer.id)
        let canvas = CanvasView(document: document.state.document, images: document.state.images)
        let ziel = Tastaturziel(state: document.state)
        canvas.keyboardCommandDelegate = ziel
        let fenster = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        fenster.contentView?.addSubview(canvas)

        canvas.keyDown(with: try tastenEreignis("b", keyCode: 11, window: fenster))

        XCTAssertEqual(ziel.empfangen, [.selectTool(.brush)])
    }

    func testEbenenmenueEnthaeltAlleBefehleMitKollisionsfreienKuerzeln() throws {
        let vorherigesMenue = NSApp.mainMenu
        defer { NSApp.mainMenu = vorherigesMenue }
        AppDelegate().applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        let menue = try XCTUnwrap(NSApp.mainMenu?.items.first {
            $0.submenu?.title == "Ebene"
        }?.submenu)
        let befehle = Dictionary(uniqueKeysWithValues: menue.items
            .filter { !$0.isSeparatorItem }
            .map { ($0.title, ($0.keyEquivalent, $0.keyEquivalentModifierMask)) })

        XCTAssertEqual(befehle["Ebene ein-/ausblenden"]?.0, "h")
        XCTAssertEqual(befehle["Ebene ein-/ausblenden"]?.1, [.command, .shift])
        XCTAssertEqual(befehle["Ebene löschen"]?.0, "\u{8}")
        XCTAssertEqual(befehle["Ebene löschen"]?.1, [.command, .shift])
        XCTAssertEqual(befehle["Ebene nach oben"]?.0, "]")
        XCTAssertEqual(befehle["Ebene nach oben"]?.1, [.command])
        XCTAssertEqual(befehle["Ebene nach unten"]?.0, "[")
        XCTAssertEqual(befehle["Ebene nach unten"]?.1, [.command])
        XCTAssertEqual(befehle["Ebene ganz nach oben"]?.1, [.command, .shift])
        XCTAssertEqual(befehle["Ebene ganz nach unten"]?.1, [.command, .shift])
    }

    func testAlleEbenenbefehleSindOhneAuswahlDeaktiviert() {
        let document = AssemblageDocument()
        document.makeWindowControllers()
        guard let controller = document.windowControllers.first as? DocumentWindowController else {
            return XCTFail("Das Dokument braucht seinen Fenstercontroller")
        }
        let actions = [
            #selector(DocumentWindowController.toggleSelectedLayerVisibility(_:)),
            #selector(DocumentWindowController.deleteSelectedLayer(_:)),
            #selector(DocumentWindowController.moveSelectedLayerUp(_:)),
            #selector(DocumentWindowController.moveSelectedLayerDown(_:)),
            #selector(DocumentWindowController.moveSelectedLayerToTop(_:)),
            #selector(DocumentWindowController.moveSelectedLayerToBottom(_:))
        ]

        for action in actions {
            let item = NSMenuItem(title: "Ebene", action: action, keyEquivalent: "")
            XCTAssertFalse(controller.validateMenuItem(item))
        }
    }

    private func tastenEreignis(
        _ characters: String,
        keyCode: UInt16,
        window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
