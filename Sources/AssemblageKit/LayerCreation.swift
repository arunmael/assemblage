import Foundation
import AssemblageModel

/// Was sich einfügen lässt (Plan 5.6, 5.7).
enum NewLayerKind: Equatable, CaseIterable {
    case text
    case rectangle
    case roundedRectangle
    case ellipse

    /// Beschriftung für Menü und Werkzeugleiste.
    var localizedName: String {
        switch self {
        case .text: "Text"
        case .rectangle: "Rechteck"
        case .roundedRectangle: "Abgerundetes Rechteck"
        case .ellipse: "Ellipse"
        }
    }

    /// Name des Undo-Schritts.
    var undoActionName: String { "\(localizedName) einfügen" }
}

@MainActor
enum LayerCreation {

    /// Baut die neue Ebene, passend zur Leinwandgrösse und versetzt gegen
    /// bereits vorhandene.
    static func makeLayer(
        _ kind: NewLayerKind,
        canvas: CanvasSize,
        existingLayers: [Layer]
    ) -> Layer {
        let transform = initialTransform(canvas: canvas, existingLayers: existingLayers)

        switch kind {
        case .text:
            // Sechs Prozent der kurzen Leinwandseite bleiben auf kleinen
            // Formaten handlich und sind auf einem A4-Poster noch gut sichtbar.
            let fontSize = max(min(canvas.width, canvas.height) * 0.06, 1)
            return Layer(
                name: kind.localizedName,
                transform: transform,
                content: .text(TextLayerContent(
                    string: "Text eingeben",
                    fontSize: fontSize,
                    colorHex: "#1F2937",
                    alignment: .center
                ))
            )

        case .rectangle:
            return makeShapeLayer(kind, shapeKind: .rectangle, canvas: canvas, transform: transform)
        case .roundedRectangle:
            return makeShapeLayer(kind, shapeKind: .roundedRectangle, canvas: canvas, transform: transform)
        case .ellipse:
            return makeShapeLayer(kind, shapeKind: .ellipse, canvas: canvas, transform: transform)
        }
    }

    private static func makeShapeLayer(
        _ kind: NewLayerKind,
        shapeKind: ShapeKind,
        canvas: CanvasSize,
        transform: Transform2D
    ) -> Layer {
        let shortSide = max(min(canvas.width, canvas.height), 1)
        let size = Size(width: shortSide * 0.4, height: shortSide * 0.24)
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
