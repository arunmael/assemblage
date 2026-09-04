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
}
