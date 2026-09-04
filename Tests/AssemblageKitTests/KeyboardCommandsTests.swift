import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Tastenkürzel für Power-User (Plan 9, Phase 4).
///
/// Die Übersetzung Taste → Befehl liegt bewusst getrennt von der
/// Ereignisbehandlung: Eine Tastatur lässt sich nicht automatisiert bedienen,
/// diese Zuordnung schon.
@MainActor
final class KeyboardCommandsTests: XCTestCase {

    private func befehl(
        _ zeichen: String,
        _ modifiers: NSEvent.ModifierFlags = [],
        tippt: Bool = false
    ) -> KeyboardCommand? {
        KeyboardCommands.command(forCharacters: zeichen, modifiers: modifiers, isEditingText: tippt)
    }

    // MARK: - Werkzeugwechsel

    func testToolKeysFollowTheUsualConvention() {
        XCTAssertEqual(befehl("v"), .selectTool(.select))
        XCTAssertEqual(befehl("c"), .selectTool(.crop))
        XCTAssertEqual(befehl("b"), .selectTool(.brush))
    }

    func testToolKeysAreCaseInsensitive() {
        XCTAssertEqual(befehl("V"), .selectTool(.select))
    }

    /// **Der wichtigste Test.** Ohne diesen Schutz wechselt beim Schreiben
    /// eines Titels mit jedem „b" das Werkzeug.
    func testNoCommandsWhileTypingText() {
        for zeichen in ["v", "c", "b", "1", "0"] {
            XCTAssertNil(befehl(zeichen, tippt: true), "Taste \(zeichen) darf beim Tippen nichts auslösen")
        }
        XCTAssertNil(befehl(String(UnicodeScalar(NSUpArrowFunctionKey)!), tippt: true))
    }

    /// Mit Befehlstaste gehören die Tasten dem Menü — ⌘V ist Einsetzen und
    /// darf nicht das Werkzeug wechseln.
    func testModifiedKeysAreLeftToTheMenu() {
        XCTAssertNil(befehl("v", .command))
        XCTAssertNil(befehl("0", .command), "⌘0 ist Originalgrösse")
        XCTAssertNil(befehl("c", [.command, .shift]))
    }

    // MARK: - Pfeiltasten

    /// y wächst nach unten — ein vertauschtes Vorzeichen muss hier auffallen.
    func testArrowKeysNudgeInTheRightDirection() {
        XCTAssertEqual(befehl(String(UnicodeScalar(NSLeftArrowFunctionKey)!)), .nudge(dx: -1, dy: 0))
        XCTAssertEqual(befehl(String(UnicodeScalar(NSRightArrowFunctionKey)!)), .nudge(dx: 1, dy: 0))
        XCTAssertEqual(befehl(String(UnicodeScalar(NSUpArrowFunctionKey)!)), .nudge(dx: 0, dy: -1))
        XCTAssertEqual(befehl(String(UnicodeScalar(NSDownArrowFunctionKey)!)), .nudge(dx: 0, dy: 1))
    }

    func testShiftNudgesFurther() {
        XCTAssertEqual(
            befehl(String(UnicodeScalar(NSRightArrowFunctionKey)!), .shift),
            .nudge(dx: 10, dy: 0)
        )
    }

    // MARK: - Deckkraft

    func testDigitsSetOpacity() {
        XCTAssertEqual(befehl("1"), .setOpacity(0.1))
        XCTAssertEqual(befehl("5"), .setOpacity(0.5))
        XCTAssertEqual(befehl("9"), .setOpacity(0.9))
        XCTAssertEqual(befehl("0"), .setOpacity(1), "0 steht für volle Deckkraft")
    }

    func testUnknownKeysDoNothing() {
        XCTAssertNil(befehl("q"))
        XCTAssertNil(befehl(""))
    }

    // MARK: - Ausführen

    private func dokumentMitEbene() -> (AssemblageDocument, UUID, UndoManager) {
        let document = AssemblageDocument()
        let undoManager = UndoManager()
        document.undoManager = undoManager
        let ebene = Layer(
            name: "Foto",
            transform: Transform2D(x: 100, y: 100),
            content: .shape(ShapeLayerContent(kind: .rectangle, size: Size(width: 50, height: 50)))
        )
        document.modify("Anlegen") { try? $0.addLayer(ebene) }
        document.state.selectedLayerID = ebene.id
        undoManager.removeAllActions()
        return (document, ebene.id, undoManager)
    }

