import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// Formvorlagen einfügen (aus missing.md).
@MainActor
final class ShapeTemplateInsertionTests: XCTestCase {

    private func vorbereitetesDokument() -> AssemblageDocument {
        let document = AssemblageDocument()
        document.undoManager = UndoManager()
        document.modify("Vorbereiten") { $0.canvas = CanvasSize(width: 800, height: 600) }
        return document
    }

    /// Jede Einfügeart muss zu einer Ebene führen. Ein vergessener Fall in
    /// `makeLayer` würde sonst eine stumme Menüzeile ergeben.
    func testEveryKindInsertsALayer() {
        for art in NewLayerKind.allCases {
            let document = vorbereitetesDokument()
            LayerCreation.insert(art, into: document.state)

            XCTAssertEqual(document.state.document.layers.count, 1, "\(art) hat nichts eingefügt")
            XCTAssertEqual(document.state.document.layers.first?.name, art.localizedName)
            XCTAssertNotNil(document.state.selectedLayerID, "\(art) müsste ausgewählt sein")
        }
    }

    /// Die Einfügeart und die Form im Dokument dürfen nicht auseinanderfallen —
    /// „Herz einfügen" darf kein Rechteck ergeben.
    func testShapeKindMatchesTheMenuEntry() {
        for art in NewLayerKind.allCases {
            guard let erwartet = art.shapeKind else { continue }
            let document = vorbereitetesDokument()
            LayerCreation.insert(art, into: document.state)

            guard case .shape(let form)? = document.state.document.layers.first?.content else {
                return XCTFail("\(art) hat keine Formebene ergeben")
            }
            XCTAssertEqual(form.kind, erwartet)
        }
    }

    /// Um einen Mittelpunkt gedachte Formen werden quadratisch eingefügt.
    /// In ein breitgezogenes Rechteck gepresst sähen sie verzerrt aus.
    func testCentredShapesAreInsertedSquare() {
        for art in [NewLayerKind.triangle, .pentagon, .hexagon, .star, .heart,
                    .diamond, .octagon, .rightTriangle, .crescent, .lightningBolt, .shield] {
            let document = vorbereitetesDokument()
            LayerCreation.insert(art, into: document.state)

            guard case .shape(let form)? = document.state.document.layers.first?.content else {
                return XCTFail("\(art) hat keine Formebene ergeben")
            }
            XCTAssertEqual(form.size.width, form.size.height, accuracy: 0.001, "\(art)")
        }
    }

    /// Die drei Grundformen und die beiden gerichteten Vorlagen bleiben breit.
    func testWideShapesStayWide() {
        for art in [NewLayerKind.rectangle, .ellipse, .arrow, .speechBubble,
                    .parallelogram, .trapezoid, .cloud] {
            let document = vorbereitetesDokument()
            LayerCreation.insert(art, into: document.state)

            guard case .shape(let form)? = document.state.document.layers.first?.content else {
                return XCTFail("\(art) hat keine Formebene ergeben")
            }
            XCTAssertGreaterThan(form.size.width, form.size.height, "\(art)")
        }
    }

    /// Einfügen ist ein Undo-Schritt mit sprechendem Namen.
    func testInsertionIsUndoable() {
        let document = vorbereitetesDokument()
        document.undoManager?.removeAllActions()

        LayerCreation.insert(.star, into: document.state)
        XCTAssertEqual(document.state.document.layers.count, 1)

        document.undoManager?.undo()
        XCTAssertTrue(document.state.document.layers.isEmpty, "Widerrufen müsste die Ebene entfernen")
    }
}
