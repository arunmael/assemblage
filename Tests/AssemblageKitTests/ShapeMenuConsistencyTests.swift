import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

@MainActor
final class ShapeMenuConsistencyTests: XCTestCase {

    func testJedeVorlageHatEinePassendeEinfuegeart() {
        for template in ShapeTemplate.allCases {
            let kind = ShapeKind(rawValue: template.rawValue)
            XCTAssertNotNil(kind, "Für \(template.rawValue) fehlt ein ShapeKind")
            XCTAssertTrue(
                NewLayerKind.allCases.contains { $0.shapeKind == kind },
                "Für \(template.rawValue) fehlt ein NewLayerKind"
            )
        }


        let templateKinds = Set(ShapeTemplate.allCases.compactMap {
            ShapeKind(rawValue: $0.rawValue)
        })
        let insertionTemplateKinds = Set(NewLayerKind.allCases.compactMap(\.shapeKind).filter {
            $0.template != nil
        })
        XCTAssertEqual(insertionTemplateKinds, templateKinds)
    }

    func testWerkzeugleistenMenuesSindVollstaendigVerdrahtet() throws {
        let document = AssemblageDocument()
        document.makeWindowControllers()
        let windowController = try XCTUnwrap(
            document.windowControllers.first as? DocumentWindowController
        )
        let toolbar = ToolbarController(
            state: document.state,
            canvasViewController: CanvasViewController(state: document.state),
            commandTarget: windowController
        )
        let row = toolbar.buildFloatingToolbarRow()
        let popups = popupButtons(in: row)
        let shapeMenu = try XCTUnwrap(popups.first { $0.toolTip == "Form" }?.menu)
        let gridMenu = try XCTUnwrap(popups.first { $0.toolTip == "Raster" }?.menu)

        let shapeItems = shapeMenu.items.filter {
            $0.action == #selector(DocumentWindowController.insertShapeFromMenu(_:))
        }
        XCTAssertGreaterThanOrEqual(shapeItems.count, 30)
        for item in shapeItems {
            XCTAssertNotNil(item.representedObject as? NewLayerKind, item.title)
            XCTAssertNotNil(item.target, item.title)
        }

        let gridItems = gridMenu.items.filter {
            $0.action == #selector(DocumentWindowController.applyTemplateFromMenu(_:))
        }
        XCTAssertGreaterThanOrEqual(gridItems.count, 10)
        for item in gridItems {
            XCTAssertNotNil(item.representedObject as? CollageTemplate, item.title)
            XCTAssertNotNil(item.target, item.title)
        }
    }

    private func popupButtons(in view: NSView) -> [NSPopUpButton] {
        view.subviews.flatMap { child in
            (child as? NSPopUpButton).map { [$0] } ?? popupButtons(in: child)
        }
    }
}