    func testPerformWithoutSelectionChangesNothing() {
        let document = AssemblageDocument()
        let vorher = document.state.document

        KeyboardCommands.perform(.nudge(dx: 5, dy: 5), in: document.state)
        KeyboardCommands.perform(.setOpacity(0.5), in: document.state)

        XCTAssertEqual(document.state.document, vorher)
    }

    func testNudgeMovesTheSelectedLayerAndIsUndoable() {
        let (document, id, undoManager) = dokumentMitEbene()

        KeyboardCommands.perform(.nudge(dx: 10, dy: -3), in: document.state)

        XCTAssertEqual(document.state.document.layer(withID: id)?.transform.x, 110)
        XCTAssertEqual(document.state.document.layer(withID: id)?.transform.y, 97)

        document.endInteraction(actionName: "Ebene bewegen")
        undoManager.undo()
        XCTAssertEqual(document.state.document.layer(withID: id)?.transform.x, 100)
    }

    func testOpacityCommandIsClamped() {
        let (document, id, _) = dokumentMitEbene()

        KeyboardCommands.perform(.setOpacity(1), in: document.state)

        XCTAssertEqual(document.state.document.layer(withID: id)?.opacity, 1)
    }

    /// Zehnmal die Pfeiltaste drücken darf nicht zehn Undo-Schritte ergeben —
    /// sonst muss man zehnmal widerrufen, um eine Bewegung zurückzunehmen.
    func testRapidNudgesFormASingleUndoStep() {
        let (document, id, undoManager) = dokumentMitEbene()
        let start = Date()

        for schritt in 0..<10 {
            document.modifyCoalescing(
                "Ebene bewegen",
                at: start.addingTimeInterval(Double(schritt) * 0.05)
            ) {
                try? $0.updateLayer(id: id) { $0.transform.x += 1 }
            }
        }
        document.endInteraction(actionName: "Ebene bewegen")

        XCTAssertEqual(document.state.document.layer(withID: id)?.transform.x, 110)
        undoManager.undo()
        XCTAssertEqual(document.state.document.layer(withID: id)?.transform.x, 100)
        XCTAssertFalse(undoManager.canUndo, "ein einziger Schritt")
    }

    /// Nach einer Pause beginnt ein neuer Schritt — sonst liesse sich eine
    /// halbe Stunde Arbeit nur am Stück zurücknehmen.
    ///
    /// Geprüft wird der Schnappschuss, auf den ein Widerrufen zurückführen
    /// würde, und nicht die Anzahl der Schritte im `NSUndoManager`: Der fasst
    /// von sich aus alles eines Ereignisses zusammen, und in einem synchronen
    /// Test ist alles dasselbe Ereignis. Der Test prüfte dann AppKit statt
    /// unser Zusammenfassen.
    func testNudgeAfterAPauseStartsANewUndoStep() throws {
        let (document, id, _) = dokumentMitEbene()
        let start = Date()

        document.modifyCoalescing("Ebene bewegen", at: start) {
            try? $0.updateLayer(id: id) { $0.transform.x += 5 }
        }
        let ersterSchnappschuss = try XCTUnwrap(document.interactionSnapshot)
        XCTAssertEqual(ersterSchnappschuss.layer(withID: id)?.transform.x, 100)

        // Kurz danach: derselbe Schritt, der Schnappschuss bleibt.
        document.modifyCoalescing("Ebene bewegen", at: start.addingTimeInterval(0.1)) {
            try? $0.updateLayer(id: id) { $0.transform.x += 5 }
        }
        XCTAssertEqual(
            document.interactionSnapshot?.layer(withID: id)?.transform.x, 100,
            "dicht aufeinander folgende Drücke gehören zusammen"
        )

        // Deutlich später: ein neuer Schritt, also ein neuer Schnappschuss.
        document.modifyCoalescing("Ebene bewegen", at: start.addingTimeInterval(5)) {
            try? $0.updateLayer(id: id) { $0.transform.x += 5 }
        }
        XCTAssertEqual(
            document.interactionSnapshot?.layer(withID: id)?.transform.x, 110,
            "nach der Pause führt ein Widerrufen nur bis hierher zurück"
        )
        XCTAssertEqual(document.state.document.layer(withID: id)?.transform.x, 115)
    }
}
