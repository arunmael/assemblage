import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

@MainActor
final class CollageTemplateCommandTests: XCTestCase {

    func testAnwendenIstEinUndoSchrittUndWirdVollstaendigZurueckgenommen() {
        let (document, bilder) = dokumentMitBildern(4)
        let vorher = document.state.document
        let undoManager = UndoManager()
        document.undoManager = undoManager

        CollageTemplateCommand.apply(.grid2x2, to: document.state) { _ in
            Size(width: 1_600, height: 1_200)
        }

        XCTAssertNotEqual(document.state.document, vorher)
        XCTAssertTrue(undoManager.canUndo)
        for bild in bilder {
            XCTAssertNotEqual(document.state.document.layer(withID: bild.id)?.transform, bild.transform)
        }

        undoManager.undo()

        XCTAssertEqual(document.state.document, vorher)
        XCTAssertFalse(undoManager.canUndo, "Die ganze Vorlage muss genau ein Undo-Schritt sein")
    }

    func testTextFormUndUnsichtbaresBildBleibenUnveraendert() {
        let (document, _) = dokumentMitBildern(2)
        let text = Layer(
            name: "Titel",
            transform: Transform2D(x: 41, y: 42, rotationDegrees: 7),
            content: .text(TextLayerContent(string: "Hallo"))
        )
        let form = Layer(
            name: "Rahmen",
            transform: Transform2D(x: 51, y: 52, scaleX: 2, scaleY: 3),
            content: .shape(ShapeLayerContent(
                kind: .rectangle,
                size: Size(width: 100, height: 80)
            ))
        )
        let verborgen = bild(index: 99, sichtbar: false)
        document.modify("Weitere Ebenen") {
            _ = try? $0.addLayer(text)
            _ = try? $0.addLayer(form)
            _ = try? $0.addLayer(verborgen)
        }
        let vorher = document.state.document

        CollageTemplateCommand.apply(.grid2x2, to: document.state) { _ in
            Size(width: 800, height: 600)
        }

        XCTAssertEqual(document.state.document.layer(withID: text.id), vorher.layer(withID: text.id))
        XCTAssertEqual(document.state.document.layer(withID: form.id), vorher.layer(withID: form.id))
        XCTAssertEqual(document.state.document.layer(withID: verborgen.id), vorher.layer(withID: verborgen.id))
    }

    func testUeberzaehligeBilderBleibenUnveraendert() {
        let (document, bilder) = dokumentMitBildern(6)
        let vorher = document.state.document

        CollageTemplateCommand.apply(.grid2x2, to: document.state) { _ in
            Size(width: 800, height: 600)
        }

        for bild in bilder.prefix(4) {
            XCTAssertNotEqual(document.state.document.layer(withID: bild.id), vorher.layer(withID: bild.id))
        }
        for bild in bilder.dropFirst(4) {
            XCTAssertEqual(document.state.document.layer(withID: bild.id), vorher.layer(withID: bild.id))
        }
    }

    func testOhneSichtbareBildebenenPassiertNichts() {
        let document = AssemblageDocument()
        let text = Layer(name: "Text", content: .text(TextLayerContent(string: "Nur Text")))
        document.modify("Text einsetzen") { _ = try? $0.addLayer(text) }
        let vorher = document.state.document
        let undoManager = UndoManager()
        document.undoManager = undoManager

        XCTAssertFalse(CollageTemplateCommand.canApply(to: document.state))
        CollageTemplateCommand.apply(.grid3x3, to: document.state) { _ in
            XCTFail("Für Nicht-Bildebenen darf keine Bildgrösse angefordert werden")
            return nil
        }

        XCTAssertEqual(document.state.document, vorher)
        XCTAssertFalse(undoManager.canUndo)
    }

    func testSichtbareBilderWerdenInBestehenderReihenfolgeAngeordnet() throws {
        let (document, bilder) = dokumentMitBildern(3)

        CollageTemplateCommand.apply(.grid2x2, to: document.state) { _ in
            Size(width: 1_000, height: 1_000)
        }

        for (index, bild) in bilder.enumerated() {
            let erwartet = try XCTUnwrap(CollageTemplate.grid2x2.placement(
                forIndex: index,
                contentSize: Size(width: 1_000, height: 1_000),
                canvas: document.state.document.canvas
            ))
            XCTAssertEqual(document.state.document.layer(withID: bild.id)?.transform, erwartet.transform)
        }
    }

    func testEinfuegenMenueEnthaeltGenauDieDreiKuratiertenVorlagen() throws {
        let vorherigesMenue = NSApp.mainMenu
        defer { NSApp.mainMenu = vorherigesMenue }
        AppDelegate().applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        let einfuegen = try XCTUnwrap(NSApp.mainMenu?.items.first {
            $0.submenu?.title == "Einfügen"
        }?.submenu)
        let vorlagen = try XCTUnwrap(einfuegen.items.first {
            $0.title == "Collage-Vorlage"
        }?.submenu)

        XCTAssertEqual(vorlagen.items.map(\.title), [
            "2×2-Raster",
            "3×3-Raster",
            "Polaroid-Stapel"
        ])
    }

    func testAlleVorlagenMenuepunkteSindOhneSichtbaresBildDeaktiviert() {
        let document = AssemblageDocument()
        document.makeWindowControllers()
        guard let controller = document.windowControllers.first as? DocumentWindowController else {
            return XCTFail("Das Dokument braucht seinen Fenstercontroller")
        }
        let actions = [
            #selector(DocumentWindowController.applyGrid2x2Template(_:)),
            #selector(DocumentWindowController.applyGrid3x3Template(_:)),
            #selector(DocumentWindowController.applyPolaroidStackTemplate(_:))
        ]

        for action in actions {
            let item = NSMenuItem(title: "Vorlage", action: action, keyEquivalent: "")
            XCTAssertFalse(controller.validateMenuItem(item))
        }
    }

    private func dokumentMitBildern(_ anzahl: Int) -> (AssemblageDocument, [Layer]) {
        let document = AssemblageDocument()
        let bilder = (0..<anzahl).map { bild(index: $0) }
        document.modify("Testbilder einsetzen") { dokument in
            for bild in bilder { _ = try? dokument.addLayer(bild) }
        }
        return (document, bilder)
    }

    private func bild(index: Int, sichtbar: Bool = true) -> Layer {
        Layer(
            name: "Bild \(index)",
            isVisible: sichtbar,
            transform: Transform2D(
                x: Double(20 + index),
                y: Double(30 + index),
                scaleX: 0.5,
                scaleY: 0.75,
                rotationDegrees: Double(index)
            ),
            content: .image(ImageLayerContent(
                originalFileReference: "originals/bild-\(index).png"
            ))
        )
    }
}
