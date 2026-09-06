import XCTest
import AppKit
@testable import AssemblageKit

@MainActor
final class UndoBarLayoutTests: XCTestCase {

    func testAlleKnöpfeSindVertikalInDerPilleZentriert() throws {
        let document = AssemblageDocument()
        document.makeWindowControllers()
        let windowController = try XCTUnwrap(
            document.windowControllers.first as? DocumentWindowController
        )
        let canvas = CanvasViewController(state: document.state)
        let toolbar = ToolbarController(
            state: document.state,
            canvasViewController: canvas,
            commandTarget: windowController
        )
        let panel = toolbar.buildUndoBar()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 44))
        host.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            panel.topAnchor.constraint(equalTo: host.topAnchor),
            panel.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        host.layoutSubtreeIfNeeded()

        let knöpfe = buttons(in: panel)
        XCTAssertEqual(knöpfe.count, 4)
        let sichtbareKnöpfe = knöpfe.filter { !$0.isHidden && !$0.ancestorsContainHiddenView }
        XCTAssertEqual(sichtbareKnöpfe.count, 3)
        for button in sichtbareKnöpfe {
            let frame = button.convert(button.bounds, to: panel)
            XCTAssertEqual(frame.midY, panel.bounds.midY, accuracy: 0.5)
        }
    }

    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { child in
            (child as? NSButton).map { [$0] } ?? buttons(in: child)
        }
    }
}

private extension NSView {
    var ancestorsContainHiddenView: Bool {
        var ancestor = superview
        while let view = ancestor {
            if view.isHidden { return true }
            ancestor = view.superview
        }
        return false
    }
}
