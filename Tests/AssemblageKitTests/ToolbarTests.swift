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
        XCTAssertTrue(ToolSelection.isAvailable(.freehand, forSelected: nil))
        XCTAssertFalse(ToolSelection.isAvailable(.crop, forSelected: nil))
        XCTAssertFalse(ToolSelection.isAvailable(.brush, forSelected: nil))
        XCTAssertFalse(ToolSelection.isAvailable(.lasso, forSelected: nil))
        XCTAssertFalse(ToolSelection.isAvailable(.paint, forSelected: nil))
        XCTAssertFalse(ToolSelection.isAvailable(.distort, forSelected: nil))
    }

    func testImageToolsAreUnavailableForTextAndShapeLayers() {
        for layer in [textLayer, shapeLayer] {
            XCTAssertTrue(ToolSelection.isAvailable(.select, forSelected: layer))
            XCTAssertTrue(ToolSelection.isAvailable(.freehand, forSelected: layer))
            XCTAssertFalse(ToolSelection.isAvailable(.crop, forSelected: layer))
            XCTAssertFalse(ToolSelection.isAvailable(.brush, forSelected: layer))
            XCTAssertFalse(ToolSelection.isAvailable(.lasso, forSelected: layer))
            XCTAssertFalse(ToolSelection.isAvailable(.paint, forSelected: layer))
            XCTAssertTrue(ToolSelection.isAvailable(.distort, forSelected: layer))
        }
    }

    func testAllToolsAreAvailableForImageLayer() {
        for tool in [CanvasTool.select, .crop, .brush, .lasso, .paint, .freehand, .distort] {
            XCTAssertTrue(ToolSelection.isAvailable(tool, forSelected: imageLayer))
        }
    }

    func testSecondClickOnActiveToolReturnsToSelect() {
        XCTAssertEqual(ToolSelection.toggled(.crop, current: .crop), .select)
        XCTAssertEqual(ToolSelection.toggled(.brush, current: .brush), .select)
        XCTAssertEqual(ToolSelection.toggled(.lasso, current: .lasso), .select)
        XCTAssertEqual(ToolSelection.toggled(.distort, current: .distort), .select)
        XCTAssertEqual(ToolSelection.toggled(.select, current: .select), .select)
    }

    func testClickOnAnotherToolSwitchesToIt() {
        XCTAssertEqual(ToolSelection.toggled(.crop, current: .select), .crop)
        XCTAssertEqual(ToolSelection.toggled(.brush, current: .crop), .brush)
        XCTAssertEqual(ToolSelection.toggled(.lasso, current: .brush), .lasso)
        XCTAssertEqual(ToolSelection.toggled(.select, current: .brush), .select)
        XCTAssertEqual(ToolSelection.toggled(.distort, current: .crop), .distort)
    }

    func testBrushFallsBackToSelectWhenSelectionChangesToText() {
        XCTAssertEqual(
            ToolSelection.adjusted(.brush, forSelected: textLayer),
            .select
        )
    }

    func testLassoFallsBackToSelectWhenSelectionChangesToText() {
        XCTAssertEqual(ToolSelection.adjusted(.lasso, forSelected: textLayer), .select)
    }

    func testActiveToolFallsBackToSelectWhenSelectionIsCleared() {
        XCTAssertEqual(ToolSelection.adjusted(.crop, forSelected: nil), .select)
        XCTAssertEqual(ToolSelection.adjusted(.brush, forSelected: nil), .select)
        XCTAssertEqual(ToolSelection.adjusted(.lasso, forSelected: nil), .select)
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
        XCTAssertEqual(ToolSelection.adjusted(.lasso, forSelected: imageLayer), .lasso)
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

        // Genug Schritte für die Obergrenze in 20-Prozent-Schritten.
        for _ in 0..<120 { canvas.zoomIn() }
        XCTAssertFalse(toolbar.validateMenuItem(NSMenuItem(
            title: "Vergrössern", action: NSSelectorFromString("zoomIn:"), keyEquivalent: ""
        )))
        for _ in 0..<200 { canvas.zoomOut() }
        XCTAssertFalse(toolbar.validateMenuItem(NSMenuItem(
            title: "Verkleinern", action: NSSelectorFromString("zoomOut:"), keyEquivalent: ""
        )))
    }

    /// Regler-Werkzeuge dürfen über die gekoppelte Inspector-Oberkante
    /// keinen freien Höhenplatz in die Werkzeugzeile zurückdrücken. Nur der
    /// tatsächlich vom Fenster vergebene Frame deckt diese Constraint-Kette
    /// ab; die intrinsische Wunschgrösse allein würde den Fehler übersehen.
    func testFloatingToolbarRowKeepsItsHeightForEveryTool() throws {
        for tool in CanvasTool.allToolbarCases {
            let document = AssemblageDocument()
            document.modify("Vorbereiten") { _ = try? $0.addLayer(imageLayer) }
            document.state.selectedLayerID = imageLayer.id
            document.makeWindowControllers()

            let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
            let window = try XCTUnwrap(controller.window)
            window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 820), display: false)
            let shell = try XCTUnwrap(
                window.contentViewController as? WindowDropZoneViewController
            )
            let stage = try XCTUnwrap(shell.children.first as? DocumentStageViewController)
            let row = try XCTUnwrap(
                stage.view.subviews.compactMap { $0 as? NSStackView }.first,
                "die schwebende Werkzeugzeile muss direkt in der Bühne liegen"
            )

            stage.toolbarController.simulateToolTapForTesting(tool)
            window.contentView?.layoutSubtreeIfNeeded()
            // 58 pt: Der aktive Werkzeugknopf wird 30 % grösser gezeichnet
            // (38 → 49.4 pt, siehe `ToolbarController.activeToolScale`) und
            // gibt damit die Zeilenhöhe vor.
            XCTAssertEqual(row.frame.height, 58, accuracy: 0.5, "falsche Höhe bei \(tool)")
        }
    }

    /// Der kurze Lasso-Umschalter darf nicht als schmaler Streifen über dem
    /// Inspector stehen. Gemessen wird nach echtem Fensterlayout, weil erst
    /// Auto Layout aus Inhaltsbreite und relationaler Kante den Frame bildet.
    func testLassoSettingsBarIsAtLeastAsWideAsInspectorAndRightAligned() throws {
        let document = AssemblageDocument()
        document.modify("Vorbereiten") { _ = try? $0.addLayer(imageLayer) }
        document.state.selectedLayerID = imageLayer.id
        document.makeWindowControllers()

        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 820), display: false)
        let shell = try XCTUnwrap(window.contentViewController as? WindowDropZoneViewController)
        let stage = try XCTUnwrap(shell.children.first as? DocumentStageViewController)

        stage.toolbarController.simulateToolTapForTesting(.lasso)
        window.contentView?.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let inspectorPanel = try XCTUnwrap(stage.inspectorPanel)
        let settingsBar = try XCTUnwrap(
            stage.settingsBar,
            "der sichtbare Lasso-Einstellungsstreifen muss über dem Inspector liegen"
        )

        XCTAssertGreaterThanOrEqual(
            settingsBar.frame.width, inspectorPanel.frame.width,
            "der Lasso-Streifen darf nicht schmaler als das Eigenschaften-Panel sein"
        )
        XCTAssertEqual(
            settingsBar.frame.maxX, inspectorPanel.frame.maxX, accuracy: 0.5,
            "Einstellungsstreifen und Eigenschaften-Panel müssen rechts bündig sein"
        )
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

        _ = toolbar.select(.lasso)
        XCTAssertEqual(document.state.currentTool, .lasso)

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
        XCTAssertFalse(toolbar.select(.lasso), "Formebenen können nicht mit dem Lasso maskiert werden")
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

    func testLassoModeIsReportedOnChange() {
        let bild = Layer(name: "Foto", content: .image(ImageLayerContent(originalFileReference: "originals/a.png")))
        let (document, toolbar) = aufbau(selecting: bild)

        XCTAssertEqual(document.state.lassoMode, .hide)
        toolbar.setLassoModeForTesting(.reveal)
        XCTAssertEqual(document.state.lassoMode, .reveal)
    }

    /// Dieselbe Meldung wie beim Pinsel, für den Farbpinsel (aus
    /// Anpassungen.md).
    func testPaintBrushSettingsAreReportedOnChange() {
        let bild = Layer(name: "Foto", content: .image(ImageLayerContent(originalFileReference: "originals/a.png")))
        let (document, toolbar) = aufbau(selecting: bild)

        XCTAssertEqual(document.state.paintBrushSettings.diameter, 30, accuracy: 0.001)
        XCTAssertEqual(document.state.paintBrushSettings.colorHex, "#000000")

        toolbar.setPaintBrushForTesting(PaintBrush(diameter: 50, hardness: 1, colorHex: "#00FF00", opacity: 0.8))
        XCTAssertEqual(document.state.paintBrushSettings.diameter, 50, accuracy: 0.001)
        XCTAssertEqual(document.state.paintBrushSettings.colorHex, "#00FF00")
        XCTAssertEqual(document.state.paintBrushSettings.opacity, 0.8, accuracy: 0.001)
    }
}
