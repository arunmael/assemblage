import XCTest
@testable import AssemblageKit
@testable import AssemblageModel

/// Die Werkzeugauswahl ohne AppKit-Darstellung.
///
/// Eine `NSToolbar` lässt sich nicht verlässlich automatisiert bedienen. Die
/// Regeln für Verfügbarkeit, Umschalten und Auswahlwechsel sind deshalb hier
/// getrennt von den Knöpfen geprüft.
@MainActor
final class ToolbarTests: XCTestCase {

    private let imageLayer = Layer(
        name: "Foto",
        content: .image(ImageLayerContent(originalFileReference: "originals/foto.png"))
    )
    private let textLayer = Layer(
        name: "Text",
        content: .text(TextLayerContent(string: "Titel"))
    )
    private let shapeLayer = Layer(
        name: "Form",
        content: .shape(ShapeLayerContent(
            kind: .rectangle,
            size: Size(width: 100, height: 80)
        ))
    )

    func testAvailabilityWithoutSelection() {
        XCTAssertTrue(ToolSelection.isAvailable(.select, forSelected: nil))
        XCTAssertFalse(ToolSelection.isAvailable(.crop, forSelected: nil))
        XCTAssertFalse(ToolSelection.isAvailable(.brush, forSelected: nil))
        XCTAssertFalse(ToolSelection.isAvailable(.distort, forSelected: nil))
    }

    func testImageToolsAreUnavailableForTextAndShapeLayers() {
        for layer in [textLayer, shapeLayer] {
            XCTAssertTrue(ToolSelection.isAvailable(.select, forSelected: layer))
            XCTAssertFalse(ToolSelection.isAvailable(.crop, forSelected: layer))
            XCTAssertFalse(ToolSelection.isAvailable(.brush, forSelected: layer))
            XCTAssertTrue(ToolSelection.isAvailable(.distort, forSelected: layer))
        }
    }

    func testAllToolsAreAvailableForImageLayer() {
        for tool in [CanvasTool.select, .crop, .brush, .distort] {
            XCTAssertTrue(ToolSelection.isAvailable(tool, forSelected: imageLayer))
        }
    }

    func testSecondClickOnActiveToolReturnsToSelect() {
        XCTAssertEqual(ToolSelection.toggled(.crop, current: .crop), .select)
        XCTAssertEqual(ToolSelection.toggled(.brush, current: .brush), .select)
        XCTAssertEqual(ToolSelection.toggled(.distort, current: .distort), .select)
        XCTAssertEqual(ToolSelection.toggled(.select, current: .select), .select)
    }

    func testClickOnAnotherToolSwitchesToIt() {
        XCTAssertEqual(ToolSelection.toggled(.crop, current: .select), .crop)
        XCTAssertEqual(ToolSelection.toggled(.brush, current: .crop), .brush)
        XCTAssertEqual(ToolSelection.toggled(.select, current: .brush), .select)
        XCTAssertEqual(ToolSelection.toggled(.distort, current: .crop), .distort)
    }

    func testBrushFallsBackToSelectWhenSelectionChangesToText() {
        XCTAssertEqual(
            ToolSelection.adjusted(.brush, forSelected: textLayer),
            .select
        )
    }

    func testActiveToolFallsBackToSelectWhenSelectionIsCleared() {
        XCTAssertEqual(ToolSelection.adjusted(.crop, forSelected: nil), .select)
        XCTAssertEqual(ToolSelection.adjusted(.brush, forSelected: nil), .select)
    }

    func testAvailableActiveToolSurvivesImageSelection() {
        XCTAssertEqual(
            ToolSelection.adjusted(.crop, forSelected: imageLayer),
            .crop
        )
        XCTAssertEqual(
            ToolSelection.adjusted(.brush, forSelected: imageLayer),
            .brush
        )
    }

    func testUnavailableKeyboardToolIsNotReportedAsHandled() {
        let document = AssemblageDocument()
        let canvas = CanvasViewController(state: document.state)
        let windowController = DocumentWindowController()
        let toolbar = ToolbarController(
            state: document.state,
            canvasViewController: canvas,
            commandTarget: windowController
        )

        XCTAssertFalse(toolbar.select(.brush))
    }

