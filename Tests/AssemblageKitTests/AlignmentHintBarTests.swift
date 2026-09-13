import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

@MainActor
final class AlignmentHintBarTests: XCTestCase {

    func testDieAusrichtungslinienSindSystemblau() throws {
        let canvas = makeCanvas()
        let tatsaechlich = try XCTUnwrap(
            NSColor(cgColor: try XCTUnwrap(canvas.guideLayerForTesting.strokeColor))?
                .usingColorSpace(.deviceRGB)
        )
        let erwartet = try XCTUnwrap(NSColor.systemBlue.usingColorSpace(.deviceRGB))

        XCTAssertEqual(tatsaechlich.redComponent, erwartet.redComponent, accuracy: 0.001)
        XCTAssertEqual(tatsaechlich.greenComponent, erwartet.greenComponent, accuracy: 0.001)
        XCTAssertEqual(tatsaechlich.blueComponent, erwartet.blueComponent, accuracy: 0.001)
        XCTAssertEqual(tatsaechlich.alphaComponent, erwartet.alphaComponent, accuracy: 0.001)
    }

    func testDieHinweispilleHaengtUntenInDerFenstermitte() throws {
        let document = AssemblageDocument()
        document.makeWindowControllers()
        let windowController = try XCTUnwrap(
            document.windowControllers.first as? DocumentWindowController
        )
        let window = try XCTUnwrap(windowController.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 820), display: false)
        let huelle = try XCTUnwrap(
            windowController.contentViewController as? WindowDropZoneViewController
        )
        let stage = try XCTUnwrap(huelle.children.first as? DocumentStageViewController)
        let container = stage.view
        window.contentView?.layoutSubtreeIfNeeded()
        let pille = try XCTUnwrap(stage.alignmentHintBar)

        let mitte = try XCTUnwrap(container.constraints.first {
            ($0.firstItem as? NSView) === pille
                && $0.firstAttribute == .centerX
                && ($0.secondItem as? NSView) === container
                && $0.secondAttribute == .centerX
        })
        let unten = try XCTUnwrap(container.constraints.first {
            ($0.firstItem as? NSView) === pille
                && $0.firstAttribute == .bottom
                && ($0.secondItem as? NSView) === container
                && $0.secondAttribute == .bottom
        })

        XCTAssertEqual(mitte.constant, 0, accuracy: 0.001)
        XCTAssertEqual(unten.constant, -(AssemblageTheme.margin + 14), accuracy: 0.001)
        XCTAssertEqual(pille.frame.height, 32, accuracy: 0.5)
        XCTAssertTrue(pille.isHidden)
    }

    func testDerHinweisRueckrufFeuertNichtZweimalMitDemselbenText() throws {
        let canvas = makeCanvas()
        let fenster = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        fenster.contentView?.addSubview(canvas)
        canvas.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        canvas.selectedLayerID = canvas.documentForTesting.layers[0].id
        var meldungen: [String?] = []
        canvas.onAlignmentHintChange = { meldungen.append($0) }

        canvas.mouseDown(with: try ereignis(.leftMouseDown, x: 250, y: 250, canvas: canvas, fenster: fenster))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, x: 300, y: 296, canvas: canvas, fenster: fenster))
        canvas.mouseDragged(with: try ereignis(.leftMouseDragged, x: 300, y: 296, canvas: canvas, fenster: fenster))

        XCTAssertEqual(meldungen.count, 1)
        XCTAssertEqual(meldungen.first ?? nil, "Quadrat")
    }

    private func makeCanvas() -> CanvasView {
        let ebene = Layer(
            name: "Form",
            transform: Transform2D(x: 200, y: 200),
            content: .shape(
                ShapeLayerContent(kind: .rectangle, size: Size(width: 100, height: 100))
            )
        )
        let document = AssemblageModel.Document(
            canvas: CanvasSize(width: 400, height: 400),
            layers: [ebene]
        )
        return CanvasView(
            document: document,
            images: ImageStore(resources: DocumentResources())
        )
    }

    private func ereignis(
        _ typ: NSEvent.EventType,
        x: Double,
        y: Double,
        canvas: CanvasView,
        fenster: NSWindow
    ) throws -> NSEvent {
        let inView = NSPoint(x: x, y: Double(canvas.bounds.height) - y)
        let inWindow = canvas.convert(inView, to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: typ,
            location: inWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: fenster.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}
