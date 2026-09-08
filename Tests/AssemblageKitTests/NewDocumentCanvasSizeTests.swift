import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Ein frisch angelegtes Dokument fragt sofort nach der Leinwandgrösse
/// (Nutzer-Auftrag), ein geöffnetes nicht — das bringt seine Grösse mit.
///
/// Geprüft wird am angehängten Sheet des Fensters statt an der Oberfläche des
/// Dialogs: Das ist der beobachtbare Unterschied und braucht keine
/// UI-Automation.
@MainActor
final class NewDocumentCanvasSizeTests: XCTestCase {

    /// Räumt ein offenes Sheet wieder ab, damit es nicht in den nächsten Test
    /// hineinragt.
    private func closeSheet(of window: NSWindow) {
        if let sheet = window.attachedSheet {
            window.endSheet(sheet)
        }
    }

    private func makeShownDocument() throws -> (AssemblageDocument, NSWindow) {
        let document = AssemblageDocument()
        document.makeWindowControllers()
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        document.showWindows()
        return (document, window)
    }

    /// Die Vorlagenliste, wie sie im Menü steht. A4 muss es in beiden
    /// Ausrichtungen geben (ausdrücklicher Nutzer-Auftrag), und zwar mit den
    /// Massen im Titel — sonst müsste man jede Vorlage erst auswählen, um zu
    /// sehen, was sie bedeutet.
    func testPresetMenuOffersA4InBothOrientations() {
        let titel = CanvasPreset.selectable.map(CanvasResizePanelLogic.menuTitle(for:))
        XCTAssertTrue(titel.contains { $0.hasPrefix("A4 hoch") && $0.contains("2480 × 3508") }, "\(titel)")
        XCTAssertTrue(titel.contains { $0.hasPrefix("A4 quer") && $0.contains("3508 × 2480") }, "\(titel)")
    }

    func testNewDocumentAsksForTheCanvasSize() throws {
        let (_, window) = try makeShownDocument()
        defer { closeSheet(of: window) }

        XCTAssertNotNil(
            window.attachedSheet,
            "ein neues Dokument muss nach der Leinwandgrösse fragen"
        )
    }

    /// Der Dialog darf genau einmal kommen. Ohne das zurückgesetzte
    /// Kennzeichen erschiene er bei jedem erneuten Anzeigen des Fensters
    /// wieder — etwa beim Klick aufs Dock-Symbol.
    func testTheQuestionIsAskedOnlyOnce() throws {
        let (document, window) = try makeShownDocument()
        closeSheet(of: window)

        document.showWindows()
        XCTAssertNil(
            window.attachedSheet,
            "die Frage nach der Leinwandgrösse darf sich nicht wiederholen"
        )
    }

    /// Ein aus einer Datei gelesenes Dokument hat seine Grösse schon — es darf
    /// beim Öffnen nicht danach gefragt werden. Dasselbe gilt für eine Kopie
    /// („Duplizieren"), die ebenfalls über `read` entsteht.
    func testOpenedDocumentDoesNotAsk() throws {
        var geladen = AssemblageModel.Document(preset: .a4Landscape)
        geladen.canvas = CanvasSize(width: 640, height: 480)
        let paket = FileWrapper(directoryWithFileWrappers: [
            DocumentPackage.documentFileName: FileWrapper(
                regularFileWithContents: try DocumentPackage.encode(geladen)
            )
        ])

        let document = AssemblageDocument()
        try document.read(from: paket, ofType: AssemblageDocument.fileType)
        document.makeWindowControllers()
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        document.showWindows()
        defer { closeSheet(of: window) }

        XCTAssertNil(
            window.attachedSheet,
            "ein geöffnetes Dokument bringt seine Leinwandgrösse mit"
        )
    }
}
