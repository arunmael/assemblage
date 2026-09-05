import Foundation
import AssemblageModel

/// Was sich einfügen lässt (Plan 5.6, 5.7).
enum NewLayerKind: Equatable, CaseIterable {
    case text
    case rectangle
    case roundedRectangle
    case ellipse
    case triangle
    case pentagon
    case hexagon
    case star
    case heart
    case arrow
    case speechBubble
    case diamond
    case cross
    case octagon
    case rightTriangle
    case parallelogram
    case trapezoid
    case crescent
    case lightningBolt
    case cloud
    case shield

    /// Beschriftung für Menü und Werkzeugleiste.
    var localizedName: String {
        switch self {
        case .text: "Text"
        case .rectangle: "Rechteck"
        case .roundedRectangle: "Abgerundetes Rechteck"
        case .ellipse: "Ellipse"
        case .triangle: "Dreieck"
        case .pentagon: "Fünfeck"
        case .hexagon: "Sechseck"
        case .star: "Stern"
        case .heart: "Herz"
        case .arrow: "Pfeil"
        case .speechBubble: "Sprechblase"
        case .diamond: "Raute"
        case .cross: "Kreuz"
        case .octagon: "Achteck"
        case .rightTriangle: "Rechtwinkliges Dreieck"
        case .parallelogram: "Parallelogramm"
        case .trapezoid: "Trapez"
        case .crescent: "Sichel"
        case .lightningBolt: "Blitz"
        case .cloud: "Wolke"
        case .shield: "Schild"
        }
    }

    /// Name des Undo-Schritts.
    var undoActionName: String { "\(localizedName) einfügen" }

    /// Die Form hinter dieser Einfügeart — `nil` bei Text.
    var shapeKind: ShapeKind? {
        switch self {
        case .text: nil
        case .rectangle: .rectangle
        case .roundedRectangle: .roundedRectangle
        case .ellipse: .ellipse
        case .triangle: .triangle
        case .pentagon: .pentagon
        case .hexagon: .hexagon
        case .star: .star
        case .heart: .heart
        case .arrow: .arrow
        case .speechBubble: .speechBubble
        case .diamond: .diamond
        case .cross: .cross
        case .octagon: .octagon
        case .rightTriangle: .rightTriangle
        case .parallelogram: .parallelogram
        case .trapezoid: .trapezoid
        case .crescent: .crescent
        case .lightningBolt: .lightningBolt
        case .cloud: .cloud
        case .shield: .shield
        }
    }
}

@MainActor
enum LayerCreation {

    static func makeLayer(_ kind: NewLayerKind, canvas: CanvasSize, existingLayers: [Layer]) -> Layer {
        let transform = initialTransform(canvas: canvas, existingLayers: existingLayers)

        switch kind {
        case .text:
            let fontSize = max(min(canvas.width, canvas.height) * 0.06, 1)
            return Layer(
                name: kind.localizedName,
                transform: transform,
                content: .text(TextLayerContent(
                    string: "Text eingeben", fontSize: fontSize,
                    colorHex: "#1F2937", alignment: .center
                ))
            )

        default:
            // Falls kein gültiger ShapeKind ermittelt werden kann, weichen wir auf ein Rechteck aus.
            let shape = kind.shapeKind ?? .rectangle
            return makeShapeLayer(kind, shapeKind: shape, canvas: canvas, transform: transform)
        }
    }

    private static func makeShapeLayer(
        _ kind: NewLayerKind, shapeKind: ShapeKind, canvas: CanvasSize, transform: Transform2D
    ) -> Layer {
        let shortSide = max(min(canvas.width, canvas.height), 1)
        let size: Size

        switch shapeKind {
        case .triangle, .pentagon, .hexagon, .star, .heart,
             .diamond, .octagon, .rightTriangle, .crescent, .lightningBolt, .shield:
            // In ein breitgezogenes Rechteck gepresst wirken diese Formen verzerrt,
            // weil sie um einen Mittelpunkt herum gedacht sind.
            let side = shortSide * 0.32
            size = Size(width: side, height: side)
        default:
            size = Size(width: shortSide * 0.4, height: shortSide * 0.24)
        }

        return Layer(
            name: kind.localizedName,
            transform: transform,
            content: .shape(ShapeLayerContent(
                kind: shapeKind,
                size: size,
                cornerRadius: shapeKind == .roundedRectangle ? size.height * 0.12 : 0,
                fillColorHex: "#4F7CAC"
            ))
        )
    }

    /// Fügt sie zuoberst ein und wählt sie aus.
    static func insert(_ kind: NewLayerKind, into state: DocumentState) {
        guard let owner = state.owner else { return }
        let layer = makeLayer(
            kind,
            canvas: state.document.canvas,
            existingLayers: state.document.layers
        )
        owner.modify(kind.undoActionName) { document in
            _ = try? document.addLayer(layer)
        }
        state.selectedLayerID = layer.id
    }

    // MARK: - Platzierung

    /// Die erste Ebene liegt exakt mittig. Weitere Ebenen suchen vom Zentrum
    /// aus den nächsten freien Rasterplatz. Anders als die Import-Kaskade
    /// funktioniert das auch über mehrere einzelne Einfügebefehle hinweg,
    /// weil die Positionen der bereits vorhandenen Ebenen einbezogen werden.
    private static func initialTransform(
        canvas: CanvasSize,
        existingLayers: [Layer]
    ) -> Transform2D {
        let centerX = canvas.width / 2
        let centerY = canvas.height / 2
        let step = max(min(canvas.width, canvas.height) * 0.025, 1)

        func isFree(x: Double, y: Double) -> Bool {
            !existingLayers.contains {
                abs($0.transform.x - x) < 0.001 && abs($0.transform.y - y) < 0.001
            }
        }

        if isFree(x: centerX, y: centerY) {
            return Transform2D(x: centerX, y: centerY)
        }

        // Quadratische Ringe halten die Kaskade kompakt und bieten pro Ring
        // acht neue Positionen, ohne nach wenigen Ebenen zum Zentrum
        // zurückzuspringen.
        for ring in 1...1_000 {
            let distance = Double(ring) * step
            let offsets = [
                (distance, distance), (0, distance), (-distance, distance),
                (-distance, 0), (-distance, -distance), (0, -distance),
                (distance, -distance), (distance, 0)
            ]
            if let offset = offsets.first(where: {
                isFree(x: centerX + $0.0, y: centerY + $0.1)
            }) {
                return Transform2D(x: centerX + offset.0, y: centerY + offset.1)
            }
        }

        // Nur bei mehr als 8001 identisch zentrierten Ebenen erreichbar.
        return Transform2D(x: centerX + step, y: centerY + step)
    }
}
