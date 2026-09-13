import Foundation
import AssemblageModel

@MainActor
enum DrawingLayerCommand {

    static let defaultName = "Zeichnung"

    @discardableResult
    static func insertEmptyLayer(
        into state: DocumentState,
        strokeColorHex: String = "#1D3557",
        strokeWidth: Double = 6.0
    ) -> UUID? {
        guard let owner = state.owner,
              strokeWidth.isFinite
        else { return nil }

        let canvas = state.document.canvas
        guard canvas.width.isFinite, canvas.height.isFinite,
              canvas.width > 0, canvas.height > 0
        else { return nil }

        let ebene = Layer(
            name: defaultName,
            transform: Transform2D(x: canvas.width / 2, y: canvas.height / 2),
            content: .shape(ShapeLayerContent(
                kind: .freehand,
                size: canvas,
                fillColorHex: "#00000000",
                strokeColorHex: strokeColorHex,
                strokeWidth: strokeWidth,
                path: VectorPath()
            ))
        )
        let index = LayerInsertion.indexAboveSelection(in: state)
        owner.modify("Leere Ebene einfügen") { dokument in
            _ = try? dokument.addLayer(ebene, at: index)
        }
        state.selectedLayerID = ebene.id
        return ebene.id
    }
}