    func testToolbarZoomMenuDisablesCommandsAtLimits() {
        let document = AssemblageDocument()
        let canvas = CanvasViewController(state: document.state)
        let toolbar = ToolbarController(
            state: document.state,
            canvasViewController: canvas,
            commandTarget: DocumentWindowController()
        )

        for _ in 0..<20 { canvas.zoomIn() }
        XCTAssertFalse(toolbar.validateMenuItem(NSMenuItem(
            title: "Vergrössern", action: NSSelectorFromString("zoomIn:"), keyEquivalent: ""
        )))
        for _ in 0..<40 { canvas.zoomOut() }
        XCTAssertFalse(toolbar.validateMenuItem(NSMenuItem(
            title: "Verkleinern", action: NSSelectorFromString("zoomOut:"), keyEquivalent: ""
        )))
    }
}

/// Das aktive Werkzeug und die Pinsel-Einstellungen müssen im
/// `DocumentState` ankommen (aus Anpassungen.md: „Die Spezifikation des
/// Werkzeugs sollte im Inspector ersichtlich sein"). Der Inspector selbst
/// ist SwiftUI und lässt sich hier nicht rendern — geprüft wird deshalb die
/// Zustandsspiegelung, die er liest.
@MainActor
final class ToolStateReportingTests: XCTestCase {

    private func aufbau(selecting layer: Layer? = nil) -> (AssemblageDocument, ToolbarController) {
        let document = AssemblageDocument()
        if let layer {
            document.modify("Vorbereiten") { _ = try? $0.addLayer(layer) }
            document.state.selectedLayerID = layer.id
        }
        let canvas = CanvasViewController(state: document.state)
        let toolbar = ToolbarController(
            state: document.state,
            canvasViewController: canvas,
            commandTarget: DocumentWindowController()
        )
        return (document, toolbar)
    }

    /// Startzustand: „Auswählen", ohne dass ein Werkzeug erst umgeschaltet
    /// werden musste.
    func testInitialToolIsSelect() {
        let (document, _) = aufbau()
        XCTAssertEqual(document.state.currentTool, .select)
    }

    func testSwitchingToolsUpdatesTheReportedTool() {
        let bild = Layer(name: "Foto", content: .image(ImageLayerContent(originalFileReference: "originals/a.png")))
        let (document, toolbar) = aufbau(selecting: bild)

        _ = toolbar.select(.crop)
        XCTAssertEqual(document.state.currentTool, .crop)

        _ = toolbar.select(.brush)
        XCTAssertEqual(document.state.currentTool, .brush)

        // Zurück zu „Auswählen": derselbe Weg, den ein zweiter Klick auf den
        // aktiven Knopf nimmt.
        _ = toolbar.select(.select)
        XCTAssertEqual(document.state.currentTool, .select)
    }

    /// Ein Werkzeug, das für die aktuelle Auswahl nicht verfügbar ist, darf
    /// den gemeldeten Zustand nicht verändern — sonst zeigte der Inspector
    /// ein Werkzeug an, das gar nicht aktiv wurde.
    func testUnavailableToolDoesNotChangeTheReportedTool() {
        let form = Layer(name: "Form", content: .shape(
            ShapeLayerContent(kind: .rectangle, size: Size(width: 10, height: 10))))
        let (document, toolbar) = aufbau(selecting: form)

        XCTAssertFalse(toolbar.select(.brush), "Formebenen können nicht bemalt werden")
        XCTAssertEqual(document.state.currentTool, .select)
    }

    func testBrushSettingsAreReportedOnChange() {
        let bild = Layer(name: "Foto", content: .image(ImageLayerContent(originalFileReference: "originals/a.png")))
        let (document, toolbar) = aufbau(selecting: bild)

        XCTAssertEqual(document.state.brushSettings.diameter, 60, accuracy: 0.001)
        XCTAssertEqual(document.state.brushSettings.hardness, 0.5, accuracy: 0.001)
        XCTAssertEqual(document.state.brushSettings.mode, .hide)

        toolbar.setBrushDiameterForTesting(120)
        XCTAssertEqual(document.state.brushSettings.diameter, 120, accuracy: 0.001)
    }
}
